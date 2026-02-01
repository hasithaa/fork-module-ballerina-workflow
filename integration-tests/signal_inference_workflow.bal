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
// SIGNAL INFERENCE WORKFLOW - Tests for optional signalName in sendEvent
// ================================================================================
// 
// These workflows test the optional signalName feature:
// 1. Single signal workflow - signal name should be inferred
// 2. Distinct types workflow - signal name inferred by type matching
// 3. Workflow with no events - tests sendEvent to workflow without signals
//
// ================================================================================

import ballerina/workflow;

// ================================================================================
// SINGLE SIGNAL WORKFLOW - Signal name inference with one signal
// ================================================================================

# Input for single signal inference workflow.
type SingleSignalInferInput record {|
    string id;
    string data;
|};

# Signal data for the single signal.
type SingleInferSignal record {|
    string id;
    string response;
|};

# Result of single signal inference workflow.
type SingleSignalInferResult record {|
    string inputData;
    string signalResponse;
|};

# Workflow with a single signal - signal name should always be inferable.
@workflow:Process
function singleSignalInferWorkflow(
    workflow:Context ctx,
    SingleSignalInferInput input,
    record {|
        future<SingleInferSignal> onlySignal;
    |} signals
) returns SingleSignalInferResult|error {
    SingleInferSignal signal = check wait signals.onlySignal;
    return {
        inputData: input.data,
        signalResponse: signal.response
    };
}

// ================================================================================
// DISTINCT TYPES WORKFLOW - Signal name inference by type structure
// ================================================================================

# Input for distinct types workflow.
type DistinctTypesInput record {|
    string id;
    string requestId;
|};

# First signal with distinct structure (has 'approved' boolean).
type ApprovalTypeSignal record {|
    string id;
    boolean approved;
    string approverName;
|};

# Second signal with distinct structure (has 'amount' decimal).
type PaymentTypeSignal record {|
    string id;
    decimal amount;
    string transactionRef;
|};

# Third signal with distinct structure (has 'rating' int).
type FeedbackTypeSignal record {|
    string id;
    int rating;
    string comment;
|};

# Result of distinct types workflow.
type DistinctTypesResult record {|
    boolean wasApproved;
    decimal paymentAmount;
    int feedbackRating;
|};

# Workflow with three signals of distinct types - each should be inferable.
@workflow:Process
function distinctTypesWorkflow(
    workflow:Context ctx,
    DistinctTypesInput input,
    record {|
        future<ApprovalTypeSignal> approval;
        future<PaymentTypeSignal> payment;
        future<FeedbackTypeSignal> feedback;
    |} signals
) returns DistinctTypesResult|error {
    // Wait for signals in order
    ApprovalTypeSignal approvalSignal = check wait signals.approval;
    PaymentTypeSignal paymentSignal = check wait signals.payment;
    FeedbackTypeSignal feedbackSignal = check wait signals.feedback;
    
    return {
        wasApproved: approvalSignal.approved,
        paymentAmount: paymentSignal.amount,
        feedbackRating: feedbackSignal.rating
    };
}

// ================================================================================
// EXPLICIT SIGNAL NAME WORKFLOW - For testing explicit signalName with ambiguous types
// ================================================================================

# Input for explicit signal name test.
type ExplicitSignalInput record {|
    string id;
    string message;
|};

# Ambiguous signal type 1 - same structure as type 2.
type AmbiguousSignal1 record {|
    string id;
    string value;
|};

# Ambiguous signal type 2 - same structure as type 1.
type AmbiguousSignal2 record {|
    string id;
    string value;
|};

# Result for explicit signal name workflow.
type ExplicitSignalResult record {|
    string fromSignal1;
    string fromSignal2;
|};

# Workflow with ambiguous signal types - requires explicit signalName.
@workflow:Process
function explicitSignalNameWorkflow(
    workflow:Context ctx,
    ExplicitSignalInput input,
    record {|
        future<AmbiguousSignal1> ambig1;
        future<AmbiguousSignal2> ambig2;
    |} signals
) returns ExplicitSignalResult|error {
    AmbiguousSignal1 sig1 = check wait signals.ambig1;
    AmbiguousSignal2 sig2 = check wait signals.ambig2;
    return {
        fromSignal1: sig1.value,
        fromSignal2: sig2.value
    };
}

// ================================================================================
// MIXED SIGNALS WORKFLOW - Some distinct, some need explicit name
// ================================================================================

# Input for mixed signals workflow.
type MixedSignalsInput record {|
    string id;
    string orderId;
|};

# Distinct signal type with unique field (statusCode: int).
type StatusUpdateSignal record {|
    string id;
    int statusCode;
    string description;
|};

# Result for mixed signals workflow.
type MixedSignalsResult record {|
    int finalStatus;
|};

# Workflow with a single distinct signal type.
@workflow:Process
function mixedSignalsWorkflow(
    workflow:Context ctx,
    MixedSignalsInput input,
    record {|
        future<StatusUpdateSignal> statusUpdate;
    |} signals
) returns MixedSignalsResult|error {
    StatusUpdateSignal status = check wait signals.statusUpdate;
    return {
        finalStatus: status.statusCode
    };
}
