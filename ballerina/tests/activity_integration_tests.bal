// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com) All Rights Reserved.
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

// ================================================================================
// ACTIVITY INTEGRATION TESTS
// ================================================================================
// 
// These tests validate activity registration, invocation, and result handling.
// They run against the embedded Temporal test server started by Gradle.
//
// Test lifecycle:
// 1. Gradle startTestServer task runs → starts embedded Temporal server
// 2. Gradle writes test Config.toml with the server URL
// 3. These tests run, connecting to the test server
// 4. Gradle stopTestServer task runs → stops the server
//
// Run with: ./gradlew :workflow-ballerina:test
//
// ================================================================================

import ballerina/test;
import ballerina/lang.runtime;
import ballerina/time;

// Helper function to generate unique workflow IDs
isolated function uniqueId(string prefix) returns string {
    time:Utc now = time:utcNow();
    int nanoTime = now[0] * 1000000000 + <int>now[1];
    return prefix + "-" + nanoTime.toString();
}

// Track if test processes have been registered
boolean integrationTestsInitialized = false;

// Initialize integration tests - register processes and start worker
// This is called by setupIntegrationTests which other tests depend on
function initializeIntegrationTests() returns error? {
    if integrationTestsInitialized {
        return;
    }
    
    // Register singleActivityProcess
    map<function> singleActivities = {"greetActivity": greetActivity};
    _ = check registerProcess(singleActivityProcess, "singleActivityProcess", singleActivities);
    
    // Register multiActivityProcess
    map<function> multiActivities = {
        "greetActivity": greetActivity,
        "multiplyActivity": multiplyActivity,
        "getTimestampActivity": getTimestampActivity
    };
    _ = check registerProcess(multiActivityProcess, "multiActivityProcess", multiActivities);
    
    // Register orderProcess
    map<function> orderActivities = {"processOrderActivity": processOrderActivity};
    _ = check registerProcess(orderProcess, "orderProcess", orderActivities);
    
    // Register errorHandlingProcess
    map<function> errorActivities = {
        "failingActivity": failingActivity,
        "greetActivity": greetActivity
    };
    _ = check registerProcess(errorHandlingProcess, "errorHandlingProcess", errorActivities);
    
    // Register arrayProcess
    map<function> arrayActivities = {"sumArrayActivity": sumArrayActivity};
    _ = check registerProcess(arrayProcess, "arrayProcess", arrayActivities);
    
    // Register integrationTestWorkflow from integration_tests.bal (no activities)
    _ = check registerProcess(integrationTestWorkflow, "integrationTestWorkflow");
    
    // Start the singleton worker to poll for tasks
    check startWorker();
    
    integrationTestsInitialized = true;
}

// Setup test that initializes integration test environment
// Other integration tests depend on this to ensure proper initialization order
@test:Config {
    groups: ["integration", "activity"]
}
function setupIntegrationTests() returns error? {
    check initializeIntegrationTests();
}

// ================================================================================
// ACTIVITY DEFINITIONS
// ================================================================================

// Simple string processing activity
@Activity
function greetActivity(string name) returns string|error {
    return "Hello, " + name + "!";
}

// Numeric computation activity
@Activity
function multiplyActivity(int a, int b) returns int|error {
    return a * b;
}

// Activity that returns a record
type OrderResult record {|
    string orderId;
    string status;
    int quantity;
|};

@Activity
function processOrderActivity(string orderId, int quantity) returns OrderResult|error {
    return {
        orderId: orderId,
        status: "PROCESSED",
        quantity: quantity
    };
}

// Activity that returns an error
@Activity
function failingActivity(string reason) returns string|error {
    return error("Activity failed: " + reason);
}

// Activity with no parameters
@Activity
function getTimestampActivity() returns string|error {
    return "2026-01-31T12:00:00Z";
}

// Activity that processes arrays
@Activity
function sumArrayActivity(int[] numbers) returns int|error {
    int sum = 0;
    foreach int n in numbers {
        sum += n;
    }
    return sum;
}

