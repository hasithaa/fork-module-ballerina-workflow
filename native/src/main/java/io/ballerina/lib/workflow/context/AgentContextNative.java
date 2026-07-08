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

package io.ballerina.lib.workflow.context;

import io.ballerina.lib.workflow.utils.TypesUtil;
import io.ballerina.lib.workflow.worker.WorkflowWorkerNative;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.types.FunctionType;
import io.ballerina.runtime.api.types.Parameter;
import io.ballerina.runtime.api.types.TypeTags;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BFunctionPointer;
import io.ballerina.runtime.api.values.BHandle;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.api.values.BTypedesc;
import io.temporal.workflow.Workflow;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Native implementations backing the {@code workflow:AgentContext} client class and the durable agent loop.
 * <p>
 * The imperative agent body registers tools on the context ({@link #recordTool}); the loop then advertises them to the
 * model ({@link #getToolDefs}) and invokes them / the built-in LLM activities as durable Temporal activities
 * ({@link #callActivity}). Events declared in the agent's signature are reachable via {@link #awaitChatEvent}.
 *
 * @since 0.6.0
 */
public final class AgentContextNative {

    private static final String CALL_CONFIG_MARKER = "__callConfig__";
    private static final String RETRY_ON_ERROR_KEY = "retryOnError";
    private static final String CHAT_EVENT = "chat";

    // Final agent responses keyed by workflowId, so a completed agent's answer can be retrieved
    // (the agent workflow itself returns no value).
    private static final Map<String, String> FINAL_RESPONSES = new ConcurrentHashMap<>();

    private AgentContextNative() {
        // Utility class
    }

    /**
     * Per-execution state for an agent context. Holds the workflow identity, the signal wrapper (for event waits), the
     * declared event names, the registered tools, and the agent's final response.
     */
    public static final class AgentContextInfo {
        private final String workflowId;
        private final String workflowType;
        private final SignalAwaitWrapper signalWrapper;
        private final Set<String> eventNames;
        private final List<ToolMeta> tools = new ArrayList<>();
        private String finalResponse = "";

        public AgentContextInfo(String workflowId, String workflowType, SignalAwaitWrapper signalWrapper,
                                Set<String> eventNames) {
            this.workflowId = workflowId;
            this.workflowType = workflowType;
            this.signalWrapper = signalWrapper;
            this.eventNames = eventNames;
        }

        public String finalResponse() {
            return finalResponse;
        }
    }

    private record ToolMeta(String name, String description, Map<String, Object> schema) { }

    /**
     * Records a tool function on the agent context: derives its name and parameter JSON schema so the loop can
     * advertise it to the model. The function pointer itself is already registered as a Temporal activity at module
     * init (by the compiler plugin), so only metadata is stored here.
     *
     * @param handle the agent context handle
     * @param fn     the tool function pointer
     * @param kind   the tool kind ("activity", "aitool", "humantask") — reserved for iteration-2 behaviour
     * @return null on success, or a Ballerina error
     */
    public static Object recordTool(BHandle handle, BFunctionPointer fn, BString kind) {
        try {
            AgentContextInfo info = (AgentContextInfo) handle.getValue();
            String name = fn.getType().getName();
            if (name == null || name.isBlank()) {
                return ErrorCreator.createError(StringUtils.fromString(
                        "Agent tools must be named module-level functions; anonymous functions are not supported."));
            }
            FunctionType funcType = (FunctionType) fn.getType();
            Parameter[] allParams = funcType.getParameters();
            List<Parameter> dataParams = new ArrayList<>();
            if (allParams != null) {
                for (Parameter p : allParams) {
                    if (p.type.getTag() != TypeTags.TYPEDESC_TAG) {
                        dataParams.add(p);
                    }
                }
            }
            Parameter[] params = dataParams.toArray(new Parameter[0]);
            Map<String, Object> schema = TypesUtil.toParameterSchemaMap(params, 0, params.length);
            info.tools.add(new ToolMeta(name, "Tool " + name, schema));
            return null;
        } catch (Exception e) {
            return ErrorCreator.createError(StringUtils.fromString(
                    "Failed to register agent tool: " + e.getMessage()));
        }
    }

    /**
     * Returns the recorded tools as a JSON string shaped like {@code ai:ChatCompletionFunctions[]}.
     *
     * @param handle the agent context handle
     * @return a JSON array string of {name, description, parameters}
     */
    public static Object getToolDefs(BHandle handle) {
        AgentContextInfo info = (AgentContextInfo) handle.getValue();
        List<Object> defs = new ArrayList<>();
        for (ToolMeta tool : info.tools) {
            Map<String, Object> def = new LinkedHashMap<>();
            def.put("name", tool.name());
            def.put("description", tool.description());
            def.put("parameters", tool.schema());
            defs.add(def);
        }
        return StringUtils.fromString(TypesUtil.toJsonString(defs));
    }

    /**
     * Returns the agent's workflow type (e.g. {@code workflow-orderAgent}).
     *
     * @param handle the agent context handle
     * @return the workflow type
     */
    public static BString getWorkflowType(BHandle handle) {
        AgentContextInfo info = (AgentContextInfo) handle.getValue();
        return StringUtils.fromString(info.workflowType);
    }

    /**
     * Registers the model provider for this agent so the built-in {@code llmChat}/{@code generate} activities can
     * resolve it (keyed by the agent's workflow type).
     *
     * @param handle the agent context handle
     * @param model  the model provider client object
     */
    public static void registerModel(BHandle handle, BObject model) {
        AgentContextInfo info = (AgentContextInfo) handle.getValue();
        WorkflowWorkerNative.putAgentModel(info.workflowType, model);
    }

    /**
     * Stores the agent's final textual response for later retrieval.
     *
     * @param handle   the agent context handle
     * @param response the final response text
     * @return null (always succeeds)
     */
    public static Object setResponse(BHandle handle, BString response) {
        AgentContextInfo info = (AgentContextInfo) handle.getValue();
        info.finalResponse = response.getValue();
        FINAL_RESPONSES.put(info.workflowId, response.getValue());
        return null;
    }

    /**
     * Returns the final textual response recorded for a completed agent, or null if none.
     *
     * @param workflowId the agent's workflow id
     * @return the final response (BString) or null
     */
    public static Object getFinalResponse(BString workflowId) {
        String response = FINAL_RESPONSES.get(workflowId.getValue());
        return response == null ? null : StringUtils.fromString(response);
    }

    /**
     * Waits durably for the agent's {@code chat} event, if the agent declared one. Returns the message string, or
     * null when no chat event is declared.
     *
     * @param handle the agent context handle
     * @return the chat message (BString), null, or a Ballerina error
     */
    public static Object awaitChatEvent(BHandle handle) {
        try {
            AgentContextInfo info = (AgentContextInfo) handle.getValue();
            if (info.eventNames == null || !info.eventNames.contains(CHAT_EVENT)) {
                return null;
            }
            io.temporal.workflow.CompletablePromise<SignalAwaitWrapper.SignalData> future =
                    info.signalWrapper.getSignalFuture(CHAT_EVENT);
            Workflow.await(future::isCompleted);
            Object data = future.get().data();
            Object ballerina = TypesUtil.convertJavaToBallerinaType(data);
            if (ballerina instanceof BString bStr) {
                return bStr;
            }
            return StringUtils.fromString(String.valueOf(ballerina));
        } catch (Exception e) {
            return ErrorCreator.createError(StringUtils.fromString(
                    "Failed to await agent chat event: " + e.getMessage()));
        }
    }

    /**
     * Executes a registered agent tool (or a built-in activity such as {@code llmChat}) as a durable Temporal
     * activity, resolving the activity type from the current workflow. Mirrors the NoRetry path of
     * {@link WorkflowContextNative#callActivity} but resolves the activity by name rather than by function pointer.
     *
     * @param nameB the activity/tool name
     * @param args  named arguments
     * @param td    the expected return type (dependent typing)
     * @return the activity result coerced to {@code td}, or a Ballerina error
     */
    @SuppressWarnings("unchecked")
    public static Object callActivity(BString nameB, BMap<BString, Object> args, BTypedesc td) {
        try {
            String workflowType = Workflow.getInfo().getWorkflowType();
            String fullActivityName = workflowType + "." + nameB.getValue();

            Map<String, Object> namedArgs = new HashMap<>();
            for (BString key : args.getKeys()) {
                namedArgs.put(key.getValue(), TypesUtil.convertBallerinaToJavaType(args.get(key)));
            }

            Map<String, Object> callConfig = new HashMap<>();
            callConfig.put(CALL_CONFIG_MARKER, true);
            callConfig.put(RETRY_ON_ERROR_KEY, false);

            io.temporal.activity.ActivityOptions options =
                    io.temporal.activity.ActivityOptions.newBuilder()
                            .setStartToCloseTimeout(java.time.Duration.ofMinutes(5))
                            .setRetryOptions(io.temporal.common.RetryOptions.newBuilder()
                                    .setMaximumAttempts(1).build())
                            .build();
            io.temporal.workflow.ActivityStub stub = Workflow.newUntypedActivityStub(options);
            Object result = stub.execute(fullActivityName, Object.class, new Object[]{namedArgs, callConfig});

            Object ballerinaResult = TypesUtil.convertJavaToBallerinaType(result);
            return TypesUtil.cloneWithType(ballerinaResult, td.getDescribingType());
        } catch (io.temporal.failure.ActivityFailure e) {
            Throwable cause = e.getCause();
            String errorMsg;
            if (cause instanceof io.temporal.failure.ApplicationFailure appFailure) {
                errorMsg = appFailure.getOriginalMessage();
            } else {
                errorMsg = cause != null ? cause.getMessage() : e.getMessage();
            }
            return ErrorCreator.createError(StringUtils.fromString(errorMsg));
        } catch (io.temporal.worker.NonDeterministicException | io.temporal.failure.TemporalFailure e) {
            throw e;
        } catch (Exception e) {
            return ErrorCreator.createError(StringUtils.fromString("Agent activity failed: " + e.getMessage()));
        }
    }
}
