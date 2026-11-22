# Roadmap

What has been decided for mac-os-agent, what is proposed, what is still open, what has not been started, and ideas to try later. `README.md` says what the app is and how to run it.

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
  - The index is brought up to date or rebuilt in the background, off the main thread, so launch and the first summon never wait on it. Until it is ready, search reads the entries directly. Entries added meanwhile go into the index when it is ready, each once.
- Incognito
  - Incognito is a window of its own, separate from the main panel. `/incognito` in the main panel, or Open Incognito Window in the menu bar menu, opens it. When it is already open, both bring it forward with its text field focused. There is one at a time. The main panel does not change: it keeps its thread, its episode, and its focus rules, and both windows can be on screen and used at once.
  - Both windows are the same panel and the same content view with different configuration: the same top bar and close button, history, rows, text field, inspector, and theme.
  - It leaves no trace. Its conversation runs on a store held only in memory, with no file and no index. Nothing from it reaches the thread, the search index, `instant-actions.json`, the preferences, or any other file. Only token counts reach `usage.jsonl`, which holds no content. Its problems go to a log of its own that nothing shows and that goes with it.
  - It is only for opening apps and asking questions. The agent there has the three application tools, `search_applications`, `open_application`, and `list_running_applications`, and nothing else: no shell, no Reminders or Calendar, no system tools, no clipboard, no file search, no skills, no themes, and no history search or episode reading. It cannot search the kept past.
  - Its instructions are the owner's editable instructions followed by a short fixed part of its own, which says what the window is, what it can and cannot do, and to say plainly when a request needs the main panel. They are read once when its conversation starts. Its tool list and instructions stay the same for the whole conversation, and its requests use a prompt cache key of their own, so they are a cached prefix apart from the main panel's.
  - It stays open until the owner clears it. It has no episode timeout. Closing it, with the close button or Command-W, discards the conversation. Clear in its top bar, or `/new`, discards the conversation and keeps the window open on a fresh one. There is no way to hide it without discarding. With no task running, closing and clearing happen at once. With one running, a card by the text field asks first, and Escape or Keep answers no. Quitting the app discards it too.
  - Escape never closes it. It dismisses an instant action suggestion, or the inspector, or a question about closing, and otherwise does nothing, so a reflex press cannot lose the conversation.
  - `/incognito` typed inside it sends nothing and shows a line saying it is already incognito.
  - The hotkey and the menu bar icon toggle only the main panel.
  - It is plain which window is which. The incognito window's surface has the theme's incognito tint for its whole life, and its top bar says "Incognito. Nothing here is kept." It has no layout menu.
  - It opens beside the main panel, to its right when there is room, then to its left, and otherwise against the screen's edge on the roomier side. It is 480 by 500 points, and the owner can move and resize it. Nothing about its place is remembered between uses, since that would be a trace.
  - Instant actions work there and open apps with no model request. The window stays up after one. It ranks matches by what the main panel has learned, read when the window opens, and it learns nothing and writes nothing.
- Commands in the panel
  - A message that is exactly a known command, such as `/new`, is handled by the app. It is never sent to the model or written to the thread. Any other text that starts with a slash is sent as a normal message.
  - The commands are `/new` and `/incognito`. Typing a slash lists the commands that match, under the history. In the incognito window `/new` clears its conversation and `/incognito` only says it is already incognito.
