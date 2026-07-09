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

// ============================================================================
// Durable AI agent workflows (imperative AgentContext API) — exercised through
// the REAL compiler-plugin codegen path against the shared Temporal dev server.
// The model is a scripted mock ai:ModelProvider so no credentials are needed.
// ============================================================================

import ballerina/ai;
import ballerina/jballerina.java;
import ballerina/workflow;

# Input for the agent workflows.
#
# + id - The workflow identifier
# + request - The user's request forwarded to the agent
type AgentStockInput record {|
    string id;
    string request;
|};

# Inventory-lookup tool exposed to the agent; runs as a durable activity.
#
# + item - Item to look up
# + return - Availability text, or an error
@workflow:Activity
function agentCheckStock(string item) returns string|error {
    return item + " is in stock";
}

// Scripted mock: first turn requests an agentCheckStock tool call; once a tool
// result is present in the conversation, produce the final answer from it.
isolated client class AgentMockModelProvider {
    *ai:ModelProvider;

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        if messages is ai:ChatMessage[] {
            foreach ai:ChatMessage message in messages {
                if message is ai:ChatFunctionMessage && message.name == "agentCheckStock" {
                    string? content = message.content;
                    return {role: ai:ASSISTANT, content: "Stock check result: " + (content ?: "")};
                }
            }
        }
        return {
            role: ai:ASSISTANT,
            toolCalls: [{name: "agentCheckStock", arguments: {"item": "laptop"}, id: "call-1"}]
        };
    }

    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.workflow.test.TestNatives",
        name: "mockGenerate"
    } external;
}

final AgentMockModelProvider agentMockModel = new;

# Prompt-driven durable agent: reasons over the initial request.
#
# + ctx - The agent context
# + input - The agent input
# + return - An error if the agent fails
@workflow:DurableAgent
function stockCheckAgent(workflow:AgentContext ctx, AgentStockInput input) returns error? {
    check ctx.registerActivities([agentCheckStock]);
    check ctx.runDurableAgent(input.request,
            systemPrompt = {role: "", instructions: "You are an inventory assistant. Use agentCheckStock for availability."},
            model = agentMockModel);
}

# Chat-driven durable agent: waits durably for the first chat event before reasoning.
#
# + ctx - The agent context
# + input - The agent input
# + events - The agent's chat event
# + return - An error if the agent fails
@workflow:DurableAgent
function chatDrivenStockAgent(workflow:AgentContext ctx, AgentStockInput input,
        record {| future<string> chat; |} events) returns error? {
    check ctx.registerActivities([agentCheckStock]);
    check ctx.runDurableAgent(systemPrompt = {role: "", instructions: "You are an inventory assistant. Use agentCheckStock for availability."},
            model = agentMockModel);
}

// Scripted conversation: turn 1 answers and re-arms the chat wait; subsequent
// turns echo the latest chat message and wait again, until the user says "bye".
isolated client class ConversationMockModelProvider {
    *ai:ModelProvider;

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        string? lastChat = ();
        if messages is ai:ChatMessage[] {
            foreach ai:ChatMessage message in messages {
                if message is ai:ChatFunctionMessage && message.name == "awaitEvent_chat" {
                    lastChat = message.content;
                }
            }
        }
        if lastChat is () {
            return {
                role: ai:ASSISTANT,
                content: "Turn 1 answer",
                toolCalls: [{name: "awaitEvent_chat", arguments: {}}]
            };
        }
        if lastChat.includes("bye") {
            return {
                role: ai:ASSISTANT,
                content: "Conversation ended",
                toolCalls: [{name: "endConversation", arguments: {}}]
            };
        }
        return {
            role: ai:ASSISTANT,
            content: "Echo: " + lastChat,
            toolCalls: [{name: "awaitEvent_chat", arguments: {}}]
        };
    }

    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.workflow.test.TestNatives",
        name: "mockGenerate"
    } external;
}

final ConversationMockModelProvider conversationMockModel = new;

# Multi-turn conversational agent (MULTI_EVENT interaction): the model answers
# each turn and re-arms the chat wait until the user says bye.
#
# + ctx - The agent context
# + input - The agent input
# + events - The agent's chat event
# + return - An error if the agent fails
@workflow:DurableAgent
function conversationalStockAgent(workflow:AgentContext ctx, AgentStockInput input,
        record {| future<string> chat; |} events) returns error? {
    check ctx.setInteraction(workflow:MULTI_EVENT, eventTimeout = {minutes: 5});
    check ctx.runDurableAgent(input.request,
            systemPrompt = {role: "", instructions: "Chat with the user until they say bye."},
            model = conversationMockModel);
}
