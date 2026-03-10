# Dynamic Workflow Implementation (Temporal Wrapper)

applyTo: "**/native/**/*.java"

---

## Overview

This module provides a Ballerina integration for Temporal using Dynamic Workflow and Dynamic Activity patterns to route workflow executions to Ballerina functions.

## Current Implementation

### 1. Design Principles

1. **Dynamic Workflow Pattern**: Uses Temporal's `DynamicWorkflow` interface to route all workflow types through a single adapter (`BallerinaWorkflowAdapter`)
2. **Dynamic Activity Pattern**: Uses Temporal's `DynamicActivity` interface to route all activity calls through `BallerinaActivityAdapter`
3. **Per-Instance Isolation**: Creates fresh workflow context for each execution
4. **Context Injection**: Workflow `Context` is automatically created and injected as the first parameter
5. **Signal/Query Routing**: Signal and query handlers are dynamically routed

### 2. Native Layer Implementation

#### WorkflowWorkerNative.java
Location: [WorkflowWorkerNative.java](native/src/main/java/io/ballerina/stdlib/workflow/worker/WorkflowWorkerNative.java)

**Registries:**
```java
// Static registry to store process functions (workflow type to BFunctionPointer)
private static final Map<String, BFunctionPointer> PROCESS_REGISTRY = new ConcurrentHashMap<>();

// Static registry to store activity implementations (activity name to BFunctionPointer)
private static final Map<String, BFunctionPointer> ACTIVITY_REGISTRY = new ConcurrentHashMap<>();

// Static registry to store event names per process (process name to list of event names)
private static final Map<String, List<String>> EVENT_REGISTRY = new ConcurrentHashMap<>();

// Legacy service registry for backward compatibility
private static final Map<String, BObject> SERVICE_REGISTRY = new ConcurrentHashMap<>();
```

