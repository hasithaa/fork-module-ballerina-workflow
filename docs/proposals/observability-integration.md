# Proposal: Observability integration for the workflow module

- Status: Implemented (initial minimal integration)
- Authors: @hasithaa
- Reviewed by: TBD

## Summary

Add first-class observability — distributed tracing spans and runtime metrics — to the
`ballerina/workflow` module, covering both normal workflows and durable agent workflows.
The integration lives entirely in the module's durable-engine wrapper layer and plugs into
Ballerina's standard observability pipeline (`observabilityIncluded = true`, Prometheus /
Jaeger / New Relic extensions), so users get workflow telemetry with the same switches
they already use for HTTP services. No business data (inputs, payloads, results) is ever
recorded — only structural identifiers such as workflow types, instance IDs, and declared
event names.

## Motivation

The `ballerina/ai` module already ships an exported `ai.observe` submodule that traces
agent operations following the OpenTelemetry GenAI semantic conventions. Workflow
applications have no equivalent: a service that starts workflows, sends data, and
completes human tasks produces traces that end at the service boundary, and no metrics
exist for workflow throughput, failures, or activity latency.

The workflow engine (Temporal) is a separate service, so its server-side observability
cannot stand in for application-side telemetry — and the engine's own client metrics/
tracing hooks would tie the module's observability story to a vendor-specific pipeline.
Instead, this proposal instruments the module's own wrapper layer and emits through
Ballerina's observability runtime.

## Design

The design mirrors `ai.observe` where the execution model allows it, and deliberately
diverges where durable execution makes the AI module's approach incorrect.

### The replay constraint

Workflow bodies are re-executed ("replayed") deterministically by the durable engine
after worker crashes, on queries, and during resets. Two consequences:

1. **Spans must not be emitted from inside a workflow body** — every replay would emit
   duplicates, and wall-clock timings taken inside a body are meaningless. Execution-side
   visibility already exists through the engine history and the management API
   (`getWorkflowHistory`, `getActivityTree`, `getExecutionGraph`).
2. **Worker-side metrics must be replay-gated** — a completion is only counted when the
   engine reports fresh progress (`not replaying`), so crash recovery and queries never
   double-count.

### Tracing: the `workflow.observe` submodule (Ballerina, client side)

A new exported submodule `workflow.observe` provides typed span classes over
`ballerina/observe`, one per instrumented client-side operation:

| Span | Created by | Tags |
|---|---|---|
| `StartWorkflowSpan` | `workflow:run` | `workflow.type`, `workflow.instance.id` |
| `SendDataSpan` | `workflow:sendData` | `workflow.instance.id`, `workflow.data.name` |
| `GetWorkflowResultSpan` | `workflow:getWorkflowResult` | `workflow.instance.id` |
| `TaskDecisionSpan` | `completeHumanTask`, `management:failHumanTask` | `workflow.human_task.id`, `workflow.task.action`, `workflow.task.name`, `user.id`, `user.roles`, `workflow.task.input`, `workflow.task.content` |
| `TaskDecisionSpan` | `management:completeReviewActivity` | `workflow.review_activity.id`, `workflow.task.action`, `workflow.task.name`, `user.id`, `user.roles`, `workflow.task.input`, `workflow.task.content` |
| `StartAgentSpan` | `DurableAgent.run` | `gen_ai.agent.name`, `workflow.instance.id` |
| `SendAgentEventSpan` | `DurableAgent.sendData` | `gen_ai.agent.name`, `workflow.instance.id`, `workflow.event.name` |

Every span carries `workflow.operation.name` and `span.type = workflow` (mirroring
`span.type = ai` in the AI module), and closes with error status via
`observe:finishSpanWithError` on failure. Agent spans reuse the OpenTelemetry GenAI
attribute `gen_ai.agent.name` so agent traces correlate with `ai.observe` spans; decision
spans reuse the OpenTelemetry `user.id` and `user.roles` attributes for who decided.

