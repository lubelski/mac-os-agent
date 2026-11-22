# Ideas to try later

Experiments the owner has raised. None is a plan. Each says what would have to be true for it to be worth building.

## Pre-agents: a fast model first, a stronger one when it declines

Subagents hand work down. A pre-agent hands it up. Every new message goes first to the fast model with the whole episode, as it does now. The fast model answers if it can do so quickly, and it has a way to say the request is too much for it. When it says so, the same episode and message go to a stronger model, which answers instead.

- What it needs
  - A way for the fast model to decline. A tool it can call, or a fixed reply the app recognizes, are the two candidates. Declining has to be cheap and early, before the model has started acting.
  - A rule for what the stronger model sees of the declined attempt. The simplest is nothing: the decline is never part of the thread.
  - A way to show in the panel which model answered, and a setting to turn the whole thing off.
- The prompt cache
  - OpenAI caches per model, so each model has its own cached prefix. Sending the same messages to a second model does not reuse the first model's cache.
  - The first escalation in an episode is therefore cold for the stronger model, however warm the fast model was.
  - After that, each model keeps hitting its own cache only if the request it sees is a prefix of the next one it sees. An episode answered by two models interleaves their messages, so the rule has to be: what a model is sent is a fixed function of the append-only thread, and that function never changes what it produced for earlier entries.
  - Today the request already differs by model. Items that only make sense to the model that wrote them, such as encrypted reasoning, are left out after a model change. That is compatible with the rule as long as it is decided per entry and not by where the conversation currently stands.
  - A declined attempt must never appear in one request and vanish from a later one for the same model.
- What would make it not worth it
  - A declined attempt adds its whole latency to exactly the requests that are already slow.
  - The fast model may not know what it cannot do, and answer badly instead of declining.
  - One model may be simple and fast enough. Debugging in Settings records seconds per request by model, so this can be measured before anything is built.
  - Instant actions already answer the simplest requests with no model at all.
- How to try it
  - Measure first: time the same set of real requests on the fast model and the strong one.
  - Then build it behind a switch in Settings, Experiments, off by default, and compare cached share and seconds per request with it on and off.
