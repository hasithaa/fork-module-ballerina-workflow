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

import ballerina/http;
import ballerina/test;

type StartResponse record {|
    string status;
    string workflowId;
    string contactId;
    string message;
|};

type WorkflowResponse record {|
    string workflowId;
    string status;
    SyncResult result;
|};

final http:Client crmSyncClient = check new ("http://localhost:9091/sync");

@test:Config {}
function testSyncNewContact() returns error? {
    string _ = check crmSyncClient->post("/reset", ());

    StartResponse startResp = check crmSyncClient->post("/contact", {
        id: "CONT-TEST-001",
        email: "test@example.com",
        firstName: "Test",
        lastName: "User",
        phone: "+1234567890",
        company: "Test Corp"
    });
    test:assertNotEquals(startResp.workflowId, "", "Workflow ID should not be empty");

    WorkflowResponse result = check crmSyncClient->get(string `/${startResp.workflowId}/result`);
    test:assertEquals(result.status, "COMPLETED", "Workflow should complete successfully");
    test:assertEquals(result.result.status, "CREATED", "Contact should be created in target CRM");
}

@test:Config {}
function testSyncContactValidationFailure() returns error? {
    string _ = check crmSyncClient->post("/reset", ());

    StartResponse startResp = check crmSyncClient->post("/contact", {
        id: "CONT-TEST-002",
        email: "invalid-email",
        firstName: "Test",
        lastName: "User",
        phone: (),
        company: ()
    });

    WorkflowResponse result = check crmSyncClient->get(string `/${startResp.workflowId}/result`);
    test:assertEquals(result.status, "COMPLETED", "Workflow should complete even on validation failure");
    test:assertEquals(result.result.status, "FAILED", "Contact sync should fail validation");
}
