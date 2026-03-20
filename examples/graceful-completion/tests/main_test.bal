import ballerina/http;
import ballerina/test;

type StartResponse record {|
    string workflowId;
|};

type WorkflowResponse record {
    string status;
    string result;
};

// Email fails (non-critical, skipped), audit succeeds, order completes

@test:Config {}
function testProcessOrderGraceful() returns error? {
    http:Client cl = check new ("http://localhost:8094/api");

    StartResponse startResp = check cl->post("/orders", {
        orderId: "ORD-TEST-001",
        item: "wireless-headphones",
        quantity: 1,
        customerEmail: "alice@example.com"
    });
    test:assertNotEquals(startResp.workflowId, "", "Workflow ID should not be empty");

    WorkflowResponse result = check cl->get(string `/orders/${startResp.workflowId}`);
    test:assertEquals(result.status, "COMPLETED");
    test:assertTrue(result.result.includes("ORD-TEST-001"), "Should contain order ID");
    test:assertTrue(result.result.includes("COMPLETED"), "Should indicate completion");
    test:assertTrue(result.result.includes("skipped: email"), "Should note email was skipped");
}
