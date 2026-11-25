# mac-os-agent

Read `README.md` first for what the product is, then `VISION.md` for what a change is judged against, then `planning/`: `decided.md` records what is settled and built, `planned.md` what is proposed, open, or not started, and `ideas.md` experiments to try later.

## Product rules

- This is an agent, not a coding tool. Do not give it a working directory, a project, or a session directory.
- Do not add a dependency on pi or another agent harness. The loop is ours.
- Anything the agent owns at run time lives in `~/Library/Application Support/mac-os-agent/`, never in this repo.
- Target the current macOS only. Use the newest APIs and Liquid Glass. Do not add fallbacks for older versions.
- Name things in full. The app, bundle, and folders are `mac-os-agent`, not an abbreviation.
- Keep font weight constant across hover and selection states.
- The text field holds one icon at its left and the text. No other controls go in it.

## Working here

- Work in a numbered worktree under `.wt/` (for example `.wt/wt-01`), on a branch. Keep the primary checkout on `main`.
- Commit and push as you work, and open a pull request early.
- Merge your own pull requests as needed, squashed. Hold a pull request for the owner only when it needs a discussion: a product decision that is not already in `planning/decided.md`, or something you could not verify that the owner has to try.
- A pull request that changes anything visible includes evidence of how it looks. For a change to something that exists, show before and after. Make it this way, as part of opening the pull request, not as a later step:
  1. List the states the change touches: each panel state and Settings section a person would see differently, including waiting, error, and empty states.
  2. If no stand-in state shows the change, add one in the same pull request: a case in `PanelPreview.session(named:)` or the matching `*Preview.swift`, or a `--preview-item` for Settings. Use placeholder people and data. A new feature without a state cannot be shown, so the state is part of the feature.
  3. Render them with `scripts/render-previews.sh --pr <number> panel:<state> settings:<section>:<item>`. It draws offscreen and opens no window, so run it without asking the owner. It attaches the PNGs to the pull request as a comment. For before and after, render on `main` too with `--out` and `--title "Before"`.
  4. Look at every PNG before posting. Say in the pull request what the renders cannot show, such as glass.
- Screenshots of real windows (`scripts/capture-*-previews.sh`) put a window on screen, so ask the owner first. Use them only for what a render cannot draw: glass and blur, the inspector beside the panel, two windows, and motion.
- Put images and videos on a pull request with `gh`'s `--attach` flag, which uploads the file and adds it to the body. It works on `gh pr create`, `gh pr edit`, and `gh pr comment`.
  - Alt text follows the path after `#`, as in `--attach './panel-dark.png#The panel in dark mode'`.
  - A reference to the file already in the body, such as `![The panel](./panel-dark.png)`, is rewritten to point at the upload, so the image lands where you wrote it.
  - Do not commit screenshots to a branch for this. Earlier pull requests pushed them to a `pr-assets` branch and linked the raw files. That is no longer needed, and nothing new should go there.
- Screen capture from an agent session often shows only the wallpaper, because the terminal lacks Screen Recording permission. Renders do not need it. If you could not see a change, say so in the pull request.
- A new feature the owner has not settled goes behind a switch in Settings, Experiments, off by default, with its four lines in `planning/decided.md` under Experiments: question, wins when, decide by, and afterward. With the switch off the app is as it was before.
- Do not change `VISION.md` without the owner. When a change seems to go against it, say so in the pull request and hold it.
- When a decision changes, move it between `planning/decided.md` and the Proposed and Open lists in `planning/planned.md` in the same pull request. Keep `README.md` short: what the app is and how to run it.

## Tickets

Work is ticketed in Linear, in the `mac-os-agent` project on the Mac Apps team: https://linear.app/interstellar-cafe/project/mac-os-agent-e0407eab5b3f

- An issue is intent: what is wanted and why, in the product's terms. It does not say how.
- A sub-issue is implementation: one piece of the work that carries out its parent's intent, usually one pull request.
- Before starting, find the issue the work belongs to, or create it. Then do the work under a sub-issue of it.
- Name the sub-issue in the pull request, so the two are linked.
- Linear tracks the work. `planning/` still records what is decided and what is open.

There is one Linear user, the owner, so the assignee cannot say who is doing the work. A label does instead.

