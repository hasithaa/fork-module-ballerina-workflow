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

# Configuration for a durable agent run.
#
# + systemPrompt - Instructions that define the agent's role and behaviour
# + maxIterations - Maximum number of LLM reasoning iterations before the agent
#                   fails with an error
public type AgentRunConfig record {|
    string systemPrompt;
    int maxIterations = 16;
|};

# The execution context for a durable AI agent. Injected as the first parameter
# of a `@workflow:DurableAgent` function.
#
# Unlike `workflow:Context`, this context deliberately does not expose
# `callActivity`, `sleep`, or `awaitHumanTask`. Instead, tools and human tasks
# are registered declaratively and the durable ReAct loop is driven by
# `runDurableAgent`. Events declared in the agent function's signature are wired
# into the context implicitly.
public client class AgentContext {
    private handle nativeContext;

    # Creates an agent context wrapping the native handle. Called by the workflow
    # runtime; do not instantiate `AgentContext` directly.
    # + nativeContext - Native agent context handle from the workflow engine
    public isolated function init(handle nativeContext) {
        self.nativeContext = nativeContext;
    }

    # Registers `@workflow:Activity` functions as agent tools. Each tool becomes
    # a durable Temporal activity that the agent may invoke during reasoning.
    #
    # + tools - The `@workflow:Activity` functions to expose as tools
    # + return - An error if a tool cannot be registered, otherwise nil
    public isolated function registerActivities(function[] tools) returns error? {
        foreach function tool in tools {
            check recordAgentTool(self.nativeContext, tool, "activity");
        }
    }

    # Registers `@ai:AgentTool` functions as agent tools.
    #
    # + tools - The `@ai:AgentTool` functions to expose as tools
    # + return - An error if a tool cannot be registered, otherwise nil
    public isolated function registerAgentTools(function[] tools) returns error? {
        foreach function tool in tools {
            check recordAgentTool(self.nativeContext, tool, "aitool");
        }
    }

    # Registers a human task as an agent tool. When the agent invokes it, the task
    # is executed as a durable human interaction.
    #
    # + task - The human task function to expose as a tool
    # + return - An error if the task cannot be registered, otherwise nil
    public isolated function registerHumanTask(function task) returns error? {
        return recordAgentTool(self.nativeContext, task, "humantask");
    }

    # Runs the durable AI agent loop. Every LLM call and tool call is executed as
    # a durable Temporal activity, so the agent survives worker crashes and can
    # wait durably for events. This call may block for a long time; a durable
    # agent has no direct return value.
    #
    # + model - The model provider used for the agent's LLM calls
    # + config - The system prompt and reasoning limits
    # + prompt - The initial user prompt. When empty, the agent waits for the
    #            first `chat` event declared in the function signature
    # + return - An error if the agent fails, otherwise nil
    remote isolated function runDurableAgent(ai:ModelProvider model, AgentRunConfig config, string prompt = "")
            returns error? {
        registerAgentModelForContext(self.nativeContext, model);
        string agentName = getAgentWorkflowType(self.nativeContext);
        string toolDefsJson = check getAgentToolDefs(self.nativeContext);
        json toolDefs = check toolDefsJson.fromJsonString();
        ai:ChatCompletionFunctions[] defs = check toolDefs.cloneWithType();
        return runAgentLoop(self.nativeContext, agentName, config, prompt, defs);
    }
}

// ============================================================================
// Native bindings for AgentContext
// ============================================================================

isolated function recordAgentTool(handle nativeContext, function tool, string kind) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "recordTool"
} external;

isolated function getAgentToolDefs(handle nativeContext) returns string|error = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "getToolDefs"
} external;

isolated function getAgentWorkflowType(handle nativeContext) returns string = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "getWorkflowType"
} external;

isolated function registerAgentModelForContext(handle nativeContext, object {} model) = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "registerModel"
} external;
