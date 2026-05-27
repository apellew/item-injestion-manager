#!/bin/zsh
# jellyfin-injest.zsh
# ---------------------------------------------------------------------------
# Parent orchestrator: discovers and runs jellyfin-injest-*.zsh child scripts,
# then waits and repeats. Exit with Ctrl-C.
#
# Each child script handles a specific media type (video, books, audiobooks,
# etc). Children receive the same three arguments and decide their own
# library subfolders internally.
#
# Usage:
#   jellyfin-injest.zsh <injest_root> <library_root> [DEBUG]
#
# Example:
#   jellyfin-injest.zsh /Volumes/Media /Volumes/Jellyfin DEBUG
#
# Child script contract:
#   - Named jellyfin-injest-<type>.zsh in the same directory as this script.
#   - Called with: <injest_root> <library_root> [DEBUG]
#   - Must be a single-run script (run once, then exit).
#   - Exit code 0 = success. Non-zero = logged as a warning but does not
#     stop other children from running.
# ---------------------------------------------------------------------------

emulate -L zsh
setopt PIPE_FAIL NO_UNSET EXTENDED_GLOB NULL_GLOB

# --- cron-safe PATH ---------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# --- argument parsing -------------------------------------------------------
if (( $# < 2 || $# > 3 )); then
  print -u2 "Usage: $0 <injest_root> <library_root> [DEBUG]"
  exit 64
fi

INJEST_ROOT="${1:A}"
LIBRARY_ROOT="${2:A}"
DEBUG_ARG=""
if (( $# == 3 )); then
  if [[ "${3:u}" == "DEBUG" ]]; then
    DEBUG_ARG="DEBUG"
  else
    print -u2 "Third arg must be 'DEBUG' if present (got: $3)"
    exit 64
  fi
fi

LOOP_SLEEP_SECONDS=120
UNAVAILABLE_CHECK_SECONDS=3600  # 1 hour: how long to wait when library root is unavailable

# --- locate child scripts ---------------------------------------------------
# Children live alongside this script and match jellyfin-injest-*.zsh.
SCRIPT_DIR="${0:A:h}"

log() { print -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Graceful exit on Ctrl-C.
trap 'print ""; log "interrupted — exiting"; exit 0' INT

log "jellyfin-injest orchestrator starting (Ctrl-C to stop)"
log "  script dir   = $SCRIPT_DIR"
log "  injest root  = $INJEST_ROOT"
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
  children=( "$SCRIPT_DIR"/jellyfin-injest-*.zsh(.N) )

  if (( ${#children[@]} == 0 )); then
    log "WARNING: no child scripts found matching $SCRIPT_DIR/jellyfin-injest-*.zsh"
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
      "$child" "$INJEST_ROOT" "$LIBRARY_ROOT" "$DEBUG_ARG" || rc=$?
    else
      "$child" "$INJEST_ROOT" "$LIBRARY_ROOT" || rc=$?
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
