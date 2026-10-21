#!/usr/bin/env bash
# Round-trips the generic engine through a rendered shim against a synthetic git
# repo and a synthetic config dir (AGENT_ENV_CONFIG_DIR), and checks the shim's
# local `guard` for both flows, the Herd-adoption cleanup in list and destroy
# (against a fake Herd registry and a stub herd), plus the WordPress engine's
# config loading (no WordPress round-trip: that needs an install and a
# database). Self-contained:
# builds and removes its own temp dirs, starts no servers (the minimal config's
# project_start_servers is a no-op, its health list is empty, and PORT_BASE sits
# in a high band nothing uses). Run with `bash tests/engine-config-test.sh`; it
# exits non-zero on any failure. Tests the engines next to this file, not the
# ones a repo's shim would resolve.
set -uo pipefail

skill=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
engine="$skill/assets/agent-env.sh"
wp_engine="$skill/assets/agent-env-wp.sh"
template="$skill/assets/shim.sh"

# pwd -P: macOS keeps the temp dir behind a symlink and destroy compares realpaths.
root=$(mktemp -d "${TMPDIR:-/tmp}/engine-config-test.XXXXXX"); root=$(cd "$root" && pwd -P)
cfgdir="$root/config"
repo="$root/repo"
trap 'rm -rf "$root"' EXIT

export AGENT_ENV_CONFIG_DIR="$cfgdir"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Keep the global and system git config out of the synthetic repos: commit.gpgsign
# would route every commit through 1Password, which fails or hangs when it is locked.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset AGENT_ENV_PROJECT AGENT_ENV_SHIM AGENT_ENV_ENGINE
# A rendered shim execs $AGENT_ENV_ENGINE, else whatever engine is installed
# under $HOME; point it at the sibling so every case exercises the engine here.
export AGENT_ENV_ENGINE="$engine"
# Herd's registry and CLI: a synthetic valet dir and a stub that logs each call
# (cwd|args) and behaves like Herd: workspace:delete drops the site's record and
# link, `workspaces` prunes records whose path is gone. $root/herd-mode switches
# it: "noop" exits 0 doing nothing (Herd's wrapper when it can't find its php),
# "fail-delete" fails only workspace:delete. No case touches the real Herd.
export AGENT_ENV_HERD_VALET="$root/herd-valet" AGENT_ENV_HERD_BIN="$root/fake-herd"
mkdir -p "$AGENT_ENV_HERD_VALET/Sites"
echo '{"workspaces":[]}' >"$AGENT_ENV_HERD_VALET/workspaces.json"
cat >"$AGENT_ENV_HERD_BIN" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$PWD" "\$*" >>"$root/herd.log"
mode=\$(cat "$root/herd-mode" 2>/dev/null)
reg="$AGENT_ENV_HERD_VALET/workspaces.json"
[[ "\$mode" == noop ]] && exit 0
case "\$1" in
  workspace:delete)
    [[ "\$mode" == fail-delete ]] && exit 1
    jq --arg s "\$2" '.workspaces |= map(select(.site != \$s))' "\$reg" >"\$reg.tmp" && mv "\$reg.tmp" "\$reg"
    rm -f "$AGENT_ENV_HERD_VALET/Sites/\$2" ;;
  workspaces)
    tmp=\$(mktemp); jq -c '.workspaces[]' "\$reg" | while read -r rec; do
      p=\$(jq -r .path <<<"\$rec"); [[ -d "\$p" ]] && echo "\$rec"; done | jq -s '{workspaces: .}' >"\$tmp" && mv "\$tmp" "\$reg" ;;
esac
exit 0
EOF
chmod +x "$AGENT_ENV_HERD_BIN"
herd_adopt() { # path-as-recorded site [link-target]: add a registry record and a Sites link
  jq --arg s "$2" --arg p "$1" '.workspaces += [{site: $s, path: $p, url: ("http://" + $s + ".test")}]' \
    "$AGENT_ENV_HERD_VALET/workspaces.json" >"$root/reg.tmp" && mv "$root/reg.tmp" "$AGENT_ENV_HERD_VALET/workspaces.json"
  ln -s "${3:-$1}" "$AGENT_ENV_HERD_VALET/Sites/$2"
}
herd_calls() { [[ -f "$root/herd.log" ]] && wc -l <"$root/herd.log" | tr -d ' ' || echo 0; }

