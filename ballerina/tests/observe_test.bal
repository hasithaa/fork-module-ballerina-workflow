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

import ballerina/test;
import ballerina/workflow.observe;

// ================================================================================
// workflow.observe SUBMODULE - TESTS
// ================================================================================
// This build runs without observabilityIncluded, so tracing is disabled and every
// span operation must be a safe no-op — the default for all existing users. The
// observability-enabled behavior (real span/metric emission) is asserted in the
// integration tests, which build with observabilityIncluded = true.
// ================================================================================

function observeSampleFlow() returns string => "ok";

@test:Config {
    groups: ["observe"]
}
function testWorkflowTypeNameOf() {
    test:assertEquals(observe:workflowTypeNameOf(observeSampleFlow), "workflow-observeSampleFlow",
            "workflowTypeNameOf should apply the engine's workflow type prefix to the function name");
}

@test:Config {
    groups: ["observe"]
}
function testStartWorkflowSpanNoOpWhenTracingDisabled() {
    observe:StartWorkflowSpan span = observe:createStartWorkflowSpan("workflow-observeSampleFlow");
    span.addInstanceId("wf-instance-1");
    span.close();

    observe:StartWorkflowSpan failedSpan = observe:createStartWorkflowSpan("workflow-observeSampleFlow");
    failedSpan.close(error("start failed"));
}

@test:Config {
    groups: ["observe"]
}
function testDataAndResultSpansNoOpWhenTracingDisabled() {
    observe:SendDataSpan sendSpan = observe:createSendDataSpan("wf-instance-1", "approval");
    sendSpan.close();

    observe:GetWorkflowResultSpan resultSpan = observe:createGetWorkflowResultSpan("wf-instance-1");
    resultSpan.close(error("timed out"));

}

@test:Config {
    groups: ["observe"]
}
function testTaskDecisionSpansAuditWithoutTracing() {
    // Tracing is off, so the span itself is a no-op — but the decision's audit entry and its
    // metric leg still run, and must survive every shape of input.
    observe:TaskDecisionSpan accepted = observe:createHumanTaskDecisionSpan("humantask-wf-1-approve-x", "complete");
    accepted.addDecider("alice", ["FINANCE_APPROVER"]);
    accepted.addContent({approved: true, comment: "LGTM"});
    accepted.addTaskDetails({taskName: "expenseFlow.approve", parentWorkflowId: "wf-1",
                             assignedRoles: ["FINANCE_APPROVER", "CFO"], taskInput: {amount: 1200, currency: "USD"}});
    accepted.close();

    observe:TaskDecisionSpan anonymous = observe:createHumanTaskDecisionSpan("humantask-wf-1-approve-y", "fail");
    anonymous.addDecider((), ());
    anonymous.addContent({reason: "incomplete", details: ()});
    anonymous.close(error("Unauthorized: caller does not have a required role"));

    observe:TaskDecisionSpan review = observe:createReviewActivityDecisionSpan("review-1", "proceed-with-input");
    review.addDecider("bob", ["OPS"]);
    review.addContent({input: {orderId: "NEW-1"}, feedback: ()});
    review.addTaskDetails({});
    review.close();
}

@test:Config {
    groups: ["observe"]
}
function testContentCaptureIsOnByDefault() {
    test:assertTrue(observe:isHumanTaskContentCaptured(),
            "a decision's content is recorded unless the deployment switches it off, as ai.observe does");
    test:assertTrue(observe:isActivityContentCaptured(),
            "activity arguments and results are logged unless the deployment switches it off");
}

@test:Config {
    groups: ["observe"]
}
function testAgentSpansNoOpWhenTracingDisabled() {
    observe:StartAgentSpan agentSpan = observe:createStartAgentSpan("assistantAgent");
    agentSpan.addInstanceId("wf-agent-1");
    agentSpan.close();

    observe:SendAgentEventSpan eventSpan = observe:createSendAgentEventSpan("assistantAgent", "wf-agent-1", "chat");
    eventSpan.close(error("agent event failed"));
}
