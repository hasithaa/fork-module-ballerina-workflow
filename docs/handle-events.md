# Handle Data Events

Workflows can receive external data while running using future-based event handling. This allows a workflow to pause and wait for signals — such as approvals, payments, or user actions — before continuing execution.

## Overview

1. Define event types as records
2. Add an events parameter to the workflow function with `future<T>` fields
3. Use Ballerina's `wait` keyword to pause until an event arrives
4. Send events to running workflows using `workflow:sendData()`

## Define Event Types

Create record types for each kind of event your workflow expects:

```ballerina
type ApprovalSignal record {|
    string approverId;
    boolean approved;
|};

type PaymentConfirmation record {|
    decimal amount;
    string transactionRef;
|};
```

Event types must be subtypes of `anydata`.

## Add an Events Parameter

Add a third parameter to your workflow function — a record with `future<T>` fields. Each field name becomes the event name:

```ballerina
@workflow:Workflow
function orderProcess(
    workflow:Context ctx,
    OrderInput input,
    record {|
        future<ApprovalSignal> approval;       // Event name: "approval"
        future<PaymentConfirmation> payment;    // Event name: "payment"
    |} events
) returns OrderResult|error {
    // ...
}
```

The runtime automatically manages the futures and delivers events when they arrive.

## Wait for Events

Use Ballerina's `wait` keyword to pause the workflow until an event arrives:

```ballerina
@workflow:Workflow
function orderProcess(
    workflow:Context ctx,
    OrderInput input,
    record {| future<ApprovalSignal> approval; future<PaymentConfirmation> payment; |} events
) returns OrderResult|error {
    // Check inventory first
    boolean inStock = check ctx->callActivity(checkInventory, {"item": input.item});

    if !inStock {
        return {orderId: input.orderId, status: "OUT_OF_STOCK"};
    }

    // Wait for approval (workflow pauses here)
    ApprovalSignal approvalData = check wait events.approval;

    if !approvalData.approved {
        return {orderId: input.orderId, status: "REJECTED"};
    }

    // Wait for payment
    PaymentConfirmation paymentData = check wait events.payment;

    return {
        orderId: input.orderId,
        status: "COMPLETED",
        message: string `Paid ${paymentData.amount} via ${paymentData.transactionRef}`
    };
}
```

## Send Events to a Running Workflow

Use `workflow:sendData()` to deliver an event to a running workflow:

```ballerina
// Start the workflow
string workflowId = check workflow:run(orderProcess, {orderId: "ORD-001", item: "laptop"});

// Send approval event (the dataName must match the field name in the events record)
check workflow:sendData(orderProcess, workflowId, "approval", {
    approverId: "manager-1",
    approved: true
});

// Send payment event
check workflow:sendData(orderProcess, workflowId, "payment", {
    amount: 1999.99,
    transactionRef: "TXN-12345"
});
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `workflow` | The workflow function reference (must be annotated with `@Workflow`) |
| `workflowId` | The ID of the running workflow instance (returned by `workflow:run()`) |
| `dataName` | The event name — must match a field name in the events record |
| `data` | The event payload — must match the type of the corresponding `future<T>` |

## Expose Events via HTTP

A common pattern is to expose event delivery through HTTP endpoints:

```ballerina
import ballerina/http;
import ballerina/workflow;

map<string> activeWorkflows = {};

service /orders on new http:Listener(9090) {
    // Start a workflow
    resource function post .(OrderInput request) returns json|error {
        string workflowId = check workflow:run(orderProcess, request);
        activeWorkflows[request.orderId] = workflowId;
        return {status: "started", workflowId: workflowId};
    }

    // Send payment event to a running workflow
    resource function post [string orderId]/payment(PaymentConfirmation payment) returns json|error {
        string? workflowId = activeWorkflows[orderId];
        if workflowId is () {
            return error("No active workflow for order: " + orderId);
        }
        check workflow:sendData(orderProcess, workflowId, "payment", payment);
        return {status: "payment received"};
    }
}
```

## Conditional Event Waiting

You can wait for events conditionally. Events that are never waited on are simply ignored:

```ballerina
@workflow:Workflow
function conditionalProcess(
    workflow:Context ctx,
    Input input,
    record {| future<ApprovalSignal> approval; future<PaymentConfirmation> payment; |} events
) returns Output|error {
    ApprovalSignal decision = check wait events.approval;

    if decision.approved {
        // Only wait for payment if approved
        PaymentConfirmation pay = check wait events.payment;
        return {status: "PAID", amount: pay.amount};
    }

    return {status: "REJECTED"};
}
```

## What's Next

- [Handle Errors](handle-errors.md) — Error handling patterns

