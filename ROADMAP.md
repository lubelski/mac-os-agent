# Roadmap

What has been decided for mac-os-agent, what is proposed, what is still open, and what has not been started. `README.md` says what the app is and how to run it.

When a decision changes, move it between the lists here in the same pull request.

## Decided

- One thread
  - Every summon continues the same thread. There are no separate chats to pick from.
  - The thread is a single append-only chain that goes back in time, divided into episodes. An episode can be one exchange or many.
  - Within an episode the context only grows by appending, so prompt caching keeps working.
- Episodes
  - A new episode starts when the owner sends a message after the last one has been idle longer than a timeout, or when they type `/new`. The timeout defaults to 30 minutes. Idleness counts from the last message, reply, or command in the episode, not from when the panel was shown.
  - A new episode is recorded as an `episode_start` line in `thread.jsonl`, written just before its first message. Nothing earlier is rewritten. The part of the thread written before episodes existed has no markers, and its episodes are derived from pauses of 30 minutes or more. That pause is fixed, so episode numbers never change.
  - Only the current episode is sent to the model, after the instructions and the tool list. A new episode starts with that short prefix, which is where the prompt cache starts over. Earlier episodes are not summarized into the prompt.
  - The fixed part of the instructions tells the agent that earlier episodes exist and are not in view, and to search them when the owner refers to something from before.
- Search over past episodes
  - `search_history` finds the owner's messages, the agent's replies, and the commands that ran, by words, and returns the best matches with their dates, their episode, and the messages around them. It leaves out the episode the agent already sees. `read_episode` reads one episode in order, a page at a time, with the start of each command's output.
  - The search runs on a full text index, `history-index.sqlite` in Application Support. It is a copy of the thread that is brought up to date on launch and rebuilt from the thread whenever it is missing or does not match, so deleting it is always safe. Without it, search reads the entries directly.
- Incognito
  - An incognito episode leaves no trace. It runs on a store held only in memory, with no file and no index, and it is gone when it ends. Only token counts reach `usage.jsonl`, which holds no content.
  - It starts fresh, with no earlier messages in the model's context. The agent can still search past episodes. It cannot add to them.
  - It starts with `/incognito` or the Incognito item in the menu bar menu. It ends with `/new`, with `/incognito` again, after the episode timeout, or when the app quits. Tools work as usual, including the go-ahead for destructive commands.
  - While it is on, the panel's glass has a faint tint and a line at the top says nothing from the episode is kept. If the owner writes after it timed out, the message is kept in the text field and not sent.
- Commands in the panel
  - A message that is exactly a known command, such as `/new`, is handled by the app. It is never sent to the model or written to the thread. Any other text that starts with a slash is sent as a normal message.
  - The commands are `/new` and `/incognito`. Typing a slash lists the commands that match, under the history.
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
  - The built-in tools are a shell command, three app tools (search the installed apps by a loose name, open an app or bring it to the front, and list the running apps), a tool that loads a skill, and two tools for past episodes (search them, and read one).
