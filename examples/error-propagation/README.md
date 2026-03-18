# Error Propagation Example

This example demonstrates **error propagation**: when an activity fails, use `check` to propagate the error directly to the workflow caller. The workflow transitions to **Failed** in Temporal and all subsequent steps are skipped.

See the full pattern explanation in [Handle Errors — Propagate](../../docs/patterns/error-propagation.md).

## What This Example Shows

- Using `check` with `callActivity` to propagate errors
- Workflow transitions to **Failed** when an activity error is not caught
- Full error details visible in the Temporal UI Event History
- Two scenarios: success path and failure path

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Using IN_MEMORY mode (no server required)

```bash
bal run
```

Expected output:

```text
=== Error Propagation Example ===

--- Scenario 1: valid item (workflow succeeds) ---
Checking inventory for: laptop
Confirming order ORD-001 for item: laptop
Result: {"orderId":"ORD-001","status":"COMPLETED"}

--- Scenario 2: unknown item (workflow fails) ---
Checking inventory for: unknown-item
Workflow failed as expected: Item not found in catalog: unknown-item
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
