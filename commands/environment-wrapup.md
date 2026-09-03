---
description: Tears down the current agent environment and runs /session-wrapup.
---

The PR for this environment's work is merged. Wrap up the agent environment:

1. Note this env's name from the current worktree branch (`worktree-<name>`) before you move — once you leave the worktree, the name is harder to recover. Note the **main checkout's absolute path** too (`git rev-parse --path-format=absolute --git-common-dir`, minus the trailing `.git`); every later step uses it, because after a move relative paths point somewhere else.
2. **Leave the env, then move the session to the main checkout.** Which tool depends on how the session got into the env:
   - If this session ever called `EnterWorktree`, call `ExitWorktree` with action `keep`. The runtime's worktree isolation is still on until then, invisibly: it survives a compaction and an app restart, so do it even if you cannot see the call any more. It is a harmless no-op if you never entered.
   - Otherwise (the WordPress flow moves the session with `mcp__ccd_directory__change_directory`, which binds nothing), call `mcp__ccd_directory__change_directory` with the main checkout's path. It takes effect when the turn ends, so end the turn and continue from the next one.
   This is a directory move, NOT `git checkout main` — main is already checked out there, so a branch checkout in the worktree fails. Do not `cd` there in Bash either: a hook refuses `cd` into a main checkout from inside an env, and the WordPress `destroy` refuses to run while the shell stands inside the env it would delete.
3. Tear the env down, by which path depends on whether the project uses the engine:
   - **Engine-based env** (`scripts/agent-env.sh` or `scripts/agent-env-wp.sh` exists): use its guarded teardown command (`npm run destroy <name>` / `./scripts/agent-env.sh destroy <name>` / `./scripts/agent-env-wp.sh destroy <name>`) — never by hand. It stops servers, removes the worktree (for WordPress, every sibling worktree too), frees the port slot, and deletes the merged branch(es).
   - **Lightweight env, no engine** (e.g. a Shopify theme — no `scripts/agent-env.sh`): there's no `destroy`. Stop the env's dev server (e.g. `pkill -f "theme dev.*--port <PORT>"`), confirm nothing is unpushed, then from the main checkout `git worktree remove .claude/worktrees/<name>` and delete the merged branch. The agent-environments skill's `references/shopify.md` has the full teardown.
4. `git -C <main checkout> pull --ff-only`, then run `/session-wrapup`.
5. If session-wrapup changes any files **inside the repo** (modified or new — memory files under `~/.claude` are not in the repo and don't count), commit them to `main` and push. Note that pushing to `main` may trigger prod/CI deploys; if that's a meaningful side effect for this project, flag it before pushing.
