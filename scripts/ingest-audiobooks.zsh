#!/bin/zsh
# ingest-audiobooks.zsh
# ---------------------------------------------------------------------------
# Audiobook ingestion child: scans <INGEST_ROOT>/ingest-audiobooks for
# Author/Book/ directories. A book directory must contain:
#     metadata.json + cover.jpg + one-or-more .mp3 files (at the root)
# Single-file and multi-file books are both supported.
#
# Configuration is read from `scripts/.env` (sibling of this script). Copy
# `scripts/.env.template` to `scripts/.env` and fill in the paths before
# the first run. Shared helpers are sourced from `scripts/_lib.zsh`.
#
# Required .env keys:
#   INGEST_ROOT, ABS_LIBRARY_DIR,
#   ABS_PARSE_REGEX, ABS_NAME_TEMPLATE.
# All paths are absolute; no fallbacks or derived defaults.
#
# Destination flow per book directory:
#   1. Source book dir: <INGEST_ROOT>/ingest-audiobooks/<rel> where <rel>
#      is the relative path (typically "Author/Book").
#   2. <rel> is matched against ABS_PARSE_REGEX. No match -> parse_error.
#   3. ABS_NAME_TEMPLATE is expanded (%NAME% replaced with captures).
#   4. Live destination: <ABS_LIBRARY_DIR>/<expanded>/
#      Staging:          <ABS_LIBRARY_DIR> zzz/<expanded>/
#   5. Individual mp3 filenames within the book are preserved verbatim.
#
# Pipeline per book:
#   1. validate     (audio type, author dir naming, required files, mp3 count)
#   2. classify     (per-mp3 vs LIVE: new / winner / loser via ffprobe)
#   3. install      (cp source -> staging, mv staging -> LIVE)
#   4. metadata     (if any mp3 installed, refresh cover.jpg + metadata.json)
#
# Why staging? AudioBookShelf scans aggressively. Copying directly into the
# live library risks it picking up half-copied files. Files are copied into
# a sibling "<LIVE_DIR> zzz" directory (which ABS does not watch); once on
# disk, they are moved into LIVE_DIR via fast same-fs renames. The "zzz"
# suffix sorts the staging dir to the bottom in file managers.
#
# Per-mp3 conflict resolution (matched by filename):
#   no LIVE counterpart                                  ->  install fresh
#   new bitrate > existing AND |duration delta| <= 5%   ->  new wins:
#       existing LIVE mp3 -> rejected/replaced/Author/Book/<file>
#       new mp3 installs into LIVE
#   otherwise                                            ->  existing wins:
#       new mp3 -> rejected/lower_quality/Author/Book/<file>
#
# Metadata coupling: if at least one mp3 is installed (new or replacement),
# cover.jpg and metadata.json are always installed too — any existing LIVE
# versions move to rejected/replaced/. This keeps audio + metadata coherent.
#
# Whole-book lower_quality: if every source mp3 loses against LIVE (i.e.
# nothing would be installed), the whole source book moves to
# rejected/lower_quality/Author/Book/ in one piece, instead of fragmenting
# the rejection across many per-mp3 logs.
#
# Reject categories:
#   wrong_type      – non-mp3 audio file present
#   parse_error     – bad author name, missing required files, no mp3
#   replaced        – existing file bumped out by higher-quality incoming
#                     (per-file for mp3s; whole-book metadata refresh too)
#   lower_quality   – incoming file/book lost the comparison
#
# Layout expected:
#   <INGEST_ROOT>/ingest-audiobooks/<Author>/<Book>/{*.mp3, cover.jpg, metadata.json}
#
# Output:
#   <ABS_LIBRARY_DIR>/<Author>/<Book>/...        (live library)
#   <ABS_LIBRARY_DIR> zzz/<Author>/<Book>/...    (staging — sibling of LIVE_DIR)
#   <INGEST_ROOT>/ingest-audiobooks_rejected/<category>/<Author>/<Book>/*
#
# Usage:
#   ingest-audiobooks.zsh [DEBUG]
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
PARSE_HELPER="${SCRIPT_DIR}/_parse_name.py"

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
    print -u2 "    export ABS_LIBRARY_DIR=\"/path/to/your/audiobookshelf/Audiobooks\""
    print -u2 "    export ABS_PARSE_REGEX='...'"
    print -u2 "    export ABS_NAME_TEMPLATE='...'"
  fi
  print -u2 ""
  exit 78  # EX_CONFIG
