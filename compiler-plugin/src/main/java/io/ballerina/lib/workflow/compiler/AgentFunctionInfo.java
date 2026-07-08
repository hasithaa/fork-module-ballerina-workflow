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

package io.ballerina.lib.workflow.compiler;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Holds information about a {@code @workflow:DurableAgent} function, collected during the code-modifier analysis phase
 * and consumed by {@link WorkflowSourceModifier} to emit the agent's workflow registration (its tools plus the
 * built-in {@code llmChat}/{@code generate} activities).
 *
 * @param functionName   the name of the agent function
 * @param workflowPrefix the import prefix through which {@code ballerina/workflow} is referenced (from the
 *                       {@code @<prefix>:DurableAgent} annotation), used to qualify the built-in activities
 * @param toolRefs       map of tool simple name -> source reference, collected from the arguments of
 *                       {@code ctx.registerActivities(...)} / {@code ctx.registerAgentTools(...)} calls
 * @since 0.6.0
 */
public record AgentFunctionInfo(String functionName, String workflowPrefix, Map<String, String> toolRefs) {

    public AgentFunctionInfo {
        toolRefs = new LinkedHashMap<>(toolRefs);
    }

    @Override
    public Map<String, String> toolRefs() {
        return java.util.Collections.unmodifiableMap(toolRefs);
    }
}
