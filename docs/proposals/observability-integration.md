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
| `TaskDecisionSpan` | `completeHumanTask`, `management:failHumanTask` | `workflow.human_task.id`, `workflow.task.action`, `workflow.task.name`, `user.id`, `user.roles` |
| `TaskDecisionSpan` | `management:completeReviewActivity` | `workflow.review_activity.id`, `workflow.task.action`, `workflow.task.name`, `user.id`, `user.roles` |
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
and no task name.

The audit entry goes through `ballerina/log` deliberately, not the worker's Java log: it is
the governance record, so it must land where the application's logs land, in the format
and at the level `[ballerina.log]` configures, and it is written whether or not tracing or
metrics are enabled. Logs are the right primary carrier for an audit event: traces are
sampled and metrics are aggregates, and neither may drop or merge a decision.

### Content capture is opt-in

None of the above records what the person *submitted*. That is governed by two switches
under `[ballerina.workflow.observe]`, both `false` by default:

| Switch | What it adds | Where |
|---|---|---|
| `captureHumanTaskContent` | the completion result, the rejection reason and details, or the review decision's input and feedback, as JSON | `workflow.task.content` on the decision span and `content` on its audit entry |
| `captureActivityContent` | every activity execution attempt's arguments and result (or error), as JSON | one `INFO` line per attempt in the worker's module log, beside the attempt's outcome and duration |

Values longer than 8192 characters are cut. The activity line is a worker-side Java log —
the stream the module's activity-failure warnings already use — because activity threads
are outside any Ballerina strand.

Off by default is the deliberate choice, and it is the call the user of this module makes
on the workflow store itself: everything a workflow handles is persisted by the engine, so
the module's standing advice is to keep sensitive data out of inputs, arguments and results
altogether. Telemetry is a second copy of that data in sinks that are typically read more
widely (a Grafana or Kibana login rather than a Temporal namespace grant) and retained on
their own schedule. OpenTelemetry's GenAI conventions make the same choice for message
content — capture is opt-in — for the same reason. The in-house precedent goes the other
way: `ai.observe` records prompt and completion content on its spans unconditionally, with
no switch at all. This module does not follow it; a deployment that wants the content asks
for it, once, in configuration.

Spans are recorded only when **both** hold:

- tracing is enabled for the program (`observe:isTracingEnabled()`), and
- the call is **not** executing inside a workflow body (checked natively via the engine's
  thread-local workflow context) — the replay constraint above.

Because these calls run in the caller's strand (typically an HTTP resource), the spans
nest naturally into the service's existing request trace. When observability is not
included or tracing is disabled, every span operation is a no-op.

The public API functions keep their exact signatures; they become thin Ballerina wrappers
around renamed private externals. Functions whose signatures use inferred typedesc
parameters (`typedesc<anydata> T = <>`, e.g. `DurableAgent.getResult`) must remain
external and are not traced in this iteration.

### Metrics: the wrapper-layer Java hooks (worker + client side)

Metrics are recorded natively through the Ballerina runtime metric registry
(`io.ballerina.runtime.observability.metrics`), the same registry the Prometheus/
New Relic metric extensions publish from. All recording is gated on
`ObserveUtils.isMetricsEnabled()` and never throws into workflow execution.

| Metric | Type | Tags | Recorded at |
|---|---|---|---|
| `workflow_starts_total` | counter | `workflow_type` | client-side top-level start |
| `workflow_completions_total` | counter | `workflow_type`, `status` | workflow adapter, replay-gated |
| `workflow_duration_seconds` | gauge (summary) | `workflow_type`, `status` | run start → completion, engine time |
| `workflow_activity_executions_total` | counter | `activity_type`, `status` | activity adapter, per attempt |
| `workflow_activity_duration_seconds` | gauge (summary) | `activity_type`, `status` | activity adapter, wall clock |
| `workflow_data_events_sent_total` | counter | `data_name` | client-side data delivery |
| `workflow_task_decisions_total` | counter | `task_kind`, `task_name`, `action`, `outcome` | every decision on a human task or review activity, accepted or refused |

Placement rationale — every execution funnels through two dynamic adapters in the
wrapper layer, so instrumenting them covers everything with two hooks:

- **Workflow adapter** (`BallerinaWorkflowAdapter.execute`): covers user workflows,
  durable agent runner workflows (`workflow-<agentName>` types), human task child
  workflows (`humantask-…` types), and review-activity child workflows
  (`reviewactivity-…` types) — each distinguishable by its `workflow_type` tag.
  Duration uses the engine's deterministic clock against the run-start timestamp,
  so it is exact even across worker restarts.
- **Activity adapter** (`BallerinaActivityAdapter.execute`): covers user activities,
  built-in activities, and — for durable agents — every LLM turn (`…​.llmChat`) and tool
  dispatch, since agent steps execute as activities. Activity attempts are never
  replayed, so each record is a real execution; retries appear as multiple attempts.

Tag cardinality is bounded by construction: tags are workflow/activity **types**, declared
event names and declared task names (compile-time sets), and closed vocabularies for actions
and outcomes — never instance IDs, and never who decided; that lives on the span and the
audit entry, where it belongs.

### What is deliberately out of scope (this iteration)

- Spans inside workflow bodies (activity calls, sleeps, awaits) — blocked by the replay
  constraint; revisit with engine-side interceptors plus trace-context propagation
  through headers if cross-boundary traces are needed.
- The engine SDK's own client metrics scope — vendor-specific pipeline; the wrapper-layer
  metrics above cover the application-facing signals.
- Tracing for inferred-typedesc APIs (`getResult`, `waitForResult`, `callActivity`, …).
- Management/REST API metrics (already observable as regular HTTP listeners).
- Worker liveness/slot gauges.

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
entries follow `[ballerina.log]`. The two content switches are off unless asked for:

```toml
# Config.toml
[ballerina.workflow.observe]
captureHumanTaskContent = true    # the decision's submitted value on its span and audit entry
captureActivityContent = true     # each activity attempt's arguments and result in the worker log
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
  roles and the action — with the submitted result on the span exactly when
  `captureHumanTaskContent` is on. `testReviewActivityDecisionTelemetry` does the same for
  a `proceed-with-input` review decision. The integration config turns both content
  switches on, so the capture paths run under the whole suite. The full pre-existing
  integration suite also runs with observability enabled, so it doubles as a regression
  check that instrumentation never disturbs execution.
- With observability off (the default for all existing users), every new code path
  reduces to a flag check.
