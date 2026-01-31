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
// INTEGRATION TESTS - Workflow Execution Tests
// ================================================================================
// 
// These tests use the embedded Temporal test server started by Gradle.
// 
// The test lifecycle is:
// 1. Gradle startTestServer task runs → starts embedded Temporal server
// 2. Gradle writes test Config.toml with the server URL
// 3. Ballerina tests run, connecting to the test server
// 4. Gradle stopTestServer task runs → stops the server
//
// Run with: ./gradlew :workflow-ballerina:test
//
// ================================================================================

import ballerina/test;
import ballerina/time;

// Helper function to generate unique workflow IDs
isolated function integrationUniqueId(string prefix) returns string {
    time:Utc now = time:utcNow();
    int nanoTime = now[0] * 1000000000 + <int>now[1];
    return prefix + "-" + nanoTime.toString();
}

// Record type for integration test workflow input
type IntegrationTestInput record {|
    string id;
    string name;
|};

// Integration test workflow - defined at module level
@Process
function integrationTestWorkflow(IntegrationTestInput input) returns string|error {
    return "Hello from workflow: " + input.name;
}

// Note: Registration and worker startup is handled by setupIntegrationTests() 
// in activity_integration_tests.bal which this test depends on

// Test that uses the embedded Temporal test server
@test:Config {
    groups: ["integration", "activity"],
    dependsOn: [setupIntegrationTests]
}
function testWorkflowExecutionWithTestServer() returns error? {
    // Process was registered in @BeforeSuite
    
    // Start the workflow with unique ID using record type input
    string testId = integrationUniqueId("integration-test");
    IntegrationTestInput input = {id: testId, name: "IntegrationTest"};
    string workflowId = check startProcess(integrationTestWorkflow, input);
    
    test:assertEquals(workflowId, testId, "Workflow ID should match input id");
}
