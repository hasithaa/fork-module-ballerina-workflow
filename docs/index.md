# Ballerina Workflow Module

The Ballerina Workflow module provides durable workflow orchestration for Ballerina applications. It enables you to define long-running, fault-tolerant business processes using familiar Ballerina constructs.

## Key Features

- **Durable, Long-Running Execution** — Workflows run for as long as needed — minutes, hours, or days — and survive process restarts and infrastructure failures. The runtime automatically checkpoints workflow state and recovers from failures, guaranteeing that workflows always run to completion.
- **Protocol-Independent Entry Points** — Workflow logic is independent of the protocol used to trigger it. You can start the same workflow from an HTTP endpoint, a message queue consumer, a scheduled job, or any other entry point. Multiple entry points can trigger the same workflow.
- **Asynchronous Execution** — Workflows can pause and wait for external data events or timer events during execution. This enables patterns like human-in-the-loop approvals, payment confirmations, or scheduled follow-ups without blocking resources.
- **Activities with Automatic Retry** — Encapsulate non-deterministic operations (I/O, API calls, database access) in activity functions. Activities are automatically retried on failure with configurable retry policies, and their results are recorded so they execute exactly once even during workflow replays.


## Documentation

| Guide | Description |
|-------|-------------|
| [Get Started](get-started.md) | Write and run your first workflow |
| [Key Concepts](key-concepts.md) | Workflows, activities, data events, timer events, and triggers |
| [Set Up Temporal Server](set-up-temporal-server.md) | Install and run the Temporal server for local development |
| [Write Workflow Functions](write-workflow-functions.md) | Workflow signatures, determinism rules, durable sleep, and metadata |
| [Write Activity Functions](write-activity-functions.md) | Activity patterns, error handling, and retry options |
| [Handle Errors](handle-errors.md) | Error propagation, retry, fallback, compensation, and human-in-the-loop patterns |
| [Handle Data Events](handle-events.md) | Signal events, waiting for human input, and sending data to running workflows |

## Examples

| Example | Description |
|---------|-------------|
| [Get Started](../examples/get-started/) | Write and run your first workflow |
| [Error Propagation](examples/error-propagation.md) | Propagate an activity error to fail the workflow |
| [Error Fallback](examples/error-fallback.md) | Fall back to a secondary activity when the primary fails |
| [Error Compensation](examples/error-compensation.md) | Saga pattern: undo committed steps when a later step fails |
| [Graceful Completion](examples/graceful-completion.md) | Tolerate non-critical activity failures and complete successfully |
| [Human in the Loop](examples/human-in-the-loop.md) | Pause and wait for a human decision signal (forward recovery) |

