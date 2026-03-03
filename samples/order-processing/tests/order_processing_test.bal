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
function testProcessOrderCompleted() returns error? {
    OrderRequest request = {orderId: "TEST-ORD-001", item: "laptop", quantity: 2};
    string workflowId = check workflow:run(processOrder, request);

    workflow:WorkflowExecutionInfo execInfo = check workflow:getWorkflowResult(workflowId, 30);

    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete successfully");

    if execInfo.result is map<anydata> {
        map<anydata> result = <map<anydata>>execInfo.result;
        test:assertEquals(result["status"], "COMPLETED", "Order should be completed");
        test:assertTrue(result["reservationId"] is string, "Should have a reservation ID");
    } else {
        test:assertFail("Result should be a map representing OrderResult");
    }
}

@test:Config {}
function testProcessOrderOutOfStock() returns error? {
    OrderRequest request = {orderId: "TEST-ORD-002", item: "laptop", quantity: 1000};
    string workflowId = check workflow:run(processOrder, request);

    workflow:WorkflowExecutionInfo execInfo = check workflow:getWorkflowResult(workflowId, 30);

    test:assertEquals(execInfo.status, "COMPLETED", "Workflow should complete even for out-of-stock");

    if execInfo.result is map<anydata> {
        map<anydata> result = <map<anydata>>execInfo.result;
        test:assertEquals(result["status"], "OUT_OF_STOCK", "Order should be out of stock");
    } else {
        test:assertFail("Result should be a map representing OrderResult");
    }
}
