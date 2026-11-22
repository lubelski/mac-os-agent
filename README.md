# mac-os-agent

An agent for this Mac that lives in the menu bar. You summon it with a hotkey, tell it what you want ("change the wallpaper to a sunset", "delete zoom"), and it acts on the system.

It is like Siri in shape, without being slow or locked down, and it keeps a visible conversation like an agent chat. It is not a coding tool.

The first slice is built: a menu bar item, a hotkey, a panel, one flat thread, a shell tool, and tools for finding and opening apps. This file records what has been decided so far.

## Building and running

- `swift build` and `swift test` build the code and run the tests.
- `scripts/bundle.sh` builds `build/mac-os-agent.app`, signed ad hoc. `scripts/bundle.sh --install` moves it to `~/Applications` and launches it.
- Run only the bundle, not `swift run`. The bundle has the `Info.plist` that keeps the app out of the Dock.
- Press Option-Shift-Space to show or hide the panel. The chord is set in `Sources/mac-os-agent/SummonHotKey.swift`.
- Use "Sign in with ChatGPT" in the menu bar menu or in Settings before the first instruction.
- Settings opens from the menu bar menu, or with Command-comma while one of the app's windows is in front.
- `scripts/capture-panel-previews.sh` shows the panel in a few stand-in states and captures each one, for pull request screenshots. `--backdrop` captures it over a busy page instead, which shows the glass and its edges. Each preview quits on its own after a few seconds and never takes keyboard focus.
- `scripts/capture-settings-previews.sh` does the same for each Settings section, against a temporary data folder with sample skills, usage lines, and a thread file. `--preview-settings <section>` shows one section, and `--preview-item <name>` selects a skill or tool in it.
- `--data-folder <path>` points the app at another folder instead of `~/Library/Application Support/mac-os-agent/`, for checking a build without touching the real thread.

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
  - The default model is `gpt-6-luna`, the fastest GPT-6 model, with low reasoning effort. The model is a setting in the menu bar menu and in Settings, and both read the same preference.
- Its own tools
  - The agent runs with a set of tools that it can modify itself.
  - The tool list sent to the model stays fixed within a conversation, because a list that changes breaks prompt caching.
  - Built-in tools are a fixed, ordered list. New built-in tools go at the end. Tools from other sources will go after the built-ins, sorted by name.
  - The built-in tools are a shell command, three app tools (search the installed apps by a loose name, open an app or bring it to the front, and list the running apps), and a tool that loads a skill.
- Settings
  - A Settings window with a sidebar of sections on the left and the selected section beside it, in the style of System Settings. The sections are General, Instructions, Skills, Tools, and Debugging.
  - The window keeps one size whichever section is showing. It opens at 900 by 620 points, the owner can resize it down to 760 by 480, and it comes back at the size and place it was left. A section scrolls inside the window when it does not fit. The last section shown opens again next time.
  - Debugging is always the last section. New sections, such as MCP servers, go above it.
  - General holds the sign-in, the model, and the summon shortcut, which is shown but not editable yet.
  - Skills is a list of every skill, with a filter, beside the selected skill's detail: its description, on or off, its problem if the file is broken, the files in its folder, and its `SKILL.md` for reading. Editing happens in the owner's editor.
  - Tools lists the agent's tools in the order the model sees them, grouped by where they come from, with each tool's description as sent, its parameters, and whether it asks for a go-ahead. It is read-only. Tools from an MCP server will be a group of their own.
  - Debugging is read-only. It shows recent model requests with their token counts and duration, the prompt's size and fingerprint, the sign-in state, the thread file's size and entry count, problems since launch, and the build and how it is signed. Copy Diagnostics puts the same as plain text on the clipboard, without message content or secrets.
- Measuring prompt caching
  - The app reads the token counts from each model response: input, cached input, output, and reasoning. They pass through the provider seam in a provider-neutral shape.
  - Each model request adds one line to `usage.jsonl` in Application Support with the time, provider, model, and counts. It holds no message content and is kept apart from the thread.
  - Each line also records how long the request took and a fingerprint of the instructions and tool list sent with it, so a change that restarted the cache shows up.
  - Debugging in Settings shows the recent requests and today's total, with the cached share as a percentage.
