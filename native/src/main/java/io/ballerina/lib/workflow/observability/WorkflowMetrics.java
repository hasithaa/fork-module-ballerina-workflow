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
import io.ballerina.runtime.observability.ObserveUtils;
import io.ballerina.runtime.observability.metrics.DefaultMetricRegistry;
import io.ballerina.runtime.observability.metrics.MetricId;
import io.ballerina.runtime.observability.metrics.MetricRegistry;
import io.ballerina.runtime.observability.metrics.StatisticConfig;
import io.ballerina.runtime.observability.metrics.Tag;
import io.temporal.failure.ApplicationFailure;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.InetAddress;
import java.time.Duration;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Records workflow runtime metrics through the Ballerina observability metric registry, following the
 * Ballerina integration observability standard: one {@code workflow_events_total} counter carries every
 * lifecycle event, distinguished by tags; logical metrics (starts, completions, activity attempts, data
 * deliveries, task decisions) are derived by filtering, never given their own metric names.
 * <p>
 * Every increment of a metric carries the same set of label keys — a tag that does not apply to an event
 * holds the sentinel {@code none} rather than being omitted, so tag-filtered aggregations never split or
 * drop series. Each sample also carries the standard identity tags ({@code module}, {@code type},
 * {@code remote_url}, {@code task_queue}, {@code host}), and outcomes use the standard vocabulary:
 * {@code outcome=success|failure} with {@code error_type} set on failures.
 * <p>
 * All metrics are published only when the program is built with {@code observabilityIncluded = true}
 * and metrics are enabled at runtime; otherwise every call is a no-op. Only structural identifiers
 * (workflow types, activity types, declared event names) are used as tag values — never instance-level
 * IDs or business data, keeping tag cardinality bounded.
 * <p>
 * Recording must never affect workflow execution: every method swallows and logs unexpected errors.
 *
 * @since 0.9.1
 */
public final class WorkflowMetrics {

    private static final Logger LOGGER = LoggerFactory.getLogger(WorkflowMetrics.class);

    /** Sentinel for a label that does not apply to an event, keeping label sets uniform. */
    public static final String NONE = "none";

    private static final String EVENTS_METRIC = "workflow_events_total";
    private static final String EVENTS_DESC = "Total workflow lifecycle events, distinguished by tags";

    // Identity tags, present on every sample.
    private static final String TAG_MODULE = "module";
    private static final String TAG_TYPE = "type";
    private static final String TAG_REMOTE_URL = "remote_url";
    private static final String TAG_TASK_QUEUE = "task_queue";
    private static final String TAG_HOST = "host";
    private static final String MODULE_VALUE = "workflow";
    private static final String TYPE_CLIENT = "client";
    private static final String TYPE_WORKER = "worker";

    // Event tags; non-applicable keys carry the sentinel so every increment has the same key set.
    private static final String TAG_EVENT = "event";
    private static final String TAG_WORKFLOW_TYPE = "workflow_type";
    private static final String TAG_ACTIVITY_TYPE = "activity_type";
    private static final String TAG_DATA_NAME = "data_name";
    private static final String TAG_TASK_KIND = "task_kind";
    private static final String TAG_TASK_NAME = "task_name";
    private static final String TAG_ACTION = "action";
    private static final String TAG_OUTCOME = "outcome";
    private static final String TAG_ERROR_TYPE = "error_type";

    private static final String EVENT_STARTED = "started";
    private static final String EVENT_CLOSED = "closed";
    private static final String EVENT_ACTIVITY = "activity_executed";
    private static final String EVENT_DATA_SENT = "data_sent";
    private static final String EVENT_TASK_DECIDED = "task_decided";

    private static final String OUTCOME_SUCCESS = "success";
    private static final String OUTCOME_FAILURE = "failure";

