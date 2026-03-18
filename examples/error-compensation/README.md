# Error Compensation Example (Saga Pattern)

This example demonstrates the **Saga compensation pattern**: when a later step fails after exhausting its retries, the workflow executes compensating activities to reverse earlier committed work, then completes with a rolled-back status.

See the full pattern explanation in [Handle Errors — Compensation](../../docs/patterns/error-compensation.md).

## What This Example Shows

- Executing multiple activities in sequence (step 1 then step 2)
- Retrying step 2 on transient failures with `retryOnError = true, maxRetries = 2`
- Running a compensating activity to undo step 1 when step 2 fails
- Workflow completes with ROLLED_BACK status (not Failed)

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Using IN_MEMORY mode (no server required)

```bash
bal run
```

Expected output:

```text
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

### Using a local Temporal server

Update `Config.toml`:

```toml
[ballerina.workflow]
mode = "LOCAL"
```

Then start your Temporal dev server and run:

```bash
bal run
```

## Building with the local module

```bash
cd ../..
./gradlew :workflow-examples:build
```
