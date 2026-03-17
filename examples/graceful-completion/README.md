# Graceful Completion Example

This example demonstrates **graceful completion**: when a non-critical side-effect activity fails (e.g., a notification email or audit log), the workflow catches the error, notes the skipped step, and completes successfully. The core business outcome is preserved regardless of the non-critical failure.

See the full pattern explanation in [Handle Errors — Graceful Completion](../../docs/examples/graceful-completion.md).

## What This Example Shows

- Distinguishing critical activities (use `check`) from non-critical ones (capture `T|error`)
- Retrying non-critical activities once before tolerating failure
- Workflow completes successfully when only non-critical steps fail
- Result message records which steps were skipped

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Using IN_MEMORY mode (no server required)

```bash
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
