# A panel with bars and an input pill

A redesign of the panel's frame and of where matches show. The frame, the working row, and the lines in the conversation are built, behind a switch in Settings, Experiments. The rest is not built. Proposed, and worked out with the owner in Figma on 2026-11-24.

The panel reads as bar, conversation, band:

- A quiet title bar at the top.
- The conversation, which scrolls and is cut by the edges of its area.
- A band at the bottom, on the same faint fill as the title bar. It holds a row of task links, the input pill, and a status line.

A match opens the pill into a card that holds the field and an Alfred-style list.

## Mockups

- The design, with each built-in theme: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=99-1200
- How it got there, the pill, the mark, and the corner radii: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=81-867
- Boards A to F, which it grew out of, redrawn as rows: https://www.figma.com/design/8EIhw6IhPM67ZJq7NcfkdJ?node-id=71-465

## Settled

### Title bar

- The model's name is at the left. It is a label, not a control.
- "MacOS Agent" is centered, small and gray.
- The `···` menu is at the right.
- The bar is the handle for moving the panel.

### The field

- The text field is a pill inside the band, 38 points tall with 14 point text, close to the 13 points of a message.
- A second line turns it into a taller box that grows upward, to about 8 lines. Then the text scrolls inside it.
- The mark at the left of the field is the app's logo: a plain triangle pointing right, close to equilateral, with slightly rounded tips.
- The mark never changes. It does not become the icon of what Return will act on.

### Matches

- A match opens the pill into a card that holds the field and the list.
- The list is there as soon as there is a match, with no key to open it.
- The rows are Alfred's: an icon, a name, a second line, and Command numbers.
- With room below, the card opens downward, past the panel's bottom edge. The panel does not resize.
- With no room, as in slide over, the card opens upward over the end of the conversation, and covers the links.
- The selected row is a band from one edge of the card to the other, with no radius of its own. The card's corners clip it.
- The rows are indented so their icons sit under the mark.

### Corner radii

- An inner radius is the outer radius less the gap between them.
- The panel is 16, the inset 8, the pill and its card 8, and a message 6.

### Status line

- The line under the pill says what the keys do now:
  - "↵ send" while typing a message.
  - The list's keys while a match shows.
  - "⌘. stop" while a task runs.
- When the card opens downward it covers that line, so the card carries the keys on its own last row.

### Task links

- The row above the pill holds task links, right aligned: tickets, pull requests, mock pages.
- The agent sets them with a tool. It is a port of the links mod in `agent-customizations`.
- Three fit. More go into an overflow menu.
- They are quiet gray, and take the accent under the pointer.

### Lines in the conversation

- Opening an app or running a quick action leaves one small line in the conversation: "Opened Balsamiq", "Ran Balcony Lights On".
- The line is centered and faint, with the icon of the thing at 10 points.
- A failed quick action is the same line in red, with why.
- Several in a row are not folded together.
- Opening an app is included lazily. Nothing is sent to the model when it happens. The entry is logged, and it joins the thread only when the next message that needs the model is sent.

### While a task runs

- The last row of the conversation is three small copies of the mark, with the bright one stepping left to right, then "Working…".
- Stop is a link that shows when the pointer is over the row. Other links may join it later.
- Queued messages show in the conversation, not in the band.

### Color

- Messages take each theme's own fills, as today.
- There is one accent per theme, for the mark, the caret, the selection band, and a link under the pointer.
- The theme format gains a color for the field, its fill and its edge. Without one the pill is too faint on the dark themes.

## Open

- Whether a line for an opened app or a quick action opens the inspector with its steps. As built it opens nothing, and a run's steps are kept in the thread as before.
- What happens to a logged app opening when the episode ends before another message is sent. As built the opening is logged as an entry from the owner is: when the episode has timed out or a fresh start was asked for, it starts the new episode, and a message within the timeout joins it. When the episode ends first, the opening stays in the thread, a line in its episode, and is never sent.
- What the links' overflow menu looks like.
- Whether the links row closes up or holds its height when there are no links.
- Whether the links give up their row once the box is tall.
- Which other links sit beside Stop: edit, cancel.
- Whether Stop on the keys alone is enough when no pointer is over the working row.
- The status line's bottom right says "↵ queue" with the queue experiment on. Steering is not built, so its key is not chosen.
- Whether queued messages sit after the working row, as built, or above it.
- What the working row's marks do with Reduce Motion on. As built they stand still, all three at full strength.
- The field color's value in each built-in theme. The mockups use placeholders, and the first slice gives each built-in theme a value of its own for the owner to judge.
- Whether the logo also replaces the app icon, or is only the mark in the field.
- The last row of the list still reads "Ask Iris". What it says now that the title is "MacOS Agent".

## What it changes when built

Each of these is described in [decided.md](decided.md) as it works today.

- It takes the place of both the row above the field and the suggestions-in-the-field experiment, board E. The gray completion stays, the footer becomes the status line, and the list opens by itself instead of on Down Arrow.
- The model's name moves from the footer to the title bar.
- A quick action's run shows as one line, where today it shows the typed text and a row per step.
- Opening an app leaves a line and a logged entry, where today it leaves nothing.
- The working row gains the animation and "Working…", and Stop becomes a link on hover.
- The field's icon is the logo, where today it is the sparkle.

It is a new feature the owner has not tried in the app, so it is built behind a switch in Settings, Experiments, "Panel with bars and an input pill". Its four experiment lines are in [decided.md](decided.md) under Experiments.

The first slice, the frame, is built: the title bar, the band with the pill and the status line, the logo as the mark, the radii, and the field color in the theme format. The working row is built too: the marks and "Working…", Stop as a link under the pointer, "⌘. stop" and "↵ queue" on the status line, and queued messages in the conversation. So are the lines in the conversation, with opened apps logged and included lazily. The match card and the task links are not.
