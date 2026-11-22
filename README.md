# mac-os-agent

An agent for this Mac that lives in the menu bar. You summon it with a hotkey, tell it what you want ("change the wallpaper to a sunset", "delete zoom"), and it acts on the system.

It is like Siri in shape, without being slow or locked down. It is not a chat app and not a coding tool.

Nothing is built yet. This file records what has been decided so far.

## Decided

- One thread
  - Every summon continues the same conversation. There are no separate chats to pick from.
  - The thread is a single chain that goes back in time, chunked by topic.
  - Resuming loads only the recent chunks. Older ones stay on disk.
  - Within a conversation the context only grows by appending, so prompt caching keeps working.
- Its own harness
  - The agent loop is ours: a while loop and tool calls, talking to the model API directly.
  - No dependency on pi or any other coding agent. Pi is an influence on the design, not a component.
  - The agent has no working directory, project, or session directory. Those are coding tool concepts.
- Its own tools
  - The agent runs with a set of tools that it can modify itself.
- State lives where Mac apps keep theirs
  - Thread records, tool definitions, and everything else the agent owns go in `~/Library/Application Support/mac-os-agent/`.
  - This repo holds the app. It holds nothing specific to one machine.
- A current Mac app
  - It lives in the menu bar.
  - It uses Liquid Glass and the newest macOS APIs. Supporting older macOS versions is not a goal.
  - The summon interaction will change as we use it. The first version only has to exist.

## Proposed, not yet agreed

- Write the harness in Swift inside the app, so there is no second runtime to ship.
- Keep the tool list sent to the model small and fixed (for example, a shell tool and a "run one of my scripts" tool), and let new abilities be scripts on disk. A tool list that changes mid-conversation breaks prompt caching.
- Make the tools folder a local git repo with no remote, so every self-edit is a commit that can be reverted.
- Ask before destructive actions.
- First slice: menu bar item, hotkey, panel, one flat thread, shell as the only tool. Topic chunking and self-modification come after a week of real use.

## Open

- Which model, and where the API key comes from.
- How a multistep task shows its progress, and what happens when the panel is dismissed while one is running.
- Code signing. This machine has no signing identity, and without one macOS forgets Accessibility and Automation grants on every rebuild.
