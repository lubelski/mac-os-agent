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
- A panel with bars and an input pill. Not built. It is a redesign of the panel's frame and of where matches show. The mockups are in Figma:
  - The design, with each built-in theme: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=99-1200
  - How it got there, the pill, the mark, and the corner radii: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=81-867
  - Boards A to F, which it grew out of, redrawn as rows: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=71-465
  - What it is: the panel reads as bar, conversation, band. A quiet title bar at the top. The conversation, which scrolls and is cut by the edges of its area. A band at the bottom, on the same faint fill as the title bar, that holds a row of task links, the input pill, and a status line.
  - Settled so far, on 2026-11-24:
    - The title bar holds the model's name at the left, as a label and not a control, "MacOS Agent" centered, small and gray, and the `···` menu at the right. It is the handle for moving the panel.
    - The text field is a pill inside the band, 38 points tall with 14 point text, close to the 13 points of a message. A second line turns it into a taller box that grows upward, to about 8 lines, and then the text scrolls inside it.
    - The mark at the left of the field is the app's logo, a plain triangle pointing right, close to equilateral, with slightly rounded tips. It never changes. It does not become the icon of what Return will act on.
    - A match opens the pill into a card that holds the field and the list. The list is there as soon as there is a match, with no key to open it. The rows are Alfred's: an icon, a name, a second line, and Command numbers.
    - The card opens downward, past the panel's bottom edge, when there is room below. The panel does not resize. With no room, as in slide over, it opens upward over the end of the conversation, and covers the links.
    - The selected row is a band from one edge of the card to the other, with no radius of its own. The card's corners clip it. The rows are indented so their icons sit under the mark.
    - Corner radii follow from one another: an inner radius is the outer radius less the gap between them. The panel is 16, the inset 8, the pill and its card 8, and a message 6.
    - The status line under the pill says what the keys do now: "↵ send" while typing a message, the list's keys while a match shows, and "⌘. stop" while a task runs. When the card opens downward it covers that line, so the card carries the keys on its own last row.
    - The row above the pill holds task links, right aligned: tickets, pull requests, mock pages. The agent sets them with a tool. It is a port of the links mod in `agent-customizations`. Three fit, and more go into an overflow menu. They are quiet gray, and take the accent under the pointer.
    - Opening an app or running a quick action leaves one small line in the conversation, centered and faint, with the icon of the thing at 10 points: "Opened Balsamiq", "Ran Balcony Lights On". A failed quick action is the same line in red, with why. Several in a row are not folded together.
    - Opening an app is included lazily. Nothing is sent to the model when it happens. The entry is logged, and it joins the thread only when the next message that needs the model is sent.
    - While a task runs, the last row of the conversation is three small copies of the mark, with the bright one stepping left to right, then "Working…". Stop is a link that shows when the pointer is over the row. Other links may join it later.
    - Queued messages show in the conversation, not in the band.
    - Messages take each theme's own fills, as today. There is one accent per theme, for the mark, the caret, the selection band, and a link under the pointer.
    - The theme format gains a color for the field, its fill and its edge. Without one the pill is too faint on the dark themes.
  - Open:
    - Whether a line for an opened app or a quick action opens the inspector with its steps.
    - What happens to a logged app opening when the episode ends before another message is sent.
    - What the links' overflow menu looks like, and whether the row closes up or holds its height when there are no links.
    - Whether the links give up their row once the box is tall.
    - Which other links sit beside Stop: edit, cancel. And whether Stop on the keys alone is enough when no pointer is over the row.
    - The status line's bottom right is meant to say how to queue or steer while a task runs. Queueing is an experiment and steering is not built, so its key is not chosen.
    - The field color's value in each built-in theme. The mockups use placeholders.
    - Whether the logo also replaces the app icon, or is only the mark in the field.
    - The last row of the list still reads "Ask Iris". What it says now that the title is "MacOS Agent".
  - What it changes in [decided.md](decided.md) when it is built:
    - It takes the place of both the row above the field and the suggestions-in-the-field experiment, board E: the gray completion stays, the footer becomes the status line, and the list opens by itself instead of on Down Arrow.
    - The model's name moves from the footer to the title bar.
    - A quick action's run shows as one line, where today it shows the typed text and a row per step.
    - Opening an app leaves a line and a logged entry, where today it leaves nothing.
    - The working row gains the animation and "Working…", and Stop becomes a link on hover.
    - The field's icon is the logo, where today it is the sparkle.
  - It is a new feature the owner has not tried in the app, so it is built behind a switch in Settings, Experiments.