- Instant actions
  - A short input that is confidently an action is answered on the spot with no model request. Applications are the only kind so far: "saf", "safari", "open safari", and "switch to slack" open the app. Anything else goes to the agent exactly as before, so the model is the fallback and never a second guess.
  - The check runs on every keystroke against the installed apps, read ahead of time from the standard folders and never from Spotlight. It takes well under a millisecond, so it runs in step with the text and never shows a suggestion for text that has since changed.
  - The rule is strict, because opening an app when the owner meant to send a message is worse than being slow.
    - The whole input is a few words at most, with no line breaks and no sentence punctuation, optionally after a launch verb: open, launch, start, switch to, go to, or bring up.
    - A word such as "the", "is", "it", or "and" makes it a sentence, unless the input is exactly an app's name, such as Find My.
    - Without a verb, a match has to be the app's name, a prefix of it, a whole word of it, a word prefix, or initials from three letters. Typos and letters found inside a word are left to the agent.
    - A single everyday word, such as "find", "help", "word", or "what", opens only an app with exactly that name, or with a verb an app with it as a whole word ("open word").
    - A single character opens only what the owner took for that character before.
    - The best match has to lead the next clearly to be offered alone. Otherwise the few close ones are offered to choose between, but only with a verb or three or more characters.
  - A quiet row above the text field, where the command hint shows, says what Return will do. Return opens the app, clears the field, and hides the panel the normal way. Command-Return sends the text to the agent instead. Up, Down, Tab, and Shift-Tab choose between several matches. Escape dismisses the suggestion for this input, and the next Escape closes the inspector or hides the panel as before. The suggestion stays dismissed while the owner keeps typing after it.
  - Nothing about an instant action is sent to the model or written to the thread, and the panel shows no line for it, so the episode's request and its prompt cache stay as they were. If the app fails to open, the panel comes back with the text and a line saying why, which is shown only.
  - What the owner opens this way is learned, in `instant-actions.json` in Application Support: which app they took for which typed text, and how often and how recently each was taken. It ranks the matches, so "s" can come to mean Safari for one owner and Slack for another. The incognito window learns nothing and writes nothing.
  - The model's `search_applications` and `open_application` tools are unchanged.
  - Providers for other kinds, such as System Settings panes, recent files, web addresses, or skills, can be added behind the same rule and row later.
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
  - The built-in tools are a shell command, three app tools (search the installed apps by a loose name, open an app or bring it to the front, and list the running apps), a tool that loads a skill, two tools for past episodes (search them, and read one), two tools each for Reminders and Calendar (read, and change), six system tools (open an item, find files, read and write the clipboard, set the desktop picture, and quit or hide an app), and two appearance tools (read the themes, and save, apply, or delete one).
- Settings
  - A Settings window with a sidebar of sections on the left and the selected section beside it, in the style of System Settings. The sections are General, Appearance, Instructions, Skills, Tools, History, and Debugging.
  - The window keeps one size whichever section is showing. It opens at 900 by 620 points, the owner can resize it down to 760 by 480, and it comes back at the size and place it was left. A section scrolls inside the window when it does not fit. The last section shown opens again next time.
  - Debugging is always the last section. New sections, such as MCP servers, go above it.
  - General holds the sign-in, the model, the episode timeout, and the summon shortcut. The timeout is a choice from 5 minutes to 8 hours, 30 minutes by default.
  - History lists the kept episodes newest first, with each one's date, length, and first line, and a search over all of them that lists the episodes that match with the matching line. The selected episode is shown read-only, with the owner's messages, the commands that ran, and the replies as selectable text. Incognito conversations are never kept, so they never appear. Nothing can be edited or deleted there yet.
  - Skills is a list of every skill, with a filter, beside the selected skill's detail: its description, on or off, its problem if the file is broken, the files in its folder, and its `SKILL.md` for reading. Editing happens in the owner's editor.
  - Tools lists the agent's tools in the order the model sees them, grouped by where they come from, with each tool's description as sent, its parameters, whether it asks for a go-ahead, and whether the incognito window has it. It is read-only. Tools from an MCP server will be a group of their own.
  - A group of tools that needs a macOS permission, such as Reminders or Calendar, shows in each tool's detail whether the app has it, with a button that opens that pane of Privacy & Security, and one that asks for it when the owner has not been asked yet.
  - Debugging is read-only. It shows recent model requests with their token counts and duration, the prompt's size and fingerprint, the sign-in state, the thread file's size and entry count, problems since launch, and the build and how it is signed. Copy Diagnostics puts the same as plain text on the clipboard, without message content or secrets.
