# Example: Error Compensation (Saga Pattern)

**Pattern:** When a later step fails after exhausting retries, run compensating activities to undo earlier committed work.

**Source:** [`examples/error-compensation/`](../../examples/error-compensation/)

---

## Overview

In distributed systems, a multi-step workflow cannot rely on a single database transaction spanning all services. The Saga pattern solves this: each step that commits work has a corresponding **compensating activity** that undoes it. If a downstream step fails, the workflow executes the compensating activities in reverse order, leaving the system in a consistent state.

The workflow completes with a "rolled back" status rather than failing — the rollback itself is the intended outcome.

---

## Code Walkthrough

### Activities

`debitAccount` is step 1 — it commits a change (money leaves the source account):

```ballerina
@workflow:Activity
function debitAccount(string accountId, decimal amount) returns string|error {
    return string `Debited ${amount} from ${accountId}`;
}
```

`creditAccount` is step 2 — it simulates a failing destination bank to trigger the compensation path:

```ballerina
@workflow:Activity
function creditAccount(string accountId, decimal amount) returns string|error {
    // Simulate destination bank unavailable — triggers compensation
    return error(string `Destination bank unavailable for account ${accountId}`);
}
```

`reverseDebit` is the compensating activity for step 1 — it reverses the committed debit:

```ballerina
@workflow:Activity
function reverseDebit(string accountId, decimal amount) returns string|error {
    return string `Reversed debit of ${amount} on ${accountId}`;
}
```

### Workflow

The structure is: commit step 1 → attempt step 2 → if step 2 fails, compensate step 1:

```ballerina
@workflow:Workflow
function transferFunds(workflow:Context ctx, TransferInput input) returns string|error {
    // Step 1: commit the debit — must succeed before we proceed
    string debitConfirm = check ctx->callActivity(debitAccount, {
        "accountId": input.sourceAccount,
        "amount": input.amount
    });

    // Step 2: credit destination — retry twice on transient failures
    string|error creditResult = ctx->callActivity(creditAccount, {
        "accountId": input.destAccount,
        "amount": input.amount
    }, retryOnError = true, maxRetries = 2, retryDelay = 1.0, retryBackoff = 2.0);

    if creditResult is error {
        // Step 2 exhausted retries — compensate by reversing the debit
        string compensation = check ctx->callActivity(reverseDebit, {
            "accountId": input.sourceAccount,
            "amount": input.amount
        });
        return string `Transfer ${input.transferId} ROLLED_BACK. ${compensation}`;
    }

    return string `Transfer ${input.transferId} COMPLETED. ${debitConfirm} -> ${creditResult}`;
}
```

**Key points:**

- Step 1 uses `check` — the workflow fails immediately if the debit itself fails (nothing to compensate)
- Step 2 uses `string|error` — after retries the error is captured as a value
- The compensating activity (`reverseDebit`) uses `check` — if compensation fails, the workflow fails so an operator can investigate
- Each activity in this workflow (debit, credit attempts, reversal) appears as a distinct event in Temporal's Event History

### Scaling to More Steps

For N steps, maintain a list of compensation actions and execute them in reverse:

```ballerina
// Pseudocode for multiple compensation steps
check ctx->callActivity(step1Activity, {...});  // committed
check ctx->callActivity(step2Activity, {...});  // committed
string|error step3Result = ctx->callActivity(step3Activity, {...});

if step3Result is error {
    // Compensate step 2 then step 1 (reverse order)
    check ctx->callActivity(compensateStep2, {...});
    check ctx->callActivity(compensateStep1, {...});
    return "ROLLED_BACK";
}
```

---

## Running the Example

```bash
cd examples/error-compensation
bal run
```

Expected output:

```
=== Error Compensation (Saga Pattern) Example ===

Debiting 500.0 from account ACC-SRC-123
Step 1 committed: Debited 500.0 from ACC-SRC-123
Crediting 500.0 to account ACC-DST-456
Crediting 500.0 to account ACC-DST-456
Crediting 500.0 to account ACC-DST-456
Step 2 failed after retries: Destination bank unavailable for account ACC-DST-456
Running compensation for step 1...
Reversing debit of 500.0 on account ACC-SRC-123

Workflow completed. Result: "Transfer TXN-001 ROLLED_BACK. Reversed debit of 500.0 on ACC-SRC-123"
```

---

## When to Use This Pattern

- Multiple activities commit real-world side effects (database writes, money movements, external API calls) and must all succeed or all be undone
- A distributed transaction / 2PC is not available across all services
- Partial completion leaves the system in an inconsistent state

For a non-critical failure that can simply be skipped, see [Graceful Completion](graceful-completion.md).

---

## What's Next

- [Graceful Completion](graceful-completion.md) — Tolerate non-critical activity failures
- [Human in the Loop](human-in-the-loop.md) — Pause and wait for a human decision instead of rolling back
- [Handle Errors](../handle-errors.md) — Overview of all error handling patterns
- [Write Activity Functions](../write-activity-functions.md) — Full `ActivityOptions` reference
