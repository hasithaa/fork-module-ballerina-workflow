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
import ballerina/time;

# Configuration for a durable agent run. Mirrors `ai:AgentConfiguration` so a
# durable agent is configured the same way as a regular `ai:Agent` — the agent's
# identity, model, and tools are all passed to `runDurableAgent` in one place.
public type AgentRunConfig record {|
    # The system prompt assigned to the agent
    @display {label: "System Prompt"}
    ai:SystemPrompt systemPrompt;

    # The model provider used for the agent's LLM calls
    @display {label: "Model"}
    ai:ModelProvider model;

    # The AI tools available to the agent. `@workflow:Activity` functions and
    # human tasks are added separately via `registerActivity` and
    # `registerHumanTask`
    @display {label: "Tools"}
    (ai:BaseToolKit|ai:ToolConfig|ai:FunctionTool)[] tools = [];

    # The maximum number of LLM reasoning iterations per conversation turn
    # before the agent fails with an error
    @display {label: "Maximum Iterations"}
    int maxIter = 16;

    # Specifies whether verbose logging is enabled
    @display {label: "Verbose"}
    boolean verbose = false;
|};

# How a durable agent consumes its external data events.
public enum AgentInteractionPattern {
    # Each event declared in the agent's signature may be consumed once per run (default)
    SINGLE_EVENT,
    # Events are re-armable: the agent may wait repeatedly on the same event, each wait
    # consuming the next queued payload (conversational agents). Requires an event
    # timeout as its safety mechanism
    MULTI_EVENT
}