- Themes
  - The panel draws from one theme at a time. Settings keeps the standard system look and is not themed.
  - A theme is a JSON file, format 1: a name, and a light appearance, a dark one, or both. A theme with only one appearance holds the panel to it. Each appearance gives the surface (Liquid Glass, a frosted blur, or a solid fill, with an optional tint whose alpha is its strength, and an opaque fallback fill), the primary, secondary, and tertiary text, the accent, the fill and edge of the owner's message box, the agent's reply box, and the go-ahead card, the divider, the color of the bracket around code, and the incognito tint and badge. Colors are `#RRGGBB` or `#RRGGBBAA`, or a system color name such as `system-label 13%`, which the Glass theme uses to keep the system's look and vibrancy. Fonts, layout, and corner radii are not themeable.
  - Six themes are built in: Glass, the default, which looks exactly as the panel did before themes, Tidewater, a frosted teal blur, Graphite, a solid dark gray, Paper, a warm light page, High Contrast, in light and dark, and Ember, a warm brown glass. Built-in themes cannot be changed or deleted.
  - The owner's and the agent's themes are files in `themes/` in Application Support, one per theme, named by id, such as `themes/night-swim.json`. A new or changed file shows without a relaunch. A file that cannot be read is listed in Settings with its problem, and the panel falls back to Glass when the active theme's file breaks or goes away.
  - The active theme and the Use glass switch are kept in the app's preferences.
  - Use glass in Settings turns glass and blur off for every theme, which then draws on its fallback fill. Reduce Transparency in Accessibility settings does the same, whatever the switch says.
  - Increase Contrast strengthens a theme's box fills by a third and its edges and divider to at least 35 percent, and an edge the theme leaves empty takes its box's fill at full strength.
  - Primary and secondary text must reach 4.5:1, WCAG AA, everywhere it sits: on the surface, in each box, and on the incognito label. A glass or blur surface is checked over its fallback fill and with its tint over pure black and pure white. Text in a system label color is held to 3:1, the level the system's own secondary label reaches, and on glass only over the fallback fill, since vibrancy adapts it. The built-in themes are checked by a test.
  - Appearance in Settings sits under General. It shows each theme as a small live preview of a few rows of conversation, built-in themes first, then the owner's and the agent's, with the active one ringed. Clicking one applies it to the panel. It can duplicate a theme, show the themes folder in Finder, delete one of the owner's themes, and turn Use glass off.
  - The agent makes themes with `read_themes`, which lists the themes and the format or shows one theme's file, and `change_theme`, which saves a whole file, saves and applies it, applies a theme, or deletes one. A save is checked in full, so nothing malformed reaches the folder, and text that is too hard to read is refused with each pair of colors that fails and by how much. Deleting asks for the go-ahead. The two tools add about 1,140 characters to every request.
- Measuring prompt caching
  - The app reads the token counts from each model response: input, cached input, output, and reasoning. They pass through the provider seam in a provider-neutral shape.
  - Each model request adds one line to `usage.jsonl` in Application Support with the time, provider, model, and counts. It holds no message content and is kept apart from the thread.
  - Each line also records how long the request took and a fingerprint of the instructions and tool list sent with it, so a change that restarted the cache shows up.
  - Debugging in Settings shows the recent requests and today's total, with the cached share as a percentage.
- Instructions the owner can edit
  - The system prompt has two parts. The editable part is a file, `instructions.md` in Application Support, and the default applies until the owner saves an edit.
  - A fixed part always follows it. It covers what the app needs to work correctly: how the destructive flag and the go-ahead work, the time at the start of each message, that earlier episodes exist and how to search them, and how skills are found, loaded, and written. The incognito window has a fixed part of its own instead, described under Incognito.
  - The prompt is read once at the start of each instruction from the owner, so an edit applies from the next one. It comes out byte for byte the same when nothing changed, so the prompt cache holds.
  - Settings shows the editable part and the full prompt in the system's monospaced font. The editor saves what is typed: smart quotes, smart dashes, text replacement, and autocorrection are off in it.
