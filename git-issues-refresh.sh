#!/usr/bin/env bash
#
# git-issues-refresh.sh
#
# Wipes all files in the sibling "git-issues" directory and regenerates them
# from GitHub, so Claude (Cowork mode) can Read the current open-issue list
# directly without needing copy/paste.
#
# Output files (in ./git-issues/ next to this script):
#   - git_issues.txt        full open-issue list (matches `gh issue list` text)
#   - git_issue<N>.txt      one file per open issue, with the full body
#
# Run from your Mac terminal. The gh CLI must be authenticated:
#   bash git-issues-refresh.sh
# or chmod +x once and run directly:
#   ./git-issues-refresh.sh

set -euo pipefail

REPO="apellew/item-injestion-manager"
LIMIT=200

# Self-locate so the script keeps working if the project folder moves.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/git-issues"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

echo "==> Cleaning old git_*.txt files in $OUT_DIR"
rm -f git_*.txt

echo "==> Writing git_issues.txt (open issues, default text format)"
gh issue list --repo "$REPO" --state open --limit "$LIMIT" > git_issues.txt

echo "==> Fetching individual issue bodies"
numbers=$(gh issue list --repo "$REPO" --state open --limit "$LIMIT" --json number --jq '.[].number')

count=0
for n in $numbers; do
    out="git_issue${n}.txt"
    printf '    %s\n' "$out"
    gh issue view "$n" --repo "$REPO" > "$out"
    count=$((count + 1))
done

echo ""
echo "==> Done. Wrote git_issues.txt + ${count} individual issue files to:"
echo "    $OUT_DIR"
