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

# Deployment mode for the workflow runtime.
#
# + LOCAL - Local development server (e.g., `temporal server start-dev`)
# + CLOUD - Managed cloud deployment (requires authentication)
# + SELF_HOSTED - Self-hosted server (authentication is optional)
# + IN_MEMORY - Lightweight in-memory engine (no persistence, no external server)
public enum Mode {
    LOCAL,
    CLOUD,
    SELF_HOSTED,
    IN_MEMORY
}

# Retry policy for activity execution.
# Controls how the workflow engine retries failed activity executions.
# All interval and attempt values must be positive integers.
#
# + initialIntervalInSeconds - Initial delay before the first retry attempt (default: 1 second).
#                              Must be a positive integer.
# + backoffCoefficient - Multiplier applied to the interval after each retry (default: 2.0).
#                        Must be greater than or equal to 1.0.
# + maximumIntervalInSeconds - Maximum delay between retries (optional, no cap if not set).
#                              Must be a positive integer when specified.
# + maximumAttempts - Maximum number of retry attempts (default: 1, meaning no retries).
#                    Must be a positive integer (0 means unlimited retries).
public type ActivityRetryPolicy record {|
    int initialIntervalInSeconds = 1;
    decimal backoffCoefficient = 2.0;
    int maximumIntervalInSeconds?;
    int maximumAttempts = 1;
|};

# Options for activity execution via `callActivity`.
# Allows configuring retry behavior and error handling semantics per activity call.
#
# + failOnError - If `true` (default), an error returned by the activity function is treated
#                 as a failure, triggering engine retries based on the retry policy.
#                 If `false`, an error is treated as a normal completion value and no
#                 retries are attempted.
public type ActivityOptions record {|
    *ActivityRetryPolicy;
    boolean failOnError = true;
|};

# Information about a registered workflow process.
#
# + name - The name of the registered process
# + activities - Array of activity names associated with this process
# + events - Array of event names (signals) this process can receive
type ProcessRegistration record {
    string name;
    string[] activities;
    string[] events;
};

# Information about all registered workflows.
# This is a map where keys are process names and values are their registration info.
type WorkflowRegistry map<ProcessRegistration>;

# Information about an activity invocation (for testing/introspection).
# + activityName - The name of the activity that was invoked
# + input - The arguments passed to the activity
# + output - The result returned by the activity (nil if not yet completed or failed)
# + status - The status of the activity execution ("COMPLETED", "FAILED", "RUNNING", "PENDING")
# + errorMessage - Error message if the activity failed
public type ActivityInvocation record {
    string activityName;
    anydata[] input;
    anydata? output;
    string status;
    string? errorMessage;
};

# Information about a workflow execution (for testing/introspection).
# + workflowId - The unique identifier for the workflow instance
# + workflowType - The type (process name) of the workflow
# + status - The execution status ("RUNNING", "COMPLETED", "FAILED", "CANCELED", "TERMINATED")
# + result - The workflow result if completed successfully
# + errorMessage - Error message if the workflow failed
# + activityInvocations - List of activities invoked by this workflow
public type WorkflowExecutionInfo record {
    string workflowId;
    string workflowType;
    string status;
    anydata? result;
    string? errorMessage;
    ActivityInvocation[] activityInvocations;
};

