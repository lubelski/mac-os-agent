# mac-os-agent

Read `README.md` first. It records what the product is and which decisions are settled, proposed, or open.

## Product rules

- This is an agent, not a coding tool. Do not give it a working directory, a project, or a session directory.
- Do not add a dependency on pi or another agent harness. The loop is ours.
- Anything the agent owns at run time lives in `~/Library/Application Support/mac-os-agent/`, never in this repo.
- Target the current macOS only. Use the newest APIs and Liquid Glass. Do not add fallbacks for older versions.
- Name things in full. The app, bundle, and folders are `mac-os-agent`, not an abbreviation.
- Keep font weight constant across hover and selection states.

## Working here

- Work in a numbered worktree under `.wt/` (for example `.wt/wt-01`), on a branch. Keep the primary checkout on `main`.
- Commit and push as you work, and open a pull request early. Do not merge to `main` without the owner's say.
- A pull request that changes anything visible includes evidence of how it looks: a screenshot, a recording, or a rendered image. For a change to something that exists, show before and after.
- Screen capture from an agent session often shows only the wallpaper, because the terminal lacks Screen Recording permission. If you could not see a change on screen, say so in the pull request.
- When a decision in `README.md` changes, move it between Decided, Proposed, and Open in the same pull request.