- Skills
  - A skill is a folder in `skills/` in Application Support with a `SKILL.md` that has `name` and `description` front matter and then instructions, plus any scripts beside it. This is the Agent Skills format.
  - The prompt lists only the name and description of each skill that is on. The agent reads the rest with the `load_skill` tool when a task needs it.
  - The owner can turn skills on and off, make a new one, and open the folder from Settings. Skills that are off are listed in `skill-settings.json`, so a new skill is on from the start.
  - The agent can write and improve skills itself with the shell tool. This is how it extends what it can do. A new or changed skill is listed from the owner's next instruction.
- Apps through native tools
  - The app tools use Launch Services, NSWorkspace, and Spotlight directly instead of the shell, because shell lookups with `mdfind` were slow and missed apps.
  - A search reads the standard app folders, caches each folder until it changes, and asks Spotlight only when nothing matches closely.
  - Opening, searching, listing, and hiding apps need no go-ahead. Quitting an app goes through `quit_or_hide_application`, which asks first and quits the way the app's Quit menu item does, so it can ask to save.
- Reminders and Calendar through native tools
  - `read_reminders`, `change_reminders`, `read_events`, and `change_events` call EventKit from inside the app instead of `osascript`, which was slow, fragile, and needed Automation permission for each app.
  - Each area has one tool to read and one to change. A change tool takes a list of changes, so the model can do several in one call, and each change creates, edits, or deletes one item.
  - The app asks for full access to Reminders or to Calendar the first time a tool needs it. When access is denied or restricted, the tool says so and names the pane in System Settings that grants it. The bundle carries `NSRemindersFullAccessUsageDescription` and `NSCalendarsFullAccessUsageDescription`.
  - Deleting, changing more than one item in a call, and changing a repeating event from one occurrence on ask for the same go-ahead as a destructive shell command. Creating, completing, and editing a single item do not ask.
  - Dates go in as ISO 8601. A date alone is a day: due that day, or an all-day event. A date-time without an offset is in the Mac's time zone. Results write dates as `Sat 2026-11-21 14:00` in the Mac's time zone and say which zone that is. A reminder with a due time also gets an alert at that time, as the Reminders app does.
  - Each item comes back with a short id, eight characters from a hash of EventKit's identifier, so it is the same every time it is read. A repeating event's id adds when that occurrence was scheduled.
  - The tools sit behind small protocols, so their logic is tested against stand-in data and never against the owner's real reminders and events.
- System features through native tools
  - `open_item` opens a web address, file, or folder with its default app or a named one, or shows it in Finder, through NSWorkspace. `find_files` searches with Spotlight by name, content, kind, and date, newest first, in the home folder unless told otherwise, and leaves out hidden files and `~/Library`. `read_clipboard` and `write_clipboard` use NSPasteboard. `set_desktop_picture` sets an image file on every screen. `quit_or_hide_application` quits or hides a running app.
  - They use public frameworks only and need no new permission. Anything that would need a new permission class, private API, or the shell is left out of this set.
  - Only quitting asks for a go-ahead. Writing the clipboard and setting the desktop picture do not, since the owner asked for them and they are easy to put back.
- Ask before destructive actions
  - A shell command waits for a go-ahead in the panel when the model marks it destructive, or when it matches a broad local pattern list for deleting, overwriting, uninstalling, quitting, killing processes, `sudo`, and system settings.
  - Either one is enough. The model cannot talk its way past the pattern list.
