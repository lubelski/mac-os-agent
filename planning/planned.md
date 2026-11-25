# Planned

What is not built yet: proposals waiting for agreement, open questions, and work nobody has started. When one is settled and built, move it to [decided.md](decided.md) in the same pull request.

## Proposed, not yet agreed

- Make the skills folder a local git repo with no remote, so every self-edit is a commit that can be reverted.
- Self-modification comes after a week of real use of the first slice.
- Memory that tidies itself: between episodes, the agent reviews its memory on its own, merging duplicates, moving items out of a full core, and archiving what is stale. Not built. Memory today changes only when the agent acts in an episode.
- Memories proposed at the end of an episode: when an episode ends, the agent suggests what from it is worth keeping, for the owner to accept. Not built. Related to the [open question](#open) about starting a new episode with a short summary of the recent ones.
- More habits from terminal coding agents, as switches in Settings, Behaviors:
  - Control-R searches the owner's earlier messages backward as they type, as in a shell.
  - Escape twice clears the field. Escape today dismisses a suggestion, then closes the inspector, then hides the panel, so the second press would need to change meaning only when the field has text.
  - A leading `!` runs the rest of the line as a shell command with no model call, through the shell tool, so the go-ahead and the destructive check apply, and shows it as a `Bash` row. Not in the incognito window. Undecided: how the run is kept so the agent knows of it next time. A quick action's run is kept as the owner's message with an `action` record and a note for the model, but that record names a quick action and says the run was pre-approved, which a `!` command is not. Either it gets a record kind of its own, or the action record is widened to a typed command with a real go-ahead.
- Voice dictation. Not built. The mockups are in Figma: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=26-345
  - Settled so far:
    - The engine is a setting with three values: Off, macOS (on this Mac, through the Speech framework), and OpenAI.
    - There are two ways to start: a microphone button, and holding the summon shortcut. A tap of the shortcut still summons the panel for typing.
    - The transcription fills the field. The footer line says how it is being heard: that it is listening, which engine, and the keys. Nothing is added to the field for it.
    - A voice color marks everything that means the microphone is live, and a theme can set it. It is not in the theme yet, since nothing would draw in it.
  - Open:
    - What letting go of the shortcut does: send the message, or leave the text in the field.
    - Whether the microphone button lives in the field, as the one exception to the field's rule, or in the footer line.
    - Whether a spoken app or quick action name may run without Return.
    - Whether the ChatGPT sign-in covers OpenAI's transcription, or it needs an API key.
    - How long a hold is. 0.3 seconds is the starting value.
- A panel with bars and an input pill: a redesign of the panel's frame and of where matches show. The frame, the working row, the lines in the conversation, the task links, and the match card are built behind a switch in Settings, Experiments (see Experiments in [decided.md](decided.md)). It has a file of its own, [panel-with-input-pill.md](panel-with-input-pill.md), with the mockups, what is settled, and what is open.
- One typed parameter per quick action, such as the 40 in "volume 40": the rest of the typed text, checked against a declared type, filled into one argument. The file has room for it: a top-level `parameters` list, and an argument value of the form `{"$parameter": "level"}`, in a file marked `"format": 2`, which this version lists with a problem instead of running the placeholder as written. A stored call with a parameter is the same piece the agent-built controls idea needs (a slider or field that fills one argument of a fixed call), so the two should share it.

- More Settings sections on the pane stack, if the experiment "Settings panes that slide over" wins: Skills, MCP Servers, and History are lists beside a detail pane today. The sidebar as the stack's first level is possible with the same model and not planned.
- Editing a tool in Settings, Tools, on the pane stack: MAC-33. The Figma frames show an Edited badge and Revert.

## Open

- What OpenAI's terms say about this app using the sign-in. The app is on OpenAI's documented path for open-source and locally hosted apps. That path registers its own client at sign-in, with no requested client ID, client secret, or partner API key, and OpenAI's interest form is only for paid or remotely hosted apps. The docs name ChatGPT Plus and Pro as the eligible plans, and the models now come from the account's own list. Still unread are the specific OpenAI policy documents behind https://openai.com/policies, and the docs do not say whether a prebuilt download of an open-source app is covered.
- Whether the ChatGPT sign-in token covers OpenAI's hosted web search. It is built but has not been tried with a real sign-in. Also unchecked: whether a kept `web_search_call` is accepted when the request no longer offers the tool, such as after a relaunch with web search turned off partway through an episode.
- Whether a new episode should start with a short summary of the recent ones, and whether the agent should name episodes by topic. For now it starts with nothing from before and searches when it needs to.
- Whether an experiment that wins may keep the path it replaced as a setting, as Behaviors keeps a switch per habit, or whether the old path is always deleted. The rule in [decided.md](decided.md) under Experiments says deleted, and names this as undecided.
- What each of the three experiments is asking, what would make it win, and what settles it. Their "Not set" lines are in [decided.md](decided.md) under Experiments.
- For the suggestions-in-the-field experiment, which is built behind its switch (see Experiments in [decided.md](decided.md)):
  - Whether the list under the field should open by itself when there are two or more matches, as Alfred does, instead of on Down Arrow.
  - Whether queued messages should move into the footer instead of the rows above the field.
  - The panel with bars and an input pill, in [panel-with-input-pill.md](panel-with-input-pill.md), answers those two differently for its own design: its list opens by itself, and its queued messages show in the conversation.
  - If the experiment wins, the rows above the field go away: the instant action row and the slash command list.

## Not started

Ideas the owner has raised that nobody has designed or built yet.

- A tool that reads a page, to follow a Brave Search result. `search_web` returns only titles, addresses, and snippets.
- More kinds of instant action. Instant actions for apps and quick actions are built. Other kinds, such as System Settings panes, recent files, web addresses, and skills, are not.
- Interfaces the agent builds itself: a small markup language for forms and other inputs shown in the panel, with the go-ahead card as the first case, and later visualizations such as maps.
- Suggestions in the empty space of a fresh episode. What they contain is not decided. The slot for them exists: `FreshStartContent` in `Sources/mac-os-agent/HistoryView.swift` is shown at the bottom of a fresh page and is empty for now.
- MCP servers, after the first slice. See [MCP servers](#mcp-servers) below for the slices.
- Summoning by double-tapping Option. Shelved in favor of a key chord for now. The stored trigger has room for it as another kind.
- More native system tools, each left out of the first set for the reason given:
  - Volume, mute, and brightness. Volume needs CoreAudio device code and brightness has no public API for built-in displays.
  - Dark mode, Focus, Night Shift, and other appearance settings. There is no public API to change them, only AppleScript through System Events, which needs Automation permission.
  - Moving files to the Trash, renaming, and making folders with FileManager. Useful and easy, but they change the owner's files and want the go-ahead and undo design worked out first.
  - Notifications and scheduled alerts from the agent with UserNotifications. A new permission prompt.
  - Window layout, such as tiling the front windows. Needs Accessibility permission.
  - Screenshots and reading the screen. Needs Screen Recording permission.
  - Contacts, Mail, Messages, Music, Photos, and Notes. Each needs a permission of its own or Automation, and Notes and Mail have no public framework.
  - Battery, disk, and network status. Readable without permission, but the shell already answers these quickly with `pmset`, `df`, and `networksetup`.
  - Location and weather. A new permission class.

## MCP servers

Agreed with the owner on 2026-11-22, as three slices in this order. The first is built. The third's first stage is built as the settings tools experiment. The rest is not started. All of it is behind the MCP servers switch in Settings, Experiments, including the next two slices.

### First slice: the bones

Built. What it does is in [decided.md](decided.md), under "MCP servers, first slice".

### Second slice: hot reload

A change to the servers takes effect at the next episode, with no relaunch.

- The tool list is taken when an episode's first request is built and kept for the rest of the episode, as the memory block is, so the prompt cache holds within an episode.
- The servers file is watched, as the skills folder is. A server that is added, changed, turned on or off, or whose tools change, joins at the next episode. Settings says when a change is waiting for one.
- To work out: a relaunch partway through an episode has to come back with the same list, or cost one cache miss as the memory block does.

### Third slice: progressive disclosure, stage 2: each MCP server as a group behind `find_tools` and `use_tool`

A server costs the prompt a line, not its whole tool list, as a skill does.

- Stage 1 is built, behind the settings tools experiment: the pair `find_tools` and `use_tool`, with one group, `settings`. See "Settings the agent can change" under Experiments in [decided.md](decided.md). The probe on MAC-2 found the model finds and calls grouped tools about as reliably as listed ones, for one or two more steps and far fewer input tokens.
- Stage 2 puts each MCP server in a group of its own behind the same pair, listed in the prompt by its name and a line about it. The tool list sent to the model then never changes for MCP, so a server can come and go in the middle of an episode, and many servers do not crowd the prompt.
- To work out: whether this replaces sending a server's tools directly or is a choice per server, where a server's one line comes from, and how its tools' go-ahead settings show in Settings.

### Later, in no order

- Remote servers over HTTP, with OAuth sign-in and the tokens kept where the app's own sign-in is.
- Adding and editing a server in Settings instead of the file.
- The agent adding a server itself. Built, behind the settings tools experiment: `change_settings` adds, removes, and turns servers on and off with the owner's go-ahead. See decided.md. Still to build: a card in Settings for the secret values the agent cannot set.
- MCP tools as steps of a quick action. A step is checked against the built-in tools today.
- Resources and prompts from a server. Only tools are used.
