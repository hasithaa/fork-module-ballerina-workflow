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

import io.ballerina.lib.workflow.worker.WorkflowWorkerNative;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BFunctionPointer;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;
import io.temporal.workflow.Workflow;

/**
 * Native implementations backing the {@code workflow.observe} Ballerina submodule.
 *
 * @since 0.9.1
 */
public final class ObservabilityNative {

    // Set once at module init from the `workflow.observe` configurables. Read on activity
    // threads, where Ballerina configurables are out of reach; volatile so those threads see
    // the value the init strand wrote.
    private static volatile boolean activityContentCaptured = false;
    private static volatile boolean metricSamplesPublished = true;

    private ObservabilityNative() {
    }

    /**
     * Records the worker-side switches from the {@code workflow.observe} configurables.
     *
     * @param activityContent whether every activity execution logs its arguments and result
     * @param metricSamples   whether the runtime publishes one structured log record per workflow event
     */
    public static void configure(boolean activityContent, boolean metricSamples) {
        activityContentCaptured = activityContent;
        metricSamplesPublished = metricSamples;
    }

    /**
     * Whether the runtime publishes one structured log record per workflow event, for log-based metrics.
     *
     * @return {@code true} when {@code publishMetricSamples} is on
     */
    public static boolean areMetricSamplesPublished() {
        return metricSamplesPublished;
    }

    /**
     * Whether activity executions log their arguments and results.
     *
     * @return {@code true} when {@code captureActivityContent} is on
     */
    public static boolean isActivityContentCaptured() {
        return activityContentCaptured;
    }

    /**
     * Counts one decision a person made on a task. The Ballerina side owns the decision's audit
     * entry and span; this is the metric leg, kept with the other counters.
     *
     * @param taskKind  {@code HUMAN_TASK} or {@code REVIEW_ACTIVITY}
     * @param taskName  the task's declared name, or {@code unknown} when the decision was refused
     *                  before the task was resolved
     * @param action    what was decided
     * @param accepted  whether the runtime accepted the decision
     * @param errorType the refusing error's type name, or empty when accepted
     */
    public static void recordTaskDecisionMetric(BString taskKind, BString taskName, BString action,
                                                boolean accepted, BString errorType) {
        WorkflowMetrics.recordTaskDecision(taskKind.getValue(), taskName.getValue(), action.getValue(),
                                           accepted, errorType.getValue());
    }

    /**
     * The identity tags every span carries, as the standard's identity dimensions: the module, the
     * caller side, the engine endpoint, the task queue, and the local host.
     *
     * @return the identity tag names and values, ready to add to a span
     */
    public static BMap<BString, Object> spanIdentityTags() {
        BMap<BString, Object> tags = ValueCreator.createMapValue(
                TypeCreator.createMapType(PredefinedTypes.TYPE_STRING));
        tags.put(StringUtils.fromString("module"), StringUtils.fromString("workflow"));
        tags.put(StringUtils.fromString("type"), StringUtils.fromString("client"));
        String url = WorkflowWorkerNative.getServerUrl();
        if (url != null && !url.isEmpty()) {
            tags.put(StringUtils.fromString("remote.url"), StringUtils.fromString(url));
        }
        String queue = WorkflowWorkerNative.getTaskQueue();
        if (queue != null && !queue.isEmpty()) {
            tags.put(StringUtils.fromString("task.queue"), StringUtils.fromString(queue));
        }
        tags.put(StringUtils.fromString("host"), StringUtils.fromString(hostName()));
        return tags;
    }

    private static String hostName() {
        try {
            return java.net.InetAddress.getLocalHost().getHostName();
        } catch (Exception e) {
            return "none";
        }
    }

    /**
     * Checks whether the current thread is executing inside a workflow context.
     * <p>
     * Used to suppress span recording from workflow bodies: those are replayed
     * deterministically by the durable engine, so client-side spans emitted from
     * within them would be duplicated on every replay.
     *
     * @return {@code true} if inside a workflow execution, {@code false} otherwise
     */
    public static boolean isInsideWorkflowContext() {
        try {
            Workflow.getInfo();
            return true;
        } catch (Throwable e) {
            return false;
        }
    }

    /**
     * Returns the workflow type name registered for a workflow function.
     *
     * @param processFunction the workflow function pointer
     * @return the workflow type name used by the durable engine
     */
    public static BString workflowTypeNameOf(BFunctionPointer processFunction) {
        String functionName = processFunction.getType().getName();
        return StringUtils.fromString(
                WorkflowWorkerNative.WORKFLOW_TYPE_PREFIX + (functionName == null ? "" : functionName));
    }
}