- Each sub-issue carries one label from the Worker group, naming the lane that is doing it. Put yours on when you take the sub-issue.
- A lane's label is the machine, the role, and a number: `Mac-Mini-IC-1`. IC is a session that does the work itself.
  - `Mac-Mini-IC-1` is agent sessions on the Mac mini.
  - `Macbook-Air-IC-1` is the owner working directly from his laptop.
- `scutil --get ComputerName` says which machine you are on.
- A second lane on the same machine takes the next number. Add its label to the Worker group.
- There is no convention yet for the owner himself or for an orchestrator. When one is needed, propose it to the owner and record it here.

## Tests

- `PromptCacheWireTests` checks the prompt cache in the bytes the provider sends, against `StubResponsesServer`, a stand-in for the Responses API with a fake cache. A change to the request shows as a diff in `Tests/MacOSAgentCoreTests/Fixtures/openai-wire-episode.json`. When the change is meant, run `MAC_OS_AGENT_UPDATE_GOLDEN=1 swift test --filter PromptCacheWireTests` and commit the file, and say in the pull request why the requests changed and what it does to the cache.
- `OllamaLiveTests` runs one warmed, tool-calling episode against the Ollama on this Mac and prints its timings and cache counts. It is skipped unless `MAC_OS_AGENT_LIVE_OLLAMA` names an installed model, as in `MAC_OS_AGENT_LIVE_OLLAMA=inkling-2-mini:latest swift test --filter OllamaLiveTests`. It takes about a minute, most of it the cold read.

## Previews and captures

- `scripts/bundle.sh` builds `build/mac-os-agent.app` without installing it.
- `scripts/render-icon.sh` redraws `Resources/AppIcon.icon` and `docs/icon.png` from `AppIconDrawing.swift`. Run it after changing the drawing, and commit what it writes. `scripts/render-icon.sh <1-4>` draws one of the other designs. It writes files only and launches nothing.
- `scripts/render-previews.sh` draws panel states and Settings sections to PNGs in `build/renders`, in dark and light, with no window on screen. `--list` lists the states, and `--pr <number>` attaches the PNGs to a pull request. It runs `--preview-panel` or `--preview-settings` with `--render-to <file.png>`, which builds the same window from the same stand-in data and draws it offscreen without ordering it in (`PreviewRender`). The panel is drawn with Use glass off, since glass and the vibrant colors on it do not draw offscreen. A sidebar's selection material does not draw offscreen either, so Settings draws the selected row's highlight itself while rendering.
- `scripts/capture-panel-previews.sh` shows the panel in a few stand-in states and captures each one, for pull request screenshots. `--backdrop` captures it over a busy page instead, which shows the glass and its edges.
- `scripts/capture-settings-previews.sh` does the same for each Settings section, against a temporary data folder with sample skills, usage lines, and a thread file. `--preview-settings <section>` shows one section, and `--preview-item <name>` selects a skill or tool in it.
- The Settings captures include MCP servers from sample files, with stand-in connections that never start a process. MCP is an experiment, off by default. A preview of MCP Servers or of an MCP tool shows it as if it were on, without touching the preference, and the other previews show it off. `--preview-settings mcp-servers --preview-item <server>` selects a server, and `--preview-settings tools --preview-item weather__add_alert` shows an MCP tool's go-ahead.
- `--preview-settings tools --preview-item change_settings` (or `find_tools`, `use_tool`, `read_settings`) shows the settings tools as a run with that experiment on has them. `panel:confirmation-settings-server` and `panel:confirmation-settings-experiment` show their go-ahead card.
- `--preview-settings tools --preview-item run_script` shows `run_script` as a run with the scripts experiment on has it. Its tests run the real helper SwiftPM builds. `MAC_OS_AGENT_SCRIPT_RUNNER=$PWD/build/mac-os-agent.app/Contents/MacOS/mac-os-agent-script-runner swift test --filter RunScriptToolTests` runs them against the signed, sandboxed one after `scripts/bundle.sh`.
- `--check-mcp-servers --data-folder <path>` starts the real MCP servers listed in that folder as a launch does, reports to `mcp-check.txt` there, stops them as quitting does, and quits. Launch it with `open -n -g -a build/mac-os-agent.app --args …` to get an app's PATH and never take focus.
- Each preview quits on its own after a few seconds and never takes keyboard focus. Check that none is left running when you finish.
- `--data-folder <path>` points the app at another folder instead of `~/Library/Application Support/mac-os-agent/`. Use it for every manual check. The owner's real thread is private. A run with `--data-folder` keeps its secrets in `secrets.json` in that folder, in any build, and never touches the Keychain, so it never sees the owner's. A development build has no sign-in of its own, with or without `--data-folder`. It reaches its models through inference-gateway (see Models below).
- The summon shortcut is a setting. Its default, rules, and storage are in `Sources/MacOSAgentCore/SummonTrigger.swift`. `--preview-settings general --preview-item recording` shows the recorder recording, and `conflict` and `rejected` show its messages. `--preview-settings general --preview-item brave` shows Brave Search chosen for web search with no key, and `brave-saved` with a key saved in a temporary file. Previews and tests use a stand-in hotkey that never registers, so they cannot take the installed app's.

