# Example: Graceful Completion

**Pattern:** Tolerate non-critical activity failures and complete the workflow successfully.

**Source:** [`examples/graceful-completion/`](../../examples/graceful-completion/)

---

## Overview

Not every activity is equally important. A reservation or payment is critical — its failure should stop the workflow. A confirmation email or audit log entry is a side effect — its failure should be noted but should not prevent the order from being processed.

Graceful completion separates critical activities (propagated with `check`) from non-critical ones (captured as `T|error`). The workflow records which steps were skipped and completes with a success status.

---

## Code Walkthrough

### Activities

`reserveInventory` is the critical core step. If it fails the workflow must also fail:

```ballerina
@workflow:Activity
function reserveInventory(string orderId, string item, int quantity) returns string|error {
    return string `RES-${orderId}`;
}
```

`sendConfirmationEmail` is a non-critical side effect. It simulates a failing email service:

```ballerina
@workflow:Activity
function sendConfirmationEmail(string email, string orderId) returns string|error {
    // Simulate intermittent email service failure
    return error("Email service temporarily unavailable");
}
```

`writeAuditLog` is another non-critical side effect:

```ballerina
@workflow:Activity
function writeAuditLog(string orderId, string reservationId) returns string|error {
    return string `Audit logged: ${orderId}`;
}
```

### Workflow

The workflow distinguishes critical from non-critical activities by how their return values are handled:

```ballerina
@workflow:Workflow
function processOrder(workflow:Context ctx, OrderInput input) returns string|error {
    // CRITICAL: propagate failure with `check` — order cannot complete without inventory
    string reservationId = check ctx->callActivity(reserveInventory, {
        "orderId": input.orderId,
        "item": input.item,
        "quantity": input.quantity
    });

    string[] skipped = [];

    // NON-CRITICAL: capture the error — failure tolerated, retry once
    string|error emailResult = ctx->callActivity(sendConfirmationEmail,
            {"email": input.customerEmail, "orderId": input.orderId},
            retryOnError = true, maxRetries = 1, retryDelay = 1.0);
    if emailResult is error {
        skipped.push("email");
    }

    // NON-CRITICAL: capture the error — failure tolerated, retry once
    string|error auditResult = ctx->callActivity(writeAuditLog,
            {"orderId": input.orderId, "reservationId": reservationId},
            retryOnError = true, maxRetries = 1, retryDelay = 1.0);
    if auditResult is error {
        skipped.push("audit");
    }

    string suffix = skipped.length() > 0
        ? string ` (skipped: ${string:'join(", ", ...skipped)})`
        : "";

    return string `Order ${input.orderId} COMPLETED — reservation ${reservationId}${suffix}`;
}
```

**Key points:**

- `check` on `reserveInventory` — critical path, propagate any failure
- `string|error` on `sendConfirmationEmail` and `writeAuditLog` — tolerated failures
- Non-critical activities still get one retry (`maxRetries = 1`) before the failure is accepted
- Skipped steps are recorded in the return value for observability
- The Temporal Event History always shows `ActivityTaskFailed` for any failed activity, even tolerated ones

---

## Running the Example

```bash
cd examples/graceful-completion
bal run
```

Expected output:

```
=== Graceful Completion Example ===

Reserving 1 unit(s) of "wireless-headphones" for order ORD-001
Core step completed: RES-ORD-001
Sending confirmation email to alice@example.com for order ORD-001
Sending confirmation email to alice@example.com for order ORD-001
Email skipped: Email service temporarily unavailable
Writing audit log for order ORD-001, reservation RES-ORD-001
Audit logged: ORD-001

Workflow completed. Result: "Order ORD-001 COMPLETED — reservation RES-ORD-001 (skipped: email)"
```

The reservation succeeded, the audit log succeeded, but the email failed after one retry and was skipped. The workflow still completes as COMPLETED.

---

## When to Use This Pattern

- Some activities are pure side effects (notifications, logs, metrics pushes) that do not affect the business outcome
- You want a best-effort attempt with retries before accepting the skip
- The caller should receive a success result even when optional steps fail

For critical failures that must trigger rollback, see [Error Compensation](error-compensation.md). For failures that need human review before proceeding, see [Human in the Loop](human-in-the-loop.md).

---

## What's Next

- [Human in the Loop](human-in-the-loop.md) — Pause and wait for a human decision signal
- [Handle Errors](../handle-errors.md) — Overview of all error handling patterns
- [Error Compensation](error-compensation.md) — Undo committed steps when a critical step fails
- [Write Activity Functions](../write-activity-functions.md) — Full `ActivityOptions` reference
