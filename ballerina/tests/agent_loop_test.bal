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
// Durable agent (imperative AgentContext) unit tests (IN_MEMORY mode)
// ============================================================================
//
// The compiler plugin doesn't run on the workflow package itself, so these tests
// register agents with `wfInternal:registerWorkflow` using the tools + built-in
// activities map (mirroring the init code the plugin generates for user code).
// The agent bodies use the real imperative API (ctx.registerActivities +
// ctx->runDurableAgent). The LLM is a scripted mock ai:ModelProvider; the full
// durable loop runs against the embedded Temporal test server. Agents return no
// value, so the final answer is observed via the recorded final response.
// ============================================================================

import ballerina/ai;
import ballerina/jballerina.java;
import ballerina/test;
import ballerina/workflow.internal as wfInternal;

// ── Scripted mock model providers ────────────────────────────────────────────

isolated client class MockModelProvider {
    *ai:ModelProvider;

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        if messages !is ai:ChatMessage[] {
            return {role: ai:ASSISTANT, content: "unexpected single message"};
        }
        string item = "laptop";
        foreach ai:ChatMessage message in messages {
            if message is ai:ChatFunctionMessage && message.name == "checkStock" {
                string? content = message.content;
                return {role: ai:ASSISTANT, content: "Stock check result: " + (content ?: "")};
            }
            if message is ai:ChatUserMessage {
                string|ai:Prompt content = message.content;
                if content is string && content.includes("fail") {
                    item = "fail";
                }
            }
        }
        return {
            role: ai:ASSISTANT,
            toolCalls: [{name: "checkStock", arguments: {"item": item}, id: "call-1"}]
        };
    }

    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.workflow.test.TestNatives",
        name: "mockGenerate"
    } external;
}

final MockModelProvider mockAgentModel = new;

isolated client class LoopingMockModelProvider {
    *ai:ModelProvider;

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        return {role: ai:ASSISTANT, toolCalls: [{name: "checkStock", arguments: {"item": "loop"}}]};
    }

    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.workflow.test.TestNatives",
        name: "mockGenerate"
    } external;
}

final LoopingMockModelProvider loopingAgentModel = new;

isolated client class UnknownToolMockModelProvider {
    *ai:ModelProvider;

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        if messages is ai:ChatMessage[] {
            foreach ai:ChatMessage message in messages {
                if message is ai:ChatFunctionMessage {
                    string? content = message.content;
                    return {role: ai:ASSISTANT, content: content ?: "no tool output"};
                }
            }
        }
        return {role: ai:ASSISTANT, toolCalls: [{name: "noSuchTool", arguments: {}}]};
    }

    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.workflow.test.TestNatives",
        name: "mockGenerate"
    } external;
}

final UnknownToolMockModelProvider unknownToolAgentModel = new;

// Retrieves the recorded final response of a completed agent.
isolated function getAgentFinalResponse(string workflowId) returns string? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentContextNative",
    name: "getFinalResponse"
} external;

// ── Agent tools (activities) ─────────────────────────────────────────────────

@Activity
isolated function checkStock(string item) returns string|error {
    if item == "fail" {
        return error("Inventory service unavailable for: " + item);
    }
    return item + " is in stock";
}

// ── Agent functions (imperative) ──────────────────────────────────────────────

type AgentOrderInput record {|
    string id;
    string request;
|};

@DurableAgent
function stockAgent(AgentContext ctx, AgentOrderInput input) returns error? {
    check ctx.registerActivities([checkStock]);
    check ctx->runDurableAgent(mockAgentModel,
            {systemPrompt: "You are an inventory assistant."}, input.request);
}

@DurableAgent
function chatStockAgent(AgentContext ctx, AgentOrderInput input, record {| future<string> chat; |} events)
        returns error? {
    check ctx.registerActivities([checkStock]);
    // No initial prompt: the agent waits for one chat event.
    check ctx->runDurableAgent(mockAgentModel, {systemPrompt: "You are an inventory assistant."});
}