    /** Duration summaries publish p50/p75/p90/p95/p99 over a five-minute sliding window. */
    private static final StatisticConfig DURATION_STATS = StatisticConfig.builder()
            .percentiles(0.5, 0.75, 0.9, 0.95, 0.99)
            .expiry(Duration.ofMinutes(5))
            .build();

    private static final String HOST_NAME = resolveHostName();

    private WorkflowMetrics() {
    }

    /**
     * Records that a run began executing on this worker — fresh progress only; callers gate on replay.
     * The worker's first execution is where every start path (a {@code workflow:run}, a management
     * start, a child workflow, a human task, an agent) converges, so each run counts exactly once.
     *
     * @param workflowType the workflow type name
     */
    public static void recordWorkflowStarted(String workflowType) {
        if (!isMetricsEnabled()) {
            return;
        }
        try {
            recordWorkflowStarted(registry(), workflowType);
        } catch (Exception e) {
            LOGGER.debug("Failed to record workflow started metric", e);
        }
    }

    static void recordWorkflowStarted(MetricRegistry registry, String workflowType) {
        event(registry, EVENT_STARTED, TYPE_WORKER, workflowType, NONE, NONE, NONE, NONE, NONE,
              OUTCOME_SUCCESS, NONE).increment();
    }

    /**
     * Records the completion of a workflow execution on this worker, along with its duration
     * measured from the run start. Callers must gate this on {@code !Workflow.isReplaying()}
     * so replays never double-count completions.
     *
     * @param workflowType   the workflow type name
     * @param durationMillis run duration in milliseconds (ignored when negative)
     * @param failure        the failure that closed the run, or {@code null} when it succeeded
     */
    public static void recordWorkflowClosed(String workflowType, long durationMillis, Throwable failure) {
        if (!isMetricsEnabled()) {
            return;
        }
        try {
            recordWorkflowClosed(registry(), workflowType, durationMillis, failure);
        } catch (Exception e) {
            LOGGER.debug("Failed to record workflow closed metric", e);
        }
    }

    static void recordWorkflowClosed(MetricRegistry registry, String workflowType, long durationMillis,
                                     Throwable failure) {
        boolean failed = failure != null;
        event(registry, EVENT_CLOSED, TYPE_WORKER, workflowType, NONE, NONE, NONE, NONE, NONE,
              failed ? OUTCOME_FAILURE : OUTCOME_SUCCESS, errorTypeOf(failure)).increment();
        if (durationMillis >= 0) {
            Set<Tag> tags = identityTags(TYPE_WORKER);
            tags.add(Tag.of(TAG_WORKFLOW_TYPE, workflowType));
            tags.add(Tag.of(TAG_OUTCOME, failed ? OUTCOME_FAILURE : OUTCOME_SUCCESS));
            registry.gauge(new MetricId("workflow_duration_seconds",
                                        "Workflow execution duration from run start to completion", tags),
                           DURATION_STATS)
                    .setValue(durationMillis / 1000.0);
        }
    }

    /**
     * Records one activity execution attempt on this worker. Activity attempts are never
     * replayed, so every call represents a real execution.
     *
     * @param activityType   the activity type name
     * @param workflowType   the workflow type the attempt ran under
     * @param durationMillis execution duration in milliseconds
     * @param failure        the failure the attempt threw, or {@code null} when it succeeded
     */
    public static void recordActivityExecution(String activityType, String workflowType, long durationMillis,
                                               Throwable failure) {
        if (!isMetricsEnabled()) {
            return;
        }
        try {
            recordActivityExecution(registry(), activityType, workflowType, durationMillis, failure);
        } catch (Exception e) {
            LOGGER.debug("Failed to record activity execution metric", e);
        }
    }