failures=0
check() { # label exit-code-of-the-condition
  if [[ "$2" -eq 0 ]]; then echo "ok   $1"; else failures=$((failures + 1)); echo "FAIL $1"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
render_shim() { # project engine-basename dest
  sed -e "s/__PROJECT__/$1/g" -e "s/__ENGINE__/$2/g" "$template" >"$3" && chmod +x "$3"
}

# --- a repo with an initial commit; the shim is tracked, .env and .claude/ ignored
mkdir -p "$repo/scripts" "$cfgdir"
git -C "$repo" init -q -b main
render_shim repo agent-env.sh "$repo/scripts/agent-env.sh"
printf '.env\n.claude/\n' >"$repo/.gitignore"
echo hello >"$repo/README.md"
git -C "$repo" add -A && git -C "$repo" commit -q -m init
wt="$repo/.claude/worktrees/x"

# (a) no config at all
out=$(cd "$repo" && ./scripts/agent-env.sh list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "$cfgdir/repo/project.sh" && contains "$out" "project.example.sh"
check "(a) missing config: exit 1, names $cfgdir/repo/project.sh and the example to start from" $?

# the engine run directly, without the shim
out=$(cd "$repo" && "$engine" list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "AGENT_ENV_PROJECT is not set" && contains "$out" "shim"
check "engine without AGENT_ENV_PROJECT: exit 1, names the variable and the shim" $?
out=$(cd "$repo" && AGENT_ENV_PROJECT="../repo" "$engine" list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "invalid AGENT_ENV_PROJECT"
check "a traversal-shaped AGENT_ENV_PROJECT is refused before any path is built" $?

# (b) a config that lacks a required scalar and every required function
mkdir -p "$cfgdir/repo"
printf 'PORT_BASE=47000\n' >"$cfgdir/repo/project.sh"
out=$(cd "$repo" && ./scripts/agent-env.sh list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "$cfgdir/repo/project.sh is incomplete" \
  && contains "$out" "PORTS_PER_ENV (required scalar" \
  && contains "$out" "project_seed_env_files (required function" \
  && contains "$out" "project_env_port_lines (required function" \
  && contains "$out" "project_start_servers (required function"
check "(b) incomplete config: exit 1, lists the missing scalar and all three functions, names the path" $?
[[ $(grep -c "ERROR:" <<<"$out") -eq 1 ]] && ! contains "$out" "project_sync_deps" && ! contains "$out" "PORT_BASE"
check "(b) dies once, and optional hooks or present scalars are not reported" $?

# a minimal config: no-op servers, no health urls, a high port band, plus a
# top-level statement and a helper (sourcing must allow both)
cat >"$cfgdir/repo/project.sh" <<'CFG'
PORT_BASE=47000
PORTS_PER_ENV=2
CFG_HELPER_PREFIX="helped"
cfg_helper() { printf '%s-by-config' "$CFG_HELPER_PREFIX"; }
project_seed_env_files() { :; }
project_env_port_lines() {
  local name="$1" slot="$2"; shift 2
  printf 'WEB_PORT=%s\nAPI_PORT=%s\nHELPER=%s\n' "$1" "$2" "$(cfg_helper)"
}
project_start_servers() { :; }
CFG

# install-hooks through the shim, then commit .githooks/ (the documented setup
# step) so the round-trip below can leave the main checkout fully clean
out=$(cd "$repo" && ./scripts/agent-env.sh install-hooks 2>&1); rc=$?
[[ $rc -eq 0 && -x "$repo/.githooks/post-merge" && "$(git -C "$repo" config core.hooksPath)" == ".githooks" ]]
check "install-hooks via the shim writes .githooks/ and sets core.hooksPath" $?
grep -q 'exec "$root/scripts/agent-env.sh" sync-deps' "$repo/.githooks/post-merge"
check "the git hook still delegates to scripts/agent-env.sh (the shim)" $?
git -C "$repo" add .githooks && git -C "$repo" commit -q -m hooks

# (c) guard at the main checkout
(cd "$repo" && ./scripts/agent-env.sh guard >/dev/null 2>&1)
check "(c) guard exits 0 at the main checkout" $?
(cd "$repo" && AGENT_ENV_ENGINE=/nonexistent/engine ./scripts/agent-env.sh guard >/dev/null 2>&1)
check "(c) guard passes at the main checkout with no engine on the machine" $?
out=$(cd "$repo" && AGENT_ENV_ENGINE=/nonexistent/engine ./scripts/agent-env.sh list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "/nonexistent/engine" && contains "$out" "agent-environments skill"
check "shim without an engine: exit 1, names the engine path and the skill" $?

# (d) create
out=$(cd "$repo" && ./scripts/agent-env.sh create x 2>&1); rc=$?
[[ $rc -eq 0 && -f "$wt/.agent-env.json" && -f "$wt/.git" ]]
check "(d) create x via the shim provisions .claude/worktrees/x (linked worktree + marker)" $?
contains "$out" "ports:  47002 47003"
check "(d) slot 1 -> 47002 47003 (PORT_STRIDE defaulted to PORTS_PER_ENV)" $?
grep -q '^WEB_PORT=47002$' "$wt/.env" && grep -q '^HELPER=helped-by-config$' "$wt/.env"
check "(d) managed block written by the config's hook, via a helper defined at the config's top level" $?
[[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" == "worktree-x" ]]
check "(d) worktree is on the canonical branch worktree-x" $?

# (c) guard inside the env, and in a marker-less linked worktree
out=$(cd "$wt" && ./scripts/agent-env.sh guard 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "pinned to the main checkout's ports" \
  && contains "$out" "./scripts/agent-env.sh serve <name>" && contains "$out" "test and build commands"
check "(c) guard exits 1 inside the env worktree with the expected message shape" $?
(cd "$wt" && AGENT_ENV_ENGINE=/nonexistent/engine ./scripts/agent-env.sh guard >/dev/null 2>&1); [[ $? -eq 1 ]]
check "(c) guard refuses inside the env without touching the engine" $?
git -C "$repo" worktree add -q "$root/plain-wt" -b plain
(cd "$root/plain-wt" && ./scripts/agent-env.sh guard >/dev/null 2>&1); [[ $? -eq 1 ]]
check "(c) guard exits 1 in a hand-made linked worktree with no marker (.git is a file)" $?

# (d) list, provision from inside the worktree, run
out=$(cd "$repo" && ./scripts/agent-env.sh list 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qE '^x +worktree-x +no +0 +47002 47003 +no' <<<"$out"
check "(d) list shows x on worktree-x, clean, no unique commits, its ports, not serving" $?
out=$(cd "$wt" && ./scripts/agent-env.sh provision 2>&1); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "provisioned 'x' (slot 1)"
check "(d) provision from inside the worktree via the shim it checked out (idempotent, same slot)" $?
out=$(cd "$repo" && ./scripts/agent-env.sh run x -- pwd 2>&1)
[[ "$out" == "$wt" ]]
check "run x -- pwd from the main checkout lands in the worktree" $?
out=$(cd "$wt" && ./scripts/agent-env.sh run x -- pwd 2>&1)
[[ "$out" == "$wt" ]]
check "run x -- pwd from inside the worktree works too" $?
out=$(cd "$repo" && ./scripts/agent-env.sh serve x 2>&1); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "starting 'x' on ports: 47002 47003"
check "serve x with no-op servers and no health urls returns cleanly" $?
(cd "$repo" && ./scripts/agent-env.sh stop x >/dev/null 2>&1)
check "stop x" $?

# view: serves a stopped env and prints its URL; AGENT_ENV_NO_OPEN=1 skips the browser
out=$(cd "$repo" && AGENT_ENV_NO_OPEN=1 ./scripts/agent-env.sh view x 2>&1); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "starting 'x' on ports: 47002 47003" && contains "$out" "view 'x' at: http://localhost:47002/"
check "view x (AGENT_ENV_NO_OPEN=1) serves the stopped env and prints http://localhost:<first port>/ when the config lists no health url" $?
# an env that is already serving is not re-served, and the config's first health
# url (scheme and path included) beats the port fallback. A pid file pointing at
# a sleeping process stands in for a live server; it is removed by hand, not
# through stop, so nothing in the test's own process group is signalled.
mkdir -p "$cfgdir/viewcfg"
{ cat "$cfgdir/repo/project.sh"; printf 'project_health_urls() { echo "web|https://127.0.0.1:$1/app/|5"; }\n'; } >"$cfgdir/viewcfg/project.sh"
sleep 30 & fake_pid=$!
echo "$fake_pid" >"$wt/.agent-env/fake.pid"
out=$(cd "$repo" && AGENT_ENV_PROJECT=viewcfg AGENT_ENV_NO_OPEN=1 "$engine" view x 2>&1); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "'x' is already serving" && ! contains "$out" "starting 'x'" && contains "$out" "view 'x' at: https://127.0.0.1:47002/app/"
check "view x on a serving env does not re-serve and prints the config's first health url" $?
rm -f "$wt/.agent-env/fake.pid"
{ kill "$fake_pid"; wait "$fake_pid"; } 2>/dev/null

# (e) destroy from inside: refused, and the message names the shim
out=$(cd "$wt" && ./scripts/agent-env.sh destroy x 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "then rerun: $repo/scripts/agent-env.sh destroy x"
check "(e) destroy from inside is refused; the message names the shim in the main checkout" $?
out=$(cd "$wt" && AGENT_ENV_PROJECT=repo AGENT_ENV_SHIM=/elsewhere/custom-shim.sh "$engine" destroy x 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "$repo/scripts/custom-shim.sh destroy x"
check "(e) AGENT_ENV_SHIM is what reaches that message" $?
[[ -d "$wt" ]]
check "(e) the refused destroy left the worktree in place" $?

# (d) destroy from the main checkout; everything is reclaimed and main is clean
out=$(cd "$repo" && ./scripts/agent-env.sh destroy x 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$wt" && ! -e "$repo/.agent-env/slots/x" ]]
check "(d) destroy x from the main checkout removes the worktree and frees the slot" $?
! git -C "$repo" show-ref --verify --quiet refs/heads/worktree-x
check "(d) branch worktree-x deleted (no unique commits)" $?
[[ -z "$(git -C "$repo" status --porcelain)" ]]
check "(d) main checkout is clean after the round-trip" $?
[[ ! -e "$root/herd.log" ]]
check "(h) an env Herd never adopted makes no herd call on destroy (empty registry)" $?

# (h) Herd adoption. The registry starts with a decoy from another repo that
# shares the branch name and must never be touched; u is never adopted, h is.
herd_has() { jq -e --arg s "$1" 'any(.workspaces[]; .site == $s)' "$AGENT_ENV_HERD_VALET/workspaces.json" >/dev/null; }
mkdir -p "$root/other/.claude/worktrees/h"
herd_adopt "$root/other/.claude/worktrees/h" worktree-h.other
ln -s "$root/elsewhere" "$AGENT_ENV_HERD_VALET/Sites/other.repo"
wtu="$repo/.claude/worktrees/u"; wth="$repo/.claude/worktrees/h"
(cd "$repo" && ./scripts/agent-env.sh create u >/dev/null 2>&1)
(cd "$repo" && ./scripts/agent-env.sh create h >/dev/null 2>&1)
herd_adopt "$wth" worktree-h.repo
out=$(cd "$repo" && ./scripts/agent-env.sh list 2>&1)
contains "$out" "^ adopted by Herd as worktree-h.repo" && [[ $(grep -c 'adopted by Herd' <<<"$out") -eq 1 ]]
check "(h) list flags the adopted env only, not an unadopted one or another repo's record" $?
# destroyed from inside u, Herd is still driven from the main checkout
out=$(cd "$wtu" && ./scripts/agent-env.sh destroy h 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$wth" ]] && contains "$out" "unlinked 'h' from Herd (it had been adopted as worktree-h.repo)"
check "(h) destroy of an adopted env reports the unlink once Herd's registry no longer has it" $?
expected=$(printf '%s|processes:stop %s --site=worktree-h.repo\n' "$repo" dev "$repo" vite "$repo" pail "$repo" queue
  printf '%s|workspace:delete worktree-h.repo --keep-files --force\n' "$repo")
[[ "$(cat "$root/herd.log")" == "$expected" ]]
check "(h) from the main checkout, by the env's own site: stop dev, vite, pail, queue, then workspace:delete --keep-files --force" $?
herd_has worktree-h.other && ! herd_has worktree-h.repo && [[ -L "$AGENT_ENV_HERD_VALET/Sites/other.repo" ]]
check "(h) the other repo's same-named record and an unrelated link are left alone" $?
n=$(herd_calls); (cd "$repo" && ./scripts/agent-env.sh destroy u >/dev/null 2>&1)
[[ ! -e "$wtu" && "$(herd_calls)" == "$n" ]]
check "(h) destroying an unadopted env makes no herd call while the registry has records" $?

# Herd's wrapper exits 0 having done nothing when it can't find its php (a hook
# or GUI client's PATH): destroy must not take the exit code's word for it
wtn="$repo/.claude/worktrees/n"
(cd "$repo" && ./scripts/agent-env.sh create n >/dev/null 2>&1)
herd_adopt "$wtn" worktree-n.repo
echo noop >"$root/herd-mode"
out=$(cd "$repo" && ./scripts/agent-env.sh destroy n 2>&1); rc=$?
rm -f "$root/herd-mode"
[[ $rc -eq 0 && ! -e "$wtn" && ! -L "$AGENT_ENV_HERD_VALET/Sites/worktree-n.repo" ]] \
  && ! contains "$out" "unlinked 'n'" && contains "$out" "didn't remove it" \
  && contains "$out" "Herd still lists worktree-n.repo; run 'herd workspaces --all' before re-creating 'n'"
check "(h) a herd that exits 0 without unlinking: destroy warns, completes, removes the dangling link, says the record survived" $?

# workspace:delete failing (Herd not running): destroy completes, removes the
# dangling link and has Herd's own listing prune the record
wtf="$repo/.claude/worktrees/f"
(cd "$repo" && ./scripts/agent-env.sh create f >/dev/null 2>&1)
herd_adopt "$wtf" worktree-f.repo
echo fail-delete >"$root/herd-mode"
out=$(cd "$repo" && ./scripts/agent-env.sh destroy f 2>&1); rc=$?
rm -f "$root/herd-mode"
[[ $rc -eq 0 && ! -e "$wtf" && ! -L "$AGENT_ENV_HERD_VALET/Sites/worktree-f.repo" ]] && ! herd_has worktree-f.repo \
  && contains "$out" "removed Herd's dangling site link worktree-f.repo" \
  && contains "$out" "pruned Herd's record for worktree-f.repo" \
  && grep -qxF "$repo|workspaces --all --json" "$root/herd.log"
check "(h) with workspace:delete failing, destroy completes, removes the dangling link and has Herd prune its record" $?

# destroy through a symlinked spelling of the repo: Herd records the real path,
# but a record or link using either spelling must be matched
ln -s "$repo" "$root/repolink"
for spelling in real logical; do
  e="s-$spelling"; wts="$repo/.claude/worktrees/$e"; lns="$root/repolink/.claude/worktrees/$e"
  (cd "$repo" && ./scripts/agent-env.sh create "$e" >/dev/null 2>&1)
  if [[ $spelling == real ]]; then herd_adopt "$wts" "worktree-$e.repo"; else herd_adopt "$lns" "worktree-$e.repo"; fi
  echo fail-delete >"$root/herd-mode"
  out=$(cd "$repo" && ./scripts/agent-env.sh destroy "$lns" 2>&1); rc=$?
  rm -f "$root/herd-mode"
  [[ $rc -eq 0 && ! -e "$wts" && ! -L "$AGENT_ENV_HERD_VALET/Sites/worktree-$e.repo" ]] \
    && grep -qxF "$repo|workspace:delete worktree-$e.repo --keep-files --force" "$root/herd.log"
  check "(h) destroy via a symlinked path matches a record and a link that use the $spelling path" $?
done

# a Sites link under the env's site name that points somewhere else is not the env's to remove
wtg="$repo/.claude/worktrees/g"
(cd "$repo" && ./scripts/agent-env.sh create g >/dev/null 2>&1)
herd_adopt "$wtg" worktree-g.repo "$root/elsewhere-g"
echo fail-delete >"$root/herd-mode"
(cd "$repo" && ./scripts/agent-env.sh destroy g >/dev/null 2>&1)
rm -f "$root/herd-mode"
[[ ! -e "$wtg" && -L "$AGENT_ENV_HERD_VALET/Sites/worktree-g.repo" ]]
check "(h) a dangling link with the env's site name but another target is left alone" $?
[[ -z "$(git -C "$repo" status --porcelain)" ]] && herd_has worktree-h.other
check "(h) main checkout is clean and the other repo's record survived every case" $?

# the shipped example configs load unchanged (the "restate everything" case)
mkdir -p "$cfgdir/example" "$cfgdir/example-wp"
cp "$skill/assets/project.example.sh" "$cfgdir/example/project.sh"
cp "$skill/assets/project-wp.example.sh" "$cfgdir/example-wp/project.sh"
out=$(cd "$repo" && AGENT_ENV_PROJECT=example /bin/bash "$engine" list 2>&1); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "main checkout: $repo"
check "assets/project.example.sh loads as a config unchanged (under /bin/bash)" $?
out=$(cd "$repo" && AGENT_ENV_PROJECT=example-wp /bin/bash "$wp_engine" list 2>&1); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "repo checkout: $repo"
check "assets/project-wp.example.sh loads in the WordPress engine and list runs (under /bin/bash)" $?

# the WordPress engine's config contract
out=$(cd "$repo" && AGENT_ENV_PROJECT=nope "$wp_engine" list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "$cfgdir/nope/project.sh" && contains "$out" "project-wp.example.sh"
check "WordPress engine: missing config dies naming the path and its example" $?
mkdir -p "$cfgdir/wpmin"; printf 'WEB_HOST=localhost\n' >"$cfgdir/wpmin/project.sh"
out=$(cd "$repo" && AGENT_ENV_PROJECT=wpmin "$wp_engine" list 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "PORT_BASE (required scalar"
check "WordPress engine: a config without PORT_BASE dies naming it" $?
printf 'PORT_BASE=47100\n' >"$cfgdir/wpmin/project.sh"
(cd "$repo" && AGENT_ENV_PROJECT=wpmin "$wp_engine" list >/dev/null 2>&1)
check "WordPress engine: PORT_BASE alone is a complete config (everything else defaults)" $?

# the WordPress shim's guard
wp_repo="$root/wp-repo"; mkdir -p "$wp_repo/scripts"
git -C "$wp_repo" init -q -b main
render_shim wp-repo agent-env-wp.sh "$wp_repo/scripts/agent-env-wp.sh"
git -C "$wp_repo" add -A && git -C "$wp_repo" commit -q -m init
(cd "$wp_repo" && ./scripts/agent-env-wp.sh guard >/dev/null 2>&1)
check "WordPress shim: guard exits 0 at the main checkout" $?
git -C "$wp_repo" worktree add -q "$root/wp-wt" -b worktree-y
out=$(cd "$root/wp-wt" && ./scripts/agent-env-wp.sh guard 2>&1); rc=$?
[[ $rc -eq 1 ]] && contains "$out" "./scripts/agent-env-wp.sh serve <name>"
check "WordPress shim: guard exits 1 inside a linked worktree (no marker exists there) and names itself" $?
grep -q '^AGENT_ENV_PROJECT="wp-repo"$' "$wp_repo/scripts/agent-env-wp.sh" && grep -q 'assets/agent-env-wp.sh}' "$wp_repo/scripts/agent-env-wp.sh"
check "WordPress shim: both placeholders rendered" $?

echo "${failures} failure(s)"
[[ $failures -eq 0 ]] && echo "all cases passed"
exit $(( failures > 0 ))
