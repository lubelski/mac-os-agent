# mac-os-agent

An agent for this Mac that lives in the menu bar. You summon it with a hotkey, tell it what you want ("change the wallpaper to a sunset", "delete zoom"), and it acts on the system.

It is like Siri in shape, without being slow or locked down, and it keeps a visible conversation like an agent chat. It is not a coding tool.

The agent is called Iris unless you name it otherwise in Settings, General. The app, the repo, the bundle, and its folders are still `mac-os-agent`.

## Running it

- `scripts/bundle.sh --install` builds the app, moves it to `~/Applications`, and launches it.
- Choose "Sign in with ChatGPT" in the menu bar menu or in Settings.
- Press the summon shortcut, Option-Shift-Space unless you change it in Settings, General, or click the menu bar icon, to show or hide the panel, and type what you want done. Right-click or Control-click the icon for its menu.
- Typing an app's name, or part of it, and pressing Return opens the app at once, without the model. Command-Return sends the text to the agent instead.
- Typing a saved action's name and pressing Return runs it at once, without the model. An action is a fixed tool call, or a few, kept in `actions/`. Ask the agent to "make that instant" to save one.
- Up Arrow on the field's first line recalls your earlier messages, as in a terminal. Settings, Behaviors turns it off, and has other habits from terminal coding agents.
- Typing a slash lists the panel's commands and the skills you can invoke. `/skill-name` and some text asks the agent to use that skill for the text.
- Settings opens from the menu bar menu, or with Command-comma while the panel is in front.

Settings > Appearance picks the panel's theme. Everything the agent keeps (the thread, skills, actions, instructions, themes, usage log) is in `~/Library/Application Support/mac-os-agent/`.

## Working on it

- `swift build` and `swift test` build the code and run the tests.
- Run only the bundle, not `swift run`. The bundle has the `Info.plist` that keeps the app out of the Dock.
- [ROADMAP.md](ROADMAP.md) records what has been decided, what is proposed, and what is open.
- [AGENTS.md](AGENTS.md) has the rules for changing this repo, including how to preview and capture the interface.
