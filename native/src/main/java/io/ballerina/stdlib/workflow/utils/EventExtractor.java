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

package io.ballerina.stdlib.workflow.utils;

import io.ballerina.runtime.api.types.Field;
import io.ballerina.runtime.api.types.FunctionType;
import io.ballerina.runtime.api.types.Parameter;
import io.ballerina.runtime.api.types.RecordType;
import io.ballerina.runtime.api.types.ReferenceType;
import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.api.types.TypeTags;
import io.ballerina.runtime.api.values.BFunctionPointer;
import io.ballerina.stdlib.workflow.registry.EventInfo;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Utility class for extracting event information from process function signatures.
 * <p>
 * According to the workflow design, process functions have the following signature:
 * <pre>
 * &#64;workflow:process
 * function processName(workflow:Context ctx, T input,
 *     record { future eventX, future eventY } events) returns R|error { }
 * </pre>
 * <p>
 * The events parameter (third parameter) is a record where each field is of type future.
 * Each field represents an event/signal that the workflow can wait for. This extractor
 * analyzes the function type to extract these event definitions.
 * <p>
 * The extracted events are used at runtime to:
 * <ul>
 *   <li>Register Temporal signal handlers for each event</li>
 *   <li>Create Ballerina future values dynamically when workflow is replayed</li>
 *   <li>Complete futures when corresponding signals are received</li>
 * </ul>
 *
 * @since 0.1.0
 */
public final class EventExtractor {

    // Context type name for identifying workflow context parameter
    private static final String CONTEXT_TYPE_NAME = "Context";

    private EventExtractor() {
        // Utility class, prevent instantiation
    }

    /**
     * Extracts event information from a process function pointer.
     * <p>
     * Analyzes the function signature to find the events record parameter
     * and extracts information about each future field.
     *
     * @param processFunction the process function pointer
     * @param processName     the name of the process (for error messages)
     * @return list of EventInfo objects, empty if no events found
     */
    public static List<EventInfo> extractEvents(BFunctionPointer processFunction, String processName) {
        if (processFunction == null) {
            return Collections.emptyList();
        }

        Type funcType = processFunction.getType();
        if (!(funcType instanceof FunctionType)) {
            return Collections.emptyList();
        }

        FunctionType functionType = (FunctionType) funcType;
        Parameter[] parameters = functionType.getParameters();

        if (parameters == null || parameters.length == 0) {
            return Collections.emptyList();
        }

        // Find the events parameter (record with future fields)
        // Process signature: (Context? ctx, T input, record { future<...> ... } events?)
        RecordType eventsRecordType = findEventsRecordType(parameters);

        if (eventsRecordType == null) {
            return Collections.emptyList();
        }

        return extractEventsFromRecord(eventsRecordType, processName);
    }

    /**
     * Finds the events record type from the function parameters.
     * <p>
     * The events parameter is identified as a record type where at least one
     * field is of type future&lt;T&gt;.
     *
     * @param parameters the parameters of the function
     * @return the events record type, or null if not found
     */
    private static RecordType findEventsRecordType(Parameter[] parameters) {
        for (Parameter param : parameters) {
            Type paramType = param.type;
            
            // Dereference type references to get the actual type
            Type actualType = dereferenceType(paramType);
            
            // Check if it's a record type
            if (actualType.getTag() == TypeTags.RECORD_TYPE_TAG) {
                RecordType recordType = (RecordType) actualType;
                
                // Check if this record contains future fields (events record signature)
                if (containsFutureFields(recordType)) {
                    return recordType;
                }
            }
        }
        return null;
    }
    
    /**
     * Dereferences a type if it's a ReferenceType.
     * This handles named types like "type MyRecord record {...}".
     *
     * @param type the type to dereference
     * @return the referred type if it's a ReferenceType, otherwise the original type
     */
    private static Type dereferenceType(Type type) {
        // Keep track of max depth to prevent infinite loops with self-referencing types
        int maxDepth = 10;
        Type current = type;
        
        while (current instanceof ReferenceType && maxDepth > 0) {
            ReferenceType refType = (ReferenceType) current;
            Type referredType = refType.getReferredType();
            
            // If the referred type is the same object, stop to prevent infinite loop
            if (referredType == current) {
                break;
            }
            
            current = referredType;
            maxDepth--;
        }
        
        return current;
    }
    /**
     * Checks if a record type contains at least one future field.
     *
     * @param recordType the record type to check
     * @return true if the record contains future fields
     */
    private static boolean containsFutureFields(RecordType recordType) {
        Map<String, Field> fields = recordType.getFields();
        if (fields == null || fields.isEmpty()) {
            return false;
        }

        for (Field field : fields.values()) {
            Type fieldType = field.getFieldType();
            // Dereference in case it's a type reference
            Type actualFieldType = dereferenceType(fieldType);
            if (actualFieldType.getTag() == TypeTags.FUTURE_TAG) {
                return true;
            }
        }
        return false;
    }

