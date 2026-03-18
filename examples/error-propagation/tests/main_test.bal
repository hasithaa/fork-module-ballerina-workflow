import ballerina/http;
import ballerina/test;

type StartResponse record {|
    string workflowId;
|};

type WorkflowResponse record {
    string status;
    OrderResult result;
};

type WorkflowFailedResponse record {
    string status;
    string errorMessage;
};

// ---------------------------------------------------------------------------
// Scenario 1: valid item — workflow succeeds
// ---------------------------------------------------------------------------

@test:Config {}
function testProcessOrderSuccess() returns error? {
    http:Client cl = check new ("http://localhost:8091/api");

    StartResponse startResp = check cl->post("/orders", {orderId: "ORD-TEST-001", item: "laptop"});
    test:assertNotEquals(startResp.workflowId, "", "Workflow ID should not be empty");

    WorkflowResponse result = check cl->get(string `/orders/${startResp.workflowId}`);
    test:assertEquals(result.status, "COMPLETED");
    test:assertEquals(result.result.orderId, "ORD-TEST-001");
    test:assertEquals(result.result.status, "COMPLETED");
}

// ---------------------------------------------------------------------------
// Scenario 2: unknown item — workflow fails with error propagation
// ---------------------------------------------------------------------------

@test:Config {}
function testProcessOrderFailure() returns error? {
    http:Client cl = check new ("http://localhost:8091/api");

    StartResponse startResp = check cl->post("/orders", {orderId: "ORD-TEST-002", item: "unknown-item"});

    WorkflowFailedResponse result = check cl->get(string `/orders/${startResp.workflowId}`);
    test:assertEquals(result.status, "FAILED");
    test:assertTrue(result.errorMessage.includes("Item not found"), "Error should mention item not found");
}
