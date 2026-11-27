# Quick action recipes

A quick action is a JSON file in `quick-actions/` in the data folder, one per action, named by its id. The format is described at the top of `Sources/MacOSAgentCore/QuickActions/QuickAction.swift`. Settings > Quick Actions lists the files and says what is wrong with one that does not read.

Each recipe here is a whole file to copy, with placeholders to replace. `QuickActionRecipeTests` reads the recipes from this page and checks that each one parses and fits its tools, so keep each file in a `json` block of its own.

## Open a Slack channel

Passing a channel's `https://` link to Slack can bring Slack forward without switching to the channel's workspace or to the channel. A `slack://channel` link opens the channel itself, from another workspace or another channel. Save this as `quick-actions/open-example-channel.json`:

```json
{
  "format": 1,
  "name": "Open #example-channel",
  "description": "Open the #example-channel channel in the Example workspace.",
  "phrases": ["example-channel"],
  "enabled": true,
  "steps": [
    {
      "tool": "open_item",
      "arguments": {
        "application": "com.tinyspeck.slackmacgap",
        "reveal_in_finder": false,
        "target": "slack://channel?team=T0123456789&id=C0123456789"
      }
    }
  ]
}
```

Replace the name, description, and phrase with the channel's, `T0123456789` with the workspace's ID, and `C0123456789` with the channel's ID. `com.tinyspeck.slackmacgap` is the Slack app's bundle identifier.

- **The workspace ID** starts with `T`. Open the workspace in a web browser. The address becomes `https://app.slack.com/client/T…/C…`, and the workspace ID is the part that starts with `T`. Slack's help article [Locate your Slack URL or ID](https://slack.com/help/articles/221769328-Locate-your-Slack-URL-or-ID) gives this method.
- **The channel ID** usually starts with `C`. In Slack, open the channel's details by clicking its name. The ID is at the bottom of the details, with a button to copy it. The channel's "Copy link" also ends with it, as in `https://example.slack.com/archives/C0123456789`. Slack's developer docs give the IDs' form but not where to find them in the app, so this comes from other guides, not from Slack.

The link opens the channel, not a particular message or thread in it. Slack's [deep linking docs](https://docs.slack.dev/interactivity/deep-linking) describe `slack://channel?team={TEAM_ID}&id={CHANNEL_ID}` as opening the channel with that ID in that workspace, and they describe no `slack://` link for a message or a thread.
