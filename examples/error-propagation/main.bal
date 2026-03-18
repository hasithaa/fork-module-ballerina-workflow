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

// Error Propagation Example
//
// Demonstrates the simplest error handling strategy: propagate the activity
// error to the caller by using `check`. When the activity fails the workflow
// immediately transitions to Failed in Temporal and the error is returned
// to whoever called workflow:getWorkflowResult().

import ballerina/io;
import ballerina/workflow;

// ---------------------------------------------------------------------------
// TYPES
// ---------------------------------------------------------------------------

type OrderInput record {|
    string orderId;
    string item;
|};

type OrderResult record {|
    string orderId;
    string status;
|};

// ---------------------------------------------------------------------------
// ACTIVITIES
// ---------------------------------------------------------------------------

# Validates stock levels for an item.
# Returns an error when the item is unavailable, simulating a deterministic
# business failure that should not be retried.
#
# + item - The item to check
# + return - true when in stock, otherwise an error
@workflow:Activity
function checkInventory(string item) returns boolean|error {
    io:println("Checking inventory for: " + item);
    if item == "unknown-item" {
        return error("Item not found in catalog: " + item);
    }
    return true;
}

# Confirms an order after inventory is validated.
#
# + orderId - The order identifier
# + item - The item being ordered
# + return - Confirmation message or error
@workflow:Activity
function confirmOrder(string orderId, string item) returns string|error {
    io:println(string `Confirming order ${orderId} for item: ${item}`);
    return string `Order ${orderId} confirmed for ${item}`;
}

// ---------------------------------------------------------------------------
// WORKFLOW
// ---------------------------------------------------------------------------

# Processes an order, propagating any activity error to the caller.
#
# If `checkInventory` fails, `check` propagates the error and the workflow
# transitions to **Failed** in Temporal. The `confirmOrder` activity is never
# called. The caller of `workflow:getWorkflowResult()` receives the error.
#
# + ctx - Workflow context for calling activities
# + input - Order details
# + return - Order result or error
@workflow:Workflow
function processOrder(workflow:Context ctx, OrderInput input) returns OrderResult|error {
    // `check` propagates the error — workflow fails immediately if this activity fails
    boolean _ = check ctx->callActivity(checkInventory, {"item": input.item});

    string _ = check ctx->callActivity(confirmOrder, {
        "orderId": input.orderId,
        "item": input.item
    });

    return {orderId: input.orderId, status: "COMPLETED"};
}

// ---------------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------------

public function main() returns error? {
    io:println("=== Error Propagation Example ===\n");

    // Scenario 1: workflow succeeds
    io:println("--- Scenario 1: valid item (workflow succeeds) ---");
    string wfId1 = check workflow:run(processOrder, {orderId: "ORD-001", item: "laptop"});
    workflow:WorkflowExecutionInfo info1 = check workflow:getWorkflowResult(wfId1);
    io:println("Result: " + info1.result.toString());

    io:println("");

    // Scenario 2: workflow fails — inventory check returns an error
    io:println("--- Scenario 2: unknown item (workflow fails) ---");
    string wfId2 = check workflow:run(processOrder, {orderId: "ORD-002", item: "unknown-item"});
    // getWorkflowResult returns a WorkflowExecutionInfo with status "FAILED"
    // and errorMessage populated — it does not return a Ballerina error.
    workflow:WorkflowExecutionInfo info2 = check workflow:getWorkflowResult(wfId2);
    if info2.status == "FAILED" {
        io:println("Workflow failed as expected: " + (info2.errorMessage ?: "unknown error"));
    } else {
        io:println("Result: " + info2.result.toString());
    }
}