- A conversation you summon
  - The panel is a small chat window, not a launcher bar. It opens at 640 by 560 points, the owner can move and resize it, and it comes back where it was left, across summons and launches.
  - The whole thread is scrollable history above the text field, read as episodes. Each episode starts with a separator that shows its date and time between hairlines across the history, with the widest gap in the thread above it and a wide one below it, so it reads as a break between episodes and not a mark inside one. Rows are built lazily as they scroll into view, so a long thread scrolls smoothly.
  - When the panel comes up after the last episode timed out, or after `/new`, it opens on an empty page as tall as the history, with earlier episodes above it, out of view until the owner scrolls up. The page has a line saying the earlier episodes are above, and a slot at the bottom for content such as suggestions. Within the timeout it opens on the current episode.
  - Once an episode has its first message, it is only as tall as its rows, which sit at the bottom by the text field with no space left over below them. The episode before shows above, past its separator. A thread shorter than the panel sits at the bottom too.
  - Rows of one exchange sit close together, commands in a run closer still, and each exchange starts a little further down.
  - It opens at the latest message and follows new output unless the owner has scrolled up.
  - The owner's messages and the agent's replies sit in quiet boxes on opposite sides. The owner's have a faint accent tint, and the agent's a neutral tint strong enough to stand apart from the glass. Inside an episode, a time label marks a message on a new day or after a pause of 30 minutes or more.
  - The agent's replies are GitHub Flavored Markdown: paragraphs, emphasis, inline code, fenced code blocks, lists, task lists, quotes, links, headings kept close to the text size, rules, strikethrough, and tables. The owner's messages stay plain text.
    - Foundation's own parser reads it (`AttributedString(markdown:)` with full syntax), and the panel draws it with native, selectable text. There is no Markdown package.
    - A single line break in a reply stays a line break, as before.
    - Code blocks keep their lines and scroll sideways. Tables keep their columns aligned as written, wrap a long column at a fixed width, and scroll sideways inside the reply when wider than it.
    - While a reply streams, its unfinished end is completed before parsing, so it keeps its shape as the rest arrives: an open code fence stays code, a table's header row is a table at once, and open emphasis, code spans, and links are closed or held back.
    - The default instructions encourage Markdown where it helps, including tables for tabular answers, and still ask for short replies.
  - Messages can be copied. A quiet `copy` control shows beside a message under the pointer and copies a reply's Markdown as written, or the owner's text. A code block has its own `copy` control after its label for just the code. A message's context menu has Copy, Copy as Plain Text for replies, Share, and Speak. A command's context menu has Copy Command and Copy Output.
  - The conversation uses no icons and no status colors. Its marks are characters in the text color, at secondary and tertiary levels, taken from the owner's Pi customizations in agent-customizations.
    - A command is one small line that starts with `›`, or `✗` when it failed. The program draws in the secondary level and its arguments in the tertiary. Opening the line shows the call in the inspector beside the panel. The line never grows in place.
    - A command that needs words gets one more line starting with `└`, beneath the start of the command: why it failed, that it is running, that it is waiting for a go-ahead, or that it never ran because the owner declined or the task stopped. A command that never ran is struck through.
    - Code and command text is held by an open bracket: `┌──` above, a rule down its left side, and `└──` below. The go-ahead card and the inspector's input use it.
    - The text field starts with a `›` prompt mark. Arrows are the characters `↑` and `↓`.
  - It stays light: a floating Liquid Glass panel with no title bar, sidebar, or conversation list. The text field has focus when it appears, Return sends or takes the instant action the row offers, and Escape hides it.
  - A slim bar across the top of the glass moves the panel. It is set apart from the history by the same hairline that sets the text field apart, from one shared definition, `PanelDivider`. Double-clicking the bar does nothing.
  - The bar's left end has a close button, a quiet `xmark` in the text color, which hides the panel as Escape does and never stops a task. In the incognito window the same button closes and discards, and the incognito label and Clear follow it. After it is room for an episode title later.
  - The bar's right end has one quiet control, showing the current layout's symbol, that opens a standard Mac menu of layout presets: Centered, Slide Over Left, and Slide Over Right, with a check on the current one. The items have no keyboard shortcuts, because the standard ones for placing a window, Fn-Control with an arrow, belong to the system's window tiling. A new preset is one more case of `PanelPreset`, and the menu lists it on its own. The menu leaves the panel key with the text field focused when it closes.
