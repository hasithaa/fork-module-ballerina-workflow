# Handle Errors

Activities return errors as ordinary Ballerina values. There are no exceptions, no try/catch blocks, and no "unhandled error crashes the workflow" footgun. Every failure is an explicit, visible code choice.

## How Activity Errors Reach the Workflow

When an activity returns an `error`, the `ballerina/workflow` module records an `ActivityTaskFailed` event in the workflow's history (so the failure is always visible in Temporal's UI and audit log), then delivers the error to the workflow as a normal `T|error` return value. The workflow is never interrupted or crashed automatically.

What happens next is entirely determined by your workflow code:

```ballerina
// The workflow decides — fail, handle, or recover
string|error result = ctx->callActivity(processPayment, {"amount": input.amount});
```

---

## Controlling Retries

By default (`retryOnError = false`), errors are returned immediately as values — no Temporal retries are attempted. This matches Ballerina's standard error-as-value model and is the right default for deterministic business failures (e.g., validation errors, "item not found").

Enable retries when the failure is transient (e.g., network timeouts, intermittent downstream outages):

```ballerina
// Default: error returned immediately as a value, no retries
string|error result = ctx->callActivity(chargeCard, {"amount": input.amount});

// Opt-in retries: Temporal retries the activity up to 3 times before returning the error
string|error retried = ctx->callActivity(chargeCard, {"amount": input.amount},
        retryOnError = true, maxRetries = 3, retryDelay = 2.0, retryBackoff = 1.5);
```

Regardless of whether retries are enabled, the final outcome is the same: the error arrives at the workflow as a `T|error` value. Retries never hide the error from the workflow code.

### Retry Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `retryOnError` | `boolean` | `false` | Enable Temporal-level retries |
| `maxRetries` | `int` | `0` | Maximum number of retry attempts |
| `retryDelay` | `float` | `1.0` | Initial delay in seconds between retries |
| `retryBackoff` | `float` | `2.0` | Exponential backoff multiplier |
| `maxRetryDelay` | `float` | *(none)* | Cap on delay growth |

---

## Error Handling Patterns

### Propagate — Fail the Workflow

Use `check` to propagate the error. The workflow transitions to **Failed** in Temporal, all subsequent steps are skipped, and the caller of `workflow:getWorkflowResult()` receives the error.

```ballerina
@workflow:Workflow
function orderProcess(workflow:Context ctx, OrderInput input) returns OrderResult|error {
    // If checkInventory fails, the error propagates and the workflow is marked Failed
    InventoryStatus status = check ctx->callActivity(checkInventory, {"item": input.item});
    return {orderId: input.orderId, status: "COMPLETED"};
}
```

This is the right pattern when the failure means the workflow cannot meaningfully continue. The full error, including any detail fields, is visible in the Temporal UI under the workflow's **Event History**.

> **Full example:** [examples/error-propagation/](examples/error-propagation.md)

---

### Handle Inline — Inspect the Error Value

Capture the `T|error` return and branch on it. The workflow stays **Running** and continues executing.

```ballerina
@workflow:Workflow
function orderProcess(workflow:Context ctx, OrderInput input) returns OrderResult|error {
    string|error result = ctx->callActivity(failingActivity, {"reason": "Intentional failure"},
                    retryOnError = false);
    if result is error {
        return "Activity error caught: " + result.message();
    }
    return result;
}
```

Use `result.message()` for the error message and pattern-match on specific error types for fine-grained handling.

---

### Fallback — Try an Alternative

When the primary activity exhausts its retries, fall back to a secondary path. The workflow completes successfully via the fallback.

```ballerina
@workflow:Workflow
function sendNotification(workflow:Context ctx, NotificationInput input) returns string|error {
    // Try primary channel with 2 retries
    string|error emailResult = ctx->callActivity(sendEmail,
            {"to": input.email, "message": input.message},
            retryOnError = true, maxRetries = 2, retryDelay = 1.0);

    if emailResult is error {
        // Primary exhausted — fall back to SMS
        string smsResult = check ctx->callActivity(sendSms,
                {"phone": input.phone, "message": input.message});
        return "Delivered via SMS: " + smsResult;
    }

    return "Delivered via email: " + emailResult;
}
```

