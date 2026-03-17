# Error Fallback Example

This example demonstrates the **fallback pattern**: when a primary activity exhausts its Temporal retries, the error is captured as a value and a secondary activity is called instead. The workflow completes successfully via the fallback path.

See the full pattern explanation in [Handle Errors — Fallback](../../docs/examples/error-fallback.md).

## What This Example Shows

- Opting into Temporal retries with `retryOnError = true, maxRetries = 2`
- Capturing the `T|error` return value after retries are exhausted
- Calling a secondary (fallback) activity when the primary fails
- Workflow completes successfully even when the primary path fails

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Using IN_MEMORY mode (no server required)

```bash
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
