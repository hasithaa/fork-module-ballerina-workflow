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

package io.ballerina.stdlib.workflow.registry;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Registry for workflow events (signals) extracted from process function signatures.
 * <p>
 * This registry stores information about events extracted from process function parameters.
 * Events are modeled as fields of type {@code future<T>} in the events record parameter
 * of a process function. Each event is mapped to a Temporal signal.
 * <p>
 * Usage:
 * <pre>{@code
 * // Register an event for a process
 * EventRegistry.getInstance().registerEvent("orderProcess", 
 *     new EventInfo("paymentReceived", paymentType, "orderProcess"));
 * 
 * // Get all events for a process
 * List<EventInfo> events = EventRegistry.getInstance().getEventsForProcess("orderProcess");
 * 
 * // Use event names to register Temporal signal handlers
 * for (EventInfo event : events) {
 *     workflow.registerSignalHandler(event.getSignalName(), ...);
 * }
 * }</pre>
 *
 * @since 0.1.0
 */
public final class EventRegistry {

    // Singleton instance
    private static final EventRegistry INSTANCE = new EventRegistry();

    // Map of process name to list of events for that process
    private final Map<String, List<EventInfo>> processEvents = new ConcurrentHashMap<>();

    private EventRegistry() {
        // Private constructor for singleton
    }

    /**
     * Gets the singleton instance of the EventRegistry.
     *
     * @return the EventRegistry instance
     */
    public static EventRegistry getInstance() {
        return INSTANCE;
    }

    /**
     * Registers an event for a process.
     *
     * @param processName the name of the process
     * @param eventInfo   the event information
     */
    public void registerEvent(String processName, EventInfo eventInfo) {
        processEvents.computeIfAbsent(processName, k -> new ArrayList<>()).add(eventInfo);
    }

    /**
     * Registers multiple events for a process.
     *
     * @param processName the name of the process
     * @param events      the list of events to register
     */
    public void registerEvents(String processName, List<EventInfo> events) {
        if (events != null && !events.isEmpty()) {
            processEvents.computeIfAbsent(processName, k -> new ArrayList<>()).addAll(events);
        }
    }

    /**
     * Gets all events registered for a process.
     *
     * @param processName the name of the process
     * @return an unmodifiable list of events, or empty list if none registered
     */
    public List<EventInfo> getEventsForProcess(String processName) {
        List<EventInfo> events = processEvents.get(processName);
        return events != null ? Collections.unmodifiableList(events) : Collections.emptyList();
    }

    /**
     * Gets a specific event by field name for a process.
     *
     * @param processName the name of the process
     * @param eventName   the name of the event field
     * @return Optional containing the EventInfo if found
     */
    public Optional<EventInfo> getEvent(String processName, String eventName) {
        List<EventInfo> events = processEvents.get(processName);
        if (events != null) {
            return events.stream()
                    .filter(e -> e.getFieldName().equals(eventName))
                    .findFirst();
        }
        return Optional.empty();
    }

    /**
     * Gets all signal names for a process.
     * These are the names that should be used when registering Temporal signal handlers.
     *
     * @param processName the name of the process
     * @return list of signal names
     */
    public List<String> getSignalNames(String processName) {
        List<EventInfo> events = processEvents.get(processName);
        if (events != null) {
            List<String> signalNames = new ArrayList<>();
            for (EventInfo event : events) {
                signalNames.add(event.getSignalName());
            }
            return signalNames;
        }
        return Collections.emptyList();
    }

    /**
     * Checks if a process has any registered events.
     *
     * @param processName the name of the process
     * @return true if the process has events registered
     */
    public boolean hasEvents(String processName) {
        List<EventInfo> events = processEvents.get(processName);
        return events != null && !events.isEmpty();
    }

    /**
     * Gets the count of events registered for a process.
     *
     * @param processName the name of the process
     * @return the count of events
     */
    public int getEventCount(String processName) {
        List<EventInfo> events = processEvents.get(processName);
        return events != null ? events.size() : 0;
    }

    /**
     * Removes all events for a process.
     *
     * @param processName the name of the process
     * @return true if events were removed
     */
    public boolean removeEventsForProcess(String processName) {
        return processEvents.remove(processName) != null;
    }

    /**
     * Clears all registered events.
     * Primarily used for testing.
     */
    public void clear() {
        processEvents.clear();
    }

    /**
     * Returns the total number of processes with registered events.
     *
     * @return the count of processes with events
     */
    public int processCount() {
        return processEvents.size();
    }

    /**
     * Returns all processes with registered events.
     *
     * @return an unmodifiable map of process names to their events
     */
    public Map<String, List<EventInfo>> getAllProcessEvents() {
        return Collections.unmodifiableMap(processEvents);
    }
}
