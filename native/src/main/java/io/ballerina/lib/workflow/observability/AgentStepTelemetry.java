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

package io.ballerina.lib.workflow.observability;

import io.temporal.workflow.Workflow;
import io.temporal.workflow.WorkflowInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Records a durable agent's completed steps from the workflow thread. Every step is skipped while the
 * run is replaying — the worker that made the original progress already recorded it — so a step counts
 * once however many times the history is replayed after a restart.
 *
 * @since 0.9.1
 */
public final class AgentStepTelemetry {

    private static final Logger LOGGER = LoggerFactory.getLogger(AgentStepTelemetry.class);

    private AgentStepTelemetry() {
    }

    /**
     * Records one completed step of the current agent run; a no-op under replay. Must be called on the
     * workflow thread.
     *
     * @param step the step that just completed
     */
    public static void record(AgentStep step) {
        try {
            if (Workflow.isReplaying()) {
                return;
            }
            WorkflowInfo info = Workflow.getInfo();
            WorkflowMetrics.recordAgentStep(step);
            WorkflowSampleLog.agentStep(step, info.getWorkflowId(), info.getRunId());
        } catch (Exception e) {
            // Telemetry is never worth failing an agent over.
            LOGGER.debug("Failed to record agent step '{}'", step.event(), e);
        }
    }
}
