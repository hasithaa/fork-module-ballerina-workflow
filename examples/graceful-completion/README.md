# Graceful Completion Example

This example demonstrates **graceful completion**: when a non-critical side-effect activity fails (e.g., a notification email or audit log), the workflow catches the error, notes the skipped step, and completes successfully. The core business outcome is preserved regardless of the non-critical failure.

An HTTP service exposes the workflow so you can submit orders and observe non-critical failures being tolerated.

See the full pattern explanation in [Handle Errors — Graceful Completion](../../docs/patterns/graceful-completion.md).

## What This Example Shows

- Distinguishing critical activities (use `check`) from non-critical ones (capture `T|error`)
- Retrying non-critical activities once before tolerating failure
- Workflow completes successfully when only non-critical steps fail
- Result message records which steps were skipped

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Start the service (IN_MEMORY mode — no server required)

```bash
bal run
```

The HTTP service starts on port **8094**.

### Start an order

```bash
curl -s -X POST http://localhost:8094/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "orderId": "ORD-001",
    "item": "wireless-headphones",
    "quantity": 1,
    "customerEmail": "alice@example.com"
  }'
```

### Get the result

```bash
curl -s http://localhost:8094/api/orders/<workflow-id>
```

Response:

```json
{"status": "COMPLETED", "result": "Order ORD-001 COMPLETED — reservation RES-ORD-001 (skipped: email)"}
```

The email activity always fails in this demo. Inventory reservation and audit log succeed, so the order completes with an annotation about the skipped step.

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
