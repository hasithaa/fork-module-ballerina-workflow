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
import ballerina/observe as observability;
import ballerina/observe.mockextension as mock;
import ballerina/test;
import ballerina/workflow.observe;

// ================================================================================
// workflow.observe SUBMODULE - TESTS
// ================================================================================
// This test run is observability-ENABLED (the gradle test task passes
// --observability-included; tests/Config.toml turns on tracing with the distribution's
// mock tracer), so these tests, and the whole IN_MEMORY suite around them, execute the
// real span-recording paths. Metrics cannot be enabled here — each test module's session
// would re-set the process-wide default metric registry, which the runtime forbids — so
// the metric recorders are driven through their registry-taking seams instead; the
// integration tests assert them end-to-end. The disabled no-op paths stay covered by the
// integration auth-variant runs, whose regenerated config carries no [ballerina.observe]
// section.
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
function testStartWorkflowSpanRecordsTagsAndStatus() returns error? {
    observe:StartWorkflowSpan span = observe:createStartWorkflowSpan("workflow-observeSampleFlow");
    span.addInstanceId("wf-instance-1");
    span.close();

    observe:StartWorkflowSpan failedSpan = observe:createStartWorkflowSpan("workflow-observeSampleFlow");
    failedSpan.close(error("start failed"));

    mock:Span recorded = check findUnitSpan("start_workflow", "workflow.instance.id", "wf-instance-1");
    test:assertEquals(recorded.tags["span.type"], "workflow");
    test:assertEquals(recorded.tags["workflow.type"], "workflow-observeSampleFlow");
    test:assertEquals(recorded.tags["module"], "workflow", "spans carry the standard identity tags");
    test:assertEquals(recorded.tags["type"], "client");
}

@test:Config {
    groups: ["observe"]
}
function testDataAndResultSpansCloseWithEitherStatus() {
    observe:SendDataSpan sendSpan = observe:createSendDataSpan("wf-instance-1", "approval");
    sendSpan.close();

    observe:GetWorkflowResultSpan resultSpan = observe:createGetWorkflowResultSpan("wf-instance-1");
    resultSpan.close(error("timed out"));
}

