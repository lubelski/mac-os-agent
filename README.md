# mac-os-agent

<img src="docs/icon.png" width="128" alt="The mac-os-agent app icon: a white bar with a text cursor in it, and a spark above, on a teal background">

An agent for this Mac that lives in the menu bar. You summon it with a hotkey, tell it what you want ("change the wallpaper to a sunset", "delete zoom"), and it acts on the system.

It is like Siri in shape, without being slow or locked down, and it keeps a visible conversation like an agent chat. It is not a coding tool.

The agent is called Iris unless you name it otherwise in Settings, General. The app, the repo, the bundle, and its folders are still `mac-os-agent`.

## Running it

- `scripts/bundle.sh --install` builds the app, moves it to `~/Applications`, and launches it.
- Choose "Sign in with ChatGPT" in the menu bar menu or in Settings. A development build has no sign-in. It reaches its models through [inference-gateway](https://github.com/lubelski/inference-gateway) on this Mac, which has to be running and signed in.
- Press the summon shortcut, Option-Shift-Space unless you change it in Settings, General, or click the menu bar icon, to show or hide the panel, and type what you want done. Right-click or Control-click the icon for its menu.
- Typing an app's name, or part of it, and pressing Return opens the app at once, without the model. Command-Return sends the text to the agent instead.
- Typing a quick action's name and pressing Return runs it at once, without the model. A quick action is a fixed tool call, or a few, kept in `quick-actions/`. Ask the agent to "make that instant" to save one.
- Up Arrow on the field's first line recalls your earlier messages, as in a terminal. Settings, Behaviors turns it off, and has other habits from terminal coding agents.
- Delete twice quickly in an empty field starts a new episode, as `/new` does.
- Typing a slash lists the panel's commands and the skills you can invoke. `/skill-name` and some text asks the agent to use that skill for the text.
- Settings opens from the menu bar menu, or with Command-comma while the panel is in front.
- Web search is off unless you choose OpenAI's hosted search or Brave Search in Settings, General. Brave needs an API key, saved there. A change takes effect at the next launch.

MCP servers are an experiment: turn them on in Settings > Experiments. They go in `mcp-servers.json` in the same folder, in the `mcpServers` shape other apps use. Settings > MCP Servers shows them, and a new server's tools join at the next launch. With the "Settings the agent can change" experiment also on, you can ask the agent to add, remove, or turn off a server, or to turn an experiment on or off. It asks before every change and never sees a server's secret values.

Settings > Appearance picks the panel's theme. Everything the agent keeps (the thread, memory, skills, quick actions, instructions, themes, usage log) is in `~/Library/Application Support/mac-os-agent/`.

## Working on it

- `swift build` and `swift test` build the code and run the tests.
- Run only the bundle, not `swift run`. The bundle has the `Info.plist` that keeps the app out of the Dock.
- The app icon is `Resources/AppIcon.icon`, an Icon Composer file that `bundle.sh` compiles, which needs full Xcode. Its artwork is drawn by `AppIconDrawing.swift`, which has four designs. After changing the drawing, redraw the artwork and `docs/icon.png`. A number picks another design.

  ```sh
  scripts/render-icon.sh      # the shipped design
  scripts/render-icon.sh 3    # design 3 instead
  ```
- [VISION.md](VISION.md) says what the app is for and what a change is judged against.
- [planning/](planning/README.md) records what has been decided, what is planned, and ideas to try later.
- [AGENTS.md](AGENTS.md) has the rules for changing this repo, including how to preview and capture the interface.

## Releases and updates

A release build updates itself with [Sparkle](https://sparkle-project.org). It checks about once a day, downloads a newer build, checks its signature, and relaunches into it. The relaunch waits while a task runs or waits for a go-ahead, while messages are queued, and while the incognito window holds a conversation. Settings, General has Update automatically and Check for Updates, and the menu bar menu has Check for Updates.

```sh
scripts/release.sh 1.2.0            # build, sign, notarize, and publish v1.2.0 from main
scripts/release.sh 1.2.0 --dry-run  # build the files into build/release and publish nothing
scripts/release.sh --check          # say whether this Mac can release now, and change nothing
```

- A release is a GitHub Release with the zipped app and `appcast.xml`, the feed. Installed copies read the feed from the latest release. The one-time setup is at the top of the script.
- The version is the release tag. The build number is the commit count, which Sparkle compares, so releases are built from `main`.
- A build from `bundle.sh` alone has no feed and never updates itself.
- A release build keeps the sign-in in the login Keychain. A build from `bundle.sh` alone has no sign-in. It sends its model requests through inference-gateway, and keeps other secrets, such as a Brave Search key, in `secrets.json` in the data folder.
- Notarization uses an App Store Connect API key from `~/.appstoreconnect/notary.conf` when there is one, which works with the screen locked. Otherwise it uses the `AIMeter` notarytool profile in the Keychain, which macOS opens only while the screen is unlocked.
- The notarization login and the Sparkle signing key are shared with AI Meter and Claude FM. The public key is in `scripts/sparkle-public-key.txt`.

## License

MIT. See [LICENSE](LICENSE).
