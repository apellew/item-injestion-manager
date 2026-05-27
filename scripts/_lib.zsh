# scripts/_lib.zsh
# ---------------------------------------------------------------------------
# Shared helper library for the ingest-*.zsh child scripts.
#
# This file is NOT a child script — it starts with an underscore so the
# orchestrator's `ingest-*.zsh` glob won't pick it up. Children source it
# after loading their .env, so the helpers can see the configured
# variables if needed (none currently do, but the option is there).
#
# Conventions:
#   - Functions here MUST be side-effect-free apart from setting their
#     documented globals (e.g. IN_USE_REASON).
#   - Functions MUST work under `setopt NO_UNSET` — use `${var:-}` for
#     anything that might be missing.
#   - Constants exported here are picked up by each child via sourcing.
# ---------------------------------------------------------------------------

# How long to sleep between two file-size samples when checking whether
# a file is currently being written to. Used by is_file_in_use.
STABILITY_SLEEP_SECONDS=3

# Load zsh/stat once so the children don't each have to. Falls back to
# BSD `stat -f` (macOS) inside the helpers if the module isn't available.
zmodload -F zsh/stat b:zstat 2>/dev/null || true

# --- file stat helpers -----------------------------------------------------

# Get a file's size in bytes. Echoes "0" if the file is missing or
# unreadable.
file_size() {
  local f="$1" s
  s="$(zstat -L +size -- "$f" 2>/dev/null)" || s=""
  if [[ -z "$s" ]]; then
    s="$(stat -f %z -- "$f" 2>/dev/null)" || s=""
  fi
  print -- "${s:-0}"
}

# Get a file's age in seconds (now - mtime). Echoes the difference,
# which may be negative if the system clock skews.
file_age_seconds() {
  local f="$1" mt now
  mt="$(zstat -L +mtime -- "$f" 2>/dev/null)" || mt=""
  if [[ -z "$mt" ]]; then
    mt="$(stat -f %m -- "$f" 2>/dev/null)" || mt="0"
  fi
  now="$(date +%s)"
  print -- $(( now - mt ))
}

# --- mid-copy detection ----------------------------------------------------

# Returns 0 if the file looks mid-copy, 1 if it appears stable.
# Sets IN_USE_REASON to a human-readable explanation on detection.
#
# Heuristics, in order:
#   1. Temp-file extension on the file itself.
#   2. Sibling temp file present (e.g. foo.m4v.part).
#   3. lsof reports an open write handle (if lsof is available).
#   4. Size changes across a STABILITY_SLEEP_SECONDS-second sample.
is_file_in_use() {
  local f="$1"
  IN_USE_REASON=""

  local ext="${f:e:l}"
  case "$ext" in
    part|crdownload|download|!ut|tmp|partial)
      IN_USE_REASON="has temp-file extension (.$ext)"
      return 0
      ;;
  esac
  local sibling
  for sibling in "${f}.part" "${f}.crdownload" "${f}.!ut" "${f}.download" "${f}.tmp"; do
    if [[ -e "$sibling" ]]; then
      IN_USE_REASON="sibling temp file exists: ${sibling:t}"
      return 0
    fi
  done

  if command -v lsof >/dev/null 2>&1; then
    local lsof_out
    lsof_out="$(lsof -Fft -- "$f" 2>/dev/null || true)"
    if print -r -- "$lsof_out" | awk '/^f.*[wu]$/{ found=1 } END{ exit !found }'; then
      IN_USE_REASON="open for write by another process (lsof)"
      return 0
    fi
  fi

  local s1 s2
  s1="$(file_size "$f")"
  sleep "$STABILITY_SLEEP_SECONDS"
  s2="$(file_size "$f")"
  if [[ "$s1" != "$s2" ]]; then
    IN_USE_REASON="size changed during ${STABILITY_SLEEP_SECONDS}s sample ($s1 -> $s2 bytes)"
    return 0
  fi

  return 1
}

# --- ffprobe wrappers ------------------------------------------------------

# Probe a value out of ffprobe, video stream 0. Used for things like
# codec_name, height, width. Echoes empty string on failure.
ffprobe_value() {
  local entry="$1" file="$2"
  ffprobe -v error -select_streams v:0 \
    -show_entries "stream=$entry" \
    -of default=noprint_wrappers=1:nokey=1 \
    -- "$file" 2>/dev/null
}

# Get a file's duration in seconds (may be a float). Normalises "N/A"
# to empty string, so callers can use `[[ -z "$dur" ]]` consistently.
ffprobe_duration() {
  local file="$1" d
  d="$(ffprobe -v error -show_entries format=duration \
       -of default=noprint_wrappers=1:nokey=1 \
       -- "$file" 2>/dev/null)"
  [[ "$d" == "N/A" ]] && d=""
  print -- "$d"
}

# --- video-quality comparison ----------------------------------------------

# Decide a winner between two video files based on height, with file
# size as the tiebreaker. Echoes either "new" or "existing".
# Used by the TV and Movie children for conflict resolution; the
# audiobook child has its own bitrate-based comparator and doesn't
# call this.
compare_files() {
  local new="$1" existing="$2"
  local nh eh ns es
  nh="$(ffprobe_value height "$new")"; nh="${nh:-0}"
  eh="$(ffprobe_value height "$existing")"; eh="${eh:-0}"
  ns="$(zstat -L +size -- "$new" 2>/dev/null || stat -f %z -- "$new" 2>/dev/null || echo 0)"
  es="$(zstat -L +size -- "$existing" 2>/dev/null || stat -f %z -- "$existing" 2>/dev/null || echo 0)"
  if (( nh > eh )); then
    print new
  elif (( nh < eh )); then
    print existing
  elif (( ns > es )); then
    print new
  else
    print existing
  fi
}
