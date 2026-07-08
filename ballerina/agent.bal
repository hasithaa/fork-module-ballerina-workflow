// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com) All Rights Reserved.
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/jballerina.java;

// ============================================================================
// anydata mirrors of the ballerina/ai chat message types.
//
// `ai:ChatMessage` itself is not `anydata` because user/system message content
// may be an `ai:Prompt` object. Agent workflows only ever exchange string
// content, so the conversation history is kept in these plain-data mirrors —
// making it replay-safe workflow state that can cross the activity boundary —
// and converted to `ai:` types inside the `llmChat` activity.
// ============================================================================

# System message in an agent conversation.
public type AgentSystemMessage record {|
    # Role of the message
    "system" role = "system";
    # Content of the message
    string content;
|};

# User message in an agent conversation.
public type AgentUserMessage record {|
    # Role of the message
    "user" role = "user";
    # Content of the message
    string content;
|};

# A tool invocation requested by the model.
public type AgentFunctionCall record {|
    # Name of the tool function
    string name;
    # Arguments to pass to the tool, keyed by parameter name
    map<json>? arguments = {};
    # Identifier for the tool call
    string id?;
|};

# Assistant (model) message in an agent conversation.
public type AgentAssistantMessage record {|
    # Role of the message
    "assistant" role = "assistant";
    # Text content; nil when the model requested tool calls instead
    string? content = ();
    # An optional name for the participant
    string name?;
    # Tool calls requested by the model
    AgentFunctionCall[]? toolCalls = ();
|};

# Tool result message in an agent conversation.
public type AgentFunctionMessage record {|
    # Role of the message
    "function" role = "function";
    # Name of the tool that produced this result
    string name;
    # Tool output serialized as a string
    string? content = ();
    # Identifier correlating this result to the tool call
    string id?;
|};

# Any message in an agent conversation.
public type AgentChatMessage AgentSystemMessage|AgentUserMessage|AgentAssistantMessage|AgentFunctionMessage;

# Runs the durable agent ReAct loop. Called from `AgentContext.runDurableAgent`;
# not intended to be called directly.
#
# Conversation history is a workflow-local variable (replay-safe), and every LLM
# call and tool call goes through a durable activity.
#
# + ctxHandle - The native agent context handle
# + agentName - The agent's workflow type (keys the registered model provider)
# + config - The system prompt and reasoning limits
# + prompt - The initial user prompt, or "" to wait for the first chat event
# + toolDefs - The tool definitions advertised to the model
# + return - An error if the agent fails, otherwise nil
isolated function runAgentLoop(handle ctxHandle, string agentName, AgentRunConfig config, string prompt,
        ai:ChatCompletionFunctions[] toolDefs) returns error? {
    string[] toolNames = from ai:ChatCompletionFunctions def in toolDefs
        select def.name;

    AgentChatMessage[] history = [<AgentSystemMessage>{content: config.systemPrompt}];
    if prompt != "" {
        history.push(<AgentUserMessage>{content: prompt});
    } else {
        // No initial prompt: wait durably for one chat event, if the agent
        // declared one in its signature.
        string? chatMessage = check awaitAgentChatEvent(ctxHandle);
        if chatMessage is string {
            history.push(<AgentUserMessage>{content: chatMessage});
        }
    }

    int maxIterations = int:max(1, config.maxIterations);
    foreach int _ in 0 ..< maxIterations {
        AgentAssistantMessage assistant = check callAgentActivity("llmChat",
                {"agentName": agentName, "messages": history.toJson(), "tools": toolDefs.toJson()});
        history.push(assistant);

        AgentFunctionCall[]? toolCalls = assistant.toolCalls;
        if toolCalls is () || toolCalls.length() == 0 {
            check setAgentResponse(ctxHandle, assistant.content ?: "");
            return;
        }

        foreach AgentFunctionCall call in toolCalls {
            string output;
            if toolNames.indexOf(call.name) is () {
                output = string `Error: unknown tool '${call.name}'`;
            } else {
                map<anydata> args = {};
                map<json>? callArgs = call.arguments;
                if callArgs is map<json> {
                    foreach [string, json] [name, value] in callArgs.entries() {
                        args[name] = value;
                    }
                }
                anydata|error result = callAgentActivity(call.name, args);
                // Tool failures are fed back to the model as text so it can recover.
                output = result is error ? string `Error: ${result.message()}` : result.toJsonString();
            }
            AgentFunctionMessage functionMessage = {name: call.name, content: output};
            string? callId = call.id;
            if callId is string {
                functionMessage.id = callId;
            }
            history.push(functionMessage);
        }
    }
    return error(string `Agent exceeded the maximum number of iterations (${maxIterations})`);
}

