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

import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.observability.metrics.MetricRegistry;
import io.ballerina.runtime.observability.metrics.noop.NoOpMetricProvider;
import io.temporal.failure.ApplicationFailure;

/**
 * Test-only natives for the metric recorders. The runtime forbids re-setting the process-wide
 * default metric registry, so a multi-module test run cannot enable metrics for real; these
 * drive the recorders through their registry-taking seams against a local no-op registry —
 * the tag assembly and event routing run exactly as in production, only the sink is inert.
 *
 * @since 0.9.1
 */
public final class ObservabilityTestNatives {

    private ObservabilityTestNatives() {
    }

    /**
     * Drives every metric recorder through success, failure, filtered and unmeasured shapes.
     *
     * @return the error-type tag values the exercised failures resolved to
     */
    public static BArray exerciseMetricRecorders() {
        MetricRegistry registry = new MetricRegistry(new NoOpMetricProvider());

        WorkflowMetrics.recordWorkflowStarted(registry, "workflow-exercised");
        WorkflowMetrics.recordWorkflowClosed(registry, "workflow-exercised", 1200, null);
        WorkflowMetrics.recordWorkflowStarted(registry, "humantask-exercisedFlow.approve");
        WorkflowMetrics.recordWorkflowClosed(registry, "humantask-exercisedFlow.approve", 3600, null);
        WorkflowMetrics.recordWorkflowClosed(registry, "reviewactivity-exercisedFlow.step", 60,
                                             ApplicationFailure.newFailure("rejected", "HUMANTASK_REJECTED"));
        ApplicationFailure typedFailure = ApplicationFailure.newFailure("boom", "ExercisedFailure");
        WorkflowMetrics.recordWorkflowClosed(registry, "workflow-exercised", -1, typedFailure);
        WorkflowMetrics.recordActivityExecution(registry, "exercisedStep", "workflow-exercised", 5, null);
        WorkflowMetrics.recordActivityExecution(registry, "exercisedStep", "workflow-exercised", 5,
                                                new IllegalStateException("attempt failed"));
        WorkflowMetrics.recordDataSent(registry, "exercisedEvent", null);
        WorkflowMetrics.recordDataSent(registry, "exercisedEvent", new RuntimeException("gone"));
        WorkflowMetrics.recordTaskDecision(registry, "HUMAN_TASK", "exercised.approve", "complete", true, "");
        WorkflowMetrics.recordTaskDecision(registry, "HUMAN_TASK", "none", "complete", false, "error");

        return StringUtils.fromStringArray(new String[] {
                WorkflowMetrics.errorTypeOf(null),
                WorkflowMetrics.errorTypeOf(typedFailure),
                WorkflowMetrics.errorTypeOf(new IllegalStateException("attempt failed"))
        });
    }

    /**
     * Reports the task dimensions a workflow type resolves to.
     *
     * @param workflowType the workflow type name
     * @return the task kind and task name tag values
     */
    public static BArray deriveTaskDimensions(BString workflowType) {
        String type = workflowType.getValue();
        return StringUtils.fromStringArray(new String[] {
                WorkflowMetrics.taskKindOf(type),
                WorkflowMetrics.taskNameOf(type)
        });
    }

    /**
     * Admits more distinct data names than the series budget and reports what each resolved to.
     *
     * @param count how many distinct names to admit
     * @return the bounded tag value for each name, in admission order
     */
    public static BArray exerciseBoundedDataNames(long count) {
        BArray bounded = ValueCreator.createArrayValue(
                io.ballerina.runtime.api.creators.TypeCreator.createArrayType(
                        io.ballerina.runtime.api.types.PredefinedTypes.TYPE_STRING));
        for (long i = 0; i < count; i++) {
            BString value = StringUtils.fromString(
                    WorkflowMetrics.boundedDataName("exercised-name-" + i));
            bounded.append(value);
        }
        return bounded;
    }
}