- Layout presets
  - Choosing a preset moves the panel there. The preset lasts through hiding and relaunching.
  - Centered is a floating panel the owner moves and resizes, which appears and disappears in place. Choosing Centered from slide over brings back the frame it had before. Choosing it while already centered puts the panel back at 640 by 560 points in the middle of its screen.
  - Slide over keeps the panel against the left or right edge of its screen at the full height, as floating rounded glass with a 10 point margin, at a width the owner resizes from the free edge and that is remembered. It is not flush to the edge, because the floating glass reads as Slide Over and Notification Center do on macOS 27 and keeps the glass's shadow whole.
  - In slide over the panel slides in from its edge when summoned and back out past it when hidden, in 0.3 seconds on one ease out curve. A summon during the slide out turns it around from where it is, and so does hiding during the slide in. The text field takes focus at once, not when the slide ends. Nothing in the panel reflows on the way. With Reduce Motion on, it fades in place in 0.15 seconds instead.
  - The glass slides inside a window that reaches the edge of the screen's visible area, which cuts it off there. So it leaves at the edge and is never seen crossing a display beside that edge, and with the Dock on that side it leaves at the Dock. It slides with Core Animation driven by the display, not by moving the window, because a window cannot be cut off at a screen's edge.
  - Dragging a slide over panel away from its edge makes it Centered where it was dropped.
  - A slide over panel goes back in place on its screen when a display changes resolution or the Dock moves, and on the screen with the mouse when its display is unplugged.
  - The dock state from before presets moves to the matching slide over on the first launch, and the frame from before docking becomes the centered frame.
  - The text field is a standard Mac text view with everything the system gives one: the Edit menu's commands and shortcuts, the usual key bindings, input methods, spelling, text replacement, dictation, and the emoji picker. It grows with its text up to eight lines, then scrolls. Shift-Return and Option-Return add a line.
- The summon shortcut
  - The owner sets it in Settings, General, with a shortcut recorder: click it and press a chord. Escape cancels, Delete or the clear control removes the shortcut, and Restore Default brings back Option-Shift-Space, the default for a fresh install.
  - A change applies at once. The old hotkey is unregistered and the new one registered. If the new one fails, the old one is registered again and the recorder says what happened.
  - While recording, the hotkey is suspended, so pressing it records it, and every key pressed is swallowed, so nothing reaches the menus or the app underneath.
  - A chord needs Command, Option, or Control, except a function key, which works alone. Shift alone, and Option or Option-Shift with a key that types a character, are refused because they type. So are the app's own menu shortcuts, a few that nearly every app has (Command-N, O, S, P, T, F, G, M), and chords macOS keeps for itself (Command-Tab, Force Quit, Lock Screen, Log Out). Menu shortcuts are matched by the character the key types, so they follow the keyboard layout.
  - The hotkey is registered with Carbon's `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring permission, and with its exclusive option, so a chord another app holds exclusively fails instead of going to both. Carbon does not report a chord that one of macOS's own shortcuts uses, so the recorder reads them with `CopySymbolicHotKeys` and warns when one that is turned on matches, such as Spotlight's Command-Space. The shortcut is still set, so it works once the owner turns the system one off.
  - It is stored in the preferences as a trigger, a small JSON value with a kind, today always `keyChord`, a key code, and modifier flags. A cleared shortcut is stored as `none`, so it is not mistaken for a fresh install. Other kinds of trigger, such as double-tapping a modifier, would be new kinds of the same value.
  - Shortcuts are shown with the usual modifier symbols in the usual order, and the key is named by what it types on the current keyboard layout, falling back to the US layout.
  - The shortcut shows in Settings, as the key equivalent of the menu bar menu's Show or Hide item, and in the icon's tooltip. That item follows whether the panel is presented, so during a slide out it already says Show and brings the panel back. If it fails to register at launch, the menu says so, Settings and Debugging show the problem, and the menu bar icon still toggles the panel.
  - The recorder is our own code, about two hundred lines, rather than a package. The usual package, KeyboardShortcuts, keeps shortcuts in a storage shape of its own that has no room for other kinds of trigger, and its public interface does not tell the app when a registration fails, which is the case the owner most needs to see. The app has no dependencies so far, and this did not justify the first.
