# Write Activity Functions

Activity functions encapsulate non-deterministic operations — I/O, API calls, database access, and other side effects. The workflow runtime ensures each activity executes exactly once, even if the workflow replays.

## Define an Activity

Annotate a function with `@workflow:Activity`:

```ballerina
import ballerina/workflow;

@workflow:Activity
function sendEmail(string to, string subject) returns boolean|error {
    // Call external email service
    return true;
}
```

## Function Signature

```ballerina
@workflow:Activity
function <name>(<params...>) returns <ReturnType>|error { }
```

### Parameter and Return Type Rules

- All parameters must be subtypes of `anydata` (e.g., `string`, `int`, `decimal`, `record`, `map`, `array`)
- The return type must be a subtype of `anydata` or `error`
- Activities can return `error?` for operations that don't produce a value

## Call Activities from Workflows

Activities must be called using `ctx->callActivity()` within a workflow. Pass arguments as a `map<anydata>` where keys match the parameter names:

```ballerina
@workflow:Workflow
function orderProcess(workflow:Context ctx, OrderInput input) returns OrderResult|error {
    // Call activity with named arguments
    InventoryStatus status = check ctx->callActivity(checkInventory, {
        "item": input.item,
        "quantity": input.quantity
    });

    if status.inStock {
        check ctx->callActivity(reserveStock, {
            "orderId": input.orderId,
            "item": input.item,
            "quantity": input.quantity
        });
    }

    return {orderId: input.orderId, status: status.inStock ? "RESERVED" : "OUT_OF_STOCK"};
}

@workflow:Activity
function checkInventory(string item, int quantity) returns InventoryStatus|error {
    // Query inventory system
}

@workflow:Activity
function reserveStock(string orderId, string item, int quantity) returns error? {
    // Reserve in inventory system
}
```

## Compile-Time Validation

The compiler enforces proper activity usage:

| Error Code | Rule |
|------------|------|
| **WORKFLOW_107** | `ctx->callActivity()` target must be an `@Activity`-annotated function |
| **WORKFLOW_108** | Direct calls to `@Activity` functions inside `@Workflow` functions are not allowed |
| **WORKFLOW_114** | `typedesc` parameter in `@Activity` must use inferred default `<>` with constraint `anydata` |

```ballerina
@workflow:Workflow
function myWorkflow(workflow:Context ctx, Input input) returns Output|error {
    // WORKFLOW_107 — target is not annotated with @Activity
    check ctx->callActivity(someRegularFunction, {});

    // WORKFLOW_108 — direct call not allowed
    check sendEmail(input.email, "Hello");
}
```

## Activity Options

`callActivity` accepts named options after the args map. All fields from `ActivityOptions` can be passed directly as named arguments.

### Default behaviour — errors as values

By default (`retryOnError = false`), any error returned by the activity is handed back to the workflow as a normal return value. No automatic retries occur.

```ballerina
// Default: error returned as a value — workflow handles it
string|error result = ctx->callActivity(riskyActivity, {"data": input.data});
if result is error {
    return "Handled: " + result.message();
}
```

### Opt-in retries

Pass `retryOnError = true` to enable automatic retries. When all retries are exhausted the error propagates and the workflow fails unless caught.

```ballerina
// 3 retries, 2-second initial delay, 1.5x backoff
string result = check ctx->callActivity(sendEmail,
    {"to": email, "subject": subject},
    retryOnError = true, maxRetries = 3, retryDelay = 2.0, retryBackoff = 1.5);
```

### `ActivityOptions` reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `retryOnError` | `boolean` | `false` | Enable automatic retries on failure |
| `maxRetries` | `int` | `0` | Number of retry attempts (`0` = no retries; only used when `retryOnError = true`) |
| `retryDelay` | `decimal` | `1.0` | Initial delay in seconds before the first retry |
| `retryBackoff` | `decimal` | `2.0` | Multiplier applied to `retryDelay` after each attempt (`1.0` = fixed interval) |
| `maxRetryDelay` | `decimal?` | — | Cap on the delay between retries in seconds (optional) |

## What Activities Should Do

Activities are the right place for:

- HTTP/API calls to external services
- Database queries and updates
- File system operations
- Sending emails or notifications
- Any operation with side effects

## What Activities Should Not Do

- Call other activities (activities are flat, not nested)
- Run workflow logic (use workflow functions for orchestration)
- Access workflow context methods

## What's Next

- [Handle Events](handle-events.md) — Receive external data in running workflows
- [Handle Errors](handle-errors.md) — Error handling patterns
