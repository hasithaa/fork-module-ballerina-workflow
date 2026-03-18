import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

type StartResponse record {|
    string workflowId;
|};

type ReviewResponse record {|
    string status;
    string message;
|};

type WorkflowResponse record {
    string status;
    OrderResult result;
};

// ---------------------------------------------------------------------------
// APPROVED PATH — reviewer approves, workflow completes via manual retry
// ---------------------------------------------------------------------------

@test:Config {}
function testApprovedPath() returns error? {
    http:Client cl = check new ("http://localhost:8090/api");

    // Start a new order workflow
    StartResponse startResp = check cl->post("/orders", {
        orderId: "ORD-TEST-001",
        item: "standing-desk",
        amount: 799.00,
        cardToken: "tok_visa_4242"
    });
    test:assertNotEquals(startResp.workflowId, "", "Workflow ID should not be empty");

    // Wait for workflow to reach the review-wait point (after retries exhaust)
    runtime:sleep(10);

    // Send approved review decision
    ReviewResponse reviewResp = check cl->post(string `/orders/${startResp.workflowId}/review`, {
        reviewerId: "reviewer-test-1",
        approved: true,
        note: "Manual gateway check passed"
    });
    test:assertEquals(reviewResp.status, "accepted");

    // Get workflow result (blocks until complete)
    WorkflowResponse result = check cl->get(string `/orders/${startResp.workflowId}`);
    test:assertEquals(result.status, "COMPLETED");
    test:assertEquals(result.result.status, "COMPLETED");
    test:assertEquals(result.result.orderId, "ORD-TEST-001");
    test:assertTrue(result.result.message.includes("TXN-MANUAL"), "Should contain manual retry transaction ID");
}

// ---------------------------------------------------------------------------
// CANCELLED PATH — reviewer cancels, workflow returns CANCELLED status
// ---------------------------------------------------------------------------

@test:Config {}
function testCancelledPath() returns error? {
    http:Client cl = check new ("http://localhost:8090/api");

    // Start a new order workflow
    StartResponse startResp = check cl->post("/orders", {
        orderId: "ORD-TEST-002",
        item: "standing-desk",
        amount: 799.00,
        cardToken: "tok_visa_4242"
    });

    // Wait for workflow to reach the review-wait point
    runtime:sleep(10);

    // Send cancelled review decision
    ReviewResponse _ = check cl->post(string `/orders/${startResp.workflowId}/review`, {
        reviewerId: "reviewer-test-2",
        approved: false,
        note: "Fraud risk"
    });

    // Get workflow result
    WorkflowResponse result = check cl->get(string `/orders/${startResp.workflowId}`);
    test:assertEquals(result.status, "COMPLETED");
    test:assertEquals(result.result.status, "CANCELLED");
    test:assertEquals(result.result.orderId, "ORD-TEST-002");
    test:assertTrue(result.result.message.includes("reviewer-test-2"), "Should contain reviewer ID");
}