    static void recordActivityExecution(MetricRegistry registry, String activityType, String workflowType,
                                        long durationMillis, Throwable failure) {
        boolean failed = failure != null;
        event(registry, EVENT_ACTIVITY, TYPE_WORKER, workflowType, activityType, NONE, NONE, NONE, NONE,
              failed ? OUTCOME_FAILURE : OUTCOME_SUCCESS, errorTypeOf(failure)).increment();
        if (durationMillis >= 0) {
            Set<Tag> tags = identityTags(TYPE_WORKER);
            tags.add(Tag.of(TAG_WORKFLOW_TYPE, workflowType));
            tags.add(Tag.of(TAG_ACTIVITY_TYPE, activityType));
            tags.add(Tag.of(TAG_OUTCOME, failed ? OUTCOME_FAILURE : OUTCOME_SUCCESS));
            registry.gauge(new MetricId("workflow_activity_duration_seconds",
                                        "Workflow activity execution duration", tags),
                           DURATION_STATS)
                    .setValue(durationMillis / 1000.0);
        }
    }

    /**
     * Records a data event delivery attempted against a running workflow instance by this runtime.
     * Framework control signals ({@code __wf_suspend}, {@code __agent_wake}, …) are not data
     * events and are not counted.
     *
     * @param dataName the declared data/event name the payload was delivered to
     * @param failure  the failure the delivery threw, or {@code null} when it was accepted
     */
    public static void recordDataSent(String dataName, Throwable failure) {
        if (!isMetricsEnabled() || dataName.startsWith("__")) {
            return;
        }
        try {
            recordDataSent(registry(), dataName, failure);
        } catch (Exception e) {
            LOGGER.debug("Failed to record data event metric", e);
        }
    }

    static void recordDataSent(MetricRegistry registry, String dataName, Throwable failure) {
        boolean failed = failure != null;
        event(registry, EVENT_DATA_SENT, TYPE_CLIENT, NONE, NONE, boundedDataName(dataName), NONE, NONE, NONE,
              failed ? OUTCOME_FAILURE : OUTCOME_SUCCESS, errorTypeOf(failure)).increment();
    }

    /**
     * Records one decision a person made on a human task or a review activity, accepted or refused.
     * Task names are declared at compile time and the other tags are closed sets, so the series stay
     * bounded; who decided is deliberately not a tag — it is on the decision's span and audit entry.
     *
     * @param taskKind  {@code HUMAN_TASK} or {@code REVIEW_ACTIVITY}
     * @param taskName  the task's declared name, or {@code unknown} when the decision was refused
     *                  before the task was resolved
     * @param action    what was decided
     * @param accepted  whether the runtime accepted the decision
     * @param errorType the refusing error's type name, or empty/null when accepted
     */
    public static void recordTaskDecision(String taskKind, String taskName, String action, boolean accepted,
                                          String errorType) {
        if (!isMetricsEnabled()) {
            return;
        }
        try {
            recordTaskDecision(registry(), taskKind, taskName, action, accepted, errorType);
        } catch (Exception e) {
            LOGGER.debug("Failed to record task decision metric", e);
        }
    }

    static void recordTaskDecision(MetricRegistry registry, String taskKind, String taskName, String action,
                                   boolean accepted, String errorType) {
        event(registry, EVENT_TASK_DECIDED, TYPE_CLIENT, NONE, NONE, NONE, taskKind, taskName, action,
              accepted ? OUTCOME_SUCCESS : OUTCOME_FAILURE,
              (errorType == null || errorType.isEmpty()) ? NONE : errorType).increment();
    }

    /**
     * The error-type tag value for a failure: the application-level failure type when the engine
     * carries one, else the exception's class name; {@value NONE} for a success.
     *
     * @param failure the failure, or {@code null} on success
     * @return the bounded error type tag value
     */
    public static String errorTypeOf(Throwable failure) {
        if (failure == null) {
            return NONE;
        }
        if (failure instanceof ApplicationFailure applicationFailure && !applicationFailure.getType().isEmpty()) {
            return applicationFailure.getType();
        }
        return failure.getClass().getSimpleName();
    }

