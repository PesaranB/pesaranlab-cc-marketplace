---
name: relink-bsproj-broken-brainsight-paths
description: >-
  Fix a BrainSight .bsproj that opens with "locate file" prompts because its
  source files (STL/MRI/CT/atlas) were referenced from another user's machine or
  a different Dropbox install. Use the relink-bsproj Claude Code skill.
metadata:
  type: recipe
---

# Recipe: relink a BrainSight `.bsproj` to local paths

**Symptom.** You open a shared `.bsproj` in BrainSight and it can't find its
source files — a "locate file" dialog appears for every STL / MRI / CT / atlas.
This happens because a `.bsproj` is an Apple Core Data SQLite database whose
external files are tracked as macOS *security bookmarks* (`ZFILEREFERENCE.ZBOOKMARK`).
A bookmark encodes the absolute path + volume/inode **on the machine that made
it**, so it breaks when the project moves between users, machines, or Dropbox
installs (e.g. `~/Library/CloudStorage/Dropbox-…` vs `~/…Dropbox` vs another
person's `/Users/<name>/…`).

**Fix.** Use the `relink-bsproj` skill (in the `brainsight-tools` plugin). It
finds each referenced filename on *your* Mac and rewrites its bookmark with a
valid one. It writes a safe working copy by default, so BrainSight can stay open.

## Install the skill (once per machine)
```
/plugin marketplace add <git-url-of-pesaranlab-cc-marketplace>
/plugin install brainsight-tools@pesaranlab
```

## Run it
Preview (writes nothing):
```
relink_bsproj.sh --source "/path/to/Project.bsproj" --dry-run
```
Create the relinked working copy:
```
relink_bsproj.sh --source "/path/to/Project.bsproj"
# -> Project_relinked.bsproj next to the source; original untouched
```
Useful flags: `--out NAME`, `--search DIR` (extra search root), `--in-place`
(edit source — close BrainSight first), `--force`.

## Requirements & gotchas
- macOS with system `sqlite3` and `swiftc` (`xcode-select --install`).
- Referenced files must be **synced/downloaded** — Dropbox online-only (0-byte)
  placeholders can't be relinked until made available offline.
- Files not found locally are reported `[MISS]` and keep their old bookmark +
  filename hint; nothing is destroyed.
- Bookmarks must be regenerated **on the target Mac** (they're machine-specific),
  so this runs locally, not on the shared MCP server.
- After first use on a new machine, open the output once to confirm the models
  load.

Related: the tool itself lives in `pesaranlab-cc-marketplace` →
`plugins/brainsight-tools/skills/relink-bsproj/`.