- The tool call inspector
  - Opening a tool call row, with a click or with Return or Space when the row has keyboard focus, shows the call in an inspector beside the panel. There is one inspector. Opening another call, or Up and Down while it is open, swaps what it shows. Up and Down work in the inspector, and in the text field while the field is empty. The call it shows has a faint fill in the conversation, at the same weight.
  - It is a child window of the panel, not a wider panel. The panel's frame, layout preset, saved frame, and resize limits stay as they are, and AppKit moves the inspector, orders it, and takes it across Spaces with the panel. It has the same glass, becomes key only when the owner clicks into its text, and has a close control. Escape closes it first, and hides the panel on the next press. The incognito window has an inspector of its own, which closes when its conversation is cleared.
  - It is as tall as the panel and sits on the side with room: the panel's free side, which is the right, or the left in slide over at the right, and the other side when the free side has no room for 320 points. On a screen too narrow for either, it covers the panel's far side from the screen's edge and leaves at least 280 points of the conversation in view. The owner can resize its width, which is remembered. Which side it takes is one function, `PanelGeometry.inspectorPlacement`.
  - In slide over the inspector slides with the panel as one unit, the way out long enough for both to pass the edge, and is cut off at the same edge.
  - At the top are the call's facts: the tool and its group, the status (running, waiting for a go-ahead, succeeded, failed, declined, stopped, timed out), when it started and how long it took, a shell command's exit status, the go-ahead and its answer, the output's size in lines and characters and whether it was shortened before the model saw it, and the call id. A running call counts its time live.
  - Each tool result keeps a few more facts for this, beside the output: when the tool started, how long it took and how much of that was waiting for a go-ahead, the go-ahead's answer, the tool's group, a command's exit status, whether it timed out or was stopped, and how long the output was before it was shortened. They are optional fields on the result's line, so older lines load unchanged and show less, and nothing earlier is rewritten. The model never sees them, so requests and the prompt cache are unchanged.
  - The input is laid out for reading. A shell command shows in full and wraps, and a long one breaks before each `|`, `&&`, `||`, and `;` outside quotes, substitutions, and groups. Other tools show their arguments as named fields in the model's order, and an array of flat objects, such as the change tools' `changes`, as numbered records without their null fields. A raw view shows the arguments as written.
  - The output is laid out by its shape, with fixed rules and no model: JSON, folding, in its own key order. JSON Lines. The native tools' `as a | b | c:` field lines as a table, with the lines around them as text. Tab and comma separated tables. Columns under a header, such as `ps`, `df`, and `lsof`. `key: value` and `key=value` blocks with their nesting. Unified diffs. Lists of paths. Markdown, through the replies' Markdown views. Anything else, or anything that only nearly fits a shape, is plain text. Terminal color codes are removed, carriage return progress shows its last state, binary data shows control characters as symbols, and the shell tool's exit status, time limit, and stopped notes show as facts, not output.
  - A raw view shows exactly what was stored. Text has line numbers, a wrap toggle, and find with Command-F. There are copy controls for the input, the output, and the whole call.
  - Large output stays fast. Shapes are detected on the first 64 KB, the layout runs off the main thread, text is drawn by a standard text view that lays out only what is in view, tables show at most 5,000 rows, and output over 4 MB is plain text.
- Showing and hiding
  - The hotkey and a left click on the menu bar icon do the same thing. When the panel is hidden, they show it with keyboard focus. When it is showing but another app has focus, the first press gives it focus, so the owner can type straight away. A press while it has focus hides it.
  - The panel stays up when the owner clicks or switches to another app. It hides only on the hotkey, the menu bar icon, the close button, Escape, or Command-W. It never takes focus on its own.
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

- More kinds of instant action. Instant actions for apps are built. Other kinds, such as System Settings panes, recent files, web addresses, and skills, are not.
- Interfaces the agent builds itself: a small markup language for forms and other inputs shown in the panel, with the go-ahead card as the first case, and later visualizations such as maps.
- Suggestions in the empty space of a fresh episode. What they contain is not decided. The slot for them exists: `FreshStartContent` in `Sources/mac-os-agent/HistoryView.swift` is shown at the bottom of a fresh page and is empty for now.
- MCP servers, managed from a Settings section above Debugging, with each server's tools as a group in Tools.
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

## Ideas to try later

Experiments the owner has raised. None is a plan. Each says what would have to be true for it to be worth building.

### Pre-agents: a fast model first, a stronger one when it declines

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
  - Then build it behind an experimental switch, off by default, and compare cached share and seconds per request with it on and off.
