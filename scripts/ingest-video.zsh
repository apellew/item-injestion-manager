#!/bin/zsh
# ingest-video.zsh
# ---------------------------------------------------------------------------
# Video ingestion child: scans <INGEST_ROOT>/ingest-video for .m4v files,
# validates them (H.265 + duration), classifies each as Movie or TV episode,
# and moves into a Jellyfin-style library layout under <LIBRARY_ROOT>/Movies
# and <LIBRARY_ROOT>/TV. Conflicts resolved by resolution (size tiebreak).
#
# Configuration is read from `scripts/.env` (sibling of this script). Copy
# `scripts/.env.template` to `scripts/.env` and fill in the paths before
# the first run.
#
# Called by the parent orchestrator (ingest.zsh) or standalone:
#   ingest-video.zsh [DEBUG]
# ---------------------------------------------------------------------------

emulate -L zsh
setopt PIPE_FAIL NO_UNSET EXTENDED_GLOB NULL_GLOB

# --- cron-safe PATH ---------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# --- locate and source the config file --------------------------------------
SCRIPT_DIR="${0:A:h}"
CONFIG_FILE="${SCRIPT_DIR}/.env"
TEMPLATE_FILE="${SCRIPT_DIR}/.env.template"

if [[ ! -f "$CONFIG_FILE" ]]; then
  print -u2 ""
  print -u2 "FATAL: configuration file not found at $CONFIG_FILE"
  print -u2 ""
  if [[ -f "$TEMPLATE_FILE" ]]; then
    print -u2 "A template is shipped at $TEMPLATE_FILE"
    print -u2 "Copy it and fill in your paths, then re-run this script:"
    print -u2 ""
    print -u2 "    cp '$TEMPLATE_FILE' '$CONFIG_FILE'"
    print -u2 "    \$EDITOR '$CONFIG_FILE'"
  else
    print -u2 "Create $CONFIG_FILE with at least the following content:"
    print -u2 ""
    print -u2 "    export INGEST_ROOT=\"/path/to/your/ingest\""
    print -u2 "    export LIBRARY_ROOT=\"/path/to/your/library\""
  fi
  print -u2 ""
  exit 78  # EX_CONFIG
fi

source "$CONFIG_FILE"

typeset -a _missing
for _var in INGEST_ROOT LIBRARY_ROOT; do
  if [[ -z "${(P)_var:-}" ]]; then
    _missing+=( "$_var" )
  fi