> **Full example:** [examples/error-fallback/](examples/error-fallback.md)

---

### Compensation (Saga Pattern) — Undo Completed Steps

When a later step fails, run compensating activities to reverse earlier committed work. This is the standard pattern for distributed transactions without two-phase commit.

```ballerina
@workflow:Workflow
function transferFunds(workflow:Context ctx, TransferInput input) returns string|error {
    // Step 1: debit source account — must succeed before continuing
    string step1 = check ctx->callActivity(debitAccount,
            {"accountId": input.sourceAccount, "amount": input.amount});

    // Step 2: credit destination — retry twice on transient failures
    string|error step2Result = ctx->callActivity(creditAccount,
            {"accountId": input.destAccount, "amount": input.amount},
            retryOnError = true, maxRetries = 2, retryDelay = 1.0);

    if step2Result is error {
        // Step 2 failed after retries — compensate by reversing the debit
        string compensation = check ctx->callActivity(debitAccount,
                {"accountId": input.sourceAccount, "amount": -input.amount});
        return "Transfer rolled back: " + compensation;
    }

    return "Transfer completed: " + step1 + " -> " + step2Result;
}
```

Each compensating activity is itself a durable activity call — if the compensation activity fails, it can also be retried or escalated.

> **Full example:** [examples/error-compensation/](examples/error-compensation.md)

---

### Graceful Completion — Tolerate Non-Critical Failures

When the failed activity is not required for the core business outcome (e.g., an audit log, a notification), skip it and let the workflow complete successfully.

```ballerina
@workflow:Workflow
function processOrder(workflow:Context ctx, OrderInput input) returns string|error {
    // Core business step — must succeed
    string coreResult = check ctx->callActivity(reserveInventory, {"item": input.item});

    // Non-critical notification — retried once, but failure is tolerated
    string|error notifyResult = ctx->callActivity(sendOrderConfirmation,
            {"orderId": input.orderId, "email": input.email},
            retryOnError = true, maxRetries = 1, retryDelay = 1.0);

    if notifyResult is error {
        // Log the skip but still complete the workflow successfully
        return coreResult + " (notification skipped: " + notifyResult.message() + ")";
    }

    return coreResult + "; " + notifyResult;
}
```

> **Full example:** [examples/graceful-completion/](examples/graceful-completion.md)

---

## Forward Recovery — Human in the Loop

When an activity fails due to a condition that code alone cannot resolve (e.g., a payment dispute, a compliance hold, an ambiguous data state), you can pause the workflow and wait for a human decision rather than failing immediately. This is called **forward recovery**: instead of rolling back, you hold state and let a person decide how to proceed.

### Define the Decision Event

```ballerina
type ReviewDecision record {|
    string reviewerId;
    boolean approved;     // true = retry the failed step; false = cancel the order
    string? note;
|};
```

### Pause and Wait After Failure

```ballerina
@workflow:Workflow
function orderProcess(
    workflow:Context ctx,
    OrderInput input,
    record {| future<ReviewDecision> review; |} events
) returns OrderResult|error {
    // Attempt payment with retries
    string|error paymentResult = ctx->callActivity(chargeCard,
            {"amount": input.amount, "cardToken": input.cardToken},
            retryOnError = true, maxRetries = 3, retryDelay = 2.0);

    if paymentResult is error {
        // Payment exhausted retries — notify the review team and pause
        check ctx->callActivity(notifyReviewTeam, {
            "orderId": input.orderId,
            "reason": paymentResult.message()
        });

        // Workflow pauses here until a human sends the "review" event
        ReviewDecision decision = check wait events.review;

        if !decision.approved {
            return {
                orderId: input.orderId,
                status: "CANCELLED",
                message: "Cancelled by " + decision.reviewerId + ": " + (decision.note ?: "")
            };
        }

        // Human approved a retry — attempt payment one more time
        string retryPayment = check ctx->callActivity(chargeCard,
                {"amount": input.amount, "cardToken": input.cardToken});
        return {orderId: input.orderId, status: "COMPLETED", message: retryPayment};
    }

    return {orderId: input.orderId, status: "COMPLETED", message: paymentResult};
}
```

