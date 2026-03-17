# Example: Human in the Loop (Forward Recovery)

**Pattern:** When automated retries cannot resolve a failure, pause the workflow and wait for a human decision signal before continuing.

**Source:** [`examples/human-in-the-loop/`](../../examples/human-in-the-loop/)

---

## Overview

Some failures cannot be resolved by code alone: a payment dispute, a compliance hold, a fraud alert, or an ambiguous data state all require human judgment. Rather than rolling back (compensation) or failing immediately (propagation), **forward recovery** holds the workflow in a durable paused state and waits for an operator to send a decision.

This is implemented using Ballerina's event (signal) mechanism: the workflow pauses at `wait events.review` and resumes as soon as the reviewer sends a `ReviewDecision` signal via `workflow:sendData()`.

While paused, the workflow is fully durable — worker restarts do not lose state. The signal can also be sent directly from the Temporal UI (see [Recovering via Temporal UI](../handle-errors.md#recovering-workflows-via-temporal-ui)).

---

## Code Walkthrough

### Types

The `ReviewDecision` type is the signal payload. The reviewer chooses whether to approve a retry or cancel the order:

```ballerina
type ReviewDecision record {|
    string reviewerId;
    boolean approved;    // true = retry the charge; false = cancel the order
    string? note;
|};
```

### Activities

`chargeCard` simulates a payment gateway timeout — the kind of transient failure that warrants retries but can escalate to a human review if all retries fail:

```ballerina
@workflow:Activity
function chargeCard(string cardToken, decimal amount) returns string|error {
    return error("Payment gateway timeout: no response from acquirer");
}
```

`chargeCardManualRetry` is structurally identical but labelled distinctly — it appears in the Temporal Event History as a separate activity, making it clear a manual retry was performed:

```ballerina
@workflow:Activity
function chargeCardManualRetry(string cardToken, decimal amount) returns string|error {
    // Gateway has recovered — manual retry succeeds
    return string `TXN-MANUAL-${cardToken}`;
}
```

`notifyReviewTeam` sends an alert so the reviewer knows action is needed:

```ballerina
@workflow:Activity
function notifyReviewTeam(string orderId, string reason) returns string|error {
    // In production: send a Slack/PagerDuty alert or create a ticket
    return "Notified";
}
```

### Workflow

The events parameter `record {| future<ReviewDecision> review; |}` declares that this workflow can receive a `"review"` signal:

```ballerina
@workflow:Workflow
function processOrder(
    workflow:Context ctx,
    OrderInput input,
    record {| future<ReviewDecision> review; |} events
) returns OrderResult|error {

    // Try payment with 3 Temporal retries
    string|error paymentResult = ctx->callActivity(chargeCard, {
        "cardToken": input.cardToken,
        "amount": input.amount
    }, retryOnError = true, maxRetries = 3, retryDelay = 1.0, retryBackoff = 2.0);

    if paymentResult is error {
        // Retries exhausted — notify reviewers and pause
        _ = check ctx->callActivity(notifyReviewTeam, {
            "orderId": input.orderId,
            "reason": paymentResult.message()
        });

        // ⏸ Workflow pauses here — fully durable, survives restarts
        ReviewDecision decision = check wait events.review;

        if !decision.approved {
            return {
                orderId: input.orderId,
                status: "CANCELLED",
                message: string `Cancelled by ${decision.reviewerId}: ${decision.note ?: "no note"}`
            };
        }

        // Reviewer approved — one final manual retry
        string retryResult = check ctx->callActivity(chargeCardManualRetry, {
            "cardToken": input.cardToken,
            "amount": input.amount
        });
        return {orderId: input.orderId, status: "COMPLETED", message: retryResult};
    }

    return {orderId: input.orderId, status: "COMPLETED", message: paymentResult};
}
```

**Key points:**

- `check wait events.review` — the workflow is blocked here until a signal arrives; no CPU is consumed while waiting
- The signal name `"review"` is derived from the field name in the events record
- If the worker restarts while paused, Temporal replays history up to the `wait` and the workflow resumes exactly where it left off
- `chargeCardManualRetry` is a separate activity — the manual retry is a distinct, auditable event in the workflow history

### Sending the Signal

Signals are delivered via `workflow:sendData()`. In production this is called from an HTTP endpoint or dashboard:

```ballerina
check workflow:sendData(processOrder, workflowId, "review", {
    reviewerId: "reviewer-ops-1",
    approved: true,
    note: "Manual gateway check passed"
});
```

The signal name (`"review"`) must exactly match the field name in the events record.

---

## Running the Example

Run with the reviewer approving:

```bash
cd examples/human-in-the-loop
bal run -- approved
```

Expected output:

```
=== Human-in-the-Loop (Forward Recovery) Example ===

Outcome mode: approved

Workflow started: <uuid>

Simulating reviewer decision...
Charging card tok_visa_4242 for amount 799.0
...
Payment failed after retries: Payment gateway timeout: no response from acquirer
[REVIEW NEEDED] Order ORD-001 payment failed: Payment gateway timeout: no response from acquirer
Review team notified. Waiting for decision signal...
Review decision received from reviewer-ops-1: approved=true
Manual retry: charging card tok_visa_4242 for amount 799.0

Workflow completed. Result: {"orderId":"ORD-001","status":"COMPLETED","message":"TXN-MANUAL-tok_visa_4242"}
```

Run with the reviewer cancelling:

```bash
bal run -- cancelled
```

Expected output:

```
...
Review decision received from reviewer-ops-1: approved=false

Workflow completed. Result: {"orderId":"ORD-001","status":"CANCELLED","message":"Cancelled by reviewer-ops-1: Fraud risk — do not retry"}
```

---

## Sending the Signal via Temporal UI

When running against a local or hosted Temporal server (not `IN_MEMORY`), you can send the signal directly from the Temporal Web UI without going through the HTTP endpoint:

1. Open the Temporal Web UI (default: `http://localhost:8233`)
2. Find the running workflow (it will be in **Running** state while waiting)
3. Click **Send Signal**
4. Signal name: `review`
5. Payload:
   ```json
   {"reviewerId": "ops-1", "approved": true, "note": "manually approved"}
   ```
6. Click **Send** — the workflow resumes immediately

This is particularly useful during incidents when the normal signal path is unavailable.

---

## When to Use This Pattern

- Automated retries cannot resolve the failure (fraud, compliance, ambiguous state)
- A human decision — approve, cancel, reroute — is required before the workflow can proceed
- Rolling back (compensation) would lose valuable partial progress
- The failure is infrequent enough that a manual step is acceptable

For failures where rolling back is the right response, see [Error Compensation](error-compensation.md).

---

## What's Next

- [Handle Errors](../handle-errors.md) — Overview of all patterns including Temporal UI recovery
- [Handle Data Events](../handle-events.md) — Full documentation of the signal/event mechanism
- [Error Propagation](error-propagation.md) — Propagate errors to fail the workflow immediately
- [Error Compensation](error-compensation.md) — Roll back committed steps when human review is not needed