// ================================================================================
// WORKFLOW INPUT RECORD TYPES
// ================================================================================

// Input type for single activity process
type GreetInput record {|
    string id;
    string name;
|};

// Input type for multi-activity process
type MultiActivityInput record {|
    string id;
    string name;
|};

// Input type for order processing workflow
type OrderInput record {|
    string id;
    string orderId;
    int quantity;
|};

// Input type for error handling process
type ErrorHandlingInput record {|
    string id;
    string shouldFail;
|};

// Input type for array processing
type ArrayProcessInput record {|
    string id;
|};

// ================================================================================
// PROCESS DEFINITIONS WITH ACTIVITIES
// ================================================================================

// Simple process that calls one activity
@Process
function singleActivityProcess(Context ctx, GreetInput input) returns string|error {
    // Use Context client's callActivity remote method
    anydata greeting = check ctx->callActivity(greetActivity, input.name);
    return <string>greeting;
}

// Process that calls multiple activities in sequence
@Process
function multiActivityProcess(Context ctx, MultiActivityInput input) returns map<anydata>|error {
    // Use Context client's callActivity remote method
    anydata greetingResult = check ctx->callActivity(greetActivity, input.name);
    string greeting = <string>greetingResult;
    
    anydata productResult = check ctx->callActivity(multiplyActivity, 5, 7);
    int product = <int>productResult;
    
    anydata timestampResult = check ctx->callActivity(getTimestampActivity);
    string timestamp = <string>timestampResult;
    
    return {
        "greeting": greeting,
        "product": product,
        "timestamp": timestamp
    };
}

// Process that calls an activity with a record result
@Process
function orderProcess(Context ctx, OrderInput input) returns OrderResult|error {
    // Use Context client's callActivity remote method
    anydata resultData = check ctx->callActivity(processOrderActivity, input.orderId, input.quantity);
    // Convert map to OrderResult
    map<anydata> resultMap = <map<anydata>>resultData;
    return {
        orderId: <string>resultMap["orderId"],
        status: <string>resultMap["status"],
        quantity: <int>resultMap["quantity"]
    };
}

// Process that handles activity errors
@Process
function errorHandlingProcess(Context ctx, ErrorHandlingInput input) returns string|error {
    // Use Context client's callActivity remote method
    if input.shouldFail == "true" {
        anydata|error result = ctx->callActivity(failingActivity, "Intentional failure");
        if result is error {
            return "Activity error caught: " + result.message();
        }
        return <string>result;
    } else {
        anydata result = check ctx->callActivity(greetActivity, "World");
        return <string>result;
    }
}

// Process that uses array activity
@Process
function arrayProcess(Context ctx, ArrayProcessInput input) returns int|error {
    int[] numbers = [1, 2, 3, 4, 5];
    // Use Context client's callActivity remote method
    anydata result = check ctx->callActivity(sumArrayActivity, numbers);
    return <int>result;
}

// ================================================================================
// TEST CASES - ACTIVITY REGISTRATION
// Note: These tests are disabled because they conflict with the compiler plugin's
// auto-registration. The worker is started at module 'start() lifecycle, and
// registration cannot happen after the worker starts.
// ================================================================================

@test:Config {
    groups: ["integration", "activity"],
    enable: false  // Disabled - conflicts with compiler plugin auto-registration
}
function testActivityRegistrationWithProcess() returns error? {
    // Clear registry before test
    _ = check clearRegistry();
    
    // Create activity map
    map<function> activities = {
        "greetActivity": greetActivity
    };
    
    // Register process with activity
    boolean registered = check registerProcess(singleActivityProcess, "singleActivityProcess", activities);
    test:assertTrue(registered, "Process registration should succeed");
    
    // Verify registration
    WorkflowRegistry registry = check getRegisteredWorkflows();
    test:assertTrue(registry.hasKey("singleActivityProcess"), "Process should be in registry");
    
    ProcessRegistration? info = registry["singleActivityProcess"];
    if info is ProcessRegistration {
        test:assertEquals(info.activities.length(), 1, "Should have 1 activity");
        test:assertEquals(info.activities[0], "greetActivity", "Should have greetActivity");
    } else {
        test:assertFail("Process info should exist");
    }
}

