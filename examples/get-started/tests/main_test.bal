import ballerina/test;
import ballerina/workflow;

@test:Config {}
function testProcessOrderSuccess() returns error? {
    string workflowId = check workflow:run(processOrder, {
        orderId: "ORD-TEST-001",
        item: "laptop",
        quantity: 2
    });

    workflow:WorkflowExecutionInfo result = check workflow:getWorkflowResult(workflowId);
    test:assertEquals(result.status, "COMPLETED");

    if result.result is string {
        string resultStr = <string>result.result;
        test:assertTrue(resultStr.includes("ORD-TEST-001"), "Should contain order ID");
        test:assertTrue(resultStr.includes("RES-ORD-TEST-001"), "Should contain reservation ID");
    } else {
        test:assertFail("Expected string result");
    }
}
