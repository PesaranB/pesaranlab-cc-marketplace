# Pesaran Lab — Claude Code plugins

Internal marketplace of Claude Code plugins for the lab.

## Plugins

### `brainsight-tools`
macOS tooling for BrainSight `.bsproj` neuronavigation projects.

- **`relink-bsproj`** skill — re-points a project's external file references
  (STL / MRI / CT / atlas volumes) at the copies that exist on the *current*
  Mac. Fixes the "BrainSight can't find the source files" problem that happens
  when a shared project was created by another user, on another machine, or
  under a different Dropbox install. Writes a safe working copy by default, so
  it's fine to run with BrainSight open.

## Install (each lab member, once)

```
/plugin marketplace add <git-url-of-this-repo>
/plugin install brainsight-tools@pesaranlab
```

To update later:
```
/plugin marketplace update pesaranlab
```

### Local / offline testing before pushing
Point the marketplace at the repo on disk:
```
/plugin marketplace add /Users/<you>/path/to/pesaranlab-cc-marketplace
/plugin install brainsight-tools@pesaranlab
```

## Using relink-bsproj
Once installed, ask Claude Code to relink a project, or run the bundled script
directly:

```
plugins/brainsight-tools/skills/relink-bsproj/scripts/relink_bsproj.sh \
    --source "/path/to/Project.bsproj" --dry-run      # preview
    # then drop --dry-run to write Project_relinked.bsproj
```

## Requirements
- macOS with `/usr/bin/sqlite3` (system) and `swiftc`
  (`xcode-select --install`).
- Referenced files must be synced locally (not Dropbox online-only 0-byte
  placeholders).

## Why this can't run on a remote/shared MCP server
Re-linking regenerates macOS security bookmarks, which encode a *specific
machine's* volume ID + inode for a file on that machine's disk. They must be
created on the target Mac. A shared server-side MCP has no access to a member's
local Dropbox, so execution is inherently local; this marketplace is the
distribution mechanism.
