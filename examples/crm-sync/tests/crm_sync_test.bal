// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/test;
import ballerina/workflow;

@test:Config {}
function testSyncNewContact() returns error? {
    resetCrmData();

    SourceContact contact = {
        id: "CONT-TEST-001",
        email: "test@example.com",
        firstName: "Test",
        lastName: "User",
        phone: "+1234567890",
        company: "Test Corp"
    };
    string workflowId = check workflow:run(syncContact, contact);

    workflow:WorkflowExecutionInfo execInfo = check workflow:getWorkflowResult(workflowId, 30);

    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete successfully");

    if execInfo.result is map<anydata> {
        map<anydata> result = <map<anydata>>execInfo.result;
        test:assertEquals(result["status"], "CREATED", "Contact should be created in target CRM");
        test:assertTrue(result["targetContactId"] is string, "Should have a target contact ID");
    } else {
        test:assertFail("Result should be a map representing SyncResult");
    }
}

@test:Config {}
function testSyncContactValidationFailure() returns error? {
    resetCrmData();

    SourceContact contact = {
        id: "CONT-TEST-002",
        email: "invalid-email",
        firstName: "Test",
        lastName: "User",
        phone: (),
        company: ()
    };
    string workflowId = check workflow:run(syncContact, contact);

    workflow:WorkflowExecutionInfo execInfo = check workflow:getWorkflowResult(workflowId, 30);

    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete even on validation failure");

    if execInfo.result is map<anydata> {
        map<anydata> result = <map<anydata>>execInfo.result;
        test:assertEquals(result["status"], "FAILED", "Contact sync should fail validation");
    } else {
        test:assertFail("Result should be a map representing SyncResult");
    }
}
