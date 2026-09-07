/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com) All Rights Reserved.
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package io.ballerina.lib.workflow.runtime.nativeimpl;

import io.ballerina.lib.workflow.utils.TypesUtil;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;

import java.util.List;

/**
 * What the runtime read from a task's memo while validating a decision on it: the task's declared
 * name, the workflow that created it, and the roles it allows to decide it. Handed back to the
 * Ballerina caller as the decision's receipt, so the audit entry can name the task without a second
 * describe call.
 *
 * @param taskName         the task's declared, workflow-qualified name; {@code null} when the memo lacks it
 * @param parentWorkflowId the workflow that created the task; {@code null} when the memo lacks it
 * @param assignedRoles    the roles allowed to decide the task, in a stable order; empty when none are set
 * @param taskInput        what the person was shown — the human task's input, or the arguments of the activity
 *                         under review — as decoded Java values; {@code null} when the memo lacks it
 * @since 0.9.0
 */
record TaskMemo(String taskName, String parentWorkflowId, List<String> assignedRoles, Object taskInput) {

    /**
     * The receipt returned to Ballerina: a {@code map<anydata>} with {@code taskName} and
     * {@code parentWorkflowId} and {@code taskInput} (each present only when known) and {@code assignedRoles}
     * as a {@code string[]}.
     *
     * @return the receipt map
     */
    BMap<BString, Object> toReceipt() {
        BMap<BString, Object> receipt =
                ValueCreator.createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_ANYDATA));
        if (taskName != null) {
            receipt.put(StringUtils.fromString("taskName"), StringUtils.fromString(taskName));
        }
        if (parentWorkflowId != null) {
            receipt.put(StringUtils.fromString("parentWorkflowId"), StringUtils.fromString(parentWorkflowId));
        }
        if (taskInput != null) {
            receipt.put(StringUtils.fromString("taskInput"), TypesUtil.convertJavaToBallerinaType(taskInput));
        }
        BArray roles = ValueCreator.createArrayValue(TypeCreator.createArrayType(PredefinedTypes.TYPE_STRING));
        for (String role : assignedRoles) {
            roles.append(StringUtils.fromString(role));
        }
        receipt.put(StringUtils.fromString("assignedRoles"), roles);
        return receipt;
    }
}