- Instructions the owner can edit
  - The system prompt has two parts. The editable part is a file, `instructions.md` in Application Support, and the default applies until the owner saves an edit.
  - A fixed part always follows it. It covers what the app needs to work correctly: how the destructive flag and the go-ahead work, the time at the start of each message, and how skills are found, loaded, and written.
  - The prompt is read once at the start of each instruction from the owner, so an edit applies from the next one. It comes out byte for byte the same when nothing changed, so the prompt cache holds.
- Skills
  - A skill is a folder in `skills/` in Application Support with a `SKILL.md` that has `name` and `description` front matter and then instructions, plus any scripts beside it. This is the Agent Skills format.
  - The prompt lists only the name and description of each skill that is on. The agent reads the rest with the `load_skill` tool when a task needs it.
  - The owner can turn skills on and off, make a new one, and open the folder from Settings. Skills that are off are listed in `skill-settings.json`, so a new skill is on from the start.
  - The agent can write and improve skills itself with the shell tool. This is how it extends what it can do. A new or changed skill is listed from the owner's next instruction.
- Apps through native tools
  - The app tools use Launch Services, NSWorkspace, and Spotlight directly instead of the shell, because shell lookups with `mdfind` were slow and missed apps.
  - A search reads the standard app folders, caches each folder until it changes, and asks Spotlight only when nothing matches closely.
  - Opening, searching, and listing apps need no go-ahead. Quitting an app still goes through the shell tool and its confirmation step.
- Ask before destructive actions
  - A shell command waits for a go-ahead in the panel when the model marks it destructive, or when it matches a broad local pattern list for deleting, overwriting, uninstalling, quitting, killing processes, `sudo`, and system settings.
  - Either one is enough. The model cannot talk its way past the pattern list.
- A conversation you summon
  - The panel is a small chat window, not a launcher bar. It opens at 640 by 560 points, the owner can move and resize it, and it comes back where it was left, across summons and launches.
  - The whole thread is scrollable history above the text field. It opens at the latest message and follows new output unless the owner has scrolled up.
  - The owner's messages and the agent's replies sit in quiet boxes on opposite sides. Commands are small secondary lines between them, with their output behind a disclosure. A time label marks the first message of a new day or after a pause of 30 minutes or more.
  - It stays light: a floating Liquid Glass panel with no title bar, sidebar, or conversation list. The text field has focus when it appears, Return sends, and Escape hides it.
  - The text field is a standard Mac text view with everything the system gives one: the Edit menu's commands and shortcuts, the usual key bindings, input methods, spelling, text replacement, dictation, and the emoji picker. It grows with its text up to eight lines, then scrolls. Shift-Return and Option-Return add a line.
- Progress and dismissal
  - Each command shows as it runs, and the reply streams into place.
  - The go-ahead card and the Stop button sit by the text field, outside the scrolling history.
  - Hiding the panel never stops a task. The menu bar icon shows when a task is running or waiting for a go-ahead. A Stop button and a menu item end it.
- State lives where Mac apps keep theirs
  - Thread records, tool definitions, and everything else the agent owns go in `~/Library/Application Support/mac-os-agent/`.
  - This repo holds the app. It holds nothing specific to one machine.
- A current Mac app
  - It lives in the menu bar.
  - It uses Liquid Glass and the newest macOS APIs. Supporting older macOS versions is not a goal.
  - The summon interaction will change as we use it. The first version only has to exist.

## Proposed, not yet agreed

- Make the skills folder a local git repo with no remote, so every self-edit is a commit that can be reverted.
- Topic chunking and self-modification come after a week of real use of the first slice.

## Open

- Which ChatGPT plans and models the sign-in token covers, and what OpenAI's terms say about third-party apps using it. Neither has been checked.
- How far back the panel's history reaches once the thread is chunked by topic. For now it shows the whole file, with rows built lazily as they scroll into view.
- Code signing. This machine has no signing identity, and without one macOS forgets Accessibility and Automation grants on every rebuild. The Keychain may also ask again for the stored sign-in after a rebuild.
