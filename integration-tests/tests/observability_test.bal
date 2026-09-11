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

// ================================================================================
// OBSERVABILITY - TESTS
// ================================================================================
//
// This package builds with observabilityIncluded = true and the tests run with
// metrics enabled (Prometheus reporter) and tracing enabled (the distribution's
// mock tracer), so these tests assert the real emission paths: the workflow_*
// metrics recorded by the wrapper layer and the client-side spans recorded by
// the workflow.observe submodule.
//
// ================================================================================

import ballerina/lang.runtime;
import ballerina/observe;
import ballerina/observe.mockextension as mock;
import ballerina/test;
import ballerina/workflow;
import ballerina/workflow.management;
import ballerina/workflow.observe as wfobserve;

import ballerinax/prometheus as _;

// Service names under which the runtime may register spans; the mock tracer
// stores finished spans per service.
final readonly & string[] spanServiceCandidates = ["Ballerina", "Unknown Service"];

@test:Config {
    groups: ["integration", "observability"]
}
function testWorkflowMetricsEmission() returns error? {
    if !observe:isMetricsEnabled() {
        // The auth-variant runs regenerate Config.toml without [ballerina.observe];
        // there is nothing to assert when metrics are off — the wrapper is a no-op.
        return;
    }
    string workflowId = check workflow:run(observabilityFlow, {name: "metrics"});
    runtime:sleep(1);
    check workflow:sendData(observabilityFlow, workflowId, "obsApproval", true);
    anydata result = check workflow:getWorkflowResult(workflowId, 60);
    test:assertEquals(result, "obs:metrics", "Workflow should complete normally");

    // Every lifecycle event is one increment of workflow_events_total, distinguished by tags;
    // the identity tags (module, type, remote_url, task_queue, host) ride on every sample.
    check assertMetricAtLeast("workflow_events_total",
            {module: "workflow", 'type: "worker", event: "started",
                workflow_type: "workflow-observabilityFlow"}, 1.0);
    check assertMetricAtLeast("workflow_events_total",
            {event: "closed", workflow_type: "workflow-observabilityFlow",
                outcome: "success", error_type: "none"}, 1.0);
    // Activities are scheduled under their plain function name (no workflow qualifier).
    check assertMetricAtLeast("workflow_events_total",
            {event: "activity_executed", activity_type: "observabilityEcho",
                workflow_type: "workflow-observabilityFlow", outcome: "success"}, 1.0);
    check assertMetricAtLeast("workflow_events_total",
            {module: "workflow", 'type: "client", event: "data_sent", data_name: "obsApproval",
                workflow_type: "none", outcome: "success"}, 1.0);

    // Duration summaries exist for the completed run (value is duration, not a count).
    test:assertTrue(findMetricValue("workflow_duration_seconds",
            {workflow_type: "workflow-observabilityFlow", outcome: "success"}) !is (),
            "workflow_duration_seconds should be recorded for the completed run");
    test:assertTrue(findMetricValue("workflow_activity_duration_seconds",
            {activity_type: "observabilityEcho", outcome: "success"}) !is (),
            "workflow_activity_duration_seconds should be recorded for the activity execution");
}

@test:Config {
    groups: ["integration", "observability"]
}
function testWorkflowFailureMetricsEmission() returns error? {
    if !observe:isMetricsEnabled() {
        return;
    }
    string workflowId = check workflow:run(observabilityFailingFlow);
    anydata|error result = workflow:getWorkflowResult(workflowId, 60);
    test:assertTrue(result is error, "Failing workflow should surface an error result");

    check assertMetricAtLeast("workflow_events_total",
            {event: "closed", workflow_type: "workflow-observabilityFailingFlow",
                outcome: "failure", error_type: "ApplicationFailure"}, 1.0);
}

@test:Config {
    groups: ["integration", "observability"]
}
function testWorkflowSpanEmission() returns error? {
    if !observe:isTracingEnabled() {
        return;
    }
    string workflowId = check workflow:run(observabilityFlow, {name: "spans"});
    runtime:sleep(1);
    check workflow:sendData(observabilityFlow, workflowId, "obsApproval", true);
    anydata result = check workflow:getWorkflowResult(workflowId, 60);
    test:assertEquals(result, "obs:spans", "Workflow should complete normally");

    mock:Span startSpan = check findSpan("start_workflow workflow-observabilityFlow", workflowId);
    test:assertEquals(startSpan.tags["span.type"], "workflow", "start span should be typed as a workflow span");
    test:assertEquals(startSpan.tags["workflow.operation.name"], "start_workflow");
    test:assertEquals(startSpan.tags["workflow.type"], "workflow-observabilityFlow");
    test:assertEquals(startSpan.tags["module"], "workflow", "spans carry the standard identity tags");
    test:assertEquals(startSpan.tags["type"], "client", "client-side spans identify their side");
    test:assertTrue(startSpan.tags.hasKey("task.queue"), "spans carry the task queue identity tag");

    mock:Span sendSpan = check findSpan("send_data obsApproval", workflowId);
    test:assertEquals(sendSpan.tags["workflow.data.name"], "obsApproval");

    mock:Span resultSpan = check findSpan(string `get_workflow_result ${workflowId}`, workflowId);
    test:assertEquals(resultSpan.tags["workflow.operation.name"], "get_workflow_result");
}