fi

source "$CONFIG_FILE"

typeset -a _missing
for _var in INGEST_ROOT ABS_LIBRARY_DIR ABS_PARSE_REGEX ABS_NAME_TEMPLATE; do
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
ABS_LIBRARY_DIR="${ABS_LIBRARY_DIR:A}"

# --- load shared helpers ---------------------------------------------------
if [[ ! -f "$LIB_FILE" ]]; then
  print -u2 "FATAL: shared helper library not found: $LIB_FILE"
  exit 70  # EX_SOFTWARE
fi
source "$LIB_FILE"

if [[ ! -f "$PARSE_HELPER" ]]; then
  print -u2 "FATAL: regex helper not found: $PARSE_HELPER"
  exit 70
fi

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

INGEST_DIR="${INGEST_ROOT}/ingest-audiobooks"
REJECTED_DIR="${INGEST_ROOT}/ingest-audiobooks_rejected"
# Audiobook library is whatever ABS_LIBRARY_DIR points at (required).
LIVE_DIR="$ABS_LIBRARY_DIR"
# Staging dir is always a sibling of LIVE_DIR with a " zzz" suffix —
# same filesystem is required so the final mv into LIVE_DIR is atomic.
COPY_DIR="${LIVE_DIR%/} zzz"

# Audio extensions other than .mp3 that disqualify a book (wrong_type).
typeset -aU NON_MP3_AUDIO_EXTS=( m4a m4b mp4 flac wav ogg oga aac wma opus alac ape dsf dff aiff aif )

# Required files at the root of every Book/ directory (parse_error if missing).
typeset -aU REQUIRED_BOOK_FILES=( metadata.json cover.jpg )

DURATION_TOLERANCE_PCT=5        # max duration delta to allow a replace
MIN_FILE_AGE_SECONDS=30         # don't touch anything fresher than this
EMPTY_DIR_MIN_AGE_MIN=60        # 1 hour: cleanup of empty dirs

# --- preflight --------------------------------------------------------------
for dep in ffprobe python3; do
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

# Parent of LIVE_DIR must exist — we'll mkdir LIVE_DIR itself, but won't
# silently create an arbitrary nested tree at a path the user might have
# typo'd in ABS_LIBRARY_DIR.
if [[ ! -d "${LIVE_DIR:h}" ]]; then
  print -u2 "FATAL: parent directory of ABS_LIBRARY_DIR does not exist: ${LIVE_DIR:h}"
  print -u2 "       (ABS_LIBRARY_DIR=$ABS_LIBRARY_DIR)"
  exit 66
fi

for d in "$REJECTED_DIR" "$LIVE_DIR" "$COPY_DIR"; do
  if [[ ! -d "$d" ]]; then
    if (( DEBUG )); then
      print -- "[DEBUG] would mkdir -p: $d"
    else
      mkdir -p -- "$d"
    fi
  fi
done

# --- logging helpers --------------------------------------------------------
log()   { print -- "[$(date '+%Y-%m-%d %H:%M:%S')] [audiobooks] $*"; }
debug() { (( DEBUG )) && print -- "[DEBUG] [audiobooks] $*"; }

# --- counters ---------------------------------------------------------------
typeset -i COPIED_COUNT=0
typeset -i MERGED_COUNT=0
typeset -i REJECTED_COUNT=0
typeset -i REPLACED_COUNT=0
typeset -i SKIPPED_COUNT=0
typeset -i BOOKS_PROCESSED=0

skip() { (( SKIPPED_COUNT += 1 )); log "SKIP $*"; }

log "starting"
log "  source     = $INGEST_DIR"
log "  rejected   = $REJECTED_DIR"
log "  live       = $LIVE_DIR"
log "  staging    = $COPY_DIR"
log "  debug mode = $DEBUG"

# --- audiobook-specific helpers --------------------------------------------
# (Generic helpers — file_size, file_age_seconds, is_file_in_use,
# ffprobe_value, ffprobe_duration — are provided by _lib.zsh.)