### Governance: every decision a person makes is recorded

A human task or a review activity is where a person enters the workflow, and governance
asks four things of that moment: who acted, in which capacity, what they decided, and
when. The module answers them at the one place every path converges — the runtime natives
behind `completeHumanTask`, `failHumanTask` and `completeReviewActivity`, whether reached
through the root module, `workflow.management`, the REST service or `executeCommand`.

On a decision the native validates the task and, instead of returning nothing, hands back
a **receipt**: the task's declared name, the workflow that created it, and the roles it
allowed to decide it, all read from the memo it already fetched to validate. The Ballerina
wrapper turns the call into one `TaskDecisionSpan`, which on close writes three things:

- an **audit entry** through `ballerina/log` — `taskKind`, `taskId`, `taskName`,
  `parentWorkflowId`, `action`, `outcome`, `userId`, `userRoles` (as presented by the
  caller), `assignedRoles` (as declared on the task), `decidedAt`. Written at `INFO` for an
  accepted decision and `WARN` for a refused one, with the refusal's error attached;
- the span above, so the decision sits in the caller's request trace;
- one increment of `workflow_task_decisions_total`.

A **refused** decision — wrong role, task no longer running, task not found — is recorded
too, as `outcome = denied`: an audit trail that only shows what succeeded is half a trail.
A refused decision never resolved the task, so its entry carries what the caller presented
and no task name or input.

The audit entry goes through `ballerina/log` deliberately, not the worker's Java log: it is
the governance record, so it must land where the application's logs land, in the format
and at the level `[ballerina.log]` configures, and it is written whether or not tracing or
metrics are enabled. Logs are the right primary carrier for an audit event: traces are
sampled and metrics are aggregates, and neither may drop or merge a decision.

### Content capture: on by default, switchable off

The records above name the task; two switches under `[ballerina.workflow.observe]`, both
`true` by default, decide whether they also carry its content:

| Switch | What it adds | Where |
|---|---|---|
| `captureHumanTaskContent` | what the person was shown — the human task's input, or the arguments of the activity under review — and what they submitted — the completion result, the rejection reason and details, or the review decision's input and feedback — as JSON | `workflow.task.input` and `workflow.task.content` on the decision span; `taskInput` and `content` on its audit entry |
| `captureActivityContent` | every activity execution attempt's arguments and result (or error), as JSON | one `INFO` line per attempt in the worker's module log, beside the attempt's outcome and duration |

Values longer than 8192 characters are cut. The shown input comes from the task's memo
(`taskInput` for a human task, `activityArgs` for a review), which the decision's validation
already fetched — so recording it costs no extra call. The activity line is a worker-side
Java log — the stream the module's activity-failure warnings already use — because activity
threads are outside any Ballerina strand.

On by default follows `ai.observe`, which records prompt and completion content on its spans
with no switch at all, and the reasoning is the workflow store's own: the engine already
persists everything a workflow handles for the life of the run, and telemetry retention
retires its copy on its own schedule, so the copy adds exposure only where the content
should never have entered the workflow in the first place. The module's standing advice
still applies — keep sensitive data out of inputs, arguments and results altogether — and
where that cannot hold, a deployment switches the relevant capture off, once, in
configuration. (OpenTelemetry's GenAI conventions make the opposite call, opt-in, for
message content; this module sides with its in-house precedent.)

### Samples for log-based metrics