# The execution context for a durable AI agent. Injected as the first parameter
# of a `@workflow:DurableAgent` function.
#
# Unlike `workflow:Context`, this context deliberately does not expose
# `callActivity`, `sleep`, or `awaitHumanTask`. Instead, capabilities are
# registered on the context and the agent decides when to use them inside the
# durable ReAct loop driven by `runDurableAgent`:
#
# - `registerActivity` — a `@workflow:Activity` function becomes a tool that runs
#   as a durable Temporal activity
# - `registerHumanTask` — a human task becomes a tool; when the agent invokes it,
#   a human-task sub-workflow starts and the agent suspends durably until a
#   person completes it
# - AI tools and the model provider are passed directly to `runDurableAgent`,
#   mirroring how a regular `ai:Agent` is configured
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

    # Configures how the agent consumes external events, together with its safety
    # limits. Termination stays model-driven: the agent ends when the model produces
    # a final answer without waiting; these settings bound how long and how often it
    # may wait.
    #
    # + pattern - `SINGLE_EVENT` (each event once per run) or `MULTI_EVENT`
    #             (re-armable events for multi-turn conversations)
    # + eventTimeout - Maximum wait per event. On timeout the model is told the wait
    #                  timed out so it can wrap up gracefully. Required for
    #                  `MULTI_EVENT`; optional otherwise
    # + maxEventWaits - Hard cap on the total number of event waits per run; exceeding
    #                   it fails the agent (backstop for open-ended conversations)
    # + return - An error if the configuration is invalid, otherwise nil
    public isolated function setInteraction(AgentInteractionPattern pattern,
            time:Duration? eventTimeout = (), int maxEventWaits = 50) returns error? {
        return setAgentInteraction(self.nativeContext, pattern, eventTimeout, maxEventWaits);
    }

    # Registers a `@workflow:Activity` function as an agent tool. The tool runs as
    # a durable Temporal activity that the agent may invoke during reasoning.
    #
    # + activity - The `@workflow:Activity` function to expose as a tool
    # + return - An error if the tool cannot be registered, otherwise nil
    public isolated function registerActivity(function activity) returns error? {
        return recordActivityTool(self.nativeContext, activity);
    }

    // Registers the AI tools passed to `runDurableAgent`. Accepts `ai:ToolConfig`
    // values, functions annotated with `@ai:AgentTool` (normalized via the ai
    // module's tool plumbing), or `ai:BaseToolKit` implementations (expanded via
    // their `getTools()`). When the agent invokes one of these tools, the call is
    // executed durably through the built-in activity wrapper, delegating argument
    // binding and `ai:Context` injection to `ai:executeTool`.
    private isolated function registerTools((ai:BaseToolKit|ai:ToolConfig|ai:FunctionTool)[] tools)
            returns error? {
        foreach ai:BaseToolKit|ai:ToolConfig|ai:FunctionTool tool in tools {
            if tool is ai:BaseToolKit {
                foreach ai:ToolConfig config in tool.getTools() {
                    check self.recordToolConfig(config);
                }
            } else if tool is ai:ToolConfig {
                check self.recordToolConfig(tool);
            } else {
                ai:ToolConfig[] configs = ai:getToolConfigs([tool]);
                if configs.length() == 0 {
                    return error("Agent tool functions must be annotated with @ai:AgentTool");
                }
                check self.recordToolConfig(configs[0]);
            }
        }
    }

    private isolated function recordToolConfig(ai:ToolConfig config) returns error? {
        map<json>? parameters = config.parameters;
        return recordAiTool(self.nativeContext, config.caller, config.name, config.description,
                parameters is () ? () : parameters.toJsonString());
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
    # + timeout - Maximum time to wait for completion. On timeout the model is told
    #             the task timed out so it can react. Omit to wait indefinitely
    # + return - An error if the task cannot be registered, otherwise nil
    public isolated function registerHumanTask(string taskName, string|string[] userRoles,
            typedesc<anydata> resultType = anydata, string? title = (), string? description = (),
            time:Duration? timeout = ()) returns error? {
        return recordHumanTaskTool(self.nativeContext, taskName, userRoles, resultType, title, description,
                timeout);
    }

    # Runs the durable AI agent loop. Configured like a regular `ai:Agent` — the
    # system prompt, model, and AI tools all arrive through the included
    # `AgentRunConfig`. Every LLM call and tool call is executed durably, so the
    # agent survives worker crashes and can suspend for days waiting on human
    # tasks or events. This call may block for a long time; a durable agent has
    # no direct return value.
    #
    # + query - The initial user query. When empty, the agent waits for the
    #           first `chat` event declared in the function signature
    # + context - The tool-execution context. Reserved: tool calls run as
    #             durable activities, so a caller-provided context does not
    #             currently cross the activity boundary
    # + config - The agent configuration (system prompt, model, tools, limits)
    # + return - An error if the agent fails, otherwise nil
    public isolated function runDurableAgent(@display {label: "Query"} string query = "",
            @display {label: "Context"} ai:Context? context = (), *AgentRunConfig config) returns error? {
        setAgentModelProvider(self.nativeContext, config.model);
        check registerAgentModelForContext(self.nativeContext);
        check self.registerTools(config.tools);
        string agentName = getAgentWorkflowType(self.nativeContext);
        string toolDefsJson = check getAgentToolDefs(self.nativeContext);
        json toolDefs = check toolDefsJson.fromJsonString();
        AgentToolDef[] defs = check toolDefs.cloneWithType();
        error? result = runAgentLoop(self.nativeContext, agentName, config, query, defs);
        // Settle any outstanding updateAgent requests before the workflow completes:
        // unconsumed updates receive the agent's final response (or its failure)
        // instead of failing with "workflow completed before the update completed".
        finishAgentUpdates(self.nativeContext, result is error ? result.message() : ());
        return result;
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
        typedesc<anydata> resultType, string? title, string? description, time:Duration? timeout)
        returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "recordHumanTaskTool"
} external;

isolated function setAgentInteraction(handle nativeContext, string pattern, time:Duration? eventTimeout,
        int maxEventWaits) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "setInteraction"
} external;

isolated function finishAgentUpdates(handle nativeContext, string? failureMessage) = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "finishAgentUpdates"
} external;

isolated function getAgentToolDefs(handle nativeContext) returns string|error = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "getToolDefs"
} external;

isolated function getAgentWorkflowType(handle nativeContext) returns string = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "getWorkflowType"
} external;

isolated function setAgentModelProvider(handle nativeContext, object {} model) = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "setModelProvider"
} external;

isolated function registerAgentModelForContext(handle nativeContext) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "registerModel"
} external;
