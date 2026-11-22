# mac-os-agent

An agent for this Mac that lives in the menu bar. You summon it with a hotkey, tell it what you want ("change the wallpaper to a sunset", "delete zoom"), and it acts on the system.

It is like Siri in shape, without being slow or locked down. It is not a chat app and not a coding tool.

The first slice is built: a menu bar item, a hotkey, a panel, one flat thread, and a shell tool. This file records what has been decided so far.

## Building and running

- `swift build` and `swift test` build the code and run the tests.
- `scripts/bundle.sh` builds `build/mac-os-agent.app`, signed ad hoc. `scripts/bundle.sh --install` moves it to `~/Applications` and launches it.
- Run only the bundle, not `swift run`. The bundle has the `Info.plist` that keeps the app out of the Dock.
- Press Option-Shift-Space to show or hide the panel. The chord is set in `Sources/mac-os-agent/SummonHotKey.swift`.
- Use "Sign in with ChatGPT" in the menu bar menu before the first instruction.
- `scripts/capture-panel-previews.sh` shows the panel in a few stand-in states and captures each one, for pull request screenshots.

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
  - The harness is Swift, inside the app, so there is no second runtime to ship.
- OpenAI first, behind a seam
  - The loop talks to models through a small provider interface, with one implementation per provider.
  - The first and only provider for now is OpenAI, using "Sign in with ChatGPT" and the Responses API. There is no API key to manage.
  - The app registers as its own client at sign-in. It does not reuse the Codex CLI's client or the ChatGPT backend.
  - The default model is `gpt-6-luna`, the fastest GPT-6 model, with low reasoning effort. The model is a setting in the menu bar menu.
- Its own tools
  - The agent runs with a set of tools that it can modify itself.
  - The tool list sent to the model stays fixed within a conversation, because a list that changes breaks prompt caching. For now it holds one tool, a shell command.
- Ask before destructive actions
  - A shell command waits for a go-ahead in the panel when the model marks it destructive, or when it matches a broad local pattern list for deleting, overwriting, uninstalling, quitting, killing processes, `sudo`, and system settings.
  - Either one is enough. The model cannot talk its way past the pattern list.
- Progress and dismissal
  - The panel shows the current exchange: the instruction, each command as it runs with its output, and the reply.
  - Hiding the panel never stops a task. The menu bar icon shows when a task is running or waiting for a go-ahead. A Stop button and a menu item end it.
- State lives where Mac apps keep theirs
  - Thread records, tool definitions, and everything else the agent owns go in `~/Library/Application Support/mac-os-agent/`.
  - This repo holds the app. It holds nothing specific to one machine.
- A current Mac app
  - It lives in the menu bar.
  - It uses Liquid Glass and the newest macOS APIs. Supporting older macOS versions is not a goal.
  - The summon interaction will change as we use it. The first version only has to exist.

## Proposed, not yet agreed

- Add a second fixed tool, "run one of my scripts", and let new abilities be scripts on disk.
- Make the tools folder a local git repo with no remote, so every self-edit is a commit that can be reverted.
- Topic chunking and self-modification come after a week of real use of the first slice.

## Open

- Which ChatGPT plans and models the sign-in token covers, and what OpenAI's terms say about third-party apps using it. Neither has been checked.
- Code signing. This machine has no signing identity, and without one macOS forgets Accessibility and Automation grants on every rebuild. The Keychain may also ask again for the stored sign-in after a rebuild.
