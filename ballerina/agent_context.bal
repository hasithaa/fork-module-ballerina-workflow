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
# `callActivity`, `sleep`, or `awaitHumanTask`. Instead, capabilities are
# registered on the context and the agent decides when to use them inside the
# durable ReAct loop driven by `runDurableAgent`:
#
# - `registerActivities` — `@workflow:Activity` functions become tools that run
#   as durable Temporal activities
# - `registerTools` — `ai:ToolConfig` values or `@ai:AgentTool` functions become
#   tools executed through the built-in activity wrapper
# - `registerHumanTask` — a human task becomes a tool; when the agent invokes it,
#   a human-task sub-workflow starts and the agent suspends durably until a
#   person completes it
# - events declared in the agent function's signature become wait-tools; when the
#   agent invokes one, it suspends durably until that event arrives
public client class AgentContext {
    private handle nativeContext;

    # Creates an agent context wrapping the native handle. Called by the workflow
    # runtime; do not instantiate `AgentContext` directly.
    # + nativeContext - Native agent context handle from the workflow engine
    public isolated function init(handle nativeContext) {
        self.nativeContext = nativeContext;
    }

    # Registers `@workflow:Activity` functions as agent tools. Each tool runs as
    # a durable Temporal activity that the agent may invoke during reasoning.
    #
    # + tools - The `@workflow:Activity` functions to expose as tools
    # + return - An error if a tool cannot be registered, otherwise nil
    public isolated function registerActivities(function[] tools) returns error? {
        foreach function tool in tools {
            check recordActivityTool(self.nativeContext, tool);
        }
    }

    # Registers AI tools with the agent. Accepts `ai:ToolConfig` values or
    # functions annotated with `@ai:AgentTool` (normalized via the ai module's
    # tool plumbing). When the agent invokes one of these tools, the call is
    # executed durably through the built-in activity wrapper.
    #
    # + tools - The tools to register
    # + return - An error if a tool cannot be registered (e.g. a function
    #            missing the `@ai:AgentTool` annotation), otherwise nil
    public isolated function registerTools((ai:ToolConfig|ai:FunctionTool)[] tools) returns error? {
        foreach ai:ToolConfig|ai:FunctionTool tool in tools {
            ai:ToolConfig config;
            if tool is ai:ToolConfig {
                config = tool;
            } else {
                ai:ToolConfig[] configs = ai:getToolConfigs([tool]);
                if configs.length() == 0 {
                    return error("Agent tool functions must be annotated with @ai:AgentTool");
                }
                config = configs[0];
            }
            map<json>? parameters = config.parameters;
            check recordAiTool(self.nativeContext, config.caller, config.name, config.description,
                    parameters is () ? () : parameters.toJsonString());
        }
    }

    # Registers a human task as an agent tool. This is the durable-agent
    # counterpart of `workflow:Context`'s `awaitHumanTask`: when the agent
    # decides to involve a person, invoking this tool starts a human-task
    # sub-workflow and suspends the agent durably until the task is completed
    # (via `workflow:completeHumanTask` or the management API).
    #
    # + taskName - Identifies the task type; must not contain `.` or `|`
    # + userRoles - One or more roles permitted to complete this task
    # + resultType - Expected result type; drives form schema generation and
    #                runtime validation of the completion payload
    # + title - Short summary shown in the inbox. Defaults to `taskName`
    # + description - Additional context shown alongside the form; also used as
    #                 the tool description advertised to the model
    # + return - An error if the task cannot be registered, otherwise nil
    public isolated function registerHumanTask(string taskName, string|string[] userRoles,
            typedesc<anydata> resultType = anydata, string? title = (), string? description = ())
            returns error? {
        return recordHumanTaskTool(self.nativeContext, taskName, userRoles, resultType, title, description);
    }

    # Runs the durable AI agent loop. Every LLM call and tool call is executed
    # durably, so the agent survives worker crashes and can suspend for days
    # waiting on human tasks or events. This call may block for a long time; a
    # durable agent has no direct return value.
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
        AgentToolDef[] defs = check toolDefs.cloneWithType();
        return runAgentLoop(self.nativeContext, agentName, config, prompt, defs);
    }
}

// Internal shape of a registered tool: the LLM-facing definition plus the
// dispatch kind ("activity", "aitool", "humantask", or "event:<name>").
type AgentToolDef record {|
    string name;
    string description;
    map<json> parameters?;
    string kind;
|};

// ============================================================================
// Native bindings for AgentContext
// ============================================================================

isolated function recordActivityTool(handle nativeContext, function tool) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "recordActivityTool"
} external;

isolated function recordAiTool(handle nativeContext, function tool, string name, string description,
        string? parametersJson) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "recordAiTool"
} external;

isolated function recordHumanTaskTool(handle nativeContext, string taskName, string|string[] userRoles,
        typedesc<anydata> resultType, string? title, string? description) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "recordHumanTaskTool"
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
