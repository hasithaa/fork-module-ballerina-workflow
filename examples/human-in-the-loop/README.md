# Human-in-the-Loop (Forward Recovery) Example

This example demonstrates **forward recovery**: when an activity fails and automated retries cannot resolve the problem, the workflow pauses and waits for a human decision signal. The reviewer can approve (trigger one final retry) or cancel the order.

See the full pattern explanation in [Handle Errors — Human in the Loop](../../docs/examples/human-in-the-loop.md).

## What This Example Shows

- Exhausting Temporal retries with `retryOnError = true, maxRetries = 3`
- Pausing the workflow at a `wait events.review` after failure
- Workflow durability: state is preserved across worker restarts while paused
- Sending a decision signal with `workflow:sendData()`
- Two outcomes: reviewer approves (retry) or cancels

## Running the Example

### Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

### Using IN_MEMORY mode (no server required)

Run with reviewer approving the retry:

```bash
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

Run with reviewer cancelling the order:

```bash
bal run -- cancelled
```

Expected output:

```
=== Human-in-the-Loop (Forward Recovery) Example ===

Outcome mode: cancelled
...
Review decision received from reviewer-ops-1: approved=false

Workflow completed. Result: {"orderId":"ORD-001","status":"CANCELLED","message":"Cancelled by reviewer-ops-1: Fraud risk — do not retry"}
```

### Using a local Temporal server

Update `Config.toml`:

```toml
[ballerina.workflow]
mode = "LOCAL"
```

Start your Temporal dev server, then run the workflow. While it is paused waiting for the review signal you can also send the signal directly from the **Temporal Web UI** (see [Handle Errors — Recovering via Temporal UI](../../docs/handle-errors.md#recovering-workflows-via-temporal-ui)).

```bash
bal run -- approved
```

## Building with the local module

```bash
cd ../..
./gradlew :workflow-examples:build
```
