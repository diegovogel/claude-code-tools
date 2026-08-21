#!/usr/bin/env bash
#
# sync-from-claude.sh — pull the tracked subset of ~/.claude into this repo.
#
# This repo mirrors a hand-picked subset of ~/.claude. When you change one of
# those files in ~/.claude, run this to copy the changes back into the repo,
# then review the diff and commit.
#
#   scripts/sync-from-claude.sh            # sync
#   scripts/sync-from-claude.sh --dry-run  # show what would change, touch nothing
#
# To start tracking a new file or directory, add its repo-relative path to the
# PATHS array below. Each path is identical on both sides:
#   $SOURCE/<path>  ->  $REPO/<path>
# Directory entries are mirrored, so files deleted in ~/.claude are also removed
# from the repo copy. .DS_Store files are never copied.

set -euo pipefail

SOURCE="${HOME}/.claude"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Repo-relative paths to sync. An entry may be a file or a directory.
# Listed explicitly on purpose: ~/.claude holds more commands/skills/scripts
# than this repo tracks, and we only want these.
PATHS=(
  # Commands — only the ones tracked here; ~/.claude has others we ignore.
  commands/manual-qa.md
  commands/pr-with-codex.md
  commands/review-with-codex.md
  commands/session-wrapup.md
  commands/start-todoist-task.md

  # Scripts
  scripts/pr-with-codex

  # Skills
  skills/agent-environments
  skills/working-with-ignition-designer
  skills/brainstorm-with-panel
  skills/security-review-plus

  # Templates — single file; the rest of ~/.claude/templates is not tracked.
  templates/diegos-engineering-guidelines.md
)

# Always non-empty, so expanding it stays safe under `set -u` (macOS bash 3.2).
RSYNC_OPTS=(--archive --exclude '.DS_Store')

case "${1:-}" in
  -n | --dry-run)
    RSYNC_OPTS+=(--dry-run)
    echo "DRY RUN — no files will be changed."
    echo
    ;;
  "") ;;
  *)
    echo "Usage: $(basename "$0") [-n|--dry-run]" >&2
    exit 2
    ;;
esac

if [[ ! -d "$SOURCE" ]]; then
  echo "ERROR source not found: $SOURCE" >&2
  exit 1
fi

status=0
for path in "${PATHS[@]}"; do
  src="$SOURCE/$path"
  dst="$REPO/$path"

  if [[ ! -e "$src" ]]; then
    echo "WARN  missing in source, skipped: $path"
    status=1
    continue
  fi

  if [[ -d "$src" ]]; then
    # Trailing slashes mirror the directory's contents; --delete prunes files
    # in the repo copy that no longer exist in ~/.claude.
    mkdir -p "$dst"
    rsync "${RSYNC_OPTS[@]}" --delete "$src/" "$dst/"
    echo "DIR   $path"
  else
    mkdir -p "$(dirname "$dst")"
    rsync "${RSYNC_OPTS[@]}" "$src" "$dst"
    echo "FILE  $path"
  fi
done

echo
echo "Done. Review and commit:"
git -C "$REPO" status --short

exit "$status"
