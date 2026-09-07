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

import com.fasterxml.jackson.databind.ObjectMapper;
import io.temporal.activity.ActivityInfo;
import io.temporal.common.converter.EncodedValues;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;

/**
 * Logs what each activity execution attempt received and produced, when {@code captureActivityContent}
 * is on. Off, every call is a flag check.
 * <p>
 * This is the one place the worker writes business data to a log, and only by request: an activity's
 * arguments and result are the workflow's payload, which the engine already keeps in history. The
 * entry joins the worker's module log — the stream its activity-failure warnings already go to — and
 * never affects execution: whatever cannot be rendered is logged as its {@code toString}, and any
 * failure here is swallowed.
 *
 * @since 0.9.1
 */
public final class ActivityContentLog {

    private static final Logger LOGGER = LoggerFactory.getLogger(ActivityContentLog.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** One value longer than this is cut, so a single oversized payload cannot flood the log. */
    static final int MAX_CHARS = 8192;

    private ActivityContentLog() {
    }

    /**
     * Records one attempt, after it has completed or failed.
     *
     * @param info           the attempt, as the engine describes it
     * @param args           the attempt's encoded arguments; the first is the named-argument map
     * @param durationMillis how long the attempt ran
     * @param result         what the activity returned, already converted to Java values; {@code null} on failure
     * @param failure        what the activity threw; {@code null} on success
     */
    public static void record(ActivityInfo info, EncodedValues args, long durationMillis, Object result,
                              Throwable failure) {
        if (!ObservabilityNative.isActivityContentCaptured()) {
            return;
        }
        try {
            Object namedArgs;
            try {
                namedArgs = args.get(0, Map.class);
            } catch (Exception e) {
                namedArgs = "<undecodable: " + e.getMessage() + ">";
            }
            StringBuilder line = new StringBuilder("Activity execution")
                    .append(" type=").append(info.getActivityType())
                    .append(" workflowId=").append(info.getWorkflowId())
                    .append(" runId=").append(info.getRunId())
                    .append(" activityId=").append(info.getActivityId())
                    .append(" attempt=").append(info.getAttempt())
                    .append(" outcome=").append(failure == null ? "completed" : "failed")
                    .append(" durationMs=").append(durationMillis)
                    .append(" args=").append(render(namedArgs));
            if (failure == null) {
                line.append(" result=").append(render(result));
            } else {
                line.append(" error=").append(render(String.valueOf(failure)));
            }
            LOGGER.info(line.toString());
        } catch (Exception e) {
            LOGGER.debug("Failed to log activity content", e);
        }
    }

    private static String render(Object value) {
        String text;
        try {
            text = MAPPER.writeValueAsString(value);
        } catch (Exception e) {
            text = String.valueOf(value);
        }
        if (text.length() > MAX_CHARS) {
            return text.substring(0, MAX_CHARS) + "…(" + (text.length() - MAX_CHARS) + " more chars)";
        }
        return text;
    }
}
