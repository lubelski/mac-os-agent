# mac-os-agent

An agent for this Mac that lives in the menu bar. You summon it with a hotkey, tell it what you want ("change the wallpaper to a sunset", "delete zoom"), and it acts on the system.

It is like Siri in shape, without being slow or locked down, and it keeps a visible conversation like an agent chat. It is not a coding tool.

## Running it

- `scripts/bundle.sh --install` builds the app, moves it to `~/Applications`, and launches it.
- Choose "Sign in with ChatGPT" in the menu bar menu or in Settings.
- Press the summon shortcut, Option-Shift-Space unless you change it in Settings, General, or click the menu bar icon, to show or hide the panel, and type what you want done. Right-click or Control-click the icon for its menu.
- Settings opens from the menu bar menu, or with Command-comma while the panel is in front.

Everything the agent keeps (the thread, skills, instructions, usage log) is in `~/Library/Application Support/mac-os-agent/`.

## Working on it

- `swift build` and `swift test` build the code and run the tests.
- Run only the bundle, not `swift run`. The bundle has the `Info.plist` that keeps the app out of the Dock.
- [ROADMAP.md](ROADMAP.md) records what has been decided, what is proposed, and what is open.
- [AGENTS.md](AGENTS.md) has the rules for changing this repo, including how to preview and capture the interface.
