#!/bin/zsh
# ingest-movie.zsh
# ---------------------------------------------------------------------------
# Movie ingestion child: scans <INGEST_ROOT>/ingest-movie for .m4v files,
# validates them (H.265 + duration), parses movie title + year from the
# filename, and moves them into a Jellyfin-style library layout under
# JELLYFIN_MOVIES_DIR/Title (Year)/Title (Year).m4v. Conflicts resolved
# by resolution (size tiebreak).
#
# Configuration is read from `scripts/.env` (sibling of this script). Copy
# `scripts/.env.template` to `scripts/.env` and fill in the paths before
# the first run. Shared helpers are sourced from `scripts/_lib.zsh`.
#
# Required .env keys: INGEST_ROOT, JELLYFIN_MOVIES_DIR.
#
# Filename patterns recognised:
#   - "Title (YYYY).m4v"           — year in parens (preferred)
#   - "Title YYYY.m4v"             — year as trailing word
#   - "Title.m4v" (no year)        — accepted; folder is "Title" (no year)
#
# Called by the parent orchestrator (ingest.zsh) or standalone:
#   ingest-movie.zsh [DEBUG]
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
LIB_FILE="${SCRIPT_DIR}/_lib.zsh"

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
    print -u2 "    export JELLYFIN_MOVIES_DIR=\"/path/to/your/jellyfin/Movies\""
  fi
  print -u2 ""
  exit 78  # EX_CONFIG
fi

source "$CONFIG_FILE"

typeset -a _missing
for _var in INGEST_ROOT JELLYFIN_MOVIES_DIR; do
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
JELLYFIN_MOVIES_DIR="${JELLYFIN_MOVIES_DIR:A}"

# --- load shared helpers ---------------------------------------------------
if [[ ! -f "$LIB_FILE" ]]; then
  print -u2 "FATAL: shared helper library not found: $LIB_FILE"
  exit 70
fi
source "$LIB_FILE"

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

INGEST_DIR="${INGEST_ROOT}/ingest-movie"
REJECTED_DIR="${INGEST_ROOT}/ingest-movie_rejected"
MOVIES_DIR="$JELLYFIN_MOVIES_DIR"

MIN_DURATION_SECONDS=120
EMPTY_DIR_MIN_AGE_MIN=60
MIN_FILE_AGE_SECONDS=30
STALE_REJECT_AGE_SECONDS=86400

# --- preflight --------------------------------------------------------------
for dep in ffprobe; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    print -u2 "FATAL: required dependency '$dep' not found in PATH"
    print -u2 "PATH=$PATH"
    exit 69
  fi
done

if [[ ! -d "$INGEST_DIR" ]]; then
  print -u2 "FATAL: directory does not exist: $INGEST_DIR"
  exit 66
fi

if [[ ! -d "${MOVIES_DIR:h}" ]]; then
  print -u2 "FATAL: parent directory of JELLYFIN_MOVIES_DIR does not exist: ${MOVIES_DIR:h}"
  print -u2 "       (JELLYFIN_MOVIES_DIR=$MOVIES_DIR)"
  exit 66
fi

for d in "$REJECTED_DIR" "$MOVIES_DIR"; do
  if [[ ! -d "$d" ]]; then
    if (( DEBUG )); then
      print -- "[DEBUG] would mkdir -p: $d"
    else
      mkdir -p -- "$d"
    fi
  fi
done

# --- logging helpers --------------------------------------------------------
log()   { print -- "[$(date '+%Y-%m-%d %H:%M:%S')] [movie] $*"; }
debug() { (( DEBUG )) && print -- "[DEBUG] [movie] $*"; }

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
log "  debug mode = $DEBUG"

# --- script-local helpers --------------------------------------------------

# Reject categories used as subdirectory names under REJECTED_DIR:
#   lower_quality    – lost a conflict comparison against an existing file
#   wrong_type       – not an .m4v file
#   wrong_codec      – m4v but not HEVC/H.265
#   corrupt          – unreadable by ffprobe, zero-byte stale, bad duration
#   parse_error      – could not parse a movie title from the filename
#   replaced         – existing file bumped out by higher-quality incoming file
reject_file() {
  local src="$1" category="$2" reason="$3"
  local base="${src:t}"
  local dest="${REJECTED_DIR}/${category}/${base}"
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

# Parse movie title + year from filename stem.
# Sets: MOVIE_TITLE, MOVIE_YEAR (may be empty).
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

# --- main processing --------------------------------------------------------

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
  if [[ -z "$dur" ]]; then
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

  # --- classify: Movie -----------------------------------------------------
  local stem="${file:t:r}"

  parse_movie "$stem"
  if [[ -z "$MOVIE_TITLE" ]]; then
    reject_file "$file" "parse_error" "could not parse a movie title from filename"
    continue
  fi

  local folder
  if [[ -n "$MOVIE_YEAR" ]]; then
    folder="${MOVIE_TITLE} (${MOVIE_YEAR})"
  else
    folder="${MOVIE_TITLE}"
  fi
  local dest="${MOVIES_DIR}/${folder}/${folder}.m4v"
  log "classified as Movie: title='$MOVIE_TITLE' year='${MOVIE_YEAR:-none}'"

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