### Send the Decision from an HTTP Endpoint

```ballerina
import ballerina/http;
import ballerina/workflow;

map<string> activeWorkflows = {};

service /orders on new http:Listener(9090) {
    resource function post .(OrderInput request) returns json|error {
        string workflowId = check workflow:run(orderProcess, request);
        activeWorkflows[request.orderId] = workflowId;
        return {status: "started", workflowId};
    }

    // Called by a reviewer from an internal dashboard
    resource function post [string orderId]/review(ReviewDecision decision) returns json|error {
        string? workflowId = activeWorkflows[orderId];
        if workflowId is () {
            return error("No active workflow for order: " + orderId);
        }
        check workflow:sendData(orderProcess, workflowId, "review", decision);
        return {status: "decision received"};
    }
}
```

While the workflow is paused waiting for `events.review`, it is fully durable. If the workflow worker restarts, the workflow replays from its history and returns to the `wait` point exactly.

> **Full example:** [examples/human-in-the-loop/](examples/human-in-the-loop.md)

---

## Recovering Workflows via Temporal UI

The Temporal Web UI gives operators direct visibility into workflow failures and provides several tools for manual recovery without requiring code changes or redeployments.

### Inspect a Failed Workflow

1. Open the Temporal Web UI (default: `http://localhost:8233`)
2. Navigate to **Workflows** and filter by status **Failed** or **Timed Out**
3. Click a workflow to see its **Event History** — the `ActivityTaskFailed` event shows the error message, error type, and any detail fields your activity returned
4. The exact Ballerina error message and cause chain are serialized into the failure payload and displayed here

### Reset to a Previous Point

A **workflow reset** replays the workflow from a chosen event, discarding history after that point. Use this when:
- The activity failed due to a bug that has since been fixed
- A transient infrastructure issue caused repeated failures and you want to retry from a known-good state

Steps:
1. In the workflow detail view, click **Reset Workflow**
2. Select the event to reset to — typically the last `WorkflowTaskCompleted` event before the failed activity was scheduled
3. Confirm the reset — Temporal creates a new workflow run from that point, carrying forward all history up to the reset event

After resetting, the workflow worker will pick up the new run and execute the activity again with the fixed code.

### Terminate and Restart

If the workflow state is corrupt or the reset point is unclear, terminate the failed workflow and start a new one with corrected input:

1. In the workflow detail view, click **Terminate Workflow** and provide a reason
2. Start a fresh workflow run via your application API or by calling `workflow:run()` directly with the corrected input

Termination is permanent — it marks the workflow **Terminated** and stops all execution. Use it as a last resort when reset is not appropriate.

### Signal a Paused Workflow

If your workflow is waiting for a human-in-the-loop event (as shown above), you can send the signal directly from the Temporal UI without going through your HTTP API:

1. Open the running workflow's detail view
2. Click **Send Signal**
3. Enter the signal name (must match the field name in the events record, e.g., `"review"`)
4. Paste the JSON payload matching the event type (e.g., `{"reviewerId": "ops-1", "approved": true, "note": "manually approved"}`)
5. Click **Send** — the workflow resumes immediately

This is useful during incidents when the normal signal delivery path is unavailable.

---

## What's Next

- [Error Propagation example](examples/error-propagation.md) — Full walkthrough of the propagate pattern
- [Error Fallback example](examples/error-fallback.md) — Full walkthrough of the fallback pattern
- [Error Compensation example](examples/error-compensation.md) — Full walkthrough of the Saga pattern
- [Graceful Completion example](examples/graceful-completion.md) — Full walkthrough of tolerating non-critical failures
- [Human in the Loop example](examples/human-in-the-loop.md) — Full walkthrough of forward recovery with signals
- [Handle Data Events](handle-events.md) — Signals, human-in-the-loop patterns
- [Write Workflow Functions](write-workflow-functions.md) — Workflow function details
- [Write Activity Functions](write-activity-functions.md) — Activity options and retry configuration
- [API Reference](api-reference.md) — Complete API reference
