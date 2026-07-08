# Durable AI Agent — Order Processing

Demonstrates a durable AI agent written with the imperative `workflow:AgentContext` API.

The `@workflow:DurableAgent` function receives an `AgentContext`, registers its tools
(`@workflow:Activity` functions) imperatively, and hands control to the durable ReAct loop
via `ctx->runDurableAgent(model, config, prompt)`. Every LLM call and every tool call runs as a
durable Temporal activity, so the agent survives worker crashes and, on replay, re-loads its
previous reasoning from the workflow event history instead of re-querying the model.

Key ideas:

- **Imperative configuration** — tools and prompt are set up in ordinary Ballerina code, so system
  prompts and tool sets can depend on runtime input.
- **Model provider is a real object** — pass any `ai:ModelProvider` (here a self-contained mock so the
  example runs without credentials; use `ai:getDefaultModelProvider()` or a `ballerinax/ai.*` client in
  production).
- **No return value** — a durable agent may run for a long time; it acts through its tools and events
  rather than returning a value. The final answer is available via the workflow result APIs.

## Run

```bash
bal run
```

The agent starts, the mock model asks it to call `checkInventory`, and the agent completes after
feeding the tool result back to the model.
