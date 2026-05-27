#!/bin/zsh
# jellyfin-ingest.zsh
# ---------------------------------------------------------------------------
# Parent orchestrator: discovers and runs jellyfin-ingest-*.zsh child scripts,
# then waits and repeats. Exit with Ctrl-C.
#
# Configuration is read from `scripts/.env` (sibling of this script). Copy
# `scripts/.env.template` to `scripts/.env` and fill in the paths before the
# first run. The template documents each required key.
#
# Each child script handles a specific media type (video, books, audiobooks,
# etc). Children inherit INGEST_ROOT and LIBRARY_ROOT from this process's
# environment.
#
# Usage:
#   jellyfin-ingest.zsh [DEBUG]
#
# Child script contract:
#   - Named jellyfin-ingest-<type>.zsh in the same directory as this script.
#   - Called with: [DEBUG]
#   - Inherits INGEST_ROOT and LIBRARY_ROOT from the env (also sources
#     .env defensively, so standalone runs work too).
#   - Must be a single-run script (run once, then exit).
#   - Exit code 0 = success. Non-zero = logged as a warning but does not
#     stop other children from running.
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

# Validate that the required keys are set and non-empty.
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

# Normalise paths now that the values are set.
INGEST_ROOT="${INGEST_ROOT:A}"
LIBRARY_ROOT="${LIBRARY_ROOT:A}"
export INGEST_ROOT LIBRARY_ROOT

# --- argument parsing -------------------------------------------------------
DEBUG_ARG=""
if (( $# == 1 )); then
  if [[ "${1:u}" == "DEBUG" ]]; then
    DEBUG_ARG="DEBUG"
  else
    print -u2 "Usage: $0 [DEBUG]"
    exit 64
  fi
elif (( $# > 1 )); then
  print -u2 "Usage: $0 [DEBUG]"
  exit 64
fi

LOOP_SLEEP_SECONDS=120
UNAVAILABLE_CHECK_SECONDS=3600  # 1 hour: how long to wait when library root is unavailable

log() { print -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Graceful exit on Ctrl-C.
trap 'print ""; log "interrupted — exiting"; exit 0' INT

log "jellyfin-ingest orchestrator starting (Ctrl-C to stop)"
log "  script dir   = $SCRIPT_DIR"
log "  config file  = $CONFIG_FILE"
log "  ingest root  = $INGEST_ROOT"
log "  library root = $LIBRARY_ROOT"
log "  debug        = ${DEBUG_ARG:-off}"
log "  loop sleep   = ${LOOP_SLEEP_SECONDS}s"

# --- main loop --------------------------------------------------------------
while true; do

  # --- library availability check ------------------------------------------
  # The target is on a remote server and may not be reachable (e.g. laptop
  # is off the home network). Wait an hour between checks until it's back.
  while [[ ! -d "$LIBRARY_ROOT" ]]; do
    log "WARNING: library root not available: $LIBRARY_ROOT"
    log "sleeping $(( UNAVAILABLE_CHECK_SECONDS / 60 ))m before rechecking..."
    local remaining=$UNAVAILABLE_CHECK_SECONDS
    while (( remaining > 0 )); do
      printf "\r\033[KLibrary unavailable — next check in %d:%02d " $(( remaining / 60 )) $(( remaining % 60 ))
      sleep 1
      (( remaining -= 1 ))
    done
    printf "\r\033[K"
  done

  log "========================================"
  log "=== orchestrator run starting ==="
  log "========================================"

  typeset -a children
  children=( "$SCRIPT_DIR"/jellyfin-ingest-*.zsh(.N) )

  if (( ${#children[@]} == 0 )); then
    log "WARNING: no child scripts found matching $SCRIPT_DIR/jellyfin-ingest-*.zsh"
  else
    log "found ${#children[@]} child script(s)"
  fi

  for child in "${children[@]}"; do
    local child_name="${child:t}"
    log "--- running: $child_name ---"

    if [[ ! -x "$child" ]]; then
      log "WARNING: $child_name is not executable — skipping (chmod +x to fix)"
      continue
    fi

    local rc=0
    if [[ -n "$DEBUG_ARG" ]]; then
      "$child" "$DEBUG_ARG" || rc=$?
    else
      "$child" || rc=$?
    fi

    if (( rc != 0 )); then
      log "WARNING: $child_name exited with code $rc"
    else
      log "$child_name completed successfully"
    fi
  done

  log "=== orchestrator run complete ==="

  # Countdown to next run (overwriting in place on the terminal).
  local remaining=$LOOP_SLEEP_SECONDS
  while (( remaining > 0 )); do
    printf "\r\033[KNext run in %d:%02d " $(( remaining / 60 )) $(( remaining % 60 ))
    sleep 1
    (( remaining -= 1 ))
  done
  printf "\r\033[K"

done  # end while true
