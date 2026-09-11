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

import io.temporal.activity.ActivityInfo;
import org.slf4j.LoggerFactory;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;

/**
 * Publishes one structured log record per workflow event — a run started or closed, an activity attempt, a
 * data event delivered — the way {@code ballerinax/metrics.logs} publishes one per HTTP request. A log
 * pipeline turns them into a metrics index without ever touching this runtime's metric registry; the
 * registry counters in {@link WorkflowMetrics} stay for Prometheus.
 * <p>
 * Each record carries {@code logger="workflow-metrics"} and a {@code sample} name, then only structural
 * fields: types, ids, status, duration. Never inputs, results or who decided — those belong to the audit
 * entry and the content log. The task-decision sample is written on the Ballerina side, beside its audit
 * entry. Off when {@code publishMetricSamples} is off; every call is then a flag check.
 *
 * @since 0.9.1
 */
public final class WorkflowSampleLog {

    /** A child of the module logger, so the module's Ballerina-style console handler formats these. */
    private static final Logger SAMPLES = Logger.getLogger("io.ballerina.lib.workflow.observability.samples");
    private static final org.slf4j.Logger LOGGER = LoggerFactory.getLogger(WorkflowSampleLog.class);
    static final String LOGGER_TAG = "workflow-metrics";

    private WorkflowSampleLog() {
    }

    /**
     * A run began executing — fresh progress only; callers gate on replay. Published from the workflow
     * adapter rather than from the client that started the run, so every way a run can begin (a
     * {@code workflow:run}, a management start, a child workflow, a human task, an agent) is one sample.
     *
     * @param workflowType the registered workflow type
     * @param workflowId   the instance id
     * @param runId        the run id
     */
    public static void workflowStarted(String workflowType, String workflowId, String runId) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("workflow_type", workflowType);
        f.put("task_kind", WorkflowMetrics.taskKindOf(workflowType));
        f.put("task_name", WorkflowMetrics.taskNameOf(workflowType));
        f.put("workflow_id", workflowId);
        f.put("run_id", runId);
        record("workflow.started", f);
    }

    /**
     * A run closed — fresh progress only; callers gate on replay.
     *
     * @param workflowType   the registered workflow type
     * @param workflowId     the instance id
     * @param runId          the run id
     * @param durationMillis run start to close
     * @param failed         whether the body ended in an error
     */
    public static void workflowClosed(String workflowType, String workflowId, String runId, long durationMillis,
                                      boolean failed) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("workflow_type", workflowType);
        f.put("task_kind", WorkflowMetrics.taskKindOf(workflowType));
        f.put("task_name", WorkflowMetrics.taskNameOf(workflowType));
        f.put("workflow_id", workflowId);
        f.put("run_id", runId);
        f.put("outcome", failed ? "failure" : "success");
        f.put("duration_seconds", durationMillis / 1000.0);
        record("workflow.closed", f);
    }

    /**
     * One activity attempt finished.
     *
     * @param info           the attempt, as the engine describes it
     * @param durationMillis how long it ran
     * @param failed         whether it threw
     */
    public static void activityExecuted(ActivityInfo info, long durationMillis, boolean failed) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("activity_type", info.getActivityType());
        f.put("workflow_id", info.getWorkflowId());
        f.put("run_id", info.getRunId());
        f.put("attempt", info.getAttempt());
        f.put("outcome", failed ? "failure" : "success");
        f.put("duration_seconds", durationMillis / 1000.0);
        record("activity.executed", f);
    }

    /**
     * A data event delivery was attempted against a running instance, accepted or not — a
     * log-derived total must count failed deliveries like the registry counter does. The
     * name shares the registry's distinct-name budget so a log-derived {@code data_name}
     * dimension stays bounded too. Framework control signals ({@code __wf_suspend},
     * {@code __agent_wake}, …) are not data events and publish no sample.
     *
     * @param dataName   the declared event name
     * @param workflowId the target instance
     * @param failed     whether the delivery failed
     */
    public static void dataSent(String dataName, String workflowId, boolean failed) {
        if (dataName.startsWith("__")) {
            return;
        }
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("data_name", WorkflowMetrics.boundedDataName(dataName));
        f.put("workflow_id", workflowId);
        f.put("outcome", failed ? "failure" : "success");
        record("data.sent", f);
    }

    private static void record(String sample, Map<String, Object> fields) {
        if (!ObservabilityNative.areMetricSamplesPublished()) {
            return;
        }
        try {
            Map<String, Object> all = new LinkedHashMap<>();
            all.put("logger", LOGGER_TAG);
            all.put("sample", sample);
            all.putAll(fields);
            // An empty message and the fields as the record's one parameter: the module's formatter
            // renders a Map parameter as top-level key=value pairs, as ballerina/log would.
            LogRecord entry = new LogRecord(Level.INFO, "");
            entry.setLoggerName(SAMPLES.getName());
            entry.setParameters(new Object[] {all});
            SAMPLES.log(entry);
        } catch (Exception e) {
            // A sample is never worth failing a workflow over.
            LOGGER.debug("Failed to publish workflow sample '{}'", sample, e);
        }
    }
}
