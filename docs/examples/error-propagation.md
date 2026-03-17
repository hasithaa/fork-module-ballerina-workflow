# Example: Error Propagation

**Pattern:** Propagate activity errors to the workflow caller using `check`.

**Source:** [`examples/error-propagation/`](../../examples/error-propagation/)

---

## Overview

The simplest way to handle an activity failure is to propagate it: the workflow fails immediately and the error is returned to whoever called `workflow:getWorkflowResult()`. Use this when the failure means the workflow cannot meaningfully continue.

Every `ActivityTaskFailed` event is recorded in Temporal's Event History regardless — so observability is always preserved.

---

## Code Walkthrough

### Activities

`checkInventory` returns a deterministic business error when an item is not in the catalog. This is not a transient failure and should not be retried:

```ballerina
@workflow:Activity
function checkInventory(string item) returns boolean|error {
    if item == "unknown-item" {
        return error("Item not found in catalog: " + item);
    }
    return true;
}
```

`confirmOrder` runs only when inventory is available:

```ballerina
@workflow:Activity
function confirmOrder(string orderId, string item) returns string|error {
    return string `Order ${orderId} confirmed for ${item}`;
}
```

### Workflow

`check` is the key. If `checkInventory` returns an `error`, `check` propagates it immediately. `confirmOrder` is never reached and the workflow transitions to **Failed** in Temporal:

```ballerina
@workflow:Workflow
function processOrder(workflow:Context ctx, OrderInput input) returns OrderResult|error {
    boolean _ = check ctx->callActivity(checkInventory, {"item": input.item});

    string _ = check ctx->callActivity(confirmOrder, {
        "orderId": input.orderId,
        "item": input.item
    });

    return {orderId: input.orderId, status: "COMPLETED"};
}
```

### Main Function

Two scenarios are run back-to-back to show success and failure:

```ballerina
public function main() returns error? {
    // Scenario 1: valid item — workflow succeeds
    string wfId1 = check workflow:run(processOrder, {orderId: "ORD-001", item: "laptop"});
    workflow:WorkflowExecutionInfo info1 = check workflow:getWorkflowResult(wfId1);
    io:println("Result: " + info1.result.toString());

    // Scenario 2: unknown item — workflow fails
    string wfId2 = check workflow:run(processOrder, {orderId: "ORD-002", item: "unknown-item"});
    workflow:WorkflowExecutionInfo|error info2 = workflow:getWorkflowResult(wfId2);
    if info2 is error {
        io:println("Workflow failed as expected: " + info2.message());
    }
}
```

---

## Running the Example

```bash
cd examples/error-propagation
bal run
```

Expected output:

```
=== Error Propagation Example ===

--- Scenario 1: valid item (workflow succeeds) ---
Checking inventory for: laptop
Confirming order ORD-001 for item: laptop
Result: {"orderId":"ORD-001","status":"COMPLETED"}

--- Scenario 2: unknown item (workflow fails) ---
Checking inventory for: unknown-item
Workflow failed as expected: Item not found in catalog: unknown-item
```

---

## When to Use This Pattern

- The failed activity represents a terminal business condition (item not found, invalid input, permission denied)
- There is no meaningful fallback or recovery path
- You want the full error visible to the workflow caller

For transient failures that should be retried first, see [Error Fallback](error-fallback.md).

---

## What's Next

- [Error Fallback](error-fallback.md) — Try a secondary activity when the primary fails
- [Error Compensation](error-compensation.md) — Undo committed steps via the Saga pattern
- [Graceful Completion](graceful-completion.md) — Tolerate non-critical activity failures
- [Human in the Loop](human-in-the-loop.md) — Pause and wait for a human decision signal
- [Handle Errors](../handle-errors.md) — Overview of all error handling patterns
- [Write Activity Functions](../write-activity-functions.md) — Activity options and retry configuration
