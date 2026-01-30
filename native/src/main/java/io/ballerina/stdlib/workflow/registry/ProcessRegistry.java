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

import io.ballerina.runtime.api.values.BFunctionPointer;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Registry for workflow process functions.
 * <p>
 * This registry stores references to Ballerina functions annotated with @Process,
 * allowing them to be invoked by the workflow runtime when a process is started
 * or when a workflow needs to be replayed.
 *
 * @since 0.1.0
 */
public final class ProcessRegistry {

    // Singleton instance
    private static final ProcessRegistry INSTANCE = new ProcessRegistry();

    // Map of process name to process function pointer
    private final Map<String, ProcessInfo> processes = new ConcurrentHashMap<>();

    private ProcessRegistry() {
        // Private constructor for singleton
    }

    /**
     * Gets the singleton instance of the ProcessRegistry.
     *
     * @return the ProcessRegistry instance
     */
    public static ProcessRegistry getInstance() {
        return INSTANCE;
    }

    /**
     * Registers a process function with the given name.
     *
     * @param processName the name of the process
     * @param processFunction the Ballerina function pointer for the process
     * @return true if registration was successful, false if already registered
     */
    public boolean register(String processName, BFunctionPointer processFunction) {
        ProcessInfo info = new ProcessInfo(processName, processFunction);
        ProcessInfo existing = processes.putIfAbsent(processName, info);
        return existing == null;
    }

    /**
     * Retrieves a process by its name.
     *
     * @param processName the name of the process
     * @return an Optional containing the ProcessInfo if found
     */
    public Optional<ProcessInfo> getProcess(String processName) {
        return Optional.ofNullable(processes.get(processName));
    }

    /**
     * Checks if a process is registered with the given name.
     *
     * @param processName the name of the process
     * @return true if the process is registered
     */
    public boolean isRegistered(String processName) {
        return processes.containsKey(processName);
    }

    /**
     * Unregisters a process by name.
     *
     * @param processName the name of the process to unregister
     * @return true if the process was removed
     */
    public boolean unregister(String processName) {
        return processes.remove(processName) != null;
    }

    /**
     * Clears all registered processes.
     * Primarily used for testing.
     */
    public void clear() {
        processes.clear();
    }

    /**
     * Returns the number of registered processes.
     *
     * @return the count of registered processes
     */
    public int size() {
        return processes.size();
    }

    /**
     * Returns all registered processes.
     *
     * @return an unmodifiable map of process names to ProcessInfo
     */
    public Map<String, ProcessInfo> getAllProcesses() {
        return Collections.unmodifiableMap(processes);
    }

    /**
     * Adds an activity to a process.
     *
     * @param processName the name of the process
     * @param activityName the name of the activity to add
     * @return true if the activity was added, false if the process doesn't exist
     */
    public boolean addActivityToProcess(String processName, String activityName) {
        ProcessInfo info = processes.get(processName);
        if (info != null) {
            info.addActivity(activityName);
            return true;
        }
        return false;
    }

    /**
     * Adds events to a process.
     *
     * @param processName the name of the process
     * @param events the events to add
     * @return true if the events were added, false if the process doesn't exist
     */
    public boolean addEventsToProcess(String processName, List<EventInfo> events) {
        ProcessInfo info = processes.get(processName);
        if (info != null) {
            info.addEvents(events);
            return true;
        }
        return false;
    }

    /**
     * Gets the events for a process.
     *
     * @param processName the name of the process
     * @return list of events, or empty list if process not found
     */
    public List<EventInfo> getEventsForProcess(String processName) {
        ProcessInfo info = processes.get(processName);
        if (info != null) {
            return info.getEvents();
        }
        return Collections.emptyList();
    }

    /**
     * Gets the event names (signal names) for a process.
     *
     * @param processName the name of the process
     * @return list of event names, or empty list if process not found
     */
    public List<String> getEventNamesForProcess(String processName) {
        ProcessInfo info = processes.get(processName);
        if (info != null) {
            return info.getEventNames();
        }
        return Collections.emptyList();
    }

    /**
     * Information about a registered process.
     */
    public static class ProcessInfo {
        private final String name;
        private final BFunctionPointer functionPointer;
        private final Set<String> activityNames;
        private final List<EventInfo> events;

        public ProcessInfo(String name, BFunctionPointer functionPointer) {
            this.name = name;
            this.functionPointer = functionPointer;
            this.activityNames = ConcurrentHashMap.newKeySet();
            this.events = new ArrayList<>();
        }

        public String getName() {
            return name;
        }

        public BFunctionPointer getFunctionPointer() {
            return functionPointer;
        }

        public Set<String> getActivityNames() {
            return Collections.unmodifiableSet(activityNames);
        }

        public void addActivity(String activityName) {
            activityNames.add(activityName);
        }

        /**
         * Gets the list of events (signals) for this process.
         *
         * @return an unmodifiable list of events
         */
        public List<EventInfo> getEvents() {
            return Collections.unmodifiableList(events);
        }

        /**
         * Gets the event names (signal names) for this process.
         *
         * @return list of event field names
         */
        public List<String> getEventNames() {
            List<String> names = new ArrayList<>();
            for (EventInfo event : events) {
                names.add(event.getFieldName());
            }
            return names;
        }

        /**
         * Adds an event to this process.
         *
         * @param eventInfo the event to add
         */
        public void addEvent(EventInfo eventInfo) {
            events.add(eventInfo);
        }

        /**
         * Adds multiple events to this process.
         *
         * @param eventInfos the events to add
         */
        public void addEvents(List<EventInfo> eventInfos) {
            if (eventInfos != null) {
                events.addAll(eventInfos);
            }
        }

        /**
         * Checks if this process has any events defined.
         *
         * @return true if events are present
         */
        public boolean hasEvents() {
            return !events.isEmpty();
        }

        /**
         * Gets the count of events for this process.
         *
         * @return the number of events
         */
        public int getEventCount() {
            return events.size();
        }
    }
}
