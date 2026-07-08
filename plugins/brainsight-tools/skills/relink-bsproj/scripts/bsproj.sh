#!/bin/bash
#
# bsproj.sh — check-out / check-in workflow for shared BrainSight .bsproj files.
#
# A .bsproj is a single Core Data SQLite DB and CANNOT be safely 3-way merged
# (per-entity Z_PRIMARYKEY allocators collide; 19+ FK/join tables must be
# renumbered). So instead of merging divergent copies, we SERIALIZE edits:
#   1 editor at a time, editing the real shared file in place, behind an
# advisory lock — and the machine-specific relink is reversible so it never
# pollutes the shared copy.
#
# Subcommands:
#   checkout <proj.bsproj>   Take the lock, snapshot original file refs, and
#                            relink in place so BrainSight opens cleanly here.
#                            (Do this with BrainSight CLOSED, before editing.)
#   checkin  <proj.bsproj>   Verify integrity, restore the original (neutral)
#                            bookmarks so the shared copy carries only your
#                            content edits, release the lock. (BrainSight CLOSED.)
#   status   <proj.bsproj>   Show whether it's checked out and by whom.
#   abort    <proj.bsproj>   Release the lock + restore bookmarks WITHOUT
#                            claiming edits. (Content on disk is left as-is; use
#                            Dropbox version history to revert content.)
#
# Options:
#   --neutralize   (checkin) strip all bookmarks to display-name-only instead of
#                  restoring originals — makes the shared copy canonically
#                  "unlinked" so everyone relinks on checkout.
#   --force        (abort/checkin) proceed even if the lock is held by someone
#                  else. Use only when you know they're done.
#
# The lock is a visible sidecar `<proj>.bsproj.lock` that syncs through Dropbox
# — advisory (it works only if everyone uses this tool), but it's exactly what
# prevents the "conflicted copy" files that accumulate today.
set -euo pipefail

SQLITE=/usr/bin/sqlite3; command -v "$SQLITE" >/dev/null || SQLITE="$(command -v sqlite3)"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RELINK="$SELF_DIR/relink_bsproj.sh"

usage() { sed -n '2,45p' "$0"; }

SUB="${1:-}"; shift || true
PROJ="" NEUTRALIZE=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --neutralize) NEUTRALIZE=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; exit 2;;
    *) PROJ="$1"; shift;;
  esac
done

case "$SUB" in checkout|checkin|status|abort) ;; -h|--help|"") usage; exit 0;;
  *) echo "Unknown subcommand: $SUB" >&2; usage; exit 2;; esac
[ -n "$PROJ" ] || { echo "ERROR: need a .bsproj path" >&2; exit 2; }
[ -f "$PROJ" ] || { echo "ERROR: not found: $PROJ" >&2; exit 1; }
"$SQLITE" "$PROJ" "SELECT 1 FROM sqlite_master WHERE name='ZFILEREFERENCE';" 2>/dev/null | grep -q 1 \
  || { echo "ERROR: not a BrainSight project (no ZFILEREFERENCE): $PROJ" >&2; exit 1; }

DIR="$(cd "$(dirname "$PROJ")" && pwd)"; BASE="$(basename "$PROJ")"
LOCK="$DIR/$BASE.lock"
ORIG="$DIR/.$BASE.origrefs"
PREW="$DIR/.$BASE.prewrite"
ME="$(id -un)@$(hostname -s)"

lock_holder() { [ -f "$LOCK" ] && sed -n 's/^locked_by: //p' "$LOCK" | head -1; }

# ---------------------------------------------------------------- status ------
if [ "$SUB" = status ]; then
  if [ -f "$LOCK" ]; then echo "CHECKED OUT:"; sed 's/^/  /' "$LOCK";
  else echo "available (not checked out): $BASE"; fi
  exit 0
fi

