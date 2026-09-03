#!/usr/bin/env bash
# SessionStart hook for every source (startup, resume, clear, compact, fork): wired with no matcher.
#
# Re-tells the session where it is whenever its memory is fresh or was just
# rewritten: at startup, after a resume, after /clear, after a compaction. The
# failure this defends against: a session inside a WordPress agent env lost the
# facts of how it got there (and whether EnterWorktree bound it) to a
# compaction, and reasoned from refusals instead. Everything printed here is
# derived from the on-disk layout, never from the session's launch directory:
# the desktop app relaunches a resumed session in whatever directory it was
# moved to, so CLAUDE_PROJECT_DIR is not a stable signal.
#
# Output on stdout is injected into the model's context (SessionStart is one of
# the events where plain stdout reaches Claude). Prints nothing when the cwd is
# not inside a WordPress agent env. Always exits 0.
set -uo pipefail

input=$(cat 2>/dev/null || true)
read_field() { printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1" 2>/dev/null || true; }
cwd=$(read_field cwd); source=$(read_field source)
[[ -n "$cwd" ]] || cwd="$PWD"

# The env install: nearest ancestor of cwd that holds wp-config.php AND is named
# <site>__<env>. Keyed on the install, not on git, so it holds for any layout.
install=""; d="$cwd"
while [[ "$d" != "/" ]]; do
  if [[ -f "$d/wp-config.php" && "$(basename "$d")" == *__* ]]; then install="$d"; break; fi
  d=$(dirname "$d")
done
[[ -n "$install" ]] || exit 0
env_name="${install##*__}"; site="$(basename "$install")"; site="${site%%__*}"

# Main checkouts, the same two ways the Bash guard finds them: every repo under
# the env's wp-content whose .git is a gitdir pointer resolves to its shared
# checkout, and every repo in the MAIN install those checkouts sit in counts too
# (a sibling the env only snapshotted has no pointer to follow).
mains=""
add_main() { case " $mains " in *" $1 "*) ;; *) mains="${mains:+$mains }$1" ;; esac; }
for repo in "$install"/wp-content/themes/*/ "$install"/wp-content/plugins/*/; do
  [[ -f "$repo.git" ]] || continue
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
  main=$(dirname "$common")
  [[ "$main" == "$install"* ]] && continue
  add_main "$main"
done
for m in $mains; do
  d="$m"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/wp-config.php" ]]; then
      for repo in "$d"/wp-content/themes/*/ "$d"/wp-content/plugins/*/; do
        [[ -d "$repo.git" ]] && add_main "${repo%/}"
      done
      break
    fi
    d=$(dirname "$d")
  done
done

# The checkout that created the env is the one whose registry lists it.
owner=""
for m in $mains; do [[ -f "$m/.agent-env/wp/$env_name/meta.env" ]] && { owner="$m"; break; }; done

log="${HOME}/.claude/agent-env-hooks.log"
printf '%s session-context source=%s cwd=%s project=%s env=%s owner=%s\n' "$(date '+%F %T')" "${source:-?}" "$cwd" "${CLAUDE_PROJECT_DIR:-?}" "$env_name" "${owner:-?}" >>"$log" 2>/dev/null || true

echo "[agent-env] SessionStart(${source:-?}): this session's working directory is INSIDE the WordPress agent env '${env_name}' (site '${site}'), install: ${install}."
if [[ -n "$mains" ]]; then
  echo "[agent-env] Main checkouts of this site, off-limits from here (hooks refuse the usual shapes of git, shell writes and file edits aimed at them, but treat them as forbidden regardless):"
  for m in $mains; do
    if [[ "$m" == "$owner" ]]; then echo "[agent-env]   - $m  (created this env; its registry lists it)"; else echo "[agent-env]   - $m"; fi
  done
fi
if [[ -n "$owner" ]]; then
  echo "[agent-env] Teardown: ${owner}/scripts/agent-env-wp.sh destroy ${env_name} refuses to run from inside the env. Move the session's working directory to ${owner} first (desktop app: mcp__ccd_directory__change_directory), then run it there; it reclaims every worktree the env holds."
else
  echo "[agent-env] Teardown: run the lifecycle script's destroy from the main checkout that created this env (the one whose .agent-env/wp/${env_name} exists); it refuses to run from inside the env."
fi
echo "[agent-env] If this session ever called EnterWorktree, the runtime's worktree isolation is still on: it survives compaction and app restarts and is invisible in your context, so do not infer it from refusals. Call ExitWorktree with action \"keep\" before moving (a harmless no-op if you never entered)."
exit 0
