# Example: Error Fallback

**Pattern:** When the primary activity exhausts its Temporal retries, call a secondary activity instead.

**Source:** [`examples/error-fallback/`](../../examples/error-fallback/)

---

## Overview

A fallback keeps the workflow running when a preferred path is unavailable. The primary activity is configured with Temporal retries for transient failures. If all retries are exhausted, the error arrives as a `T|error` value and the workflow executes an alternative activity.

The workflow completes successfully via the fallback path — it is never marked Failed.

---

## Code Walkthrough

### Activities

`sendEmailNotification` simulates a failing SMTP server — the kind of transient outage that warrants automatic retries:

```ballerina
@workflow:Activity
function sendEmailNotification(string email, string message) returns string|error {
    // Simulate a failing email service
    return error("SMTP server unavailable: connection refused");
}
```

`sendSmsNotification` is the fallback channel:

```ballerina
@workflow:Activity
function sendSmsNotification(string phone, string message) returns string|error {
    return string `SMS delivered to ${phone}`;
}
```

### Workflow

`retryOnError = true` enables Temporal-level retries. `maxRetries = 2` means 3 total attempts (1 initial + 2 retries). After exhaustion the error is returned as a value — the `if result is error` branch catches it and calls the SMS fallback:

```ballerina
@workflow:Workflow
function sendNotification(workflow:Context ctx, NotificationInput input) returns string|error {
    string|error emailResult = ctx->callActivity(sendEmailNotification,
            {"email": input.email, "message": input.message},
            retryOnError = true, maxRetries = 2, retryDelay = 1.0, retryBackoff = 2.0);

    if emailResult is error {
        // Email exhausted retries — fall back to SMS
        string smsResult = check ctx->callActivity(sendSmsNotification,
                {"phone": input.phone, "message": input.message});
        return "Delivered via SMS: " + smsResult;
    }

    return "Delivered via email: " + emailResult;
}
```

**Key points:**

- The `string|error` type (not `check`) captures the error as a value after retries
- The fallback itself uses `check` — if SMS also fails, the error propagates and the workflow fails
- `retryBackoff = 2.0` doubles the delay after each attempt: 1s → 2s → 4s

### Retry Timing

With `retryDelay = 1.0` and `retryBackoff = 2.0`:

| Attempt | Delay before attempt |
|---------|----------------------|
| 1st (initial) | none |
| 2nd (retry 1) | 1.0 s |
| 3rd (retry 2) | 2.0 s |

---

## Running the Example

```bash
cd examples/error-fallback
bal run
```

Expected output:

```
=== Error Fallback Example ===

Attempting email delivery to: user@example.com
Attempting email delivery to: user@example.com
Attempting email delivery to: user@example.com
Email failed after retries: SMTP server unavailable: connection refused
Falling back to SMS...
Delivering SMS to: +1-555-0100
Workflow completed. Result: "Delivered via SMS: SMS delivered to +1-555-0100"
```

---

## When to Use This Pattern

- There are two or more delivery channels / service tiers and the preferred one is unreliable
- You want automatic retries before giving up on the primary path
- The fallback activity can fully substitute for the primary

For rolling back committed work when there is no substitute, see [Error Compensation](error-compensation.md).

---

## What's Next

- [Error Compensation](error-compensation.md) — Undo committed steps via the Saga pattern
- [Graceful Completion](graceful-completion.md) — Tolerate non-critical activity failures
- [Human in the Loop](human-in-the-loop.md) — Pause and wait for a human decision signal
- [Handle Errors](../handle-errors.md) — Overview of all error handling patterns
- [Write Activity Functions](../write-activity-functions.md) — Full `ActivityOptions` reference
