#!/bin/zsh
# Overflow: move cold data from the internal disk to an external "overflow" volume.
# Dry run by default; pass --run to actually move. Safe to re-run any time.
#
#   overflow-archive.sh                 show what would move
#   overflow-archive.sh --run           move it
#   overflow-archive.sh --print-config  show the active configuration (used by the menu bar app)
#
# Two kinds of sources, both configured in config.zsh (see config.example.zsh):
#   FILE_SOURCES    "dir|days"  every file older than N days is moved on its own (no symlink)
#   FOLDER_SOURCES  "dir|days"  each top-level subfolder whose *small* files (< 1 MB) are all
#                               untouched for N days is moved whole; a symlink is left behind
#   Small files only: copies made by cp -p / APFS clones give big media files misleading mtimes,
#   while the files you actually edit (source, json, md) are small.
#   Subfolders containing a .git directory, and names listed in FOLDER_KEEP, never move.
#
# Everything lands under $DEST using the same path relative to $HOME, so restoring is a plain
# copy back:   rsync -a "$DEST/<path>" ~/<path>    (remove the symlink first for folders)
#
# Safety: refuses to run unless $DEST/.overflow-stick exists (so it never writes into an empty
# mount point or the wrong drive); every file is copied, byte-compared, and only then deleted.
set -u
FIND=/usr/bin/find   # system find; Homebrew bfs rejects "-N days"

# ---- defaults, overridden by config.zsh ----
DEST=/Volumes/Overflow
FILE_SOURCES=( "$HOME/.codex/sessions|30" "$HOME/.codex/generated_images|30" )
FOLDER_SOURCES=( "$HOME/Projects/Advanced Content|14" )
FOLDER_KEEP=( coordination docs deliverables analysis apps experiments )
CONFIG="${OVERFLOW_CONFIG:-$HOME/Library/Application Support/Overflow/config.zsh}"
[[ -f "$CONFIG" ]] && source "$CONFIG"
# env overrides for one-off runs, e.g.  FOLDER_DAYS=7 overflow-archive.sh --run
FILE_DAYS="${FILE_DAYS:-}"; FOLDER_DAYS="${FOLDER_DAYS:-}"

if [[ "${1:-}" == "--print-config" ]]; then
  echo "DEST=$DEST"; echo "CONFIG=$CONFIG"
  for s in "${FILE_SOURCES[@]}"; do echo "FILE=$s"; done
  for s in "${FOLDER_SOURCES[@]}"; do echo "FOLDER=$s"; done
  exit 0
fi

MARKER="$DEST/.overflow-stick"
RUN=0; [[ "${1:-}" == "--run" ]] && RUN=1
if [[ ! -f "$MARKER" ]]; then
  echo "Overflow volume not mounted at $DEST (marker $MARKER missing). Nothing done."; exit 0
fi
LOG="$DEST/_archive-log.txt"
say() { echo "$*"; (( RUN )) && echo "$(date '+%F %T') $*" >> "$LOG"; }
before=$(df -k "$HOME" | awk 'NR==2{print $4}')

move_file() {
  local src="$1" rel="${1#$HOME/}" dst
  dst="$DEST/$rel"
  if (( ! RUN )); then echo "  would move  $rel"; return; fi
  mkdir -p "${dst:h}"
  if cp -p "$src" "$dst.part" && cmp -s "$src" "$dst.part"; then
    mv -f "$dst.part" "$dst" && rm -f "$src" && say "moved $rel"
  else
    rm -f "$dst.part"; say "FAILED $rel (kept original)"
  fi
}

move_dir() {
  local src="$1" rel="${1#$HOME/}" dst
  dst="$DEST/$rel"
  if (( ! RUN )); then echo "  would move  $rel/  ($(du -sh "$src" | cut -f1))"; return; fi
  mkdir -p "${dst:h}"
  if rsync -a "$src/" "$dst/" && rsync -a --checksum --dry-run --itemize-changes "$src/" "$dst/" | grep -q . ; then
    say "FAILED verify $rel (kept original)"; return
  fi
  rm -rf "$src" && ln -s "$dst" "$src" && say "moved $rel/ (symlink left)"
}

say "== archive run (RUN=$RUN) dest=$DEST =="

for spec in "${FILE_SOURCES[@]}"; do
  dir="${spec%%|*}"; days="${FILE_DAYS:-${spec##*|}}"
  [[ -d "$dir" ]] || continue
  echo "-- files older than $days days in ${dir/#$HOME/~}"
  $FIND "$dir" -type f -mtime +$days -print0 | while IFS= read -r -d '' f; do move_file "$f"; done
  $FIND "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null
done

for spec in "${FOLDER_SOURCES[@]}"; do
  root="${spec%%|*}"; days="${FOLDER_DAYS:-${spec##*|}}"
  [[ -d "$root" ]] || continue
  echo "-- folders in ${root/#$HOME/~} with no small file touched in $days days"
  for d in "$root"/*(/N); do                       # real directories only; symlinks (already moved) are skipped
    [[ -d "$d/.git" ]] && continue                 # live repos stay
    [[ -n "${FOLDER_KEEP[(r)${d:t}]:-}" ]] && continue
    if [[ -z "$($FIND "$d" -type f -size -1024k -newermt "-$days days" -print -quit 2>/dev/null)" ]]; then
      move_dir "$d"
    fi
  done
done

after=$(df -k "$HOME" | awk 'NR==2{print $4}')
say "done. internal free: $(df -h "$HOME" | awk 'NR==2{print $4}') (freed $(( (after-before)/1024 )) MB)"