done
if (( ${#_missing[@]} > 0 )); then
  print -u2 "FATAL: required configuration key(s) not set in $CONFIG_FILE:"
  for _v in "${_missing[@]}"; do print -u2 "  - $_v"; done
  print -u2 ""
  print -u2 "See $TEMPLATE_FILE for documentation."
  exit 78
fi
unset _missing _var _v

INGEST_ROOT="${INGEST_ROOT:A}"
LIBRARY_ROOT="${LIBRARY_ROOT:A}"

# --- argument parsing -------------------------------------------------------
DEBUG=0
if (( $# == 1 )); then
  if [[ "${1:u}" == "DEBUG" ]]; then
    DEBUG=1
  else
    print -u2 "Usage: $0 [DEBUG]"
    exit 64
  fi
elif (( $# > 1 )); then
  print -u2 "Usage: $0 [DEBUG]"
  exit 64
fi

INGEST_DIR="${INGEST_ROOT}/ingest-video"
REJECTED_DIR="${INGEST_ROOT}/ingest-video_rejected"
MOVIES_DIR="${LIBRARY_ROOT}/Movies"
TV_DIR="${LIBRARY_ROOT}/TV"

MIN_DURATION_SECONDS=120      # 2 minutes (content validation)
EMPTY_DIR_MIN_AGE_MIN=60      # 1 hour
STABILITY_SLEEP_SECONDS=3     # gap between size samples for mid-copy check
MIN_FILE_AGE_SECONDS=30       # don't touch anything whose mtime is fresher than this
STALE_REJECT_AGE_SECONDS=86400  # 24h: after this, an unreadable file is deemed corrupt

# --- preflight --------------------------------------------------------------
for dep in ffprobe; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    print -u2 "FATAL: required dependency '$dep' not found in PATH"
    print -u2 "PATH=$PATH"
    exit 69
  fi
done

for d in "$INGEST_DIR" "$LIBRARY_ROOT"; do
  if [[ ! -d "$d" ]]; then
    print -u2 "FATAL: directory does not exist: $d"
    exit 66
  fi
done

# Ensure writable output scaffolding exists.
for d in "$REJECTED_DIR" "$MOVIES_DIR" "$TV_DIR"; do
  if [[ ! -d "$d" ]]; then
    if (( DEBUG )); then
      print -- "[DEBUG] would mkdir -p: $d"
    else
      mkdir -p -- "$d"
    fi
  fi
done

# --- logging helpers --------------------------------------------------------
log()   { print -- "[$(date '+%Y-%m-%d %H:%M:%S')] [video] $*"; }
debug() { (( DEBUG )) && print -- "[DEBUG] [video] $*"; }

# --- counters ---------------------------------------------------------------
typeset -i COPIED_COUNT=0
typeset -i REJECTED_COUNT=0
typeset -i SKIPPED_COUNT=0
typeset -i DELETED_COUNT=0

skip()  { (( SKIPPED_COUNT += 1 )); log "SKIP $*"; }

# Extensions to auto-delete from the ingest tree (lowercase, no dot).
typeset -aU AUTO_DELETE_EXTS=( jpg png log nfo )

log "starting"
log "  ingest     = $INGEST_DIR"
log "  rejected   = $REJECTED_DIR"
log "  movies     = $MOVIES_DIR"
log "  tv         = $TV_DIR"
log "  debug mode = $DEBUG"

# --- helpers ----------------------------------------------------------------

# Probe a value out of ffprobe, stream 0.
ffprobe_value() {
  local entry="$1" file="$2"
  ffprobe -v error -select_streams v:0 \
    -show_entries "stream=$entry" \
    -of default=noprint_wrappers=1:nokey=1 \
    -- "$file" 2>/dev/null
}

ffprobe_duration() {
  local file="$1"
  ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    -- "$file" 2>/dev/null
}

# Reject a file: move to ingest_rejected/<category> with a .log explaining why.
#
# Categories (used as subdirectory names under ingest_rejected):
#   lower_quality    – lost a conflict comparison against an existing file
#   wrong_type       – not an .m4v file
#   wrong_codec      – m4v but not HEVC/H.265
#   corrupt          – unreadable by ffprobe, zero-byte stale, bad duration
#   parse_error      – could not determine show/movie or missing required data
#   replaced         – existing file bumped out by higher-quality incoming file
reject_file() {
  local src="$1" category="$2" reason="$3"
  local base="${src:t}"
  local dest="${REJECTED_DIR}/${category}/${base}"
  # Avoid clobbering an existing rejected file with the same name.
  if [[ -e "$dest" ]]; then
    dest="${REJECTED_DIR}/${category}/${base:r}.$(date +%s).${base:e}"
  fi
  local logfile="${dest}.log"
  (( REJECTED_COUNT += 1 ))
  log "REJECT [${category}]: $src -> $dest ($reason)"
  if (( DEBUG )); then
    print -- "[DEBUG] would move: $src -> $dest"
    print -- "[DEBUG] would write log: $logfile"
    print -- "[DEBUG]   reason: $reason"
  else
    mkdir -p -- "${dest:h}"
    mv -- "$src" "$dest"
    {
      print -- "Rejected: $(date '+%Y-%m-%d %H:%M:%S')"
      print -- "Category: $category"
      print -- "Original path: $src"
      print -- "Reason: $reason"
    } > "$logfile"
  fi
}

# Delete a companion/cruft file outright (no rejection, no log file).
delete_file() {
  local src="$1" reason="$2"
  (( DELETED_COUNT += 1 ))
  log "DELETE: $src ($reason)"
  if (( DEBUG )); then
    print -- "[DEBUG] would rm: $src"
  else
    rm -f -- "$src"
  fi
}

# Move a file to its Jellyfin destination.
install_file() {
  local src="$1" dest="$2"
  (( COPIED_COUNT += 1 ))
  log "INSTALL: $src -> $dest"
  if (( DEBUG )); then
    print -- "[DEBUG] would mkdir -p: ${dest:h}"
    print -- "[DEBUG] would move: $src -> $dest"
  else
    mkdir -p -- "${dest:h}"
    mv -- "$src" "$dest"
  fi
}

# Parse TV episode info from a filename stem.
# Sets: TV_SHOW, TV_YEAR (may be empty), TV_SEASON, TV_EPISODE.
# Returns 0 if a SxxEyy / NxNN pattern was found, 1 otherwise.
parse_tv() {
  local stem="$1"
  TV_SHOW=""; TV_YEAR=""; TV_SEASON=""; TV_EPISODE=""

  local normalised="${stem//[._]/ }"
  local prefix=""

  if [[ "$normalised" =~ '(.*[^[:space:]])[[:space:]]+[Ss]([0-9]{1,2})[Ee]([0-9]{1,3})' ]]; then
    prefix="${match[1]}"
    TV_SEASON="${match[2]}"
    TV_EPISODE="${match[3]}"
  elif [[ "$normalised" =~ '(.*[^[:space:]])[[:space:]]+([0-9]{1,2})x([0-9]{1,3})([^0-9]|$)' ]]; then
    prefix="${match[1]}"
    TV_SEASON="${match[2]}"
    TV_EPISODE="${match[3]}"
  else
    return 1
  fi

  if [[ "$prefix" =~ '\(((19|20)[0-9]{2})\)' ]]; then
    TV_YEAR="${match[1]}"
    TV_SHOW="${prefix%%\(${TV_YEAR}\)*}"
  elif [[ "$prefix" =~ '[[:space:]]((19|20)[0-9]{2})([[:space:]]|$)' ]]; then
    TV_YEAR="${match[1]}"
    TV_SHOW="${prefix% ${TV_YEAR}*}"
  else
    TV_SHOW="$prefix"
  fi

  TV_SHOW="${TV_SHOW%%[[:space:]]##}"
  TV_SHOW="${TV_SHOW##[[:space:]]##}"
  TV_SHOW="${TV_SHOW%%[[:space:]]#-[[:space:]]#}"
  TV_SHOW="${TV_SHOW%%[[:space:]]##}"
  TV_SHOW="${TV_SHOW//[[:space:]][[:space:]]##/ }"

  TV_SEASON="$(printf '%02d' "$TV_SEASON")"
  TV_EPISODE="$(printf '%02d' "$TV_EPISODE")"

  [[ -n "$TV_SHOW" ]] || return 1
  return 0
}

# Normalise a show name for fuzzy comparison.
normalise_show_name() {
  local s="${1:l}"
  print -r -- "${s//[^a-z0-9]/}"
}

# Infer year from existing library directory.
infer_year_from_library() {
  local needle="$1"
  local nneedle
  nneedle="$(normalise_show_name "$needle")"
  MATCH_REASON=""
  MATCH_CANDIDATES=()

  if (( ${#nneedle} < 4 )); then
    MATCH_REASON="normalised show name '${nneedle}' too short (<4 chars) for safe matching"
    return 1
  fi

  typeset -a lib_bases lib_nbases
  local dir base nbase stripped
  for dir in "$TV_DIR"/*(/N); do
    base="${dir:t}"
    if [[ "$base" =~ '^(.*) \((19|20)[0-9]{2}\)$' ]]; then
      stripped="${match[1]}"
      nbase="$(normalise_show_name "$stripped")"
      lib_bases+=( "$base" )
      lib_nbases+=( "$nbase" )
    fi
  done

  typeset -a exact_hits
  local i
  for (( i = 1; i <= ${#lib_nbases[@]}; i++ )); do
    if [[ "${lib_nbases[i]}" == "$nneedle" ]]; then
      exact_hits+=( "${lib_bases[i]}" )
    fi
  done

  if (( ${#exact_hits[@]} == 1 )); then
    MATCH_CANDIDATES=( "${exact_hits[1]}" )
  elif (( ${#exact_hits[@]} > 1 )); then
    MATCH_REASON="ambiguous: multiple library directories exact-match '$needle': ${(j:, :)exact_hits}"
    return 1
  else
    typeset -a prefix_hits
    for (( i = 1; i <= ${#lib_nbases[@]}; i++ )); do
      nbase="${lib_nbases[i]}"
      if [[ "$nbase" == "$nneedle"* || "$nneedle" == "$nbase"* ]]; then
        prefix_hits+=( "${lib_bases[i]}" )
      fi
    done

    if (( ${#prefix_hits[@]} == 0 )); then
      MATCH_REASON="no existing library directory matches show name '$needle'"
      return 1
    fi
    if (( ${#prefix_hits[@]} > 1 )); then
      MATCH_REASON="ambiguous: multiple library directories prefix-match '$needle': ${(j:, :)prefix_hits}"
      return 1
    fi
    MATCH_CANDIDATES=( "${prefix_hits[1]}" )
  fi

  local hit="${MATCH_CANDIDATES[1]}"
  if [[ "$hit" =~ '^(.*) \(((19|20)[0-9]{2})\)$' ]]; then
    TV_SHOW="${match[1]}"
    TV_YEAR="${match[2]}"
    return 0
  fi
  MATCH_REASON="internal: failed to re-parse matched dir '$hit'"
  return 1
}

# Parse movie title + year from filename stem.
parse_movie() {
  local stem="$1"
  MOVIE_TITLE=""; MOVIE_YEAR=""

  local normalised="${stem//[._]/ }"

  local title="" year=""
  if [[ "$normalised" =~ '\(((19|20)[0-9]{2})\)' ]]; then
    year="${match[1]}"
    title="${normalised%%\(${year}\)*}"
  elif [[ "$normalised" =~ '[[:space:]]((19|20)[0-9]{2})([[:space:]]|$)' ]]; then
    year="${match[1]}"
    title="${normalised% ${year}*}"
  else
    title="$normalised"
  fi

  title="${title%%[[:space:]]##}"
  title="${title##[[:space:]]##}"
  title="${title%%[[:space:]]#-[[:space:]]#}"
  title="${title//[[:space:]][[:space:]]##/ }"

  MOVIE_TITLE="$title"
  MOVIE_YEAR="$year"
}

# Get a file's age in seconds (now - mtime).
file_age_seconds() {
  local f="$1"
  local mt
  mt="$(zstat -L +mtime -- "$f" 2>/dev/null)" || mt=""
  if [[ -z "$mt" ]]; then
    mt="$(stat -f %m -- "$f" 2>/dev/null)" || mt="0"
  fi
  local now
  now="$(date +%s)"
  print -- $(( now - mt ))
}

# Get a file's size in bytes.
file_size() {
  local f="$1"
  local s
  s="$(zstat -L +size -- "$f" 2>/dev/null)" || s=""
  if [[ -z "$s" ]]; then
    s="$(stat -f %z -- "$f" 2>/dev/null)" || s=""
  fi
  print -- "${s:-0}"
}

# Returns 0 if the file appears to be mid-copy, 1 if stable.
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

# Decide winner between two files based on height, then size.
compare_files() {
  local new="$1" existing="$2"
  local nh eh ns es
  nh="$(ffprobe_value height "$new")"; nh="${nh:-0}"
  eh="$(ffprobe_value height "$existing")"; eh="${eh:-0}"
  ns="$(zstat -L +size -- "$new" 2>/dev/null || stat -f %z -- "$new" 2>/dev/null || echo 0)"
  es="$(zstat -L +size -- "$existing" 2>/dev/null || stat -f %z -- "$existing" 2>/dev/null || echo 0)"
  debug "compare: new  height=$nh size=$ns  ($new)"
  debug "compare: old  height=$eh size=$es  ($existing)"
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

# --- main processing --------------------------------------------------------

# Load zstat for file sizes.
zmodload -F zsh/stat b:zstat 2>/dev/null || true

# First pass: handle non-m4v files.
typeset -a strays
strays=( "$INGEST_DIR"/**/*(.N) )
for f in "${strays[@]}"; do
  local ext="${f:e:l}"
  if [[ "$ext" == "m4v" ]]; then
    continue
  fi
  if is_file_in_use "$f"; then
    skip "(in use): $f ($IN_USE_REASON)"
    continue
  fi
  if (( ${AUTO_DELETE_EXTS[(Ie)$ext]} )); then
    delete_file "$f" "auto-delete .${ext}"
    continue
  fi
  reject_file "$f" "wrong_type" "expected .m4v, got .${ext:-<none>}"
done

# Find candidate m4v files (case-insensitive), recursive.
typeset -a candidates
candidates=( "$INGEST_DIR"/**/*.(#i)m4v(.N) )

log "found ${#candidates[@]} candidate file(s)"

for file in "${candidates[@]}"; do
  log "---"
  log "processing: $file"

  if is_file_in_use "$file"; then
    skip "(in use): $file ($IN_USE_REASON)"
    continue
  fi

  local age
  age="$(file_age_seconds "$file")"
  debug "file age = ${age}s"

  if (( age < MIN_FILE_AGE_SECONDS )); then
    skip "(too fresh): $file (mtime ${age}s ago, settle window ${MIN_FILE_AGE_SECONDS}s)"
    continue
  fi

  local sz
  sz="$(file_size "$file")"
  debug "size = ${sz} bytes"
  if (( sz == 0 )); then
    if (( age >= STALE_REJECT_AGE_SECONDS )); then
      reject_file "$file" "corrupt" "zero-byte file older than ${STALE_REJECT_AGE_SECONDS}s (abandoned stub)"
    else
      skip "(zero-byte stub): $file (likely queued for copy)"
    fi
    continue
  fi

  local codec
  codec="$(ffprobe_value codec_name "$file")"
  debug "codec_name = '$codec'"
  if [[ -z "$codec" ]]; then
    if (( age >= STALE_REJECT_AGE_SECONDS )); then
      reject_file "$file" "corrupt" "unreadable by ffprobe and older than ${STALE_REJECT_AGE_SECONDS}s"
    else
      skip "(unreadable, ${age}s old): $file (likely still copying)"
    fi
    continue
  fi
  if [[ "$codec" != "hevc" && "$codec" != "h265" ]]; then
    reject_file "$file" "wrong_codec" "video codec is '$codec', expected HEVC/H.265"
    continue
  fi

  local dur
  dur="$(ffprobe_duration "$file")"
  debug "duration = '$dur'"
  if [[ -z "$dur" || "$dur" == "N/A" ]]; then
    if (( age >= STALE_REJECT_AGE_SECONDS )); then
      reject_file "$file" "corrupt" "no duration from ffprobe and older than ${STALE_REJECT_AGE_SECONDS}s"
    else
      skip "(no duration, ${age}s old): $file (likely still copying)"
    fi
    continue
  fi
  local dur_int="${dur%%.*}"
  if ! [[ "$dur_int" =~ '^[0-9]+$' ]]; then
    reject_file "$file" "corrupt" "duration not numeric: '$dur'"
    continue
  fi
  if (( dur_int < MIN_DURATION_SECONDS )); then
    reject_file "$file" "corrupt" "duration ${dur_int}s is below minimum ${MIN_DURATION_SECONDS}s (likely stub)"
    continue
  fi

  # --- classify: TV or Movie -----------------------------------------------
  local stem="${file:t:r}"
  local dest=""

  local tv_rc=0
  parse_tv "$stem" || tv_rc=$?
  if (( tv_rc == 0 )); then
    log "parsed TV: show='$TV_SHOW' year='${TV_YEAR:-<missing>}' season=$TV_SEASON episode=$TV_EPISODE"

    if [[ -z "$TV_YEAR" ]]; then
      log "no year in filename; attempting to infer from existing library at $TV_DIR"
      local inferred_rc=0
      infer_year_from_library "$TV_SHOW" || inferred_rc=$?
      if (( inferred_rc != 0 )); then
        reject_file "$file" "parse_error" "TV '$TV_SHOW' S${TV_SEASON}E${TV_EPISODE}: year missing and ${MATCH_REASON}"
        continue
      fi
      log "inferred year from library: show='$TV_SHOW' year=$TV_YEAR"
    fi

    local show_folder="${TV_SHOW} (${TV_YEAR})"
    dest="${TV_DIR}/${show_folder}/Season ${TV_SEASON}/${show_folder} - S${TV_SEASON}E${TV_EPISODE}.m4v"
    log "classified as TV: show='$TV_SHOW' year=$TV_YEAR season=$TV_SEASON episode=$TV_EPISODE"
  else
    parse_movie "$stem"
    if [[ -z "$MOVIE_TITLE" ]]; then
      reject_file "$file" "parse_error" "could not parse a movie title from filename"
      continue
    fi
    local folder=""
    if [[ -n "$MOVIE_YEAR" ]]; then
      folder="${MOVIE_TITLE} (${MOVIE_YEAR})"
    else
      folder="${MOVIE_TITLE}"
    fi
    dest="${MOVIES_DIR}/${folder}/${folder}.m4v"
    log "classified as Movie: title='$MOVIE_TITLE' year='${MOVIE_YEAR:-none}'"
  fi

  debug "proposed destination: $dest"

  # --- conflict resolution --------------------------------------------------
  if [[ -e "$dest" ]]; then
    log "conflict: destination already exists: $dest"
    local winner
    winner="$(compare_files "$file" "$dest")"
    if [[ "$winner" == "new" ]]; then
      log "new file wins; replacing existing"
      reject_file "$dest" "replaced" "replaced by higher-quality incoming file: ${file:t}"
      install_file "$file" "$dest"
    else
      log "existing file wins; rejecting incoming"
      reject_file "$file" "lower_quality" "lower or equal quality than existing: $dest"
    fi
  else
    install_file "$file" "$dest"
  fi
done

# --- cleanup: remove empty folders in ingest older than 1h ------------------
log "---"
log "cleaning empty directories older than ${EMPTY_DIR_MIN_AGE_MIN} minutes"

if command -v find >/dev/null 2>&1; then
  find "$INGEST_DIR" -mindepth 1 -depth -type d -empty -mmin +${EMPTY_DIR_MIN_AGE_MIN} -print 2>/dev/null | \
    while IFS= read -r emptydir; do
      if (( DEBUG )); then
        print -- "[DEBUG] would rmdir: $emptydir"
      else
        rmdir -- "$emptydir" 2>/dev/null && log "removed empty dir: $emptydir"
      fi
    done
fi

log "---"
log "summary: copied=${COPIED_COUNT}  rejected=${REJECTED_COUNT}  skipped=${SKIPPED_COUNT}  deleted=${DELETED_COUNT}"
log "finished"
exit 0
