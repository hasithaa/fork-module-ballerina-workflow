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

import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.internal.scheduling.Scheduler;
import io.ballerina.runtime.internal.scheduling.Strand;
import io.ballerina.runtime.internal.values.FutureValue;
import io.ballerina.stdlib.workflow.utils.TypesUtil;
import io.temporal.workflow.CompletablePromise;
import io.temporal.workflow.Workflow;
import org.slf4j.Logger;

import java.util.Collections;

/**
 * A FutureValue implementation for Temporal workflow signals.
 * 
 * <p>This class extends Ballerina's {@link FutureValue} to bridge Temporal's 
 * {@link CompletablePromise} to Ballerina's wait mechanism.
 * 
 * <p>CRITICAL ARCHITECTURE NOTE:
 * Ballerina's wait action does NOT call our get() method. Instead, it directly accesses
 * the inherited {@code completableFuture} field and calls {@code completableFuture.get()}.
 * See {@code AsyncUtils.handleWait(Strand, FutureValue)} in ballerina-runtime.
 * 
 * <p>Therefore, we cannot use blocking in our get() method. Instead, we must:
 * 1. Create a Temporal promise via {@code Workflow.newPromise()}
 * 2. Set up a callback using Temporal's {@code promise.thenApply()} to complete our
 *    inherited {@code completableFuture} when the signal arrives
 * 3. Let Ballerina's wait mechanism handle the Java CompletableFuture blocking
 * 
 * <p>The key insight is that when Temporal's signal handler calls {@code promise.complete()},
 * the callback will trigger, convert the signal data to Ballerina types, and complete
 * the Java CompletableFuture that Ballerina's wait is blocking on.
 *
 * @since 0.1.0
 */
public class TemporalFutureValue extends FutureValue {

    private static final Logger LOGGER = Workflow.getLogger(TemporalFutureValue.class);

    /** The Temporal promise that receives signal data. */
    private final CompletablePromise<SignalAwaitWrapper.SignalData> promise;
    
    /** The signal name this future is waiting for. */
    private final String signalName;
    
    /** The expected Ballerina type for the signal data. */
    private final Type constraintType;

    /**
     * Creates a new TemporalFutureValue wrapping a Temporal CompletablePromise.
     * 
     * <p>This constructor:
     * 1. Creates a FutureValue with a minimal Strand
     * 2. Sets up a Temporal callback to complete the Java CompletableFuture when signal arrives
     *
     * @param promise the Temporal CompletablePromise to wrap
     * @param signalName the name of the signal this future is waiting for
     * @param constraintType the Ballerina type that the signal data should be converted to
     * @param scheduler the Ballerina scheduler (from runtime)
     */
    public TemporalFutureValue(CompletablePromise<SignalAwaitWrapper.SignalData> promise, 
                               String signalName, Type constraintType, Scheduler scheduler) {
        // Create FutureValue with a valid strand that won't throw on checkStrandCancelled()
        super(createStrand(scheduler, signalName), constraintType);
        this.promise = promise;
        this.signalName = signalName;
        this.constraintType = constraintType;
        
        // Set up callback: when Temporal's promise is completed, complete the Java CompletableFuture
        setupPromiseCallback();
    }
    
    /**
     * Creates a minimal Strand for this future.
     * The strand is isolated (no global lock needed) and not cancelled.
     */
    private static Strand createStrand(Scheduler scheduler, String signalName) {
        if (scheduler == null) {
            scheduler = new Scheduler(null);
        }
        return new Strand(scheduler, "signal-" + signalName, null, true, 
                Collections.emptyMap(), null);
    }
    
    /**
     * Sets up a callback on the Temporal promise to complete the Java CompletableFuture.
     * 
     * <p>When the signal arrives:
     * 1. Temporal's signal handler completes the promise
     * 2. This callback is triggered
     * 3. We convert the signal data to Ballerina type
     * 4. We complete the inherited {@code completableFuture}
     * 5. Ballerina's wait (which is blocking on completableFuture.get()) returns
     */
    private void setupPromiseCallback() {
        // Use Temporal's thenApply to set up a callback
        // This callback runs when promise.complete() is called by the signal handler
        promise.thenApply(signalData -> {
            try {
                LOGGER.info("[TemporalFutureValue] Signal '{}' received, processing callback", signalName);
                
                // Convert the signal data to Ballerina type
                Object rawData = signalData.getData();
                Object ballerinaData = TypesUtil.convertJavaToBallerinaType(rawData);
                
                // Clone with type to ensure proper type matching
                Object result = TypesUtil.cloneWithType(ballerinaData, constraintType);
                
                // Complete the inherited Java CompletableFuture
                // This will unblock Ballerina's wait action
                this.completableFuture.complete(result);
                
                LOGGER.info("[TemporalFutureValue] CompletableFuture completed for signal '{}'", signalName);
                
                return result;
            } catch (Exception e) {
                LOGGER.error("[TemporalFutureValue] Error processing signal '{}': {}", 
                        signalName, e.getMessage(), e);
                // Complete exceptionally
                this.completableFuture.completeExceptionally(e);
                throw e;
            }
        });
        
        // Also handle failure case
        promise.exceptionally(ex -> {
            LOGGER.error("[TemporalFutureValue] Signal '{}' promise failed: {}", signalName, ex.getMessage(), ex);
            this.completableFuture.completeExceptionally(ex);
            // Return null since the exception is already handled via completeExceptionally
            return null;
        });
        
        LOGGER.info("[TemporalFutureValue] Promise callback registered for signal '{}'", signalName);
    }

    /**
     * Returns the result value of the future.
     * Note: This method is typically not called by Ballerina's wait action,
     * which directly accesses completableFuture.get() instead.
     *
     * @return the signal data converted to Ballerina type
     */
    @Override
    public Object get() {
        try {
            return this.completableFuture.get();
        } catch (Exception e) {
            throw new RuntimeException("Error getting signal value for '" + signalName + "'", e);
        }
    }

    /**
     * Checks if this future is done (signal has been received).
     *
     * @return true if the signal has been received
     */
    @Override
    public boolean isDone() {
        return completableFuture.isDone();
    }

    /**
     * Checks if this future resulted in a panic.
     *
     * @return true if the completableFuture completed exceptionally
     */
    @Override
    public boolean isPanic() {
        return completableFuture.isCompletedExceptionally();
    }

    /**
     * Cancels this future. Not supported for Temporal signal futures.
     */
    @Override
    public void cancel() {
        LOGGER.warn("[TemporalFutureValue] cancel() called on signal future '{}' - not supported", signalName);
    }

    /**
     * Gets the signal name this future is waiting for.
     *
     * @return the signal name
     */
    public String getSignalName() {
        return signalName;
    }
    
    /**
     * Checks if this future has been waited on already.
     * For signal futures, we allow multiple waits since the result is cached in completableFuture.
     * 
     * @return false always to allow multiple waits on signal futures
     */
    @Override
    public boolean getAndSetWaited() {
        // Allow multiple waits on signal futures - the result is deterministic and cached
        return false;
    }
}