    /**
     * Extracts event information from all future fields in a record type.
     *
     * @param recordType  the events record type
     * @param processName the name of the process
     * @return list of EventInfo objects
     */
    private static List<EventInfo> extractEventsFromRecord(RecordType recordType, String processName) {
        List<EventInfo> events = new ArrayList<>();
        Map<String, Field> fields = recordType.getFields();

        if (fields == null || fields.isEmpty()) {
            return events;
        }

        for (Map.Entry<String, Field> entry : fields.entrySet()) {
            String fieldName = entry.getKey();
            Field field = entry.getValue();
            Type fieldType = field.getFieldType();
            
            // Dereference in case it's a type reference
            Type actualFieldType = dereferenceType(fieldType);

            // Only process future fields
            if (actualFieldType.getTag() == TypeTags.FUTURE_TAG) {
                // FutureType doesn't expose the constraint type directly through the API,
                // so we store the futureType itself and can introspect it if needed
                EventInfo eventInfo = new EventInfo(fieldName, actualFieldType, processName);
                events.add(eventInfo);
            }
        }
        
        return events;
    }

    /**
     * Extracts event names only (without full type information).
     * <p>
     * This is useful when only the signal names are needed for
     * registering Temporal signal handlers.
     *
     * @param processFunction the process function pointer
     * @return list of event field names, empty if no events found
     */
    public static List<String> extractEventNames(BFunctionPointer processFunction) {
        if (processFunction == null) {
            return Collections.emptyList();
        }

        Type funcType = processFunction.getType();
        if (!(funcType instanceof FunctionType)) {
            return Collections.emptyList();
        }

        FunctionType functionType = (FunctionType) funcType;
        Parameter[] parameters = functionType.getParameters();

        if (parameters == null || parameters.length == 0) {
            return Collections.emptyList();
        }

        RecordType eventsRecordType = findEventsRecordType(parameters);
        if (eventsRecordType == null) {
            return Collections.emptyList();
        }

        return extractEventNamesFromRecord(eventsRecordType);
    }

    /**
     * Extracts just the event field names from a record type.
     *
     * @param recordType the events record type
     * @return list of field names that are future types
     */
    private static List<String> extractEventNamesFromRecord(RecordType recordType) {
        List<String> eventNames = new ArrayList<>();
        Map<String, Field> fields = recordType.getFields();

        if (fields == null || fields.isEmpty()) {
            return eventNames;
        }

        for (Map.Entry<String, Field> entry : fields.entrySet()) {
            Field field = entry.getValue();
            if (field.getFieldType().getTag() == TypeTags.FUTURE_TAG) {
                eventNames.add(entry.getKey());
            }
        }

        return eventNames;
    }

    /**
     * Checks if a process function has any events defined.
     *
     * @param processFunction the process function pointer
     * @return true if the function has an events parameter with future fields
     */
    public static boolean hasEvents(BFunctionPointer processFunction) {
        if (processFunction == null) {
            return false;
        }

        Type funcType = processFunction.getType();
        if (!(funcType instanceof FunctionType)) {
            return false;
        }

        FunctionType functionType = (FunctionType) funcType;
        Parameter[] parameters = functionType.getParameters();

        if (parameters == null || parameters.length == 0) {
            return false;
        }

        return findEventsRecordType(parameters) != null;
    }

    /**
     * Gets information about the input parameter type of a process function.
     *
     * @param processFunction the process function pointer
     * @return the input type, or null if not determinable
     */
    public static Type getInputType(BFunctionPointer processFunction) {
        if (processFunction == null) {
            return null;
        }

        Type funcType = processFunction.getType();
        if (!(funcType instanceof FunctionType)) {
            return null;
        }

        FunctionType functionType = (FunctionType) funcType;
        Parameter[] parameters = functionType.getParameters();

        if (parameters == null || parameters.length == 0) {
            return null;
        }

        // The input parameter is:
        // - First param if no Context
        // - Second param if Context is present
        int inputIndex = 0;
        if (parameters.length > 0 && isContextType(parameters[0].type)) {
            inputIndex = 1;
        }

        if (inputIndex < parameters.length) {
            Type potentialInput = parameters[inputIndex].type;
            // Make sure it's not the events record
            if (potentialInput.getTag() != TypeTags.RECORD_TYPE_TAG || 
                !containsFutureFields((RecordType) potentialInput)) {
                return potentialInput;
            }
        }

        return null;
    }

    /**
     * Checks if a type is the workflow Context type.
     *
     * @param type the type to check
     * @return true if it's the Context type
     */
    public static boolean isContextType(Type type) {
        if (type == null) {
            return false;
        }
        // Check by type name - Context is a record type from workflow module
        String typeName = type.getName();
        return CONTEXT_TYPE_NAME.equals(typeName);
    }

    /**
     * Checks if a process function has a Context parameter as its first parameter.
     *
     * @param processFunction the process function pointer
     * @return true if the first parameter is Context
     */
    public static boolean hasContextParameter(BFunctionPointer processFunction) {
        if (processFunction == null) {
            return false;
        }

        Type funcType = processFunction.getType();
        if (!(funcType instanceof FunctionType)) {
            return false;
        }

        FunctionType functionType = (FunctionType) funcType;
        Parameter[] parameters = functionType.getParameters();

        if (parameters == null || parameters.length == 0) {
            return false;
        }

        return isContextType(parameters[0].type);
    }
}
