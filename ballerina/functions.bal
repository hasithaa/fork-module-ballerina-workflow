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


# Starts a new workflow instance and returns its unique ID.
#
# ```ballerina
# string workflowId = check workflow:run(orderProcess, input = {"orderId": "ORD-123"});
# ```
#
# + processFunction - The workflow function (must have `@Workflow`)
# + input - Optional input data for the workflow. Must match the workflow
#           function's declared input parameter type (any `anydata` subtype)
# + return - The workflow ID, or an error
public isolated function run(function processFunction, anydata input = ()) returns string|error = @java:Method {
    'class: "io.ballerina.lib.workflow.runtime.nativeimpl.WorkflowNative",
    name: "run"
} external;

# Starts a new durable agent instance and returns its unique ID. The dedicated
# starter mirrors `run` for `@workflow:DurableAgent` functions.
#
# ```ballerina
# string agentId = check workflow:runDurableAgent(orderAgent, input = {"orderId": "ORD-123"});
# ```
#
# + agentFunction - The agent function (must have `@DurableAgent`)
# + input - Optional input data for the agent
# + return - The agent (workflow) ID, or an error
public isolated function runDurableAgent(function agentFunction, map<anydata>? input = ())
        returns string|error = @java:Method {
    'class: "io.ballerina.lib.workflow.runtime.nativeimpl.WorkflowNative",
    name: "run"
} external;

# Sends data to a running workflow's events record.
#
# ```ballerina
# check workflow:sendData(orderProcess, workflowId, "approval", {approved: true});
# ```
#
# + workflow - The workflow function (must have `@Workflow`)
# + workflowId - Target workflow ID (from `run`)
# + dataName - Field name in the workflow's events record
# + data - The data payload
# + return - An error if sending fails
public isolated function sendData(function workflow, string workflowId, string dataName, anydata data) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.runtime.nativeimpl.WorkflowNative"
} external;

# Sends a request to a running durable agent and waits for its response — the
# request-response counterpart of `sendData`, modeled as a Temporal Update.
# The payload is delivered to the agent's event wait (the message and the
# agent's answer for that turn travel together); the call blocks until the
# agent answers and returns that answer coerced to the expected type `T`.
# For structured `T`, the agent's textual answer is parsed as JSON.
#
# Only supported for `@workflow:DurableAgent` workflows: their data intake and
# turn answers are framework-managed, so the response can be correlated
# implicitly. For plain workflows use one-way `sendData` instead.
#
# ```ballerina
# string reply = check workflow:updateAgent(orderAgent, agentId, "chat", "Is the laptop available?");
# ```
#
# + agentFunction - The agent function (must have `@workflow:DurableAgent`)
# + agentId - Target agent (workflow) ID (from `run`)
# + eventName - The event field name declared in the agent's signature
# + data - The request payload
# + T - Expected response type (inferred from context)
# + return - The agent's answer for the turn that consumed this request, or an error
public isolated function updateAgent(function agentFunction, string agentId, string eventName, anydata data,
        typedesc<anydata> T = <>) returns T|error = @java:Method {
    'class: "io.ballerina.lib.workflow.runtime.nativeimpl.WorkflowNative",
    name: "updateAgent"
} external;

# Waits for a workflow to complete and returns its result.
#
# ```ballerina
# anydata raw = check workflow:getWorkflowResult(workflowId);
# ```
#
# + workflowId - The workflow ID
# + timeoutSeconds - Maximum wait time in seconds
# + return - Result of the workflow as anydata, or an error
public isolated function getWorkflowResult(string workflowId, int timeoutSeconds = 30) returns anydata|error = @java:Method {
    'class: "io.ballerina.lib.workflow.runtime.nativeimpl.WorkflowNative"
} external;

# Completes a pending human task by sending the result back to the waiting workflow.
# The `taskWorkflowId` is the child workflow ID of the task, which is
# available via the inbox/task-listing API and is composed as:
# `"humantask-<parentWorkflowId>-<taskName>-<uuid>"`.
#
# ```ballerina
# check workflow:completeHumanTask(taskWorkflowId, {approved: true, comment: "LGTM"});
# ```
#
# If `callerRoles` is provided the function fetches the `userRoles` stored on the task
# and returns an error when none of the caller's roles appear in that list.
# When omitted the role check is skipped; enforcement is then the caller's responsibility.
#
# + taskWorkflowId - Temporal workflow ID of the human task child workflow
# + result - The value to return to the workflow (must be compatible with the declared `T`)
# + callerRoles - Roles held by the caller; validated against the task's configured `userRoles`
# + userId - The user ID of the person completing the task (used for auditing)
# + return - An error if the task cannot be found, is already completed, or the caller is unauthorized
public isolated function completeHumanTask(string taskWorkflowId, anydata result,
        [string, string...]? callerRoles = (), string? userId = ()) returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.runtime.nativeimpl.WorkflowNative",
    name: "completeHumanTask"
} external;

// Internal functions

# Stops the workflow runtime gracefully, draining in-progress tasks.
#
# + return - An error if stopping fails
isolated function stopWorkflowRuntime() returns error? = @java:Method {
    'class: "io.ballerina.lib.workflow.worker.WorkflowWorkerNative",
    name: "stopSingletonWorker"
} external;