@test:Config {
    groups: ["integration", "activity"],
    enable: false  // Disabled - conflicts with compiler plugin auto-registration
}
function testMultipleActivityRegistration() returns error? {
    // Clear registry before test
    _ = check clearRegistry();
    
    // Create activity map with multiple activities
    map<function> activities = {
        "greetActivity": greetActivity,
        "multiplyActivity": multiplyActivity,
        "getTimestampActivity": getTimestampActivity
    };
    
    // Register process with multiple activities
    boolean registered = check registerProcess(multiActivityProcess, "multiActivityProcess", activities);
    test:assertTrue(registered, "Process registration should succeed");
    
    // Verify all activities are registered
    WorkflowRegistry registry = check getRegisteredWorkflows();
    ProcessRegistration? info = registry["multiActivityProcess"];
    
    if info is ProcessRegistration {
        test:assertEquals(info.activities.length(), 3, "Should have 3 activities");
        
        // Verify each activity is present
        boolean hasGreet = false;
        boolean hasMultiply = false;
        boolean hasTimestamp = false;
        
        foreach string actName in info.activities {
            if actName == "greetActivity" {
                hasGreet = true;
            }
            if actName == "multiplyActivity" {
                hasMultiply = true;
            }
            if actName == "getTimestampActivity" {
                hasTimestamp = true;
            }
        }
        
        test:assertTrue(hasGreet, "Should have greetActivity");
        test:assertTrue(hasMultiply, "Should have multiplyActivity");
        test:assertTrue(hasTimestamp, "Should have getTimestampActivity");
    } else {
        test:assertFail("Process info should exist");
    }
}

// ================================================================================
// TEST CASES - ACTIVITY EXECUTION
// ================================================================================

@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests],
    enable: true
}
function testSingleActivityExecution() returns error? {
    // Compiler plugin auto-generates registerProcess call at module level
    // No need for manual registration
    
    // Start the workflow with unique ID using record type
    string testId = uniqueId("activity-test");
    GreetInput input = {id: testId, name: "Alice"};
    string workflowId = check startProcess(singleActivityProcess, input);
    
    test:assertEquals(workflowId, testId, "Workflow ID should match input id");
    
    // Wait for workflow to complete and get result
    WorkflowExecutionInfo execInfo = check getWorkflowResult(workflowId, 30);
    
    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete successfully");
    test:assertEquals(execInfo.result, "Hello, Alice!", "Result should be the greeting");
}

@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests],
    enable: true
}
function testMultiActivityExecution() returns error? {
    // Compiler plugin auto-generates registerProcess call at module level
    // No need for manual registration
    
    // Start the workflow with unique ID using record type
    string testId = uniqueId("multi-activity");
    MultiActivityInput input = {id: testId, name: "Bob"};
    string workflowId = check startProcess(multiActivityProcess, input);
    
    // Wait for workflow to complete
    WorkflowExecutionInfo execInfo = check getWorkflowResult(workflowId, 30);
    
    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete successfully");
    
    // Verify the result contains all expected values
    if execInfo.result is map<anydata> {
        map<anydata> result = <map<anydata>>execInfo.result;
        test:assertEquals(result["greeting"], "Hello, Bob!", "Greeting should match");
        test:assertEquals(result["product"], 35, "Product should be 5 * 7 = 35");
        test:assertEquals(result["timestamp"], "2026-01-31T12:00:00Z", "Timestamp should match");
    } else {
        test:assertFail("Result should be a map");
    }
}