## Models

- A release build, the one with an update feed, signs in with ChatGPT itself and calls api.openai.com and Ollama directly.
- A development build has no sign-in of its own. It sends every model request through inference-gateway at `http://127.0.0.1:47811`, with no credentials and the header `X-Client-App: mac-os-agent`. OpenAI requests go to `/openai/...` and Ollama ones to `/ollama/...`. The rule is `ModelAccess` in `Sources/MacOSAgentCore/OpenAI/InferenceGateway.swift`.
- The gateway is in `~/dev/inference-gateway`. Its launchd agent, `dev.lubelski.inference-gateway`, keeps it running, and its `scripts/install.sh` installs the agent. `inference-gateway sign-in chatgpt` signs it in. Installing it or signing it in is machine setup, so do it only when the owner asks.
- `--preview-settings general --preview-item gateway` and `--preview-settings debugging --preview-item gateway` show Settings as a development build has it.

## Signing

- `scripts/bundle.sh` signs with the first of these that exists: the certificate `MAC_OS_AGENT_SIGNING_IDENTITY` names, a Developer ID Application certificate in the keychain, a certificate named `mac-os-agent development`, and ad hoc.
- With a Developer ID it turns on the hardened runtime and a secure timestamp, which notarization needs, and signs Sparkle's helpers first. The app's entitlements are in `Resources/mac-os-agent.entitlements`: Apple events, and Calendar, which covers Reminders too. Under the hardened runtime a permission without its entitlement is refused without asking, so a new kind of access needs its entitlement there as well as its usage string.
- `scripts/release.sh` builds, notarizes, and publishes a release. `--dry-run` builds the zip and the feed into `build/release` and publishes nothing. `--check` changes nothing and says whether this Mac can release now. Run it without `--dry-run` or `--check` only when the owner asks.
- The `mac-os-agent development` certificate is self-signed and exists only to give every build the same identity on a Mac with no Developer ID. macOS ties permission grants (Reminders, Calendar, Automation) to that identity, so with it they survive a rebuild. With ad hoc signing each build is a new app to macOS and it asks again. The certificate does not do the same for the Keychain: for an app with no Apple team identifier, macOS ties "Always Allow" on a Keychain item to the exact build. That is why a development build keeps its secrets, such as a Brave Search key, in `secrets.json` in the data folder, readable only by the owner. A release build is signed with a Developer ID, so it has a team identifier, and keeps the sign-in and its other secrets in the login Keychain. The rule, and the one-time move from the file to the Keychain, are `SecretStorage` in `Sources/MacOSAgentCore/SecretStorage.swift`.
- The Keychain needs no entitlement. The app uses generic password items in the login keychain through `SecItem`, not the data protection keychain, which would need a provisioning profile and a keychain access group. The hardened runtime does not restrict the login keychain. Tests use a stand-in for it and never read or write the real one.
- The certificate is machine setup, not part of this repo. Creating one adds a private key to the owner's keychain, so do it only when the owner asks. The steps are: make a key and a self-signed certificate with the code signing extended key usage, bundle them as a PKCS #12 file, import it with `security import <file> -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`, and delete the key files.
- `security find-identity -v` does not list it, because a self-signed certificate is not trusted. `codesign` signs with it anyway.
- Debugging in Settings shows how the running build is signed.