- One typed parameter per quick action, such as the 40 in "volume 40": the rest of the typed text, checked against a declared type, filled into one argument. The file has room for it: a top-level `parameters` list, and an argument value of the form `{"$parameter": "level"}`, in a file marked `"format": 2`, which this version lists with a problem instead of running the placeholder as written. A stored call with a parameter is the same piece the agent-built controls idea needs (a slider or field that fills one argument of a fixed call), so the two should share it.

## Open

- Which ChatGPT plans and models the sign-in token covers, and what OpenAI's terms say about third-party apps using it. Neither has been checked.
- Whether a new episode should start with a short summary of the recent ones, and whether the agent should name episodes by topic. For now it starts with nothing from before and searches when it needs to.
- Whether an experiment that wins may keep the path it replaced as a setting, as Behaviors keeps a switch per habit, or whether the old path is always deleted. The rule in [decided.md](decided.md) under Experiments says deleted, and names this as undecided.
- What each of the three experiments is asking, what would make it win, and what settles it. Their "Not set" lines are in [decided.md](decided.md) under Experiments.
- For the suggestions-in-the-field experiment, which is built behind its switch (see Experiments in [decided.md](decided.md)):
  - Whether the list under the field should open by itself when there are two or more matches, as Alfred does, instead of on Down Arrow.
  - Whether queued messages should move into the footer instead of the rows above the field.
  - The panel with bars and an input pill, under Proposed above, answers those two differently for its own design: its list opens by itself, and its queued messages show in the conversation.
  - If the experiment wins, the rows above the field go away: the instant action row and the slash command list.

## Not started

Ideas the owner has raised that nobody has designed or built yet.

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

Agreed with the owner on 2026-11-22, as three slices in this order. The first is built. The other two are not started. All of it is behind the MCP servers switch in Settings, Experiments, including the next two slices.

### First slice: the bones

Built. What it does is in [decided.md](decided.md), under "MCP servers, first slice".

### Second slice: hot reload

A change to the servers takes effect at the next episode, with no relaunch.

- The tool list is taken when an episode's first request is built and kept for the rest of the episode, as the memory block is, so the prompt cache holds within an episode.
- The servers file is watched, as the skills folder is. A server that is added, changed, turned on or off, or whose tools change, joins at the next episode. Settings says when a change is waiting for one.
- To work out: a relaunch partway through an episode has to come back with the same list, or cost one cache miss as the memory block does.

### Third slice: progressive disclosure

A server costs the prompt a line, not its whole tool list, as a skill does.

- The prompt lists each server's name and description. Two fixed tools find a server's tools and call one, as `load_skill` reads a skill.
- The tool list sent to the model then never changes for MCP, so a server can come and go in the middle of an episode, and many servers do not crowd the prompt.
- To work out: whether this replaces sending a server's tools directly or is a choice per server, and whether the model finds and calls tools as well this way. Measure it with real servers before choosing.

### Later, in no order

- Remote servers over HTTP, with OAuth sign-in and the tokens kept where the app's own sign-in is.
- Adding and editing a server in Settings instead of the file.
- The agent adding a server itself.
- MCP tools as steps of a quick action. A step is checked against the built-in tools today.
- Resources and prompts from a server. Only tools are used.
