---
name: relink-bsproj
description: >-
  Re-point a BrainSight .bsproj project's external file references (STL / MRI /
  CT / atlas volumes) at the copies that exist on the current Mac — fixing
  bookmarks that point at another user's home dir or a different Dropbox install.
  Use when a lab member opens a shared .bsproj and BrainSight can't find its
  source files, or when moving a project between machines / Dropbox layouts.
  macOS only; runs locally (bookmark regeneration must happen on the target Mac).
---

# Relink a BrainSight project to local paths

## What this does
A `.bsproj` is an Apple **Core Data SQLite** database. External source files are
tracked in the `ZFILEREFERENCE` table as:
- `ZLASTKNOWNDISPLAYNAME` — the plain filename (e.g. `eevee_brain.STL`)
- `ZBOOKMARK` — an opaque macOS **security-scoped bookmark** encoding the file's
  absolute path + volume/inode *on the machine that created it*.

When a project moves between users/machines/Dropbox installs, those bookmarks
point at paths that don't exist locally (e.g. `/Users/someoneelse/…`), so
BrainSight prompts to relocate every file. This skill finds each referenced
filename on the **current** Mac and rewrites its bookmark with a valid one,
generated through the real macOS bookmark API (via `swiftc`).

## When to use
- BrainSight shows "locate file" prompts for a shared project.
- You copied a `.bsproj` to a new machine / different Dropbox root.
- You want a private working copy re-pointed at your own synced files.

## How to run
The tool is `scripts/relink_bsproj.sh` (in this skill directory).

Safe default — writes a **new** working copy, never touches the source, so it's
fine to run while BrainSight is open:

```bash
scripts/relink_bsproj.sh --source "/path/to/Project.bsproj"
# -> Project_relinked.bsproj next to the source
```

Preview first (writes nothing):
```bash
scripts/relink_bsproj.sh --source "/path/to/Project.bsproj" --dry-run
```

Common options:
- `--out NAME`      name the output (e.g. `--out Project_myoffice.bsproj`)
- `--search DIR`    extra folder to look in (repeatable), searched before the
                    auto-detected Dropbox roots
- `--in-place`      edit the source directly — **close BrainSight first**
- `--force`         overwrite an existing output

## How it works (so you can trust / debug it)
1. Verifies the file is a BrainSight DB (`ZFILEREFERENCE` table present).
2. Auto-detects every Dropbox install on this Mac: `~/Library/CloudStorage/
   Dropbox-*`, `~/* Dropbox`, `~/Dropbox (*)`, `~/Dropbox`. The project's own
   subtree is searched first so a project's bundled copies win.
3. For each reference, locates the filename on disk; on multiple matches it
   picks the one sharing the longest path prefix with the project (and warns).
4. Copies the source to the output via `sqlite3 .backup` — a consistent
   snapshot even while BrainSight has the DB open (handles WAL too).
5. Regenerates each `ZBOOKMARK` with `swiftc` and writes them in one
   transaction. Updating a BLOB in place doesn't change row counts, so Core
   Data's `Z_PRIMARYKEY`/`Z_METADATA` bookkeeping stays valid.
6. Verifies every new bookmark resolves to an existing local file.

## Requirements & caveats
- macOS with `/usr/bin/sqlite3` (system) and `swiftc` (Xcode Command Line
  Tools: `xcode-select --install`). Optionally ship a prebuilt universal
  `bin/mkbookmark` next to the script for machines without swiftc.
- Referenced files must actually be **synced/downloaded locally** — Dropbox
  online-only placeholders (0-byte) can't be relinked until made available
  offline.
- The generated bookmarks are standard (not app-sandbox-scoped). They resolve
  correctly and the project's embedded data always loads; if a sandboxed
  BrainSight build ever ignores them, it falls back to the (correct) filename
  hint. Confirm by opening the output once after first use on a new machine.
- Any reference whose file isn't found locally is reported `[MISS]` and keeps
  its original bookmark + filename hint — nothing is destroyed.