- Settings
  - A Settings window with a sidebar of sections on the left and the selected section beside it, in the style of System Settings. The sections are General, Instructions, Skills, Tools, History, and Debugging.
  - The window keeps one size whichever section is showing. It opens at 900 by 620 points, the owner can resize it down to 760 by 480, and it comes back at the size and place it was left. A section scrolls inside the window when it does not fit. The last section shown opens again next time.
  - Debugging is always the last section. New sections, such as MCP servers, go above it.
  - General holds the sign-in, the model, the episode timeout, and the summon shortcut, which is shown but not editable yet. The timeout is a choice from 5 minutes to 8 hours, 30 minutes by default.
  - History lists the kept episodes newest first, with each one's date, length, and first line, and a search over all of them that lists the episodes that match with the matching line. The selected episode is shown read-only, with the owner's messages, the commands that ran, and the replies as selectable text. Incognito episodes are never kept, so they never appear. Nothing can be edited or deleted there yet.
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
  - A fixed part always follows it. It covers what the app needs to work correctly: how the destructive flag and the go-ahead work, the time at the start of each message, that earlier episodes exist and how to search them, and how skills are found, loaded, and written. An incognito episode adds a line saying nothing from it is kept.
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
  - The whole thread is scrollable history above the text field, read as episodes. Each episode starts with a quiet separator that shows its date and time. Rows are built lazily as they scroll into view, so a long thread scrolls smoothly.
  - The current episode is a page at least as tall as the history. When the panel comes up after the last episode timed out, or after `/new`, it opens on an empty page, with earlier episodes above it, out of view until the owner scrolls up. Within the timeout it opens on the current episode.
  - It opens at the latest message and follows new output unless the owner has scrolled up.
  - The owner's messages and the agent's replies sit in quiet boxes on opposite sides. Commands are small secondary lines between them, with their output behind a disclosure. Inside an episode, a time label marks a message on a new day or after a pause of 30 minutes or more.
  - It stays light: a floating Liquid Glass panel with no title bar, sidebar, or conversation list. The text field has focus when it appears, Return sends, and Escape hides it.
  - A slim bar across the top of the glass moves the panel. Its right end has three small controls: re-center, dock to the left, and dock to the right. Its left end is free for a state label or an episode title later. Double-clicking the bar does nothing.
  - Re-center puts the panel back at 640 by 560 points, centered on the screen it is on.
  - Docking puts the panel against the left or right edge of its screen, at the full height, with a small margin, and at its current width up to half the screen. Docked is a state: it lasts through hiding and relaunching, and the panel docks again on its screen when a display changes or is unplugged. The active dock's control is highlighted. Choosing it again undocks back to the frame from before docking. Re-center or dragging the panel away also undocks it. While docked, only the free edge resizes.
  - The text field is a standard Mac text view with everything the system gives one: the Edit menu's commands and shortcuts, the usual key bindings, input methods, spelling, text replacement, dictation, and the emoji picker. It grows with its text up to eight lines, then scrolls. Shift-Return and Option-Return add a line.
- Showing and hiding
  - The hotkey and a left click on the menu bar icon do the same thing. When the panel is hidden, they show it with keyboard focus. When it is showing but another app has focus, the first press gives it focus, so the owner can type straight away. A press while it has focus hides it.
  - The panel stays up when the owner clicks or switches to another app. It hides only on the hotkey, the menu bar icon, Escape, or Command-W. It never takes focus on its own.
  - It floats above ordinary windows, on every Space, and over full screen apps.
  - A right click or Control-click on the icon opens the menu. So does activating the icon from the keyboard or with VoiceOver, and the menu's first item shows or hides the panel. VoiceOver also lists both as actions on the icon.
- Progress and dismissal
  - Each command shows as it runs, and the reply streams into place.
  - The go-ahead card and the Stop button sit by the text field, outside the scrolling history.
  - Hiding the panel never stops a task. The menu bar icon shows when a task is running or waiting for a go-ahead. A Stop button and a menu item end it.
- A stable signing identity
  - The build script signs with a self-signed certificate named `mac-os-agent development` when the keychain has one, so every build is the same app to macOS and Keychain and permission grants survive a rebuild. Without it the script signs ad hoc.
  - The certificate lives in the owner's login keychain. It is machine setup and not in this repo.
- State lives where Mac apps keep theirs
  - Thread records, tool definitions, and everything else the agent owns go in `~/Library/Application Support/mac-os-agent/`.
  - This repo holds the app. It holds nothing specific to one machine.
- A current Mac app
  - It lives in the menu bar.
  - It uses Liquid Glass and the newest macOS APIs. Supporting older macOS versions is not a goal.
  - The summon interaction will change as we use it. The first version only has to exist.

## Proposed, not yet agreed

- Make the skills folder a local git repo with no remote, so every self-edit is a commit that can be reverted.
- Self-modification comes after a week of real use of the first slice.

## Open

- Which ChatGPT plans and models the sign-in token covers, and what OpenAI's terms say about third-party apps using it. Neither has been checked.
- Whether a new episode should start with a short summary of the recent ones, and whether the agent should name episodes by topic. For now it starts with nothing from before and searches when it needs to.

## Not started

Ideas the owner has raised that nobody has designed or built yet.

- A fast path for simple requests such as opening an app: a cheap model or a rule-based matcher answers first, and the request escalates only when there is no confident answer.
- Limits on incognito: fewer tools available, and it stays on until the owner clears it instead of ending on the timeout.
- Interfaces the agent builds itself: a small markup language for forms and other inputs shown in the panel, with the go-ahead card as the first case, and later visualizations such as maps.
- Suggestions in the empty space of a fresh episode. What they contain is not decided.
- MCP servers, managed from a Settings section above Debugging, with each server's tools as a group in Tools.
- Summoning by double-tapping Option. Shelved in favor of Option-Shift-Space for now.
- Building the history index off the main thread on first launch, before the thread gets large.
