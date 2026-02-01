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

package io.ballerina.stdlib.workflow.context;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BHandle;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.api.values.BTypedesc;
import io.ballerina.stdlib.workflow.utils.TypesUtil;
import io.temporal.workflow.CompletablePromise;
import io.temporal.workflow.Workflow;
import org.slf4j.Logger;

/**
 * Native implementation for SignalFuture operations.
 * Provides cooperative blocking for signal awaiting using Temporal's CompletablePromise.
 *
 * @since 0.1.0
 */
public final class SignalFutureNative {

    private static final Logger LOGGER = Workflow.getLogger(SignalFutureNative.class);

    private SignalFutureNative() {
        // Utility class, prevent instantiation
    }

    /**
     * Awaits the signal and returns the signal data.
     * <p>
     * This method uses Temporal's cooperative blocking mechanism via CompletablePromise.get().
     * The blocking is compatible with workflow replay and determinism requirements.
     *
     * @param self the SignalFuture BObject
     * @param typedesc the expected return type descriptor for dependent typing
     * @return the signal data converted to the expected type, or an error
     */
    @SuppressWarnings("unchecked")
    public static Object get(BObject self, BTypedesc typedesc) {
        try {
            // Get the native promise handle
            Object nativePromiseObj = self.get(StringUtils.fromString("nativePromise"));
            BString signalNameBStr = self.getStringValue(StringUtils.fromString("signalName"));
            String signalName = signalNameBStr.getValue();

            if (!(nativePromiseObj instanceof BHandle)) {
                return ErrorCreator.createError(
                        StringUtils.fromString("Invalid signal future: native promise handle not found"));
            }

            Object promiseValue = ((BHandle) nativePromiseObj).getValue();
            if (!(promiseValue instanceof CompletablePromise)) {
                return ErrorCreator.createError(
                        StringUtils.fromString("Invalid signal future: not a CompletablePromise"));
            }

            CompletablePromise<SignalAwaitWrapper.SignalData> promise =
                    (CompletablePromise<SignalAwaitWrapper.SignalData>) promiseValue;

            // Use Temporal's cooperative await - this blocks until signal arrives
            // but works with Temporal's deterministic replay mechanism
            LOGGER.info("[SignalFutureNative] Awaiting signal: {}", signalName);
            SignalAwaitWrapper.SignalData signalData = promise.get();
            LOGGER.info("[SignalFutureNative] Signal {} received", signalName);

            // Convert the signal data to Ballerina type
            Object rawData = signalData.getData();
            Object ballerinaData = TypesUtil.convertJavaToBallerinaType(rawData);

            // Use cloneWithType to convert to the expected type from typedesc
            Type targetType = typedesc.getDescribingType();
            return TypesUtil.cloneWithType(ballerinaData, targetType);

        } catch (Exception e) {
            return ErrorCreator.createError(
                    StringUtils.fromString("Failed to await signal: " + e.getMessage()));
        }
    }

    /**
     * Checks if the signal has been received.
     *
     * @param self the SignalFuture BObject
     * @return true if the signal has been received, false otherwise
     */
    @SuppressWarnings("unchecked")
    public static boolean isCompleted(BObject self) {
        try {
            Object nativePromiseObj = self.get(StringUtils.fromString("nativePromise"));

            if (!(nativePromiseObj instanceof BHandle)) {
                return false;
            }

            Object promiseValue = ((BHandle) nativePromiseObj).getValue();
            if (!(promiseValue instanceof CompletablePromise)) {
                return false;
            }

            CompletablePromise<SignalAwaitWrapper.SignalData> promise =
                    (CompletablePromise<SignalAwaitWrapper.SignalData>) promiseValue;

            return promise.isCompleted();
        } catch (Exception e) {
            return false;
        }
    }
}
