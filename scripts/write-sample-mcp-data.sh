#!/usr/bin/env bash
# Writes stand-in MCP servers into a data folder, for previews and renders. Previews use
# stand-in connections, so none of these commands runs.
#
#   scripts/write-sample-mcp-data.sh <data folder>
#
# weather, files, notes, calendar-sync, and tracker have cached tool lists. clock has none,
# so it is new. calendar-sync is turned off, "my server" has a name that is not allowed,
# files' write_file is set to always deny, and weather's get_forecast is read-only, so it is
# always allowed. tracker's create_attachment has a long description with shell and
# PowerShell lines, taken from a public tool description, the way a real server's can be.
# example has 40 invented tools, for a long list. drafts is turned off and has never
# connected, so it has no tools at all.
set -euo pipefail
cd "$(dirname "$0")/.."

DATA="${1:?name a data folder}"
mkdir -p "$DATA"

cat > "$DATA/mcp-servers.json" <<'JSON'
{
  "mcpServers": {
    "weather": { "command": "npx", "args": ["-y", "@example/weather-mcp"], "env": { "WEATHER_API_KEY": "placeholder" } },
    "files": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"] },
    "notes": { "command": "uvx", "args": ["notes-mcp"], "env": { "NOTES_API_TOKEN": "", "NOTES_FOLDER": "~/Notes" } },
    "calendar-sync": { "command": "/usr/local/bin/calendar-sync-mcp" },
    "clock": { "command": "npx", "args": ["-y", "@example/clock-mcp"] },
    "tracker": { "command": "npx", "args": ["-y", "@example/tracker-mcp"] },
    "example": { "command": "npx", "args": ["-y", "@example/workspace-mcp"], "env": { "EXAMPLE_TOKEN": "placeholder", "EXAMPLE_WORKSPACE": "placeholder" } },
    "drafts": { "command": "npx", "args": ["-y", "@example/drafts-mcp"] },
    "my server": { "command": "npx", "args": ["my-server"] }
  }
}
JSON
printf '{"disabled":["calendar-sync","drafts"],"goAhead":{"files":{"write_file":"deny"}}}\n' > "$DATA/mcp-settings.json"

jq -n --rawfile attachment Tests/MacOSAgentCoreTests/Fixtures/tool-description-create-attachment.txt '
# example: each of five verbs on each of eight things, 40 tools. Listing and getting are read-only.
def example_tools:
  [ ["list", "Lists the", "in the example workspace. Results come back in pages of 50, newest first, with a cursor for the next page.", true],
    ["get", "Gets one of the", "by its ID.", true],
    ["create", "Creates one of the", "and returns its ID.", false],
    ["update", "Changes one of the", ". Fields that are left out are kept as they are.", false],
    ["archive", "Archives one of the", ". It can be restored for 30 days.", false] ] as $verbs
  | ["projects", "tasks", "notes", "labels", "comments", "files", "teams", "views"] as $things
  | [ $things[] as $thing | $verbs[] as $verb
      | { name: "\($verb[0])_\($thing)",
          description: ("\($verb[1]) \($thing)" + (if ($verb[2] | startswith(".")) then "" else " " end) + $verb[2]),
          readOnly: $verb[3],
          inputSchema: { type: "object", properties: { id: { type: "string" } } } } ];
{
  "servers": {
    "weather": { "updated": "2026-11-21T09:00:00Z", "tools": [
      { "name": "get_forecast", "description": "The forecast for a city for the next few days.", "readOnly": true,
        "inputSchema": { "type": "object", "properties": { "city": { "type": "string", "description": "A city name, such as Lisbon." }, "days": { "type": "integer", "description": "How many days, 1 to 7.", "default": 3 } }, "required": ["city"] } },
      { "name": "add_alert", "description": "Adds an alert for severe weather in a city. The alert is kept on the weather service.", "readOnly": false,
        "inputSchema": { "type": "object", "properties": { "city": { "type": "string" }, "kinds": { "type": "array", "items": { "type": "string", "enum": ["storm", "heat", "frost"] } } }, "required": ["city"] } }
    ] },
    "files": { "updated": "2026-11-21T09:00:00Z", "tools": [
      { "name": "read_file", "description": "Read a file in an allowed folder.", "readOnly": true, "inputSchema": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] } },
      { "name": "write_file", "description": "Write a file in an allowed folder.", "readOnly": false, "inputSchema": { "type": "object", "properties": { "path": { "type": "string" }, "content": { "type": "string" } }, "required": ["path", "content"] } },
      { "name": "list_directory", "description": "List a folder.", "readOnly": true, "inputSchema": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] } }
    ] },
    "notes": { "updated": "2026-11-20T18:00:00Z", "tools": [
      { "name": "search_notes", "description": "Search notes by text.", "readOnly": true, "inputSchema": { "type": "object", "properties": { "query": { "type": "string" } } } },
      { "name": "create_note", "description": "Create a note.", "readOnly": false, "inputSchema": { "type": "object", "properties": { "title": { "type": "string" }, "body": { "type": "string" } } } }
    ] },
    "calendar-sync": { "updated": "2026-11-19T08:00:00Z", "tools": [
      { "name": "sync_now", "description": "Sync the calendars now.", "readOnly": false, "inputSchema": { "type": "object" } }
    ] },
    "example": { "updated": "2026-11-25T10:00:00Z", "tools": example_tools },
    "tracker": { "updated": "2026-11-24T16:00:00Z", "tools": [
      { "name": "create_attachment", "description": ($attachment | rtrimstr("\n")), "readOnly": false,
        "inputSchema": { "type": "object", "additionalProperties": false, "properties": {
          "issue": { "type": "string", "description": "Issue ID or identifier (e.g., LIN-123). P-prefixed identifiers (e.g., P-ENG-123) are projects, not issues" },
          "filename": { "type": "string", "description": "Filename for the upload (e.g., '\''screenshot.png'\'')" },
          "contentType": { "type": "string", "description": "MIME type for the upload (e.g., '\''image/png'\'', '\''application/pdf'\'')" },
          "base64Content": { "type": "string", "description": "Deprecated base64-encoded file content to upload" },
          "sha256": { "type": "string", "description": "Expected SHA-256 hex digest of the decoded file bytes." },
          "size": { "type": "integer", "minimum": 0, "description": "Expected decoded byte size. Optional, but gives a clearer error when the content does not match." }
        }, "required": ["issue", "filename", "contentType", "base64Content", "sha256"] } },
      { "name": "get_issue", "description": "Retrieve detailed information about an issue by ID.", "readOnly": true,
        "inputSchema": { "type": "object", "properties": { "id": { "type": "string", "description": "Issue ID or identifier." } }, "required": ["id"] } }
    ] }
  }
}' > "$DATA/mcp-tools-cache.json"
