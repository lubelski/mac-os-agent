# mac-os-agent

Read `README.md` first for what the product is, then `ROADMAP.md`, which records which decisions are settled, proposed, or open, and what has not been started.

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
- Merge your own pull requests as needed, squashed. Hold a pull request for the owner only when it needs a discussion: a product decision that is not already in `ROADMAP.md`, or something you could not verify that the owner has to try.
- A pull request that changes anything visible includes evidence of how it looks: a screenshot, a recording, or a rendered image. For a change to something that exists, show before and after.
- Screen capture from an agent session often shows only the wallpaper, because the terminal lacks Screen Recording permission. If you could not see a change on screen, say so in the pull request.
- When a decision changes, move it between Decided, Proposed, and Open in `ROADMAP.md` in the same pull request. Keep `README.md` short: what the app is and how to run it.

## Previews and captures

- `scripts/bundle.sh` builds `build/mac-os-agent.app`, signed ad hoc, without installing it.
- `scripts/capture-panel-previews.sh` shows the panel in a few stand-in states and captures each one, for pull request screenshots. `--backdrop` captures it over a busy page instead, which shows the glass and its edges.
- `scripts/capture-settings-previews.sh` does the same for each Settings section, against a temporary data folder with sample skills, usage lines, and a thread file. `--preview-settings <section>` shows one section, and `--preview-item <name>` selects a skill or tool in it.
- Each preview quits on its own after a few seconds and never takes keyboard focus. Check that none is left running when you finish.
- `--data-folder <path>` points the app at another folder instead of `~/Library/Application Support/mac-os-agent/`. Use it for every manual check. The owner's real thread is private.
- The summon chord is set in `Sources/mac-os-agent/SummonHotKey.swift`.