**Dynamic Workflow Adapter:**
```java
public static class BallerinaWorkflowAdapter implements DynamicWorkflow {
    private BObject serviceObject;  // For backward compatibility
    private String workflowType;
    private final SignalAwaitWrapper signalWrapper = new SignalAwaitWrapper();
    private static final Logger LOGGER = Workflow.getLogger(BallerinaWorkflowAdapter.class);
    
    public BallerinaWorkflowAdapter() {
        // 1. Register dynamic signal handler
        Workflow.registerListener((DynamicSignalHandler) (signalName, encodedArgs) -> {
            LOGGER.debug("Signal received: {}", signalName);
            
            // Extract signal data
            Map<String, Object> signalData = extractSignalData(encodedArgs);
            
            // Optionally invoke remote method handler if service object exists
            Object signalResult = null;
            boolean remoteMethodInvoked = false;
            
            if (this.serviceObject != null) {
                try {
                    Object ballerinaSignalData = convertJavaToBallerinaType(signalData);
                    signalResult = ballerinaRuntime.callMethod(
                        this.serviceObject, signalName,
                        new StrandMetadata(true, Collections.emptyMap()),
                        new Object[]{ballerinaSignalData}
                    );
                    remoteMethodInvoked = true;
                } catch (Exception e) {
                    LOGGER.debug("No remote method '{}' found", signalName);
                }
            }
            
            // Record signal in wrapper (for future completion)
            Object resultToRecord = remoteMethodInvoked ? signalResult : signalData;
            signalWrapper.recordSignal(signalName, resultToRecord);
        });
        
        // 2. Register dynamic query handler
        Workflow.registerListener((DynamicQueryHandler) (queryName, encodedArgs) -> {
            if (this.serviceObject == null) {
                throw new IllegalStateException("Query called before workflow execution");
            }
            
            Object result = ballerinaRuntime.callMethod(
                this.serviceObject, queryName,
                new StrandMetadata(true, Collections.emptyMap()),
                new Object[0]  // Currently supports no-arg queries
            );
            
            if (result instanceof BError) {
                throw new IllegalStateException("Query failed: " + ((BError)result).getMessage());
            }
            
            return convertBallerinaToJavaType(result);
        });
    }
    
    @Override
    public Object execute(EncodedValues args) {
        try {
            // 1. Get workflow type from Temporal
            WorkflowInfo info = Workflow.getInfo();
            this.workflowType = info.getWorkflowType();
            boolean isReplaying = Workflow.isReplaying();
            
            // 2. Get registered process function
            BFunctionPointer processFunction = PROCESS_REGISTRY.get(workflowType);
            BObject templateService = SERVICE_REGISTRY.get(workflowType);  // Fallback
            
            if (processFunction == null && templateService == null) {
                ApplicationFailure failure = ApplicationFailure.newFailure(
                    "Workflow '" + workflowType + "' is not registered",
                    "BallerinaWorkflowNotRegistered"
                );
                failure.setNonRetryable(true);
                throw failure;
            }
            
            // 3. Extract workflow arguments
            Object[] workflowArgs = extractWorkflowArguments(args);
            
            // 4. Upsert correlation keys as search attributes (for workflow discovery)
            if (processFunction != null && workflowArgs.length > 0) {
                Object firstArg = workflowArgs[0];
                if (firstArg instanceof BMap) {
                    upsertCorrelationSearchAttributes((BMap)firstArg, isReplaying);
                }
            }
            
            // 5. Check function signature for Context and Events parameters
            boolean hasContext = processFunction != null && 
                EventExtractor.hasContextParameter(processFunction);
            RecordType eventsRecordType = processFunction != null ?
                EventExtractor.getEventsRecordType(processFunction) : null;
            boolean hasEvents = eventsRecordType != null;
            
            // 6. Build arguments array
            List<Object> argsList = new ArrayList<>();
            
            // Add Context as first argument if needed
            if (hasContext) {
                BObject contextObj = createWorkflowContext();
                argsList.add(contextObj);
            }
            
            // Add workflow input arguments
            for (Object arg : workflowArgs) {
                argsList.add(arg);
            }
            
            // Add events record with TemporalFutureValue for each signal
            if (hasEvents) {
                Scheduler scheduler = getSchedulerFromRuntime();
                BMap<BString, Object> eventsRecord = EventFutureCreator.createEventsRecord(
                    eventsRecordType, signalWrapper, scheduler);
                argsList.add(eventsRecord);
            }
            
            Object[] ballerinaArgs = argsList.toArray();
            
            // 7. Invoke the workflow function or service
            Object result;
            if (processFunction != null) {
                // New pattern: Call function directly
                FPValue fpValue = (FPValue) processFunction;
                fpValue.metadata = new StrandMetadata(true, fpValue.metadata.properties());
                result = processFunction.call(ballerinaRuntime, ballerinaArgs);
            } else {
                // Old pattern: Create service instance and call execute()
                this.serviceObject = createServiceInstance(templateService);
                result = ballerinaRuntime.callMethod(
                    serviceObject, "execute",
                    new StrandMetadata(true, Collections.emptyMap()),
                    ballerinaArgs
                );
            }
            
            // 8. Handle errors
            if (result instanceof BError err) {
                ApplicationFailure failure = ApplicationFailure.newFailure(
                    "Workflow '" + workflowType + "' failed: " + err.getMessage(),
                    "BallerinaWorkflowError",
                    convertBallerinaToJavaType(err.getDetails())
                );
                failure.setNonRetryable(true);
                throw failure;
            }
            
            // 9. Convert result to Java type for Temporal
            return convertBallerinaToJavaType(result);
            
        } catch (TemporalFailure e) {
            throw e;  // Re-throw Temporal failures as-is
        } catch (Exception e) {
            // Check for expected shutdown errors
            if (isDestroyWorkflowThreadError(e)) {
                throw e;  // Expected during shutdown
            }
            
            // Wrap unexpected exceptions
            ApplicationFailure failure = ApplicationFailure.newFailure(
                "Workflow '" + workflowType + "' encountered error: " + e.getMessage(),
                "BallerinaWorkflowExecutionError"
            );
            failure.setNonRetryable(true);
            throw failure;
        }
    }
}
```

**Dynamic Activity Adapter (Named Args Map Pattern):**

Activity arguments are passed through Temporal as a **named map** (`Map<String, Object>`) rather than a positional array. This avoids misalignment when optional parameters are omitted. The adapter reconstructs positional arguments by matching map keys to the function's parameter names using `FunctionType.getParameters()`.

