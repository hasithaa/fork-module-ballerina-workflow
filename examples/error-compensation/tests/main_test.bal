import ballerina/http;
import ballerina/test;

type StartResponse record {|
    string workflowId;
|};

type WorkflowResponse record {
    string status;
    string result;
};

// Credit always fails → debit is compensated → workflow returns ROLLED_BACK

@test:Config {}
function testTransferFundsRollback() returns error? {
    http:Client cl = check new ("http://localhost:8092/api");

    StartResponse startResp = check cl->post("/transfers", {
        transferId: "TXN-TEST-001",
        sourceAccount: "ACC-SRC-123",
        destAccount: "ACC-DST-456",
        amount: 500.00
    });
    test:assertNotEquals(startResp.workflowId, "", "Workflow ID should not be empty");

    WorkflowResponse result = check cl->get(string `/transfers/${startResp.workflowId}`);
    test:assertEquals(result.status, "COMPLETED");
    test:assertTrue(result.result.includes("ROLLED_BACK"), "Should indicate rollback");
    test:assertTrue(result.result.includes("Reversed debit"), "Should confirm compensation");
}
