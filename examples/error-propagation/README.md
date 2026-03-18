# Error Propagation Example

This example demonstrates **error propagation**: when an activity fails, use `check` to propagate the error directly to the workflow caller. The workflow transitions to **Failed** in Temporal and all subsequent steps are skipped.

An HTTP service exposes the workflow so you can try both success and failure scenarios.

See the full pattern explanation in [Handle Errors — Propagate](../../docs/patterns/error-propagation.md).

## What This Example Shows

- Using `check` with `callActivity` to propagate errors
- Workflow transitions to **Failed** when an activity error is not caught
- Full error details visible in the Temporal UI Event History
- HTTP service to try both success and failure paths

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Start the service (IN_MEMORY mode — no server required)

```bash
bal run
```

The HTTP service starts on port **8091**.

### Scenario 1: valid item (workflow succeeds)

```bash
# Start the workflow
curl -s -X POST http://localhost:8091/api/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId": "ORD-001", "item": "laptop"}'

# Get the result (replace <workflow-id>)
curl -s http://localhost:8091/api/orders/<workflow-id>
```

Response:

```json
{"status": "COMPLETED", "result": {"orderId": "ORD-001", "status": "COMPLETED"}}
```

### Scenario 2: unknown item (workflow fails)

```bash
curl -s -X POST http://localhost:8091/api/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId": "ORD-002", "item": "unknown-item"}'

curl -s http://localhost:8091/api/orders/<workflow-id>
```

Response:

```json
{"status": "FAILED", "errorMessage": "Item not found in catalog: unknown-item"}
```

### Running tests

```bash
bal test
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