# ---------------------------------------------------------------- checkout ----
if [ "$SUB" = checkout ]; then
  if [ -f "$LOCK" ]; then
    h="$(lock_holder)"
    if [ "$h" = "$ME" ]; then echo "Note: already checked out by you; re-relinking.";
    else echo "REFUSED: checked out by $h" >&2; echo "  (run: bsproj.sh status \"$PROJ\")" >&2; exit 1; fi
  else
    { echo "locked_by: $ME"
      echo "locked_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "project: $BASE"
      echo "note: Checked out for editing. Do NOT edit on another machine until released via 'bsproj.sh checkin'."
    } > "$LOCK"
    echo "Locked by $ME"
  fi
  # Preserve the TRUE original refs once (don't overwrite on re-checkout).
  if [ ! -f "$ORIG" ]; then
    "$SQLITE" -separator $'\t' "$PROJ" \
      "SELECT Z_PK, COALESCE(lower(hex(ZBOOKMARK)),'') FROM ZFILEREFERENCE ORDER BY Z_PK;" > "$ORIG"
    echo "Saved original file-reference state ($(wc -l < "$ORIG" | tr -d ' ') refs)."
  fi
  echo "Relinking in place for this machine..."
  "$RELINK" --source "$PROJ" --in-place
  echo
  echo "CHECKED OUT. Open '$BASE' in BrainSight, edit, save, quit — then:"
  echo "  bsproj.sh checkin \"$PROJ\""
  exit 0
fi

# ------------------------------------------------- ownership guard (ci/abort) -
if [ -f "$LOCK" ]; then
  h="$(lock_holder)"
  if [ "$h" != "$ME" ] && [ "$FORCE" -ne 1 ]; then
    echo "REFUSED: lock held by $h (you are $ME). Use --force only if they're done." >&2; exit 1
  fi
else
  echo "Warning: no lock present — was this checked out? Proceeding." >&2
fi

# Guard: if BrainSight still has the DB open, writes will fail with 'locked'.
db_write() { # $1 = sql
  local err
  if ! err="$("$SQLITE" "$PROJ" "$1" 2>&1)"; then
    echo "ERROR writing DB: $err" >&2
    echo "  -> If BrainSight is open, quit it first (it locks the file), then re-run." >&2
    exit 1
  fi
}

restore_refs() {
  echo "==> integrity check..."
  ic="$("$SQLITE" "$PROJ" "PRAGMA integrity_check;" 2>&1)"
  [ "$ic" = "ok" ] || { echo "ERROR: integrity_check failed: $ic" >&2; exit 1; }

  echo "==> snapshotting pre-write backup..."
  "$SQLITE" "$PROJ" ".backup '$PREW'"

  # Current refs on disk (to detect adds/deletes vs the saved original).
  local now="$DIR/.$BASE.nowrefs"
  "$SQLITE" "$PROJ" "SELECT Z_PK FROM ZFILEREFERENCE ORDER BY Z_PK;" > "$now"

  if [ "$NEUTRALIZE" -eq 1 ]; then
    echo "==> neutralizing: stripping all bookmarks to display-name-only..."
    db_write "UPDATE ZFILEREFERENCE SET ZBOOKMARK=NULL;"
  elif [ -f "$ORIG" ]; then
    echo "==> restoring original bookmarks from checkout snapshot..."
    local sql="BEGIN;" restored=0
    while IFS=$'\t' read -r pk hex; do
      [ -z "${pk:-}" ] && continue
      grep -qx "$pk" "$now" || continue          # row was deleted during edit; skip
      if [ -z "$hex" ]; then sql="$sql UPDATE ZFILEREFERENCE SET ZBOOKMARK=NULL WHERE Z_PK=$pk;"
      else sql="$sql UPDATE ZFILEREFERENCE SET ZBOOKMARK=X'$hex' WHERE Z_PK=$pk;"; fi
      restored=$((restored+1))
    done < "$ORIG"
    sql="$sql COMMIT;"
    db_write "$sql"
    echo "   restored $restored refs."
    # Report refs added during the edit session (no original to restore).
    local added
    added="$(comm -13 <(cut -f1 "$ORIG" | sort) <(sort "$now") | wc -l | tr -d ' ')"
    [ "$added" -gt 0 ] && echo "   note: $added new file ref(s) added during editing keep this machine's bookmark; next editor relinks them."
  else
    echo "   no original snapshot found; leaving bookmarks as-is."
  fi
  rm -f "$now"
}

# ---------------------------------------------------------------- checkin -----
if [ "$SUB" = checkin ]; then
  restore_refs
  rm -f "$LOCK" "$ORIG" "$PREW"
  echo
  echo "CHECKED IN: '$BASE' released. Only your content edits remain in the shared copy."
  echo "Let Dropbox finish syncing. (Rollback if needed: Dropbox version history.)"
  exit 0
fi

# ---------------------------------------------------------------- abort -------
if [ "$SUB" = abort ]; then
  restore_refs
  rm -f "$LOCK" "$ORIG" "$PREW"
  echo
  echo "ABORTED: lock released and bookmarks restored. Content on disk was NOT reverted."
  echo "To discard content edits too, restore an earlier version via Dropbox history."
  exit 0
fi
