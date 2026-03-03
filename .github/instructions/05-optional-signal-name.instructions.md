# Explicit sendData and searchWorkflow API

applyTo: "**/SendEventValidatorTask.java,**/WorkflowNative.java"

---

## Overview

The `sendData()` function requires all parameters explicitly: the workflow function, the target workflow ID, the data name (matching an event field name), and the data payload. There is no signal name inference or automatic correlation-based routing.

For finding workflows by correlation keys, a separate `searchWorkflow()` function is provided. This clean separation gives users full control over workflow identification and data delivery.

## Current Implementation

### 1. Ballerina Layer

#### API Signatures ([functions.bal](ballerina/functions.bal))
```ballerina
# Send data to a running workflow process.
# + workflow - The workflow function (must be annotated with @Workflow)
# + workflowId - The unique workflow ID to send data to
# + dataName - The name identifying the data (must match a field in the events record)
# + data - The data to send
# + return - An error if sending fails, otherwise nil
public isolated function sendData(function workflow, string workflowId, string dataName, anydata data) returns error?;

# Search for a running workflow by correlation keys.
# + workflow - The workflow function (must be annotated with @Workflow)
# + correlationKeys - Map of correlation key names to values
# + return - The workflow ID if found, or an error
public isolated function searchWorkflow(function workflow, map<anydata> correlationKeys) returns string|error;
```

### 2. Compiler Plugin Layer

#### SendEventValidatorTask.java
Location: [SendEventValidatorTask.java](compiler-plugin/src/main/java/io/ballerina/stdlib/workflow/compiler/SendEventValidatorTask.java)

**Purpose**: Minimal validation for `sendData()` calls. Since all parameters are now required, the Ballerina type system enforces correct usage. The task exists as a placeholder for potential future validations (e.g., WORKFLOW_112 warning for ambiguous signal types).

```java
public class SendEventValidatorTask implements AnalysisTask<SyntaxNodeAnalysisContext> {
    @Override
    public void perform(SyntaxNodeAnalysisContext context) {
        // All parameters are now required - type system handles validation
        // Future: could warn about ambiguous signal types (WORKFLOW_112)
    }
}
```

### 3. Native Layer

#### WorkflowNative.java - sendData Implementation
Location: [WorkflowNative.java](native/src/main/java/io/ballerina/stdlib/workflow/runtime/nativeimpl/WorkflowNative.java)

```java
public static Object sendData(Environment env, BFunctionPointer workflowFunction,
        BString workflowId, BString dataName, Object data) {
    try {
        String workflowIdStr = workflowId.getValue();
        String dataNameStr = dataName.getValue();
        Object javaData = TypesUtil.convertBallerinaToJavaType(data);
        WorkflowRuntime.getInstance().sendSignalToWorkflow(workflowIdStr, dataNameStr, javaData);
        return null; // success (error? return type)
    } catch (Exception e) {
        return ErrorCreator.createError(
            StringUtils.fromString("Failed to send data: " + e.getMessage()));
    }
}
```

#### WorkflowNative.java - searchWorkflow Implementation
```java
public static Object searchWorkflow(Environment env, BFunctionPointer workflowFunction,
        BMap<BString, Object> correlationKeys) {
    try {
        String workflowType = WorkflowNative.extractProcessName(workflowFunction);
        Map<String, Object> javaCorrelationKeys = new LinkedHashMap<>();
        for (BString key : correlationKeys.getKeys()) {
            Object value = correlationKeys.get(key);
            javaCorrelationKeys.put(key.getValue(),
                value instanceof BString ? ((BString) value).getValue() : value);
        }
        String workflowId = WorkflowRuntime.getInstance()
            .findWorkflowByCorrelationKeys(workflowType, javaCorrelationKeys);
        if (workflowId == null) {
            return ErrorCreator.createError(
                StringUtils.fromString("No running workflow found for correlation keys"));
        }
        return StringUtils.fromString(workflowId);
    } catch (Exception e) {
        return ErrorCreator.createError(
            StringUtils.fromString("Failed to search workflow: " + e.getMessage()));
    }
}
```

## Usage Examples

### Direct Workflow ID (Most Common)
```ballerina
// Start workflow and get ID
string workflowId = check workflow:run(orderProcess, input);

// Send data using the workflow ID
check workflow:sendData(orderProcess, workflowId, "approval", approvalData);
check workflow:sendData(orderProcess, workflowId, "payment", paymentData);
```

### With Correlation-Based Lookup
```ballerina
// When you don't have the workflow ID, search by correlation keys
string workflowId = check workflow:searchWorkflow(orderProcess, {
    "orderId": "ORD-12345",
    "customerId": "CUST-789"
});

// Then send data using the found workflow ID
check workflow:sendData(orderProcess, workflowId, "payment", paymentData);
```

### Multiple Signals to Same Workflow
```ballerina
@workflow:Workflow
function orderProcess(
    workflow:Context ctx,
    OrderInput input,
    record {|
        future<ApprovalSignal> approval;
        future<PaymentSignal> payment;
    |} events
) returns OrderResult|error {
    ApprovalSignal decision = check wait events.approval;
    if decision.approved {
        PaymentSignal pay = check wait events.payment;
        return processPayment(pay);
    }
    return {status: "REJECTED"};
}

// Send each signal with explicit data name
string wfId = check workflow:run(orderProcess, input);
check workflow:sendData(orderProcess, wfId, "approval", {approved: true, approverName: "John"});
check workflow:sendData(orderProcess, wfId, "payment", {amount: 100.0, transactionRef: "TXN123"});
```

## Success Criteria

✅ **Compile-Time Validation:**
- All `sendData()` parameters are required - enforced by type system
- `searchWorkflow()` parameters are required - enforced by type system
- WORKFLOW_112 warning for ambiguous signal types (same structure) in workflow definition

✅ **Runtime Behavior:**
- `sendData()` delivers data to the correct workflow by ID
- `searchWorkflow()` finds workflows by correlation key values
- Clear error when workflow ID is invalid or not found
- Clear error when no workflow matches correlation keys

✅ **Error Messages:**
- Invalid workflow ID: descriptive error about workflow not found
- Search miss: descriptive error about no matching workflow for given correlation keys
- Type mismatch: runtime error if data doesn't match expected signal type