@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests],
    enable: true
}
function testActivityWithRecordResult() returns error? {
    // Compiler plugin auto-generates registerProcess call at module level
    // No need for manual registration
    
    // Start the workflow with unique ID using record type
    string testId = uniqueId("order-test");
    OrderInput input = {id: testId, orderId: "ORD-12345", quantity: 10};
    string workflowId = check startProcess(orderProcess, input);
    
    // Wait for workflow to complete
    WorkflowExecutionInfo execInfo = check getWorkflowResult(workflowId, 30);
    
    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete successfully");
    
    // Verify the result is the expected OrderResult (serialized as map)
    if execInfo.result is map<anydata> {
        map<anydata> result = <map<anydata>>execInfo.result;
        test:assertEquals(result["orderId"], "ORD-12345", "Order ID should match");
        test:assertEquals(result["status"], "PROCESSED", "Status should be PROCESSED");
        test:assertEquals(result["quantity"], 10, "Quantity should match");
    } else {
        test:assertFail("Result should be a map representing OrderResult, got: " + (execInfo.result is () ? "nil" : "other"));
    }
}

@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests],
    enable: true
}
function testActivityErrorHandling() returns error? {
    // Compiler plugin auto-generates registerProcess call at module level
    // No need for manual registration
    
    // Test with failing activity (unique ID) using record type
    string testId1 = uniqueId("error-test-fail");
    ErrorHandlingInput input1 = {id: testId1, shouldFail: "true"};
    string workflowId1 = check startProcess(errorHandlingProcess, input1);
    
    WorkflowExecutionInfo execInfo1 = check getWorkflowResult(workflowId1, 30);
    
    test:assertEquals(execInfo1.status, "COMPLETED", "Workflow should complete (error was handled)");
    test:assertTrue((<string>execInfo1.result).startsWith("Activity error caught:"), 
        "Result should indicate error was caught");
    
    // Test with successful path (unique ID) using record type
    string testId2 = uniqueId("error-test-success");
    ErrorHandlingInput input2 = {id: testId2, shouldFail: "false"};
    string workflowId2 = check startProcess(errorHandlingProcess, input2);
    
    WorkflowExecutionInfo execInfo2 = check getWorkflowResult(workflowId2, 30);
    
    test:assertEquals(execInfo2.status, "COMPLETED", "Workflow should complete successfully");
    test:assertEquals(execInfo2.result, "Hello, World!", "Result should be the greeting");
}

@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests],
    enable: true
}
function testActivityWithArrayInput() returns error? {
    // Compiler plugin auto-generates registerProcess call at module level
    // No need for manual registration
    
    // Start the workflow with unique ID using record type
    string testId = uniqueId("array-test");
    ArrayProcessInput input = {id: testId};
    string workflowId = check startProcess(arrayProcess, input);
    
    // Wait for workflow to complete
    WorkflowExecutionInfo execInfo = check getWorkflowResult(workflowId, 30);
    
    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete successfully");
    test:assertEquals(execInfo.result, 15, "Sum should be 1+2+3+4+5 = 15");
}

// ================================================================================
// TEST CASES - WORKFLOW STATUS QUERIES
// ================================================================================

@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests],
    enable: true
}
function testGetWorkflowInfo() returns error? {
    // Compiler plugin auto-generates registerProcess call at module level
    // No need for manual registration
    
    // Start the workflow with unique ID using record type
    string testId = uniqueId("info-test");
    GreetInput input = {id: testId, name: "Charlie"};
    string workflowId = check startProcess(singleActivityProcess, input);
    
    // Give it a moment to start
    runtime:sleep(0.5);
    
    // Get workflow info (may still be running or completed)
    WorkflowExecutionInfo execInfo = check getWorkflowInfo(workflowId);
    
    test:assertEquals(execInfo.workflowId, testId, "Workflow ID should match");
    // Status could be RUNNING or COMPLETED depending on timing
    test:assertTrue(execInfo.status == "RUNNING" || execInfo.status == "COMPLETED", 
        "Status should be RUNNING or COMPLETED");
}