# Author dir name has 2+ consecutive single-uppercase tokens? (J K Rowling)
author_has_bad_initials() {
  local name="$1"
  typeset -a tokens=( ${=name} )
  local t consecutive=0
  for t in "${tokens[@]}"; do
    if [[ "$t" =~ '^[[:upper:]]$' ]]; then
      (( consecutive += 1 ))
      if (( consecutive >= 2 )); then
        return 0
      fi
    else
      consecutive=0
    fi
  done
  return 1
}

# Audio bitrate (bps). Echoes "0" on failure. Tries stream first then format
# (the stream value is missing for some VBR mp3s).
ffprobe_bitrate() {
  local f="$1" br
  br="$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 -- "$f" 2>/dev/null)"
  if [[ -z "$br" || "$br" == "N/A" ]]; then
    br="$(ffprobe -v error -show_entries format=bit_rate \
          -of default=noprint_wrappers=1:nokey=1 -- "$f" 2>/dev/null)"
  fi
  [[ "$br" == "N/A" ]] && br=""
  print -- "${br:-0}"
}

# Compare two audio files (both must exist). Sets globals:
#   COMPARE_RESULT     "new_wins" | "existing_wins"
#   COMPARE_NOTE       short explanation
#   CMP_NEW_BITRATE / CMP_NEW_DURATION
#   CMP_OLD_BITRATE / CMP_OLD_DURATION
audiobook_compare_files() {
  local new="$1" existing="$2"
  COMPARE_RESULT=""
  COMPARE_NOTE=""
  CMP_NEW_BITRATE=""; CMP_NEW_DURATION=""
  CMP_OLD_BITRATE=""; CMP_OLD_DURATION=""

  CMP_NEW_BITRATE="$(ffprobe_bitrate "$new")"
  CMP_OLD_BITRATE="$(ffprobe_bitrate "$existing")"
  CMP_NEW_DURATION="$(ffprobe_duration "$new")"
  CMP_OLD_DURATION="$(ffprobe_duration "$existing")"

  local new_dur_int="${CMP_NEW_DURATION%%.*}"
  local old_dur_int="${CMP_OLD_DURATION%%.*}"
  [[ -z "$new_dur_int" ]] && new_dur_int=0
  [[ -z "$old_dur_int" ]] && old_dur_int=0

  if (( CMP_NEW_BITRATE <= 0 || CMP_OLD_BITRATE <= 0 || new_dur_int <= 0 || old_dur_int <= 0 )); then
    COMPARE_RESULT="existing_wins"
    COMPARE_NOTE="ffprobe could not read bitrate or duration cleanly; defaulting to existing wins"
    return 0
  fi

  local diff_pct
  if (( new_dur_int > old_dur_int )); then
    diff_pct=$(( (new_dur_int - old_dur_int) * 100 / old_dur_int ))
  else
    diff_pct=$(( (old_dur_int - new_dur_int) * 100 / old_dur_int ))
  fi

  if (( CMP_NEW_BITRATE > CMP_OLD_BITRATE )) && (( diff_pct <= DURATION_TOLERANCE_PCT )); then
    COMPARE_RESULT="new_wins"
    COMPARE_NOTE="new bitrate ${CMP_NEW_BITRATE} > existing ${CMP_OLD_BITRATE}; duration diff ${diff_pct}% (within ${DURATION_TOLERANCE_PCT}%)"
  else
    COMPARE_RESULT="existing_wins"
    if (( CMP_NEW_BITRATE <= CMP_OLD_BITRATE )); then
      COMPARE_NOTE="new bitrate ${CMP_NEW_BITRATE} not greater than existing ${CMP_OLD_BITRATE} (duration diff ${diff_pct}%)"
    else
      COMPARE_NOTE="duration diff ${diff_pct}% exceeds ${DURATION_TOLERANCE_PCT}% threshold (bitrate ${CMP_NEW_BITRATE} vs ${CMP_OLD_BITRATE})"
    fi
  fi
  return 0
}

# Build the human-readable comparison block for inclusion in a rejection log.
# Reads CMP_* globals (caller must have just run audiobook_compare_files).
format_compare_block() {
  local source_mp3="$1" live_mp3="$2"
  print -- "New file:"
  print -- "  path:     $source_mp3"
  print -- "  bitrate:  ${CMP_NEW_BITRATE:-?} bps"
  print -- "  duration: ${CMP_NEW_DURATION:-?} s"
  print -- ""
  print -- "Existing file:"
  print -- "  path:     $live_mp3"
  print -- "  bitrate:  ${CMP_OLD_BITRATE:-?} bps"
  print -- "  duration: ${CMP_OLD_DURATION:-?} s"
  print -- ""
  print -- "Decision: $COMPARE_NOTE"
}

