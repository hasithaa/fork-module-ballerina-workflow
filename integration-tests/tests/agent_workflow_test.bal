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

import ballerina/jballerina.java;
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/workflow;

// Probe: reads the final response the agent recorded on completion (agents have
// no workflow return value).
isolated function getAgentFinalResponse(string workflowId) returns string? = @java:Method {
    'class: "io.ballerina.lib.workflow.context.AgentResponseStore",
    name: "getFinalResponse"
} external;

@test:Config {}
function testDurableAgentPromptDriven() returns error? {
    string agentId = check workflow:run(stockCheckAgent,
            {id: "agent-int-001", request: "Is the laptop in stock?"});

    _ = check workflow:getWorkflowResult(agentId, 60);

    test:assertEquals(getAgentFinalResponse(agentId), "Stock check result: laptop is in stock",
            "Prompt-driven agent should complete the LLM -> tool -> LLM round trip");
}

@test:Config {}
function testDurableAgentChatDriven() returns error? {
    string agentId = check workflow:run(chatDrivenStockAgent,
            {id: "agent-int-002", request: "unused"});

    // Give the agent a moment to start and park on the chat event, then send it.
    runtime:sleep(2);
    check workflow:sendData(chatDrivenStockAgent, agentId, "chat", "Check availability of laptop");

    _ = check workflow:getWorkflowResult(agentId, 60);

    test:assertEquals(getAgentFinalResponse(agentId), "Stock check result: laptop is in stock",
            "Chat-driven agent should durably wait for the chat event, then complete");
}
