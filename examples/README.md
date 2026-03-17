# Examples

The `ballerina/workflow` library provides practical examples illustrating usage in various scenarios.

| Example | Description |
|---------|-------------|
| [get-started](get-started/) | Introductory example: define a workflow, call activities, run with `workflow:run()` |
| [error-propagation](error-propagation/) | Propagate an activity error to the caller with `check` — workflow transitions to Failed |
| [error-fallback](error-fallback/) | Fall back to a secondary activity when the primary exhausts its Temporal retries |
| [error-compensation](error-compensation/) | Saga pattern: run compensating activities to undo committed steps when a later step fails |
| [graceful-completion](graceful-completion/) | Tolerate failures in non-critical activities and complete the workflow successfully |
| [human-in-the-loop](human-in-the-loop/) | Forward recovery: pause the workflow after failure and wait for a human decision signal |

## Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.0 or later

## Running an example

Execute the following commands to build an example from the source:

* To build an example:

    ```bash
    bal build
    ```

* To run an example:

    ```bash
    bal run
    ```

## Building the examples with the local module

**Warning**: Because of the absence of support for reading the local repository for Java package dependencies, the Gradle build process cannot be used for the examples. Consequently, the examples directory is not a Gradle subproject.

Execute the following commands to build all the examples against the changes you have made to the module locally:

* To build all the examples:

    ```bash
    ./build.sh build
    ```

* To run all the examples:

    ```bash
    ./build.sh run
    ```