@test:Config {
    groups: ["integration", "observability"]
}
function testHumanTaskDecisionTelemetry() returns error? {
    string workflowId = check workflow:run(observabilityApprovalFlow, {name: "decision"});
    management:HumanTaskGroup[] groups = check waitForPendingHumanTask(workflowId);
    string taskId = groups[0].taskIds[0];

    // Someone outside the task's roles is refused — and the refusal is itself a recorded decision.
    error? refused = workflow:completeHumanTask(taskId, {approved: true},
            callerRoles = ["OBS_BYSTANDER"], userId = "mallory");
    test:assertTrue(refused is error, "A caller outside the task's roles must be refused");

    check workflow:completeHumanTask(taskId, {approved: true}, callerRoles = ["OBS_APPROVER"], userId = "alice");
    anydata result = check workflow:getWorkflowResult(workflowId, 60);
    test:assertEquals(result, "obs:approved", "The approved task should complete the workflow");

    if observe:isMetricsEnabled() {
        check assertMetricAtLeast("workflow_events_total",
                {event: "task_decided", task_kind: "HUMAN_TASK", action: "complete", outcome: "success"}, 1.0);
        // A refused decision is a failure event carrying the refusing error's type; it never
        // resolved the task, so the task_name dimension holds the `none` sentinel.
        check assertMetricAtLeast("workflow_events_total",
                {event: "task_decided", task_kind: "HUMAN_TASK", action: "complete",
                    task_name: "none", outcome: "failure", error_type: "error"}, 1.0);
    }
    if observe:isTracingEnabled() {
        mock:Span accepted = check findDecisionSpan("complete_human_task", "workflow.human_task.id", taskId, "alice");
        test:assertEquals(accepted.tags["user.roles"], "OBS_APPROVER", "the span should say in which role alice decided");
        test:assertEquals(accepted.tags["workflow.task.action"], "complete");
        test:assertEquals(accepted.tags["user.identity.source"], "asserted",
                "an embedded-API decision's identity is what the caller asserted");
        string taskName = accepted.tags["workflow.task.name"] ?: "";
        test:assertTrue(taskName.endsWith("obsApprove"),
                "an accepted decision's span should name the task, got '" + taskName + "'");
        if wfobserve:isHumanTaskContentCaptured() {
            test:assertEquals(accepted.tags["workflow.task.content"], "{\"approved\":true}",
                    "with content capture on, the span should carry the submitted result");
            test:assertEquals(accepted.tags["workflow.task.input"], "{\"name\":\"decision\"}",
                    "with content capture on, the span should carry what the approver was shown");
        } else {
            test:assertFalse(accepted.tags.hasKey("workflow.task.content"),
                    "with content capture off, the submitted result must stay off the span");
            test:assertFalse(accepted.tags.hasKey("workflow.task.input"),
                    "with content capture off, the task input must stay off the span");
        }

        mock:Span denied = check findDecisionSpan("complete_human_task", "workflow.human_task.id", taskId, "mallory");
        test:assertEquals(denied.tags["user.roles"], "OBS_BYSTANDER", "a refused decision still records who tried");
        test:assertFalse(denied.tags.hasKey("workflow.task.name"),
                "a refused decision never resolved the task, so it cannot name it");
    }
}