# Move a single FILE (source or LIVE) to rejected/<category>/<rel_path>,
# writing a sibling .log. category="replaced" increments REPLACED_COUNT;
# everything else increments REJECTED_COUNT.
reject_file() {
  local src="$1" category="$2" rel_path="$3" reason="$4" extra="${5:-}"
  local dest="${REJECTED_DIR}/${category}/${rel_path}"
  local label="REJECT"
  if [[ "$category" == "replaced" ]]; then
    (( REPLACED_COUNT += 1 ))
    label="REPLACED"
  else
    (( REJECTED_COUNT += 1 ))
  fi
  log "${label} [${category}]: $src -> $dest ($reason)"

  if (( DEBUG )); then
    print -- "[DEBUG] would mkdir -p: ${dest:h}"
    print -- "[DEBUG] would mv: $src -> $dest"
    print -- "[DEBUG] would write log: ${dest}.log"
    print -- "[DEBUG]   reason: $reason"
    [[ -n "$extra" ]] && print -- "[DEBUG]   extra:\n${extra}"
    return
  fi

  mkdir -p -- "${dest:h}"
  if [[ -e "$dest" ]]; then
    dest="${dest}.$(date +%s)"
  fi
  mv -- "$src" "$dest"
  {
    print -- "Rejected: $(date '+%Y-%m-%d %H:%M:%S')"
    print -- "Category: $category"
    print -- "Original path: $src"
    print -- "Reason: $reason"
    if [[ -n "$extra" ]]; then
      print -- ""
      print -- "$extra"
    fi
  } > "${dest}.log"
}

# Move an entire Author/Book/ subtree (source) to rejected/<category>/.
# Used for whole-book rejections (validation failures, all-mp3s-lost).
reject_book() {
  local src_book="$1" category="$2" reason="$3" extra="${4:-}"
  local rel="${src_book#${INGEST_DIR}/}"   # Author/Book
  local dest="${REJECTED_DIR}/${category}/${rel}"

  (( REJECTED_COUNT += 1 ))
  log "REJECT [${category}]: $src_book -> $dest ($reason)"

  if (( DEBUG )); then
    print -- "[DEBUG] would mkdir -p: ${dest:h}"
    print -- "[DEBUG] would mv: $src_book -> $dest"
    print -- "[DEBUG] would write log: ${dest}.log"
    print -- "[DEBUG]   reason: $reason"
    [[ -n "$extra" ]] && print -- "[DEBUG]   extra:\n${extra}"
    return
  fi

  mkdir -p -- "${dest:h}"
  if [[ -e "$dest" ]]; then
    dest="${dest}.$(date +%s)"
  fi
  mv -- "$src_book" "$dest"
  {
    print -- "Rejected: $(date '+%Y-%m-%d %H:%M:%S')"
    print -- "Category: $category"
    print -- "Original path: $src_book"
    print -- "Reason: $reason"
    if [[ -n "$extra" ]]; then
      print -- ""
      print -- "$extra"
    fi
  } > "${dest}.log"
}

# Copy a single file from source -> staging with size verification.
# Returns 0 on success, 1 on failure (caller should bail; staging persists
# for the next run to resume).
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
    (( COPIED_COUNT += 1 ))
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
  (( COPIED_COUNT += 1 ))
  return 0
}

# Move a single staged file into LIVE. Refuses to overwrite (if LIVE has it,
# logs WARN and leaves staged file in place — caller should have displaced
# the LIVE version first via reject_file/replaced).
merge_file() {
  local staged="$1" live="$2" rel_label="$3"

  if (( DEBUG )); then
    print -- "[DEBUG] would mkdir -p: ${live:h}"
    print -- "[DEBUG] would mv: $staged -> $live"
    (( MERGED_COUNT += 1 ))
    return 0
  fi

  if [[ ! -e "$staged" ]]; then
    return 0
  fi
  if [[ -e "$live" ]]; then
    log "  WARN live unexpectedly already has file, leaving in staging: $rel_label"
    return 0
  fi

  mkdir -p -- "${live:h}"
  log "  MERGE: $rel_label"
  mv -- "$staged" "$live"
  (( MERGED_COUNT += 1 ))
  return 0
}

