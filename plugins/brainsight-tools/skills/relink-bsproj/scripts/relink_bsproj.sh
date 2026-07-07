#!/bin/bash
#
# relink_bsproj.sh — Re-point a BrainSight .bsproj's external file references at
# the copies that exist on THIS Mac, regardless of which user/machine/Dropbox
# install originally created it.
#
# A .bsproj is an Apple Core Data SQLite DB. External sources live in the
# ZFILEREFERENCE table as (ZLASTKNOWNDISPLAYNAME = filename) + (ZBOOKMARK = an
# opaque macOS security-scoped bookmark holding the real path). This tool finds
# each referenced filename on the local machine and rewrites its bookmark with a
# freshly generated, valid one (via the macOS bookmark API through swiftc).
#
# By default it works on a consistent SNAPSHOT copy (safe with BrainSight open)
# and never touches the source. Cross-machine safe: it locates files by name on
# the current disk, so bookmarks pointing at other users' home dirs are fixed.
#
# Usage:
#   relink_bsproj.sh --source PROJECT.bsproj [options]
#
# Options:
#   --source FILE      Source .bsproj (required).
#   --out NAME|PATH    Output name or path. Default: <stem>_relinked.bsproj
#                      next to the source. Ignored with --in-place.
#   --search DIR       Extra directory to search for referenced files
#                      (repeatable). Searched before auto-detected Dropbox roots.
#   --in-place         Edit the source directly (CLOSE BrainSight first!).
#   --dry-run          Print the mapping and exit; write nothing.
#   --force            Overwrite an existing output file.
#   -h | --help        This help.
#
# Requires: /usr/bin/sqlite3 (system) and swiftc (Xcode Command Line Tools).
set -euo pipefail

# ---------------------------------------------------------------- args --------
SOURCE="" OUT="" INPLACE=0 DRYRUN=0 FORCE=0
EXTRA_ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2;;
    --out)    OUT="$2"; shift 2;;
    --search) EXTRA_ROOTS+=("$2"); shift 2;;
    --in-place) INPLACE=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    --force)  FORCE=1; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SOURCE" ] || { echo "ERROR: --source is required (-h for help)" >&2; exit 2; }
[ -f "$SOURCE" ] || { echo "ERROR: source not found: $SOURCE" >&2; exit 1; }

SQLITE=/usr/bin/sqlite3; command -v "$SQLITE" >/dev/null || SQLITE="$(command -v sqlite3)"
command -v swiftc >/dev/null || { echo "ERROR: swiftc not found. Install with: xcode-select --install" >&2; exit 1; }

# Confirm it's actually a BrainSight/Core Data SQLite file.
"$SQLITE" "$SOURCE" \
  "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ZFILEREFERENCE' LIMIT 1;" \
  2>/dev/null | grep -q 1 || { echo "ERROR: no ZFILEREFERENCE table — not a BrainSight project?" >&2; exit 1; }

SRC_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
STEM="$(basename "${SOURCE%.bsproj}")"

# --------------------------------------------------- helper binaries ----------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Prefer a prebuilt binary shipped next to this script (for machines w/o swiftc).
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SELF_DIR/bin/mkbookmark" ]; then MKBM="$SELF_DIR/bin/mkbookmark"; else
  cat > "$TMP/mk.swift" <<'SWIFT'
import Foundation
guard CommandLine.arguments.count == 2 else { exit(2) }
let d = try URL(fileURLWithPath: CommandLine.arguments[1])
        .bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
print(d.map { String(format: "%02x", $0) }.joined())
SWIFT
  swiftc -O "$TMP/mk.swift" -o "$TMP/mkbookmark"; MKBM="$TMP/mkbookmark"
fi
cat > "$TMP/rs.swift" <<'SWIFT'
import Foundation
let hex = readLine(strippingNewline: true) ?? ""
var b=[UInt8](); var i=hex.startIndex
while i<hex.endIndex { let j=hex.index(i,offsetBy:2); b.append(UInt8(hex[i..<j],radix:16)!); i=j }
var stale=false
do { let u=try URL(resolvingBookmarkData:Data(b),options:[],relativeTo:nil,bookmarkDataIsStale:&stale)
     print(FileManager.default.fileExists(atPath:u.path) ? "OK\t\(u.path)" : "GONE\t\(u.path)") }
catch { print("ERR\t\(error)") }
SWIFT
swiftc -O "$TMP/rs.swift" -o "$TMP/resolvebm"; RESBM="$TMP/resolvebm"

