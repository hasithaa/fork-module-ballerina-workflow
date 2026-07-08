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

// A durable AI agent. The body configures the agent imperatively and hands
// control to the durable ReAct loop. The function returns no value — a durable
// agent may run for a long time and communicates through its tools/events.
@workflow:DurableAgent
function orderAgent(workflow:AgentContext ctx, OrderRequest req) returns error? {
    check ctx.registerActivities([checkInventory]);
    check ctx->runDurableAgent(orderModel,
            {
                systemPrompt: string `You are the assistant for order ${req.orderId}.
                        Use checkInventory to answer availability questions.`
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
        if messages is ai:ChatMessage[] {
            foreach ai:ChatMessage message in messages {
                if message is ai:ChatFunctionMessage && message.name == "checkInventory" {
                    string? content = message.content;
                    return {role: ai:ASSISTANT, content: "Here is what I found: " + (content ?: "")};
                }
            }
        }
        return {role: ai:ASSISTANT, toolCalls: [{name: "checkInventory", arguments: {"item": "laptop"}}]};
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

    _ = check workflow:getWorkflowResult(agentId);
    io:println("Agent completed.");
}