# Stage source -> staging; then if LIVE has the target, displace it to
# rejected/replaced/ with a .log; then merge staging -> LIVE. Order matters:
# stage first so that a copy failure leaves LIVE intact.
# Returns 0 on success (file is in LIVE), 1 on stage failure.
install_or_replace() {
  local source_file="$1" live_file="$2" copy_file="$3" rel_path="$4"
  local replace_reason="$5" replace_extra="${6:-}"

  if ! stage_file "$source_file" "$copy_file" "$rel_path"; then
    return 1
  fi

  if [[ -e "$live_file" ]]; then
    reject_file "$live_file" "replaced" "$rel_path" "$replace_reason" "$replace_extra"
  fi

  merge_file "$copy_file" "$live_file" "$rel_path"
  return 0
}

# --- main processing --------------------------------------------------------

typeset -a books
books=( "$INGEST_DIR"/*/*(/N) )

log "found ${#books[@]} book directory(ies)"

typeset -a stray_top
stray_top=( "$INGEST_DIR"/*(.N) )
if (( ${#stray_top[@]} > 0 )); then
  log "WARNING: ${#stray_top[@]} loose file(s) at top of $INGEST_DIR (expected Author/Book/file structure):"
  for sf in "${stray_top[@]}"; do log "  - $sf"; done
fi
typeset -a stray_author
stray_author=( "$INGEST_DIR"/*/*(.N) )
if (( ${#stray_author[@]} > 0 )); then
  log "WARNING: ${#stray_author[@]} loose file(s) at Author level (expected Author/Book/file):"
  for sf in "${stray_author[@]}"; do log "  - $sf"; done
fi

for book_dir in "${books[@]}"; do
  log "---"
  log "processing: $book_dir"

  local rel="${book_dir#${INGEST_DIR}/}"   # Author/Book
  local author="${rel%%/*}"

  typeset -a book_files
  book_files=( "$book_dir"/**/*(.N) )

  if (( ${#book_files[@]} == 0 )); then
    skip "(empty book): $book_dir"
    continue
  fi

  # --- validation: any non-mp3 audio file -> wrong_type ------------------
  local bad_audio_witness=""
  local f
  for f in "${book_files[@]}"; do
    local ext="${f:e:l}"
    if (( ${NON_MP3_AUDIO_EXTS[(Ie)$ext]} )); then
      bad_audio_witness="${f#${book_dir}/} (.${ext})"
      break
    fi
  done
  if [[ -n "$bad_audio_witness" ]]; then
    reject_book "$book_dir" "wrong_type" \
      "contains non-mp3 audio (only .mp3 supported); witness: $bad_audio_witness"
    continue
  fi

  # --- validation: author dir name must not have spaces between initials -
  if author_has_bad_initials "$author"; then
    reject_book "$book_dir" "parse_error" \
      "author dir '$author' has spaces between initials (e.g. 'J K Rowling' should be 'JK Rowling') — metadata.json is likely also wrong"
    continue
  fi

  # --- validation: required files must be present at book root -----------
  local missing=""
  local req
  for req in "${REQUIRED_BOOK_FILES[@]}"; do
    if [[ ! -e "$book_dir/$req" ]]; then
      if [[ -z "$missing" ]]; then
        missing="$req"
      else
        missing="${missing}, $req"
      fi
    fi
  done
  if [[ -n "$missing" ]]; then
    reject_book "$book_dir" "parse_error" \
      "missing required file(s) at book root: $missing"
    continue
  fi

  # --- validation: at least one .mp3 at book root ------------------------
  typeset -a source_mp3s
  source_mp3s=( "$book_dir"/*.(#i)mp3(.N) )
  if (( ${#source_mp3s[@]} == 0 )); then
    typeset -a deep_mp3s
    deep_mp3s=( "$book_dir"/**/*.(#i)mp3(.N) )
    if (( ${#deep_mp3s[@]} > 0 )); then
      reject_book "$book_dir" "parse_error" \
        "no .mp3 at book root; mp3(s) only in subdirectories — flat layout required"
    else
      reject_book "$book_dir" "parse_error" \
        "no .mp3 file present"
    fi
    continue
  fi

  local source_jpg="${book_dir}/cover.jpg"
  local source_json="${book_dir}/metadata.json"

  # --- stability: defer the whole book if any file we'll touch is unstable
  typeset -a stab_files
  stab_files=( "${source_mp3s[@]}" "$source_jpg" "$source_json" )
  local in_use=0
  local age
  for f in "${stab_files[@]}"; do
    if is_file_in_use "$f"; then
      skip "(in use): $f ($IN_USE_REASON)"
      in_use=1
      break
    fi
    age="$(file_age_seconds "$f")"
    if (( age < MIN_FILE_AGE_SECONDS )); then
      skip "(too fresh): $f (mtime ${age}s ago, settle window ${MIN_FILE_AGE_SECONDS}s)"
      in_use=1
      break
    fi
  done
  if (( in_use )); then
    log "deferring book until stable: $rel"
    continue
  fi

  # Note any non-mp3/non-metadata files; they'll be removed after a
  # successful install (or carried with the book if it gets whole-rejected).
  typeset -a expected_files
  expected_files=( "${source_mp3s[@]}" "$source_jpg" "$source_json" )
  typeset -a extras
  extras=()
  local bf t is_expected
  for bf in "${book_files[@]}"; do
    is_expected=0
    for t in "${expected_files[@]}"; do
      if [[ "$bf" == "$t" ]]; then
        is_expected=1
        break
      fi
    done
    (( is_expected )) || extras+=( "$bf" )
  done
  if (( ${#extras[@]} > 0 )); then
    log "  ${#extras[@]} extra file(s) in book (will be removed after successful install):"
    for ef in "${extras[@]}"; do log "    - ${ef#${book_dir}/}"; done
  fi

  # --- classify destination: regex + template ----------------------------
  # The source's Author/Book relative path goes through the regex; the
  # template expands to the destination relative path. Default behaviour
  # (no-op, preserving Author/Book structure) requires:
  #   ABS_PARSE_REGEX='(?P<AUTHOR>[^/]+)/(?P<BOOK>.+)'
  #   ABS_NAME_TEMPLATE='%AUTHOR%/%BOOK%'
  local dest_rel
  if ! dest_rel="$(python3 "$PARSE_HELPER" "$ABS_PARSE_REGEX" "$ABS_NAME_TEMPLATE" "$rel" 2>/dev/null)"; then
    reject_book "$book_dir" "parse_error" "ABS_PARSE_REGEX did not match: '$rel'"
    continue
  fi
  log "  dest: '$rel' -> '$dest_rel'"

  # --- per-mp3 classification: new / winner / loser ----------------------
  local live_book="${LIVE_DIR}/${dest_rel}"
  local copy_book="${COPY_DIR}/${dest_rel}"

  typeset -A mp3_decision        # fname -> "new"|"winner"|"loser"
  typeset -A mp3_compare_block   # fname -> formatted compare info (winners+losers only)
  typeset -A mp3_live_path       # fname -> path to LIVE counterpart (winners+losers only)
  mp3_decision=()
  mp3_compare_block=()
  mp3_live_path=()

  local has_winner=0 has_new=0 loser_count=0
  local source_mp3 fname live_mp3
  for source_mp3 in "${source_mp3s[@]}"; do
    fname="${source_mp3:t}"
    live_mp3="${live_book}/${fname}"

    if [[ ! -e "$live_mp3" ]]; then
      mp3_decision[$fname]="new"
      has_new=1
      log "  ${fname}: NEW (no LIVE counterpart)"
      continue
    fi

    audiobook_compare_files "$source_mp3" "$live_mp3"
    mp3_compare_block[$fname]="$(format_compare_block "$source_mp3" "$live_mp3")"
    mp3_live_path[$fname]="$live_mp3"

    case "$COMPARE_RESULT" in
      new_wins)
        mp3_decision[$fname]="winner"
        has_winner=1
        log "  ${fname}: WINNER — $COMPARE_NOTE"
        ;;
      existing_wins)
        mp3_decision[$fname]="loser"
        (( loser_count += 1 ))
        log "  ${fname}: LOSER — $COMPARE_NOTE"
        ;;
      *)
        mp3_decision[$fname]="loser"
        (( loser_count += 1 ))
        log "  ${fname}: LOSER (unexpected compare result, fail-safe)"
        ;;
    esac
  done

  # If nothing would be installed, reject the whole book in one piece.
  if (( ! has_winner && ! has_new )); then
    reject_book "$book_dir" "lower_quality" \
      "all ${#source_mp3s[@]} mp3 file(s) lost the quality comparison vs LIVE"
    continue
  fi

  # --- install per-mp3 ---------------------------------------------------
  local install_failed=0
  local installed_count=0
  for source_mp3 in "${source_mp3s[@]}"; do
    fname="${source_mp3:t}"
    local decision="${mp3_decision[$fname]}"
    local rel_path="${rel}/${fname}"
    local live_f="${live_book}/${fname}"
    local copy_f="${copy_book}/${fname}"

    case "$decision" in
      loser)
        # Move source mp3 to rejected/lower_quality/Author/Book/<fname>.
        reject_file "$source_mp3" "lower_quality" "$rel_path" \
          "lost quality comparison vs LIVE" \
          "${mp3_compare_block[$fname]}"
        ;;
      new)
        if ! install_or_replace "$source_mp3" "$live_f" "$copy_f" "$rel_path" \
             "displaced by incoming higher-quality file"; then
          install_failed=1
          break
        fi
        (( installed_count += 1 ))
        ;;
      winner)
        if ! install_or_replace "$source_mp3" "$live_f" "$copy_f" "$rel_path" \
             "displaced by incoming higher-quality file" \
             "${mp3_compare_block[$fname]}"; then
          install_failed=1
          break
        fi
        (( installed_count += 1 ))
        ;;
    esac
  done

  if (( install_failed )); then
    log "book install aborted; staged files retained for resume: $rel"
    continue
  fi

  # --- metadata refresh: any mp3 installed -> always copy cover + json ---
  local meta_failed=0
  local meta
  for meta in "cover.jpg" "metadata.json"; do
    local source_meta="${book_dir}/${meta}"
    local live_meta="${live_book}/${meta}"
    local copy_meta="${copy_book}/${meta}"
    local meta_rel="${rel}/${meta}"
    if ! install_or_replace "$source_meta" "$live_meta" "$copy_meta" "$meta_rel" \
         "metadata refresh: ${installed_count} mp3 file(s) installed for this book"; then
      meta_failed=1
      break
    fi
  done

  if (( meta_failed )); then
    log "metadata install failed; staged files retained for resume: $rel"
    continue
  fi

  # Tidy empty staging subtree.
  if (( ! DEBUG )); then
    find "$copy_book" -depth -type d -empty -delete 2>/dev/null
  fi

  # --- source cleanup: remove installed mp3s, metadata, extras -----------
  for source_mp3 in "${source_mp3s[@]}"; do
    # Losers were already moved by reject_file. Winners and new mp3s remain
    # in source (they were cp'd, not mv'd, into staging).
    if [[ -e "$source_mp3" ]]; then
      if (( DEBUG )); then
        print -- "[DEBUG] would rm: $source_mp3"
      else
        rm -f -- "$source_mp3"
      fi
    fi
  done
  for meta in "$source_jpg" "$source_json"; do
    if [[ -e "$meta" ]]; then
      if (( DEBUG )); then
        print -- "[DEBUG] would rm: $meta"
      else
        rm -f -- "$meta"
      fi
    fi
  done
  for f in "${extras[@]}"; do
    if [[ -e "$f" ]]; then
      if (( DEBUG )); then
        print -- "[DEBUG] would rm extra: $f"
      else
        rm -f -- "$f"
      fi
    fi
  done
  if (( ! DEBUG )); then
    find "$book_dir" -depth -type d -empty -delete 2>/dev/null
  fi

  (( BOOKS_PROCESSED += 1 ))
  log "book complete: $rel  (installed=${installed_count}, losers=${loser_count})"
done

# --- cleanup: remove empty Author/ folders in source older than 1h ---------
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
log "summary: books=${BOOKS_PROCESSED}  copied=${COPIED_COUNT}  merged=${MERGED_COUNT}  replaced=${REPLACED_COUNT}  rejected=${REJECTED_COUNT}  skipped=${SKIPPED_COUNT}"
log "finished"
exit 0