# --------------------------------------------------- search roots -------------
# Source subtree first (a project's own copies win), then --search, then all
# Dropbox installs detected on this Mac (CloudStorage, new & legacy layouts).
ROOTS=("$SRC_DIR")
ROOTS+=(${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"})
shopt -s nullglob
for g in \
  "$HOME"/Library/CloudStorage/Dropbox-* \
  "$HOME"/*\ Dropbox \
  "$HOME"/Dropbox\ \(*\) \
  "$HOME"/Dropbox ; do
  [ -d "$g" ] && ROOTS+=("$g")
done
shopt -u nullglob

# Pick the best on-disk match for a filename: prefer the candidate sharing the
# longest path prefix with the source dir; tie-break shortest path. Warns on
# genuine ambiguity (same name in unrelated trees).
locate_file() {
  local name="$1" root cands=() c best="" bestscore=-1 score
  for root in "${ROOTS[@]}"; do
    while IFS= read -r c; do cands+=("$c"); done \
      < <(find "$root" -type f -iname "$name" -not -path '*/.*' 2>/dev/null)
    [ ${#cands[@]} -gt 0 ] && break   # first root that has any match wins
  done
  [ ${#cands[@]} -eq 0 ] && return 1
  for c in "${cands[@]}"; do
    # score = length of common prefix with SRC_DIR
    local common="$SRC_DIR" cd="$c"
    score=0
    while [ -n "$common" ] && [ "${cd#$common}" = "$cd" ]; do common="${common%/*}"; done
    score=${#common}
    if [ "$score" -gt "$bestscore" ] || { [ "$score" -eq "$bestscore" ] && [ ${#c} -lt ${#best} ]; }; then
      best="$c"; bestscore="$score"
    fi
  done
  [ ${#cands[@]} -gt 1 ] && printf '   [note] %s: %d candidates, chose nearest\n' "$name" "${#cands[@]}" >&2
  printf '%s\n' "$best"
}

# --------------------------------------------------- target DB ----------------
if [ "$INPLACE" -eq 1 ]; then
  DST="$SOURCE"
  echo "!! --in-place: editing the source. Make sure BrainSight is CLOSED."
else
  if [ -z "$OUT" ]; then DST="$SRC_DIR/${STEM}_relinked.bsproj"
  elif [ "${OUT##*/}" = "$OUT" ]; then DST="$SRC_DIR/$OUT"   # bare name
  else DST="$OUT"; fi
  [[ "$DST" == *.bsproj ]] || DST="$DST.bsproj"
  if [ -e "$DST" ] && [ "$FORCE" -ne 1 ]; then
    echo "ERROR: output exists: $DST  (use --force)" >&2; exit 1
  fi
fi

echo "Source : $SOURCE"
echo "Target : $DST${DRYRUN:+  (dry-run)}"
echo "Roots  : ${ROOTS[*]}"
echo

# --------------------------------------------------- do the work --------------
declare -a UPDATES   # pk<TAB>hex pairs, applied after snapshot
missing=0; total=0
echo "==> resolving file references:"
while IFS=$'\t' read -r pk name; do
  [ -z "${pk:-}" ] && continue
  total=$((total+1))
  if real="$(locate_file "$name")"; then
    printf '   [ok]   PK %-3s -> %s\n' "$pk" "$real"
    [ "$DRYRUN" -eq 1 ] || UPDATES+=("$pk"$'\t'"$("$MKBM" "$real")")
  else
    printf '   [MISS] PK %-3s    %s  (not on this machine)\n' "$pk" "$name"
    missing=$((missing+1))
  fi
done < <("$SQLITE" -separator $'\t' "$SOURCE" \
          "SELECT Z_PK, ZLASTKNOWNDISPLAYNAME FROM ZFILEREFERENCE ORDER BY Z_PK;")

if [ "$DRYRUN" -eq 1 ]; then
  echo; echo "Dry-run: $total refs, $missing missing. No changes written."; exit 0
fi

# Snapshot copy (consistent even with BrainSight open; handles WAL if present).
if [ "$INPLACE" -eq 0 ]; then
  echo "==> snapshotting working copy..."
  "$SQLITE" "$SOURCE" ".backup '$DST'"
fi

echo "==> writing ${#UPDATES[@]} bookmarks..."
{
  echo "BEGIN;"
  for u in ${UPDATES[@]+"${UPDATES[@]}"}; do
    pk="${u%%$'\t'*}"; hex="${u#*$'\t'}"
    echo "UPDATE ZFILEREFERENCE SET ZBOOKMARK=X'$hex' WHERE Z_PK=$pk;"
  done
  echo "COMMIT;"
} | "$SQLITE" "$DST"

# --------------------------------------------------- verify -------------------
echo "==> verifying bookmarks resolve on this machine:"
bad=0
while IFS= read -r hex; do
  [ -z "$hex" ] && continue
  res="$(printf '%s\n' "$hex" | "$RESBM")"
  [ "${res%%$'\t'*}" = "OK" ] || { bad=$((bad+1)); echo "   PROBLEM: $res"; }
done < <("$SQLITE" "$DST" "SELECT lower(hex(ZBOOKMARK)) FROM ZFILEREFERENCE WHERE ZBOOKMARK IS NOT NULL;")

echo
echo "Done -> $DST"
echo "Refs: $total total, ${#UPDATES[@]} re-pointed, $missing missing, $bad failed verification."
if [ "$bad" -eq 0 ] && [ "$missing" -eq 0 ]; then
  echo "All references resolve to files on this machine."
else
  echo "Open in BrainSight to confirm; any MISSING refs keep their old bookmark + filename hint."
fi
