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
#     documented globals (e.g. IN_USE_REASON) and writing to stdout
#     via the caller-provided log()/debug() functions.
#   - Functions MUST work under `setopt NO_UNSET` — use `${var:-}` for
#     anything that might be missing.
#   - Functions DO NOT bump caller-side counters (COPIED_COUNT etc.) —
#     callers do that themselves based on the return value.
#   - Functions assume the caller has defined `log()` and `debug()`
#     and `DEBUG` as appropriate.
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

# Format a byte count as a human-readable size (e.g. "2.4 GiB").
# Echoes "?" for empty, missing, or non-numeric input.
human_size() {
  local b="${1:-}"
  if ! [[ "$b" =~ '^[0-9]+$' ]]; then
    print -- "?"
    return
  fi
  if   (( b >= 1073741824 )); then printf '%.1f GiB' "$(( b / 1073741824.0 ))"
  elif (( b >= 1048576    )); then printf '%.1f MiB' "$(( b / 1048576.0 ))"
  elif (( b >= 1024       )); then printf '%.1f KiB' "$(( b / 1024.0 ))"
  else                              printf '%d B' "$b"
  fi
}

# Format a duration in seconds (may be a float) as HH:MM:SS.
# Echoes "?" for empty or non-numeric input.
human_duration() {
  local d="${1:-}"
  d="${d%%.*}"
  if ! [[ "$d" =~ '^[0-9]+$' ]]; then
    print -- "?"
    return
  fi
  printf '%02d:%02d:%02d' $(( d / 3600 )) $(( (d % 3600) / 60 )) $(( d % 60 ))
}

# Log a side-by-side comparison table for two video files (existing vs
# incoming). Used by the TV and Movie children after a duplicate-verdict
# log line, so the log makes it obvious why one file beat the other.
# Probes resolution (WxH), duration (HH:MM:SS), and file size for each
# file. Missing or unreadable values render as "?".
# Uses the caller's log() function for prefix/timestamp consistency.
log_compare_table() {
  local existing="$1" incoming="$2"
  local ew eh ed es iw ih id is
  ew="$(ffprobe_value width  "$existing")"; ew="${ew:-?}"
  eh="$(ffprobe_value height "$existing")"; eh="${eh:-?}"
  ed="$(ffprobe_duration     "$existing")"
  es="$(file_size            "$existing")"
  iw="$(ffprobe_value width  "$incoming")"; iw="${iw:-?}"
  ih="$(ffprobe_value height "$incoming")"; ih="${ih:-?}"
  id="$(ffprobe_duration     "$incoming")"
  is="$(file_size            "$incoming")"

  local e_res i_res
  if [[ "$ew" == "?" || "$eh" == "?" ]]; then e_res="?"; else e_res="${ew}x${eh}"; fi
  if [[ "$iw" == "?" || "$ih" == "?" ]]; then i_res="?"; else i_res="${iw}x${ih}"; fi

  local e_dur i_dur e_sz i_sz
  e_dur="$(human_duration "$ed")"
  i_dur="$(human_duration "$id")"
  e_sz="$(human_size "$es")"
  i_sz="$(human_size "$is")"

  log "  comparison:"
  log "$(printf '    %-12s %-18s %s' 'attribute'  'existing' 'incoming')"
  log "$(printf '    %-12s %-18s %s' 'resolution' "$e_res"   "$i_res")"
  log "$(printf '    %-12s %-18s %s' 'duration'   "$e_dur"   "$i_dur")"
  log "$(printf '    %-12s %-18s %s' 'size'       "$e_sz"    "$i_sz")"
}

# --- staged install pattern -----------------------------------------------
# These two helpers implement the "copy to staging, then atomically move
# to live" pattern. The staging directory must be on the same filesystem
# as the live destination so the final mv is a true rename, not a slow
# cp+rm. Children that use this pattern derive their staging dir as a
# sibling of the live dir with a " zzz" suffix.
#
# The pattern protects against media servers that auto-watch the live
# library — those tools never see a half-copied file because the file
# only appears in the live dir as a complete unit.
#
# Both helpers are DEBUG-aware (logging "would …" lines and skipping
# actual filesystem writes) and assume the caller has defined log() and
# debug() and DEBUG.
# --------------------------------------------------------------------------

# Copy a source file to a staging path with size verification.
# Returns 0 on success (real or dry-run), 1 on failure.
# Resume-aware: if the staging path already exists and its size matches
# the source, no copy is performed.
stage_file() {
  local src="$1" dst="$2" rel_label="$3"

  if [[ -e "$dst" ]]; then
    local src_sz="$(file_size "$src")"
    local dst_sz="$(file_size "$dst")"
    if [[ "$src_sz" == "$dst_sz" ]]; then
      debug "staged from prior run (size matches): $rel_label"
      return 0
    fi
    log "  staging size mismatch ($dst_sz vs $src_sz), recopying: $rel_label"
    if (( DEBUG )); then
      print -- "[DEBUG] would rm partial: $dst"
    else
      rm -f -- "$dst"
    fi
  fi

  log "  COPY: $rel_label"
  if (( DEBUG )); then
    print -- "[DEBUG] would mkdir -p: ${dst:h}"
    print -- "[DEBUG] would cp: $src -> $dst"
    return 0
  fi

  mkdir -p -- "${dst:h}"
  if ! cp -- "$src" "$dst"; then
    log "ERROR: copy failed: $src -> $dst"
    rm -f -- "$dst"
    return 1
  fi
  local src_sz="$(file_size "$src")"
  local dst_sz="$(file_size "$dst")"
  if [[ "$src_sz" != "$dst_sz" ]]; then
    log "ERROR: post-copy size mismatch ($dst_sz != $src_sz): $dst"
    rm -f -- "$dst"
    return 1
  fi
  return 0
}

# Move a staged file into its live destination. Refuses to overwrite an
# existing live file (the caller is expected to have displaced the
# previous live version via a rejection-replace first).
# Returns 0 on success, 1 on failure.
merge_file() {
  local staged="$1" live="$2" rel_label="$3"

  if (( DEBUG )); then
    print -- "[DEBUG] would mkdir -p: ${live:h}"
    print -- "[DEBUG] would mv: $staged -> $live"
    return 0
  fi

  if [[ ! -e "$staged" ]]; then
    log "  ERROR: staged file missing at merge time: $staged"
    return 1
  fi
  if [[ -e "$live" ]]; then
    log "  WARN: live already has file, leaving in staging: $rel_label"
    return 1
  fi

  mkdir -p -- "${live:h}"
  log "  MERGE: $rel_label"
  mv -- "$staged" "$live"
  return 0
}