```java
public static class BallerinaActivityAdapter implements DynamicActivity {
    @Override
    public Object execute(EncodedValues args) {
        // 1. Get activity name from Temporal context
        String activityName = Activity.getExecutionContext().getInfo().getActivityType();
        
        // 2. Get registered activity function
        BFunctionPointer activityFunction = ACTIVITY_REGISTRY.get(activityName);
        
        // 3. Decode [namedArgsMap, callConfigMap] from Temporal
        Map<String, Object> namedArgs = args.get(0, Map.class);
        
        // 4. Extract call configuration (failOnError flag)
        boolean failOnError = true;
        try {
            Map<String, Object> callConfigMap = args.get(1, Map.class);
            if (callConfigMap != null && Boolean.TRUE.equals(callConfigMap.get(CALL_CONFIG_MARKER))) {
                Object failOnErrorVal = callConfigMap.get(FAIL_ON_ERROR_KEY);
                if (failOnErrorVal instanceof Boolean) {
                    failOnError = (Boolean) failOnErrorVal;
                }
            }
        } catch (Exception e) { /* No call config available */ }
        
        // 5. Reconstruct positional args from named map using parameter metadata
        FunctionType funcType = (FunctionType) activityFunction.getType();
        Parameter[] params = funcType.getParameters();
        
        // Find last provided parameter index (trailing absent params use defaults)
        int lastProvidedIndex = -1;
        for (int i = 0; i < params.length; i++) {
            if (namedArgs.containsKey(params[i].name)) {
                lastProvidedIndex = i;
            }
        }
        
        // Build positional args, filling gaps with null for intermediate absent params
        List<Object> orderedArgs = new ArrayList<>();
        for (int i = 0; i <= lastProvidedIndex; i++) {
            String paramName = params[i].name;
            if (namedArgs.containsKey(paramName)) {
                orderedArgs.add(convertJavaToBallerinaType(namedArgs.get(paramName)));
            } else {
                orderedArgs.add(null);
            }
        }
        
        // 6. Invoke the activity function
        FPValue fpValue = (FPValue) activityFunction;
        fpValue.metadata = new StrandMetadata(true, fpValue.metadata.properties());
        Object result = activityFunction.call(ballerinaRuntime, orderedArgs.toArray());
        
        // 7. Handle errors based on failOnError
        if (result instanceof BError bError) {
            if (failOnError) {
                throw berrorToApplicationFailure(bError, "ActivityFailed");
            }
            // failOnError=false: return error as normal completion value
        }
        
        return convertBallerinaToJavaType(result);
    }
}
```

#### WorkflowContextNative.java
Location: [WorkflowContextNative.java](native/src/main/java/io/ballerina/stdlib/workflow/context/WorkflowContextNative.java)

Implements the `workflow:Context` client class remote methods:
```java
// Called from Ballerina: ctx->callActivity(activityFunc, {"arg1": val1}, options = {...})
public static Object callActivity(BObject self, BFunctionPointer activityFunction,
        BMap<BString, Object> args, Object options, BTypedesc typedesc) {
    // 1. Extract activity name and build full name (workflowType.activityName)
    String simpleActivityName = activityFunction.getType().getName();
    String workflowType = Workflow.getInfo().getWorkflowType();
    String fullActivityName = workflowType + "." + simpleActivityName;
    
    // 2. Convert BMap args to Java Map for Temporal serialization
    //    Named map avoids positional misalignment with optional params
    Map<String, Object> namedArgs = TypesUtil.convertBMapToMap(args);
    
    // 3. Parse options (failOnError, retryPolicy)
    boolean failOnError = true;
    RetryOptions retryOptions = null;
    if (options != null) {
        BMap<BString, Object> optionsMap = (BMap<BString, Object>) options;
        // Extract failOnError and retryPolicy from options...
    }
    
    // 4. Build ActivityOptions with timeout and retry policy
    ActivityOptions activityOptions = ActivityOptions.newBuilder()
        .setStartToCloseTimeout(Duration.ofMinutes(5))
        .setRetryOptions(retryOptions)
        .build();
    ActivityStub stub = Workflow.newUntypedActivityStub(activityOptions);
    
    // 5. Build call config map for the adapter
    Map<String, Object> callConfig = new HashMap<>();
    callConfig.put(CALL_CONFIG_MARKER, true);
    callConfig.put(FAIL_ON_ERROR_KEY, failOnError);
    
    // 6. Execute activity - passes [namedArgs, callConfig] as two Temporal args
    Object result = stub.execute(fullActivityName, Object.class,
            new Object[] { namedArgs, callConfig });
    
    // 7. Convert result back to Ballerina type using typedesc
    Object ballerinaResult = TypesUtil.convertJavaToBallerinaType(result);
    return TypesUtil.cloneWithType(ballerinaResult, typedesc.getDescribingType());
}
```

Additional Context methods:
```java
// Deterministic time - returns same value during replays
public static long currentTimeMillis(Object contextHandle) {
    return Workflow.currentTimeMillis();
}

// Replay detection
public static boolean isReplaying(Object contextHandle) {
    return Workflow.isReplaying();
}
```

### 3. Compiler Plugin Layer

The compiler plugin has **limited involvement** in dynamic workflow implementation:
- Validates `@Workflow` and `@Activity` function signatures
- Auto-generates `registerWorkflow()` calls
- Validates `ctx->callActivity()` calls use `@Activity` functions (WORKFLOW_107)
- Prevents direct activity calls (WORKFLOW_108)

## Execution Flow