    /**
     * The counter cell for one lifecycle event, with the full uniform label set.
     */
    private static io.ballerina.runtime.observability.metrics.Counter event(MetricRegistry registry,
            String event, String type, String workflowType, String activityType, String dataName,
            String taskKind, String taskName, String action, String outcome, String errorType) {
        Set<Tag> tags = identityTags(type);
        tags.add(Tag.of(TAG_EVENT, event));
        tags.add(Tag.of(TAG_WORKFLOW_TYPE, workflowType));
        tags.add(Tag.of(TAG_ACTIVITY_TYPE, activityType));
        tags.add(Tag.of(TAG_DATA_NAME, dataName));
        tags.add(Tag.of(TAG_TASK_KIND, taskKind));
        tags.add(Tag.of(TAG_TASK_NAME, taskName));
        tags.add(Tag.of(TAG_ACTION, action));
        tags.add(Tag.of(TAG_OUTCOME, outcome));
        tags.add(Tag.of(TAG_ERROR_TYPE, errorType));
        return registry.counter(new MetricId(EVENTS_METRIC, EVENTS_DESC, tags));
    }

    /**
     * The identity tags every sample carries: the module, whether the observation was made by a
     * client call or a worker execution, the engine endpoint, the task queue, and the local host.
     *
     * @param type {@code client} or {@code worker}
     * @return a mutable set holding the identity tags
     */
    private static Set<Tag> identityTags(String type) {
        Set<Tag> tags = new HashSet<>();
        tags.add(Tag.of(TAG_MODULE, MODULE_VALUE));
        tags.add(Tag.of(TAG_TYPE, type));
        String url = WorkflowWorkerNative.getServerUrl();
        tags.add(Tag.of(TAG_REMOTE_URL, url == null || url.isEmpty() ? NONE : url));
        String queue = WorkflowWorkerNative.getTaskQueue();
        tags.add(Tag.of(TAG_TASK_QUEUE, queue == null || queue.isEmpty() ? NONE : queue));
        tags.add(Tag.of(TAG_HOST, HOST_NAME));
        return tags;
    }

    private static String resolveHostName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (Exception e) {
            return NONE;
        }
    }

    /**
     * The most distinct {@code data_name} tag values given their own series. Declared event
     * names are compile-time constants for declared workflows, but a dynamic {@code sendData}
     * name skips that validation and reaches here as whatever the caller computed — and every
     * distinct tag set is a new series in the registry and the exporter. Past the cap, new
     * names collapse into {@link #OTHER_DATA_NAME}; the counter still counts, the name is the
     * only thing surrendered.
     */
    private static final int MAX_DATA_NAME_SERIES = 64;
    private static final String OTHER_DATA_NAME = "__other__";
    private static final Set<String> SEEN_DATA_NAMES = ConcurrentHashMap.newKeySet();

    /**
     * The tag value for one delivery: the name itself while the distinct-name budget lasts,
     * {@value #OTHER_DATA_NAME} afterwards. Admission is atomic — the lock-free fast path
     * serves already-admitted names, and a synchronized check-then-add admits new ones, so
     * concurrent senders can never push the registry past the budget. The sample log reuses
     * this so log-derived {@code data_name} dimensions stay within the same budget.
     *
     * @param dataName the delivered event name
     * @return the bounded tag value for the delivery
     */
    static String boundedDataName(String dataName) {
        if (SEEN_DATA_NAMES.contains(dataName)) {
            return dataName;
        }
        synchronized (SEEN_DATA_NAMES) {
            if (SEEN_DATA_NAMES.contains(dataName)) {
                return dataName;
            }
            if (SEEN_DATA_NAMES.size() >= MAX_DATA_NAME_SERIES) {
                return OTHER_DATA_NAME;
            }
            SEEN_DATA_NAMES.add(dataName);
            return dataName;
        }
    }

    private static boolean isMetricsEnabled() {
        return ObserveUtils.isMetricsEnabled() && DefaultMetricRegistry.getInstance() != null;
    }

    private static MetricRegistry registry() {
        return DefaultMetricRegistry.getInstance();
    }
}
