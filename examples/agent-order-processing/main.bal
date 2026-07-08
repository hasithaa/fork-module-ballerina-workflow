// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/io;
import ballerina/jballerina.java;
import ballerina/lang.runtime;
import ballerina/workflow;

type OrderRequest record {|
    string orderId;
    string userPrompt;
|};

// A tool the agent can invoke. Every tool call runs as a durable Temporal
// activity, so it is retried and never re-executed on replay.
@workflow:Activity
function checkInventory(string item) returns string|error {
    io:println(string `[activity] checkInventory(${item})`);
    return item + " is in stock";
}

// A conversational durable AI agent. The body configures the agent imperatively
// and hands control to the durable ReAct loop. With the MULTI_EVENT interaction
// pattern the model answers each turn and then durably re-arms the chat wait —
// suspending for hours or days without holding a thread — until the user says
// goodbye (or the safety timeout/wait-cap kicks in).
@workflow:DurableAgent
function orderAgent(workflow:AgentContext ctx, OrderRequest req,
        record {| future<string> chat; |} events) returns error? {
    check ctx.setInteraction(workflow:MULTI_EVENT, eventTimeout = {minutes: 30});
    check ctx.registerActivities([checkInventory]);
    check ctx->runDurableAgent(orderModel,
            {
                systemPrompt: string `You are the assistant for order ${req.orderId}.
                        Use checkInventory to answer availability questions. After each
                        answer, wait for the user's next chat message unless they say goodbye.`
            },
            req.userPrompt);
}

// ── A self-contained mock model provider so the example runs without credentials.
// Replace with a real provider, e.g. `check ai:getDefaultModelProvider()` or a
// `ballerinax/ai.openai` client, in a real deployment.
isolated client class MockModelProvider {
    *ai:ModelProvider;

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        string? inventory = ();
        string? lastChat = ();
        if messages is ai:ChatMessage[] {
            foreach ai:ChatMessage message in messages {
                if message is ai:ChatFunctionMessage && message.name == "checkInventory" {
                    inventory = message.content;
                }
                if message is ai:ChatFunctionMessage && message.name == "awaitEvent_chat" {
                    lastChat = message.content;
                }
            }
        }
        if inventory is () {
            return {role: ai:ASSISTANT, toolCalls: [{name: "checkInventory", arguments: {"item": "laptop"}}]};
        }
        if lastChat is () {
            return {
                role: ai:ASSISTANT,
                content: "Good news: " + inventory + ". Anything else?",
                toolCalls: [{name: "awaitEvent_chat", arguments: {}}]
            };
        }
        if lastChat.includes("bye") {
            return {role: ai:ASSISTANT, content: "Goodbye! Your order is on its way."};
        }
        return {
            role: ai:ASSISTANT,
            content: "You said: " + lastChat + ". Anything else?",
            toolCalls: [{name: "awaitEvent_chat", arguments: {}}]
        };
    }

    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.workflow.test.TestNatives",
        name: "mockGenerate"
    } external;
}

final MockModelProvider orderModel = new;

public function main() returns error? {
    string agentId = check workflow:run(orderAgent,
            {orderId: "ORD-001", userPrompt: "Is the laptop available?"});
    io:println("Agent started with ID: " + agentId);

    // Turn 1: the agent checks inventory, answers, and durably waits for chat.
    io:println("Turn 1: " + waitForResponse(agentId, "Good news"));

    // Turn 2: the user follows up; the agent consumes the next chat message.
    check workflow:sendData(orderAgent, agentId, "chat", "Please expedite the shipping");
    io:println("Turn 2: " + waitForResponse(agentId, "You said"));

    // Final turn: the user says goodbye; the model ends the conversation.
    check workflow:sendData(orderAgent, agentId, "chat", "great, bye!");
    _ = check workflow:getWorkflowResult(agentId);
    io:println("Final: " + (getAgentResponse(agentId) ?: ""));
}

function waitForResponse(string agentId, string expectedPrefix) returns string {
    foreach int i in 0 ..< 40 {
        string? response = getAgentResponse(agentId);
        if response is string && response.includes(expectedPrefix) {
            return response;
        }
        runtime:sleep(0.5);
    }
    return "<no response>";
}

// In-process probe for the agent's latest response. In a service deployment,
// use `management:getAgentResponse(agentId)` instead — importing
// `ballerina/workflow.management` also hosts the management HTTP API, which
// keeps the program running (this example is a run-to-completion demo).
isolated function getAgentResponse(string agentId) returns string? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentResponseStore",
    name: "getFinalResponse"
} external;
