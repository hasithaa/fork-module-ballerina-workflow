import ballerina/http;
import ballerina/test;

type StartResponse record {|
    string workflowId;
|};

type WorkflowResponse record {
    string status;
    string result;
};

// Email always fails → fallback to SMS → workflow succeeds via SMS

@test:Config {}
function testSendNotificationFallback() returns error? {
    http:Client cl = check new ("http://localhost:8093/api");

    StartResponse startResp = check cl->post("/notifications", {
        recipientId: "user-test-1",
        message: "Your order has shipped!",
        email: "user@example.com",
        phone: "+1-555-0100"
    });
    test:assertNotEquals(startResp.workflowId, "", "Workflow ID should not be empty");

    WorkflowResponse result = check cl->get(string `/notifications/${startResp.workflowId}`);
    test:assertEquals(result.status, "COMPLETED");
    test:assertTrue(result.result.includes("SMS"), "Should indicate SMS fallback");
}