```text
1. Workflow Start (via run)
   └─> WorkflowClient.start(workflowType, input)
       └─> Temporal schedules workflow task on task queue

2. Worker Polls and Executes
   └─> Worker.poll() receives workflow task
       └─> BallerinaWorkflowAdapter (new instance per execution)
           ├─> Constructor registers signal/query handlers
           └─> execute(encodedArgs)
               ├─> Get workflow type from Workflow.getInfo()
               ├─> Lookup processFunction in PROCESS_REGISTRY
               ├─> Extract arguments from encodedArgs
               ├─> Build arguments array (Context?, input, Events?)
               │   ├─> hasContext? → createWorkflowContext()
               │   └─> hasEvents? → EventFutureCreator.createEventsRecord()
               ├─> processFunction.call(ballerinaRuntime, args)
               └─> Convert result to Java type

3. Activity Execution (from within workflow)
   └─> Ballerina: ctx->callActivity(myActivity, {"arg1": val1, "arg2": val2})
       └─> WorkflowContextNative.callActivity()
           ├─> Extract activity name (workflowType.activityName)
           ├─> Convert BMap args to named Map<String,Object>
           ├─> Build callConfig map with failOnError flag
           ├─> Create ActivityStub with options
           ├─> stub.execute(name, [namedArgs, callConfig])
           └─> Temporal schedules activity task

4. Activity Task Execution
   └─> Worker.poll() receives activity task
       └─> BallerinaActivityAdapter.execute(encodedArgs)
           ├─> Get activity name from Activity.getExecutionContext()
           ├─> Lookup activityFunction in ACTIVITY_REGISTRY
           ├─> Decode [namedArgsMap, callConfigMap] from Temporal
           ├─> Reconstruct positional args using FunctionType.getParameters()
           ├─> activityFunction.call(ballerinaRuntime, orderedArgs)
           └─> Convert result to Java type (or throw on error if failOnError)

5. Event Handling
   └─> Ballerina: wait events.approval
       ├─> TemporalFutureValue.getAndSetWaited()
       │   └─> Workflow.await(() -> completableFuture.isDone())
       └─> External: sendData(processFunc, workflowId, "approval", data)
           └─> Temporal delivers event
               └─> DynamicSignalHandler.signal()
                   └─> signalWrapper.recordSignal()
                       └─> promise.complete() → completableFuture.complete()
                           └─> Workflow.await() returns → wait completes
```

## Key Design Points

1. **Single Adapter Classes**: One `BallerinaWorkflowAdapter` and one `BallerinaActivityAdapter` handle all workflows/activities
2. **Registry-Based Routing**: Workflow/activity type → function mapping via concurrent hash maps
3. **Per-Execution Instances**: New `BallerinaWorkflowAdapter` instance per workflow execution (including replays)
4. **Signal Wrapper Per Instance**: Each workflow execution gets its own `SignalAwaitWrapper` for signal isolation
5. **Context Injection**: `workflow:Context` automatically created and injected as first parameter if signature has it
6. **Events Injection**: Events record with `TemporalFutureValue` objects automatically created if signature has it
7. **Error Handling**: Ballerina errors converted to Temporal `ApplicationFailure` (non-retryable). `failOnError` flag controls whether activity errors are retried or returned as values.
8. **Named Args Map Pattern**: Activity arguments are passed through Temporal as a named `Map<String, Object>` rather than a positional array. The adapter reconstructs positional args using `FunctionType.getParameters()` and `Parameter.name`. This avoids misalignment when optional parameters are omitted from the args map.
9. **Call Config Map**: Each activity call includes a separate call config map (`[namedArgs, callConfig]`) carrying the `failOnError` flag and a marker to distinguish it from user data.

## Success Criteria

✅ **Registration:**
- Process functions successfully registered in PROCESS_REGISTRY
- Activity functions successfully registered in ACTIVITY_REGISTRY with qualified names
- Dynamic adapters registered exactly once per worker

✅ **Workflow Execution:**
- `BallerinaWorkflowAdapter` routes to correct process function via PROCESS_REGISTRY
- Context parameter injected when signature requires it
- Events record injected when signature requires it
- Workflow input arguments correctly extracted and passed
- Return values correctly converted to Java types for Temporal
- Ballerina errors converted to `ApplicationFailure` and fail workflow

✅ **Activity Execution:**
- `BallerinaActivityAdapter` routes to correct activity function via ACTIVITY_REGISTRY
- Activity arguments correctly extracted and converted
- Activity return values correctly converted
- Activity errors propagate to workflow as exceptions

✅ **Signal Handling:**
- Dynamic signal handler receives all signals
- Signals recorded in per-instance `SignalAwaitWrapper`
- Signal data correctly converted to Ballerina types
- Optional remote method invocation works for service objects

✅ **Query Handling:**
- Dynamic query handler routes to service object methods
- Query results correctly converted to Java types
- Query errors fail the query operation

✅ **Replay Safety:**
- Each replay creates new `BallerinaWorkflowAdapter` instance
- Signal wrapper correctly handles replay scenarios
- No shared state between workflow executions
- Deterministic execution during replay
