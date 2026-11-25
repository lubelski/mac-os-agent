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

## Keeping the prompt cache warm while idle

pi resends the last request with a one-token output cap shortly before its cache entry expires, so the next real message reads the prefix from the cache instead of writing it again. Its policy, in `pi-ai`'s `cache-warming.ts` (version 1.6.0):

- Refresh at 90% of the cache lifetime, keeping at least 10 seconds of margin. A refresh that would land after its deadline is dropped, since it would be a full-price write.
- Keep refreshing for up to 60 minutes after the request while the agent is working, and up to 30 minutes after it finished. The 30 minutes is a cap on idle warming, not a cache lifetime.
- Refresh only when it pays: 15% chance the owner sends another message before expiry while idle (measured from pi's own use), times the cost of a miss, minus the cost of the refresh, at least $0.05.
- Warm only models that declare a cache lifetime. In pi 1.6.0 that is the Anthropic and Radius models (300 seconds short, 3,600 long). No OpenAI model declares one, so pi never warms OpenAI.

- What would have to be true here
  - Requests hit the cache past the first few thousand tokens. On 2026-11-24 every hit was 0 or 3,840 tokens, even 2 seconds apart with the same instructions and tools, so the prefix is breaking for some other reason and warming would only keep those 3,840 warm. Fix that first. The usage log now records `prefix_mismatch` removals to help find it.
  - A known idle lifetime for OpenAI's cache under Sign in with ChatGPT. That sign-in rejects `prompt_cache_retention` and `prompt_cache_options`, so the 24-hour and 30-minute tiers are not available.
  - A cost model for a subscription. Sign in with ChatGPT bills against a usage limit, not dollars per token, so pi's dollar threshold does not carry over. A refresh spends some of the limit in exchange for a faster first reply.
  - It fits the episode. An episode times out after 30 minutes by default and the next one starts from the short prefix anyway, so warming past the timeout is wasted.
- How to try it
  - Measure first: from `usage.jsonl`, how often a message arrives within the cache lifetime of the last request, and how many uncached tokens the misses cost.
  - Then build it behind a switch in Settings, Experiments, off by default, and compare uncached tokens, seconds to first reply, and refresh spend.

## Writing a handoff before an episode ends

When an episode is about to time out, the app could ask the model, while its cache is still warm, for a short note on what is in progress. The next episode would start with that note instead of with nothing. pi has no such feature. The closest is an idle-compaction extension example that was proposed and closed (pi #1583).

- It goes against a settled decision: earlier episodes are not summarized into the prompt. That needs the owner.
- The note would be written for every episode that times out, and most are never continued, so it pays only if episodes that pick up where the last left off are common. The thread and `history` tools already let the agent look back when asked.
- How to try it: count, from the thread, how often the first message of an episode refers back to the one before. Build it only if that is common.

