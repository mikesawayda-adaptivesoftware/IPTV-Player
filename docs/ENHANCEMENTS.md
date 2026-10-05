# Possible enhancements

Ideas worth doing that nobody has started yet. Not commitments, and not bugs — those go in
[`HANDOFF.md`](../HANDOFF.md) under "Outstanding work". Read [`CLAUDE.md`](../CLAUDE.md)
before picking one up, especially the Android TV section.

## 1. Page through long lists with CH+ / CH-

Scrolling a 50,000-channel list or a large movie catalogue one row at a time on a remote is
slow. In the channel list and the movie grid, CH+ / CH- (`LogicalKeyboardKey.channelUp` /
`channelDown`) should move focus a page at a time.

- Today those keys are only handled inside the live player, where they change channel.
  The list screens ignore them.
- A "page" is however many rows are visible; move focus to the item that far away rather
  than just scrolling, or focus is left behind off screen.
- Mind the virtualisation trap from the EPG: a focused node that is unmounted beyond the
  `ListView` cache extent teleports focus to the top of the scope. Scroll the target into
  view (or jump by index) before requesting focus on it.
- Keyboard equivalents for desktop: Page Up / Page Down.

## 2. Movie details screen

On TV, OK on a movie card starts playback immediately. A details screen in between would
show the poster, plot, rating, year and duration, with **Play** and **Favourite** buttons
(and **Resume** once item 3 exists).

- `VODItem` already carries `plot` and `rating`; `XtreamService.getVodInfo` exists for the
  fuller record but is not wired up (see "Built but never wired up" in `CLAUDE.md`).
- This also gives the favourite a natural home on TV, where it is currently `ExcludeFocus`d
  on the card so the card stays a single focus node.
- Play should be the autofocused button so OK, OK still plays a film in two presses.

## 3. "Continue watching" row for films

Playback position is not remembered between sessions, so a film started yesterday starts
from zero today. Remember the position and show a "Continue watching" row at the top of the
movies screen, with a progress bar on each card.

- Most of the storage already exists and is unused: `StorageService.addVodToHistory`
  (takes a `progress`), `updateVodProgress` and `getVodHistory`, backed by the
  `history_vod` box and `VODItem.watchProgress` / `lastWatched`. Nothing calls them.
- The VOD player needs to save position periodically and on exit, and resume from it on
  open. `_openAndResume` already restores position for freeze recovery and is the place to
  seed it from.
- Drop a film from the row once it is nearly finished (e.g. past 95%).
- Xtream only in practice: M3U item IDs are regenerated on every parse (see "Data model
  gotchas"), so M3U progress would orphan on reload until that is fixed.