@test:Config {
    groups: ["integration", "observability"]
}
function testReviewActivityDecisionTelemetry() returns error? {
    string workflowId = check workflow:run(observabilityReviewFlow, {name: "fail"});
    management:ReviewActivitySummary review = check waitForPendingReviewActivity(workflowId);

    // Decide through executeCommand with a gateway-style verified identity, so the
    // provenance rides the whole command path into the decision's telemetry.
    json|management:Error decided = management:executeCommand({
        operation: management:DECIDE_REVIEW_ACTIVITY,
        params: {taskId: review.taskId, action: "proceed-with-input", input: {mode: "ok"}},
        identity: {userId: "bob", roles: ["OBS_REVIEWER"], identitySource: "verified"}
    });
    test:assertTrue(decided !is management:Error, "The reviewer's decision should be accepted");
    anydata result = check workflow:getWorkflowResult(workflowId, 60);
    test:assertEquals(result, "obs:recovered:ok", "The reviewer's input should let the step recover");

    if observe:isMetricsEnabled() {
        check assertMetricAtLeast("workflow_events_total",
                {event: "task_decided", task_kind: "REVIEW_ACTIVITY", action: "proceed-with-input",
                    outcome: "success"}, 1.0);
    }
    if observe:isTracingEnabled() {
        mock:Span span = check findDecisionSpan("complete_review_activity", "workflow.review_activity.id",
                review.taskId, "bob");
        test:assertEquals(span.tags["user.roles"], "OBS_REVIEWER");
        test:assertEquals(span.tags["workflow.task.action"], "proceed-with-input");
        test:assertEquals(span.tags["user.identity.source"], "verified",
                "a decision carrying a gateway-verified identity says so on its span");
        if wfobserve:isHumanTaskContentCaptured() {
            string content = span.tags["workflow.task.content"] ?: "";
            test:assertTrue(content.includes("\"mode\":\"ok\""),
                    "with content capture on, the span should carry the reviewer's input, got '" + content + "'");
            string reviewed = span.tags["workflow.task.input"] ?: "";
            test:assertTrue(reviewed.includes("\"mode\":\"fail\""),
                    "with content capture on, the span should carry the reviewed activity's arguments, got '"
                    + reviewed + "'");
        } else {
            test:assertFalse(span.tags.hasKey("workflow.task.content"));
            test:assertFalse(span.tags.hasKey("workflow.task.input"));
        }
    }
}

// ================================================================================
// HELPERS
// ================================================================================

# Looks up the current value of a metric matching the given name and tag subset.
#
# + name - The metric name
# + expectedTags - Tags the metric must carry (subset match)
# + return - The metric value, or `()` when no matching metric exists yet
function findMetricValue(string name, map<string> expectedTags) returns float? {
    foreach observe:Metric metric in observe:getAllMetrics() {
        if metric.name != name {
            continue;
        }
        boolean matches = true;
        foreach [string, string] [key, value] in expectedTags.entries() {
            if metric.tags[key] != value {
                matches = false;
                break;
            }
        }
        if matches {
            int|float value = metric.value;
            return value is int ? <float>value : value;
        }
    }
    return ();
}

# Asserts that a metric reaches at least the given value, retrying briefly because
# worker-side recording completes asynchronously with result delivery.
#
# + name - The metric name
# + expectedTags - Tags the metric must carry (subset match)
# + minimum - The minimum expected value
# + return - An error when the metric never reaches the minimum
function assertMetricAtLeast(string name, map<string> expectedTags, float minimum) returns error? {
    float? value = ();
    foreach int attempt in 0 ..< 10 {
        value = findMetricValue(name, expectedTags);
        if value is float && value >= minimum {
            return;
        }
        runtime:sleep(0.5);
    }
    return error(string `metric '${name}' with tags ${expectedTags.toString()} expected to reach ` +
            string `${minimum} but was ${value is float ? value.toString() : "absent"}`);
}

# Finds a finished decision span by its `workflow.operation.name` tag, task ID tag and decider,
# retrying briefly because the tracer finishes spans asynchronously. Keyed on the decider too: a
# refused and an accepted decision on the same task are two spans. (A span's recorded name is
# `<operation> <taskId>`; the tag is the stable half.)
#
# + operationName - The value of the span's `workflow.operation.name` tag
# + idTag - The tag carrying the task ID (`workflow.human_task.id` or `workflow.review_activity.id`)
# + taskId - The task's workflow ID
# + userId - The `user.id` the span must carry
# + return - The matching span, or an error when none is found
function findDecisionSpan(string operationName, string idTag, string taskId, string userId)
        returns mock:Span|error {
    foreach int attempt in 0 ..< 10 {
        foreach string serviceName in spanServiceCandidates {
            foreach mock:Span span in mock:getFinishedSpans(serviceName) {
                if span.tags["workflow.operation.name"] == operationName && span.tags[idTag] == taskId
                        && span.tags["user.id"] == userId {
                    return span;
                }
            }
        }
        runtime:sleep(0.5);
    }
    return error(string `decision span '${operationName}' for task '${taskId}' by '${userId}' was not recorded`);
}

# Finds a finished span by operation name carrying the given workflow instance ID,
# retrying briefly because the tracer finishes spans asynchronously.
#
# + operationName - The span's operation name
# + workflowId - The workflow instance ID the span must be tagged with
# + return - The matching span, or an error when none is found
function findSpan(string operationName, string workflowId) returns mock:Span|error {
    foreach int attempt in 0 ..< 10 {
        foreach string serviceName in spanServiceCandidates {
            foreach mock:Span span in mock:getFinishedSpans(serviceName) {
                if span.operationName == operationName && span.tags["workflow.instance.id"] == workflowId {
                    return span;
                }
            }
        }
        runtime:sleep(0.5);
    }
    return error(string `span '${operationName}' for workflow '${workflowId}' was not recorded`);
}
