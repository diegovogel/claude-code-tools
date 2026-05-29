#!/usr/bin/env bash
#
# poll-codex.sh — trigger a Codex review on a PR and wait for the response.
#
# Usage: poll-codex.sh <owner> <repo> <pr_number>
#
# Runs one full Codex review cycle:
#
#   1. Posts `@codex review` as a PR comment and captures the comment id +
#      timestamp.
#   2. Sleeps 60 s, then checks that the chatgpt-codex-connector[bot] has
#      added the `eyes` emoji reaction to the trigger comment (indicates
#      Codex saw the request). If the reaction is missing, posts the
#      comment a second time (no further eyes checks) and continues.
#   3. Polls both the PR /reviews endpoint AND the issue /comments endpoint
#      every 60 s, looking for a chatgpt-codex-connector[bot] response
#      newer than the most recent trigger comment.
#   4. When a response is found, prints a JSON envelope on stdout and
#      exits 0. If 15 minutes elapse with no response, exits 2.
#
# Codex posts findings as a PR review whose `body` is always the generic
# "Here are some automated review suggestions" header — the actual
# suggestions are inline comments on the diff. For review responses the
# script fetches those inline comments via
# /pulls/{n}/reviews/{review_id}/comments and includes them in the
# envelope so callers don't need a follow-up API call. Codex posts the
# "no issues" response as a plain issue comment whose body contains
# "Didn't find any major issues".
#
# Exit codes:
#   0 — Codex responded. Stdout is one of:
#       {"type":"review","data":{...},"inline_comments":[{id,path,line,body}...]}
#       {"type":"comment","data":{...}}
#   2 — Timed out after 15 minutes
#   3 — gh CLI or jq error (reported on stderr)
#
# This script is meant to be run as a background Bash task by the
# /pr-with-codex command. Running it synchronously works too, it'll just
# block for up to 15 minutes per cycle.

set -euo pipefail

# PATH is incomplete in the Claude Code sandbox — make sure the tools we
# need are reachable regardless of how this script is invoked.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:$PATH"

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <owner> <repo> <pr_number>" >&2
  exit 3
fi

OWNER="$1"
REPO="$2"
PR="$3"

BOT="chatgpt-codex-connector[bot]"
POLL_INTERVAL=60
MAX_WAIT_SECONDS=900  # 15 minutes total budget per cycle

for cmd in gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: $cmd is not on PATH" >&2
    exit 3
  fi
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Post `@codex review` as an issue comment on the PR. Prints the comment id.
post_trigger_comment() {
  local resp
  if ! resp=$(gh api \
    --method POST \
    "repos/$OWNER/$REPO/issues/$PR/comments" \
    -f body='@codex review' 2>&1); then
    echo "error: failed to post trigger comment: $resp" >&2
    return 1
  fi
  echo "$resp" | jq -r '.id'
}

# Check whether chatgpt-codex-connector[bot] has reacted to a specific issue
# comment with the "eyes" emoji. Returns 0 (found) or 1 (not found).
#
# Implementation note: we pipe gh directly into jq rather than capturing the
# response into a shell variable. Bash command substitution mangles embedded
# control characters (newlines in JSON string values get folded weirdly),
# which breaks jq parsing on responses that contain multi-line bodies.
has_eyes_reaction() {
  local comment_id="$1"
  gh api \
    -H "Accept: application/vnd.github+json" \
    "repos/$OWNER/$REPO/issues/comments/$comment_id/reactions" 2>/dev/null \
    | jq -e --arg bot "$BOT" \
        'any(.[]; .user.login == $bot and .content == "eyes")' \
        >/dev/null 2>&1
}

# Fetch the inline review comments for a specific review as a compact
# JSON array of {id, path, line, body}. Used to pack the actual findings
# into the envelope: Codex's review body is always the generic "Here are
# some automated review suggestions" header, and the real content lives
# in the per-line comments. Returns "[]" on any failure so the main flow
# does not abort over a transient gh blip.
fetch_review_inline_comments() {
  local review_id="$1"
  gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews/$review_id/comments" 2>/dev/null \
    | jq -c '[.[] | {id, path, line: (.line // .original_line), body}]' \
    || echo '[]'
}

# Look for a Codex response newer than $since on either endpoint. If found,
# prints a JSON envelope on stdout and returns 0; otherwise returns 1.
#
# Envelope shapes:
#   Review:  {"type":"review","data":{...review...},"inline_comments":[...]}
#   Comment: {"type":"comment","data":{...comment...}}
#
# Codex posts "no major issues" as a plain issue comment, and posts
# suggestions as a PR review with inline comments. Callers should check
# inline_comments for review responses and data.body for comment responses.
#
# Same no-intermediate-variable rule as has_eyes_reaction — PR review bodies
# routinely contain unescaped newlines in rendered markdown, which makes
# them unsafe for shell variable capture before filtering.
check_for_response() {
  local since="$1"
  local match review_id inline

  # /pulls/{n}/reviews
  if match=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -c --arg bot "$BOT" --arg since "$since" \
        '[.[] | select(.user.login == $bot and .submitted_at != null and .submitted_at > $since)]
         | sort_by(.submitted_at) | first // empty'); then
    if [[ -n "$match" && "$match" != "null" ]]; then
      review_id=$(printf '%s' "$match" | jq -r '.id')
      inline=$(fetch_review_inline_comments "$review_id")
      jq -nc --argjson d "$match" --argjson c "$inline" \
        '{type: "review", data: $d, inline_comments: $c}'
      return 0
    fi
  fi

  # /issues/{n}/comments
  if match=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/comments" 2>/dev/null \
    | jq -c --arg bot "$BOT" --arg since "$since" \
        '[.[] | select(.user.login == $bot and .created_at > $since)]
         | sort_by(.created_at) | first // empty'); then
    if [[ -n "$match" && "$match" != "null" ]]; then
      jq -nc --argjson d "$match" '{type: "comment", data: $d}'
      return 0
    fi
  fi

  return 1
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

start_seconds=$(date +%s)
deadline=$((start_seconds + MAX_WAIT_SECONDS))

# Step 1: post the initial trigger.
trigger_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
trigger_id=$(post_trigger_comment)
echo "posted @codex review as comment id=$trigger_id at $trigger_iso" >&2

# Step 2: sleep 60 s, then check for the eyes reaction. If missing, re-post
# once. We deliberately only re-post once — if the eyes reaction is still
# missing after the second post, the polling loop below will still pick up a
# response if Codex is processing, and a true silence surfaces as exit 2.
sleep "$POLL_INTERVAL"

if ! has_eyes_reaction "$trigger_id"; then
  echo "no eyes reaction on trigger $trigger_id after ${POLL_INTERVAL}s; re-posting @codex review" >&2
  trigger_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  trigger_id=$(post_trigger_comment)
  echo "re-posted @codex review as comment id=$trigger_id at $trigger_iso" >&2
  sleep "$POLL_INTERVAL"
fi

# Step 3: poll for a response until the global deadline.
while true; do
  if response=$(check_for_response "$trigger_iso"); then
    echo "$response"
    exit 0
  fi

  now=$(date +%s)
  if (( now >= deadline )); then
    echo "timed out after $((MAX_WAIT_SECONDS / 60)) minutes waiting for Codex response" >&2
    exit 2
  fi

  # Sleep, but never past the deadline.
  remaining=$((deadline - now))
  if (( remaining < POLL_INTERVAL )); then
    sleep "$remaining"
  else
    sleep "$POLL_INTERVAL"
  fi
done