Platforms such as the Integration Control Plane build their metrics from log records rather
than from a scrape: `ballerinax/metrics.logs` publishes one record per HTTP request
(`logger = "metrics"`, the request's fields as keys) and a log pipeline indexes them. The
registry counters above never reach such a platform. So the module publishes its own samples,
in the same shape, under `logger = "workflow-metrics"` with a `sample` name:

| `sample` | Fields | Written from |
|---|---|---|
| `workflow.started` | `workflow_type`, `workflow_id` | the client, on `run` |
| `workflow.closed` | `workflow_type`, `workflow_id`, `run_id`, `status` (`completed`/`failed`), `duration_seconds` | the workflow adapter, replay-gated |
| `activity.executed` | `activity_type`, `workflow_id`, `run_id`, `attempt`, `outcome`, `duration_seconds` | the activity adapter, per attempt |
| `data.sent` | `data_name`, `workflow_id` | the client, on `sendData` |
| `task.decided` | `task_kind`, `task_name`, `action`, `outcome` | beside the decision's audit entry |

Structural fields only — never inputs, results or who decided; those stay on the audit entry
and the content log. The Java-side samples go through the module's console handler, whose
formatter renders a record's `Map` parameter as top-level `key=value` pairs, so a logfmt parser
reads them exactly as it reads `ballerina/log` output. `publishMetricSamples = false` under
`[ballerina.workflow.observe]` turns them off. What a platform does with them — a
`ballerina-workflow-metrics-*` index and a workflow view — is the platform's side; the
field names above are the contract.

## Backward compatibility

None of the public API signatures change; wrappers preserve behavior exactly and the new
submodule is purely additive. Programs built without `observabilityIncluded = true` (or
with observability disabled at runtime) take the no-op paths. The `workflow.observe`
submodule is exported so applications and future tooling can attach additional tags.

## Usage

```toml
# Ballerina.toml
[build-options]
observabilityIncluded = true
```

```toml
# Config.toml
[ballerina.observe]
metricsEnabled = true
metricsReporter = "prometheus"
tracingEnabled = true
tracingProvider = "jaeger"
```

No workflow-module configuration is required for spans, metrics or the decision audit
entries; the standard Ballerina observability switches control the first two, and the audit
entries follow `[ballerina.log]`. The two content switches are on unless turned off:

```toml
# Config.toml
[ballerina.workflow.observe]
captureHumanTaskContent = false   # keep what was shown and submitted off the span and audit entry
captureActivityContent = false    # keep activity arguments and results out of the worker log
```

## Known artifact

With `observabilityIncluded = true`, the Ballerina runtime auto-instruments every remote
method call — including `ctx->callActivity` and the other `Context` remote calls — from
inside workflow bodies. Those auto-spans predate this proposal, start their own traces
(no client-side parent), and can repeat under replay. They are emitted by the runtime,
not by this module; suppressing them would require engine-side gating of the runtime
observation hooks and is left for a future iteration.

## Testing

- **Unit tests** (`ballerina/tests/observe_test.bal`): the module test build runs without
  `observabilityIncluded`, so these assert the default path every existing user takes —
  all span operations are safe no-ops when tracing is disabled — plus
  `workflowTypeNameOf` name derivation.
- **Integration tests** (`integration-tests/tests/observability_test.bal`): the
  integration package builds with `observabilityIncluded = true` and runs with metrics
  enabled (Prometheus reporter) and the distribution's mock tracer against a real engine
  dev server. They assert the six `workflow_*` metrics with expected tags for completed
  and failed runs (`testWorkflowMetricsEmission`, `testWorkflowFailureMetricsEmission`)
  and the `start_workflow`/`send_data`/`get_workflow_result` spans tagged with the
  instance ID (`testWorkflowSpanEmission`). `testHumanTaskDecisionTelemetry` refuses a
  decision from the wrong role and then accepts one, and asserts both are counted
  (`outcome = denied` and `accepted`) and both leave a span naming the decider, their
  roles and the action — with the task's input and the submitted result on the span exactly
  when `captureHumanTaskContent` is on. `testReviewActivityDecisionTelemetry` does the same
  for a `proceed-with-input` review decision, including the reviewed activity's arguments.
  The integration config leaves both content switches at their default, on, so the capture
  paths run under the whole suite. The full pre-existing
  integration suite also runs with observability enabled, so it doubles as a regression
  check that instrumentation never disturbs execution.
- With observability off (the default for all existing users), every new code path
  reduces to a flag check.