@test:Config {
    groups: ["observe"]
}
function testTaskDecisionSpansAuditEveryInputShape() {
    // The decision's audit entry and metric leg run beside the span, and must survive
    // every shape of input — a full receipt, an anonymous refusal, an empty receipt.
    observe:TaskDecisionSpan accepted = observe:createHumanTaskDecisionSpan("humantask-wf-1-approve-x", "complete");
    accepted.addDecider("alice", ["FINANCE_APPROVER"], "verified");
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
function testOversizedDecisionContentIsCut() {
    // One oversized submission must not flood a span or an audit line: values are cut
    // at the 8192-character bound before they reach either.
    string[] bulk = [];
    foreach int i in 0 ..< 1000 {
        bulk.push("segment-" + i.toString() + "-0123456789");
    }
    observe:TaskDecisionSpan span = observe:createHumanTaskDecisionSpan("humantask-wf-1-bulk", "complete");
    span.addDecider("alice", ["FINANCE_APPROVER"]);
    span.addContent(bulk);
    span.addTaskDetails({taskName: "bulkFlow.approve", taskInput: bulk});
    span.close();
}

@test:Config {
    groups: ["observe"]
}
function testContentCaptureIsOnByDefault() {
    test:assertTrue(observe:isHumanTaskContentCaptured(),
            "a decision's content is recorded unless the deployment switches it off, as ai.observe does");
    test:assertTrue(observe:isActivityContentCaptured(),
            "activity arguments and results are logged unless the deployment switches it off");
    test:assertTrue(observe:isMetricSamplesPublished(),
            "one sample per workflow event is published unless the deployment switches it off");
}

@test:Config {
    groups: ["observe"]
}
function testAgentSpansRecordAgentIdentity() returns error? {
    observe:StartAgentSpan agentSpan = observe:createStartAgentSpan("assistantAgent");
    agentSpan.addInstanceId("wf-agent-1");
    agentSpan.close();

    observe:SendAgentEventSpan eventSpan = observe:createSendAgentEventSpan("assistantAgent", "wf-agent-1", "chat");
    eventSpan.close(error("agent event failed"));

    mock:Span recorded = check findUnitSpan("start_agent", "workflow.instance.id", "wf-agent-1");
    test:assertEquals(recorded.tags["gen_ai.agent.name"], "assistantAgent");
}

@test:Config {
    groups: ["observe"]
}
function testWorkflowSpanSurfaceEndToEnd() returns error? {
    // One conversational agent turn drives the enabled tracing surface in memory:
    // the start, data and result client calls each leave a span in the mock tracer.
    test:assertTrue(observability:isTracingEnabled(), "unit tests run with tracing enabled");

    map<anydata> input = {id: "observe-surface-001", request: "unused"};
    string runId = check run(chatStockAgent, input);
    check sendData(chatStockAgent, runId, "chat", "Check availability of laptop");
    _ = check getWorkflowResult(runId, 30);

    mock:Span sendSpan = check findUnitSpan("send_data", "workflow.instance.id", runId);
    test:assertEquals(sendSpan.tags["workflow.data.name"], "chat");
    mock:Span resultSpan = check findUnitSpan("get_workflow_result", "workflow.instance.id", runId);
    test:assertEquals(resultSpan.tags["module"], "workflow");
}

@test:Config {
    groups: ["observe"]
}
function testMetricRecordersThroughTheirSeams() {
    // The runtime forbids re-setting the process-wide metric registry, so a multi-module
    // test run cannot enable metrics for real; the recorders run here against a local
    // no-op registry — full tag assembly and event routing, an inert sink.
    string[] errorTypes = exerciseMetricRecorders();
    test:assertEquals(errorTypes, ["none", "ExercisedFailure", "IllegalStateException"],
            "error_type resolves the application failure type, else the class name, else none");

    string[] bounded = exerciseBoundedDataNames(80);
    test:assertEquals(bounded.length(), 80);
    test:assertTrue(bounded[79] == "__other__",
            "past the series budget, new data names collapse into __other__");
    test:assertTrue(bounded[0].startsWith("exercised-name-"),
            "names within the budget keep their own series");
}

@test:Config {
    groups: ["observe"]
}
function testTaskDimensionsDeriveFromWorkflowTypes() {
    test:assertEquals(deriveTaskDimensions("humantask-expenseFlow.approve"),
            ["HUMAN_TASK", "expenseFlow.approve"],
            "a human task child's lifecycle events carry its kind and declared name");
    test:assertEquals(deriveTaskDimensions("reviewactivity-orderFlow.chargeCard"),
            ["REVIEW_ACTIVITY", "orderFlow.chargeCard"]);
    test:assertEquals(deriveTaskDimensions("retrytask"), ["REVIEW_ACTIVITY", "none"],
            "the legacy shared review type keeps its kind, but carries no per-task name");
    test:assertEquals(deriveTaskDimensions("workflow-orderFlow"), ["none", "none"],
            "an ordinary workflow carries the sentinel in both task dimensions");
}

isolated function deriveTaskDimensions(string workflowType) returns string[] = @java:Method {
    'class: "io.ballerina.lib.workflow.observability.ObservabilityTestNatives",
    name: "deriveTaskDimensions"
} external;

isolated function exerciseMetricRecorders() returns string[] = @java:Method {
    'class: "io.ballerina.lib.workflow.observability.ObservabilityTestNatives",
    name: "exerciseMetricRecorders"
} external;

isolated function exerciseBoundedDataNames(int count) returns string[] = @java:Method {
    'class: "io.ballerina.lib.workflow.observability.ObservabilityTestNatives",
    name: "exerciseBoundedDataNames"
} external;

// ================================================================================
// HELPERS
// ================================================================================

# Finds a finished span by its `workflow.operation.name` tag and one identifying tag.
#
# + operationName - The span's `workflow.operation.name` tag value
# + idTag - The identifying tag name
# + idValue - The identifying tag value
# + return - The matching span, or an error when none was recorded
function findUnitSpan(string operationName, string idTag, string idValue) returns mock:Span|error {
    foreach string serviceName in ["Ballerina", "Unknown Service"] {
        foreach mock:Span span in mock:getFinishedSpans(serviceName) {
            if span.tags["workflow.operation.name"] == operationName && span.tags[idTag] == idValue {
                return span;
            }
        }
    }
    return error(string `span '${operationName}' with ${idTag}='${idValue}' was not recorded`);
}