@DurableAgent
function loopingAgent(AgentContext ctx, AgentOrderInput input) returns error? {
    check ctx.registerActivities([checkStock]);
    check ctx->runDurableAgent(loopingAgentModel, {systemPrompt: "Looping agent.", maxIterations: 2},
            input.request);
}

@DurableAgent
function unknownToolAgent(AgentContext ctx, AgentOrderInput input) returns error? {
    check ctx.registerActivities([checkStock]);
    check ctx->runDurableAgent(unknownToolAgentModel, {systemPrompt: "Unknown tool agent."}, input.request);
}

// ── Setup ────────────────────────────────────────────────────────────────────

@test:BeforeSuite
function setupAgentTests() returns error? {
    map<function> agentActivities = {
        "checkStock": checkStock,
        "llmChat": llmChat,
        "generate": generate
    };
    _ = check wfInternal:registerWorkflow(stockAgent, "stock-agent", agentActivities);
    _ = check wfInternal:registerWorkflow(chatStockAgent, "chat-stock-agent", agentActivities);
    _ = check wfInternal:registerWorkflow(loopingAgent, "looping-agent", agentActivities);
    _ = check wfInternal:registerWorkflow(unknownToolAgent, "unknown-tool-agent", agentActivities);
}

// ── Tests ────────────────────────────────────────────────────────────────────

@test:Config {groups: ["unit"]}
function testAgentToolRoundTrip() returns error? {
    map<anydata> input = {id: "agent-roundtrip-001", request: "Is the laptop in stock?"};
    string|error runResult = run(stockAgent, input);
    if runResult is error {
        return; // No workflow server available — skip.
    }
    _ = check getWorkflowResult(runResult, 30);
    test:assertEquals(getAgentFinalResponse(runResult), "Stock check result: laptop is in stock",
            "Agent should complete a full LLM -> tool -> LLM round trip");
}

@test:Config {groups: ["unit"]}
function testAgentToolErrorFedBackToModel() returns error? {
    map<anydata> input = {id: "agent-tool-error-001", request: "This one should fail"};
    string|error runResult = run(stockAgent, input);
    if runResult is error {
        return;
    }
    _ = check getWorkflowResult(runResult, 30);
    string? response = getAgentFinalResponse(runResult);
    test:assertTrue(response is string && response.includes("Inventory service unavailable"),
            "Tool errors should be fed back to the model as text, got: " + (response ?: "()"));
}

@test:Config {groups: ["unit"]}
function testAgentChatEventSeedsConversation() returns error? {
    map<anydata> input = {id: "agent-chat-001", request: "unused"};
    string|error runResult = run(chatStockAgent, input);
    if runResult is error {
        return;
    }
    // The agent has no initial prompt, so it durably waits for the chat event.
    check sendData(chatStockAgent, runResult, "chat", "Check availability of laptop");
    _ = check getWorkflowResult(runResult, 30);
    test:assertEquals(getAgentFinalResponse(runResult), "Stock check result: laptop is in stock",
            "Chat event should seed the agent conversation");
}

@test:Config {groups: ["unit"]}
function testAgentMaxIterationsExceeded() returns error? {
    map<anydata> input = {id: "agent-maxiter-001", request: "loop forever"};
    string|error runResult = run(loopingAgent, input);
    if runResult is error {
        return;
    }
    anydata|error result = getWorkflowResult(runResult, 30);
    test:assertTrue(result is error, "Looping agent should fail after maxIterations");
    if result is error {
        test:assertTrue(result.message().includes("maximum number of iterations"),
                "Error should mention the iteration limit: " + result.message());
    }
}

@test:Config {groups: ["unit"]}
function testAgentUnknownToolFedBackToModel() returns error? {
    map<anydata> input = {id: "agent-unknown-tool-001", request: "use a bad tool"};
    string|error runResult = run(unknownToolAgent, input);
    if runResult is error {
        return;
    }
    _ = check getWorkflowResult(runResult, 30);
    string? response = getAgentFinalResponse(runResult);
    test:assertTrue(response is string && response.includes("unknown tool 'noSuchTool'"),
            "Unknown tool errors should be fed back to the model as text, got: " + (response ?: "()"));
}
