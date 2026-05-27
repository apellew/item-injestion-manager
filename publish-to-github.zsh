#!/bin/zsh
# publish-to-github.zsh
# ---------------------------------------------------------------------------
# One-shot helper to create a *public* GitHub repo for this project and push
# the current contents to it. Designed to be run by a human from inside the
# repo directory once, not by automation.
#
# USAGE:
#   # 1. Dry run first — shows what it would do, makes no changes:
#   ./publish-to-github.zsh
#
#   # 2. When the dry run looks right, actually do it:
#   ./publish-to-github.zsh --go
#
# Optional overrides via environment variables (defaults shown):
#   REPO_NAME=item-injestion-manager
#   REPO_DESC="Extensible zsh-based media injestion pipeline (Jellyfin / AudioBookShelf)."
#   DEFAULT_BRANCH=main
#   GH_OWNER=         # leave empty to use your default gh account
#
# REQUIREMENTS:
#   - gh CLI installed and authenticated  (`gh auth status`)
#   - git installed
#   - You're inside the repo directory when you run this
#
# WHAT IT DOES (in --go mode):
#   1. Verifies prerequisites (gh, git, gh auth).
#   2. Bails if the working dir already has a remote called "origin".
#   3. Runs `git init -b $DEFAULT_BRANCH` if no .git exists yet.
#   4. Stages all files, makes the initial commit (skipped if there is
#      already at least one commit on $DEFAULT_BRANCH).
#   5. Calls `gh repo create` with --public, sets the remote, and pushes.
#
# It deliberately does NOT delete or overwrite anything. If a step looks
# wrong, Ctrl-C is safe at every stage before the final `git push`.
# ---------------------------------------------------------------------------

emulate -L zsh
setopt PIPE_FAIL NO_UNSET ERR_EXIT

# --- config (overridable via env) ------------------------------------------
: ${REPO_NAME:=item-injestion-manager}
: ${REPO_DESC:=Extensible zsh-based media injestion pipeline (Jellyfin / AudioBookShelf).}
: ${DEFAULT_BRANCH:=main}
: ${GH_OWNER:=}

# --- mode flag --------------------------------------------------------------
DRYRUN=1
if (( $# > 0 )); then
  case "$1" in
    --go|-g)  DRYRUN=0 ;;
    --help|-h)
      sed -n '2,40p' -- "$0"
      exit 0
      ;;
    *)
      print -u2 "unknown argument: $1"
      print -u2 "run with --help for usage"
      exit 64
      ;;
  esac
fi

# --- helpers ----------------------------------------------------------------
log()  { print -- "[publish] $*"; }
warn() { print -u2 -- "[publish] WARN: $*"; }
die()  { print -u2 -- "[publish] FATAL: $*"; exit 1; }

# Run a command, or in dry-run mode just print what would be run.
run() {
  if (( DRYRUN )); then
    print -- "[DRY] would run: $*"
  else
    log "running: $*"
    "$@"
  fi
}

# --- preflight --------------------------------------------------------------
log "mode: $( (( DRYRUN )) && print -- 'DRY RUN (use --go to actually execute)' || print -- 'EXECUTE' )"
log "repo name:      $REPO_NAME"
log "description:    $REPO_DESC"
log "default branch: $DEFAULT_BRANCH"
[[ -n "$GH_OWNER" ]] && log "owner override: $GH_OWNER"

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v gh  >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed — see https://cli.github.com/"

if ! gh auth status >/dev/null 2>&1; then
  die "gh is not authenticated. Run: gh auth login"
fi

# Confirm cwd looks like the repo root.
if [[ ! -f README.md || ! -f LICENSE || ! -d scripts ]]; then
  die "this doesn't look like the repo root (expected README.md, LICENSE, scripts/)"
fi

# Refuse to clobber an existing 'origin' remote.
if [[ -d .git ]] && git remote get-url origin >/dev/null 2>&1; then
  EXISTING="$(git remote get-url origin)"
  die "this repo already has an 'origin' remote ($EXISTING) — remove or rename it first"
fi

# --- 1. git init (if needed) -----------------------------------------------
if [[ ! -d .git ]]; then
  log "step 1/4: initialising git repo"
  run git init -b "$DEFAULT_BRANCH"
else
  log "step 1/4: .git already exists — skipping git init"
fi

# --- 2. initial commit (if needed) -----------------------------------------
HAS_COMMITS=0
if [[ -d .git ]] && git rev-parse --verify "$DEFAULT_BRANCH" >/dev/null 2>&1; then
  HAS_COMMITS=1
fi

if (( HAS_COMMITS )); then
  log "step 2/4: branch '$DEFAULT_BRANCH' already has commits — skipping initial commit"
else
  log "step 2/4: staging files and making initial commit"
  run git add -A
  run git commit -m "Initial commit"
fi

# --- 3. create the GitHub repo ----------------------------------------------
log "step 3/4: creating public repo on GitHub via gh"
REPO_TARGET="$REPO_NAME"
if [[ -n "$GH_OWNER" ]]; then
  REPO_TARGET="${GH_OWNER}/${REPO_NAME}"
fi

# `gh repo create` with --source=. --push will push for us.
run gh repo create "$REPO_TARGET" \
  --public \
  --description "$REPO_DESC" \
  --source=. \
  --remote=origin \
  --push

# --- 4. summary -------------------------------------------------------------
log "step 4/4: done"
if (( DRYRUN )); then
  print -- ""
  print -- "Dry run complete. Re-run with --go to actually publish:"
  print -- "  $0 --go"
else
  log "repo created and pushed."
  log "view it: gh repo view --web"
fi
