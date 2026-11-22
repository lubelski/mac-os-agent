# mac-os-agent

Read `README.md` first for what the product is, then `planning/`: `decided.md` records what is settled and built, `planned.md` what is proposed, open, or not started, and `ideas.md` experiments to try later.

## Product rules

- This is an agent, not a coding tool. Do not give it a working directory, a project, or a session directory.
- Do not add a dependency on pi or another agent harness. The loop is ours.
- Anything the agent owns at run time lives in `~/Library/Application Support/mac-os-agent/`, never in this repo.
- Target the current macOS only. Use the newest APIs and Liquid Glass. Do not add fallbacks for older versions.
- Name things in full. The app, bundle, and folders are `mac-os-agent`, not an abbreviation.
- Keep font weight constant across hover and selection states.

## Working here

- Work in a numbered worktree under `.wt/` (for example `.wt/wt-01`), on a branch. Keep the primary checkout on `main`.
- Commit and push as you work, and open a pull request early.
- Merge your own pull requests as needed, squashed. Hold a pull request for the owner only when it needs a discussion: a product decision that is not already in `planning/decided.md`, or something you could not verify that the owner has to try.
- A pull request that changes anything visible includes evidence of how it looks: a screenshot, a recording, or a rendered image. For a change to something that exists, show before and after.
- Put images and videos on a pull request with `gh`'s `--attach` flag, which uploads the file and adds it to the body. It works on `gh pr create`, `gh pr edit`, and `gh pr comment`.
  - Alt text follows the path after `#`, as in `--attach './panel-dark.png#The panel in dark mode'`.
  - A reference to the file already in the body, such as `![The panel](./panel-dark.png)`, is rewritten to point at the upload, so the image lands where you wrote it.
  - Do not commit screenshots to a branch for this. Earlier pull requests pushed them to a `pr-assets` branch and linked the raw files. That is no longer needed, and nothing new should go there.
- Screen capture from an agent session often shows only the wallpaper, because the terminal lacks Screen Recording permission. If you could not see a change on screen, say so in the pull request.
- When a decision changes, move it between `planning/decided.md` and the Proposed and Open lists in `planning/planned.md` in the same pull request. Keep `README.md` short: what the app is and how to run it.

## Previews and captures

- `scripts/bundle.sh` builds `build/mac-os-agent.app` without installing it.
- `scripts/capture-panel-previews.sh` shows the panel in a few stand-in states and captures each one, for pull request screenshots. `--backdrop` captures it over a busy page instead, which shows the glass and its edges.
- `scripts/capture-settings-previews.sh` does the same for each Settings section, against a temporary data folder with sample skills, usage lines, and a thread file. `--preview-settings <section>` shows one section, and `--preview-item <name>` selects a skill or tool in it.
- Each preview quits on its own after a few seconds and never takes keyboard focus. Check that none is left running when you finish.
- `--data-folder <path>` points the app at another folder instead of `~/Library/Application Support/mac-os-agent/`. Use it for every manual check. The owner's real thread is private. A run with `--data-folder` keeps its sign-in in `secrets.json` in that folder, in any build, and never touches the Keychain, so it has its own and never sees the owner's.
- The summon shortcut is a setting. Its default, rules, and storage are in `Sources/MacOSAgentCore/SummonTrigger.swift`. `--preview-settings general --preview-item recording` shows the recorder recording, and `conflict` and `rejected` show its messages. Previews and tests use a stand-in hotkey that never registers, so they cannot take the installed app's.

## Signing

- `scripts/bundle.sh` signs with the first of these that exists: the certificate `MAC_OS_AGENT_SIGNING_IDENTITY` names, a Developer ID Application certificate in the keychain, a certificate named `mac-os-agent development`, and ad hoc.
- With a Developer ID it turns on the hardened runtime and a secure timestamp, which notarization needs, and signs Sparkle's helpers first. The app's entitlements are in `Resources/mac-os-agent.entitlements`: Apple events, and Calendar, which covers Reminders too. Under the hardened runtime a permission without its entitlement is refused without asking, so a new kind of access needs its entitlement there as well as its usage string.
- `scripts/release.sh` builds, notarizes, and publishes a release. `--dry-run` builds the zip and the feed into `build/release` and publishes nothing. Run it without `--dry-run` only when the owner asks.
- The `mac-os-agent development` certificate is self-signed and exists only to give every build the same identity on a Mac with no Developer ID. macOS ties permission grants (Reminders, Calendar, Automation) to that identity, so with it they survive a rebuild. With ad hoc signing each build is a new app to macOS and it asks again. The certificate does not do the same for the Keychain: for an app with no Apple team identifier, macOS ties "Always Allow" on a Keychain item to the exact build. That is why a development build keeps its sign-in in `secrets.json` in the data folder, readable only by the owner. A release build is signed with a Developer ID, so it has a team identifier, and keeps the sign-in in the login Keychain. The rule, and the one-time move from the file to the Keychain, are `SecretStorage` in `Sources/MacOSAgentCore/SecretStorage.swift`.
- The Keychain needs no entitlement. The app uses generic password items in the login keychain through `SecItem`, not the data protection keychain, which would need a provisioning profile and a keychain access group. The hardened runtime does not restrict the login keychain. Tests use a stand-in for it and never read or write the real one.
- The certificate is machine setup, not part of this repo. Creating one adds a private key to the owner's keychain, so do it only when the owner asks. The steps are: make a key and a self-signed certificate with the code signing extended key usage, bundle them as a PKCS #12 file, import it with `security import <file> -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`, and delete the key files.
- `security find-identity -v` does not list it, because a self-signed certificate is not trusted. `codesign` signs with it anyway.
- Debugging in Settings shows how the running build is signed.