# The built-in LLM chat activity. Executes one model call outside the workflow
# thread so that the non-deterministic LLM interaction is recorded in the
# workflow history and never re-executed on replay.
#
# + agentName - The agent's workflow type; keys the registered model provider
# + messages - Conversation history as JSON (`AgentChatMessage[]`)
# + tools - Tool definitions as JSON (`ai:ChatCompletionFunctions[]`)
# + return - The assistant's reply, or an error
@Activity
public isolated function llmChat(string agentName, json messages, json tools)
        returns AgentAssistantMessage|error {
    ai:ModelProvider model = check getAgentModel(agentName);
    AgentChatMessage[] history = check messages.cloneWithType();
    ai:ChatCompletionFunctions[] toolDefs = check tools.cloneWithType();

    ai:ChatMessage[] aiMessages = [];
    foreach AgentChatMessage message in history {
        aiMessages.push(check toAiMessage(message));
    }

    ai:ChatAssistantMessage reply = check model->chat(aiMessages, toolDefs);
    return reply.cloneWithType();
}

# The built-in structured-generation activity. Durably wraps
# `ai:ModelProvider->generate`, producing a value of the caller's expected type
# from a natural-language query.
#
# + agentName - The agent's workflow type; keys the registered model provider
# + query - The natural-language prompt describing what to generate
# + return - The generated value as `anydata` (coerced to the caller's type by
#            the dependent-typing path), or an error
@Activity
public isolated function generate(string agentName, string query) returns anydata|error {
    ai:ModelProvider model = check getAgentModel(agentName);
    ai:Prompt prompt = `${query}`;
    anydata result = check model->generate(prompt);
    return result;
}

// Converts a mirror message to the corresponding ballerina/ai message type.
isolated function toAiMessage(AgentChatMessage message) returns ai:ChatMessage|error {
    if message is AgentSystemMessage {
        return <ai:ChatSystemMessage>{role: ai:SYSTEM, content: message.content};
    }
    if message is AgentUserMessage {
        return <ai:ChatUserMessage>{role: ai:USER, content: message.content};
    }
    if message is AgentAssistantMessage {
        return message.cloneWithType(ai:ChatAssistantMessage);
    }
    return message.cloneWithType(ai:ChatFunctionMessage);
}

// ============================================================================
// Native bindings used by the agent loop
// ============================================================================

// Executes a registered agent tool (or the built-in llmChat) as a durable
// Temporal activity, resolving the activity type from the current workflow.
isolated function callAgentActivity(string name, map<anydata> args, typedesc<anydata> targetType = <>)
        returns targetType|error = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "callActivity"
} external;

// Waits durably for the agent's "chat" event, if declared in the signature.
// Returns nil when the agent declares no chat event.
isolated function awaitAgentChatEvent(handle nativeContext) returns string?|error = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "awaitChatEvent"
} external;

// Stores the agent's final textual response for later retrieval.
isolated function setAgentResponse(handle nativeContext, string response) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "setResponse"
} external;

// Looks up the model provider registered for an agent workflow type.
isolated function getAgentModel(string agentName) returns ai:ModelProvider|error = @java:Method {
    'class: "io.ballerina.lib.workflow.worker.WorkflowWorkerNative",
    name: "getAgentModel"
} external;

