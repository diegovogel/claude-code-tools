# Shopify themes (and other no-local-state stacks)

A Shopify theme is the case where the agent-env **engine adds nothing**, but an
isolated agent env is still worth having. This reference is the whole playbook
for it: create, serve, operate, tear down. It generalizes to any stack whose dev
server only renders **local files against a remote service** and has no local
dependencies, database, or build to isolate.

## Recognize it

A Shopify theme repo: `layout/ sections/ snippets/ templates/` plus
`config/settings_schema.json`, run via `shopify theme dev` (often wrapped in
`npm run dev` or a `bin/` script). No `node_modules`/`vendor` of substance, no
build step, no local DB; `.shopify/` is gitignored CLI state.

## Why no engine

The engine isolates **local** state: dependency dirs (CoW-clone), per-env
DB/cache/queue, build artifacts, ports. A theme has none of the first three. Its
only "service" is `shopify theme dev`, which talks to a **shared remote store**
the engine can't clone or namespace. Installing `scripts/agent-env.sh` here is
~empty hooks around a single `--port` flag. **Don't install it.**

## What you still get — the actual point

The core value of an agent env is an **isolated copy of the codebase** so
parallel agents don't clobber each other's edits. A git **worktree** delivers
exactly that. A per-env dev-server **port** plus a per-env **development theme**
let each env serve its own live preview. That is a complete, legitimate agent
env for this stack, minus the engine.

## Create

`EnterWorktree` with a meaningful, task-derived kebab-case name (the runtime
makes the worktree under `.claude/worktrees/<name>` and a branch). There is **no
provision step** — nothing to install or seed.

## Serve (per-env preview)

```
shopify theme dev --store <store-handle> --port <PORT>
```

- **`<store-handle>`**: discover it per project (a `bin/` script, `.shopify/`, or
  `shopify theme list`); never hardcode it across projects.
- **`<PORT>`**: the project's main dev server uses 9292, so give each env a
  distinct free port (9293, 9294, …). **Never** run the project's own
  `npm run dev` / `bin/dev` inside a worktree — it's pinned to 9292 and collides
  with the main server. Always pass an explicit `--port`.
- Drop `--open` for a background/headless serve; the preview is
  `http://127.0.0.1:<PORT>`.
- Sync is one-way by default (local files → preview), which is what you want for
  an isolated env. `--theme-editor-sync` is a valueless boolean that opts INTO
  two-way sync; don't pass `--theme-editor-sync=false` (the CLI rejects a value).
- **Store-side isolation**: each worktree has its own gitignored `.shopify/`, so
  `theme dev` creates/uses a **separate development theme** per env on the store.
  Concurrent envs get independent dev themes; the store's
  product/collection/settings **data** is shared and read-only from the theme's
  view (fine for parallel rendering). Verify dev-theme separation once if you
  depend on truly parallel serving.

## Verify

A theme has no test suite, so verification is **visual**. Load the preview URL
and check the change; for `/manual-qa`, drive the preview headlessly (curl the
rendered markup, or eyeball the specific pages/products the change affects). The
rest of the pre-PR workflow (`/simplify`, `/security-review-plus` when warranted,
`/review-with-codex`) applies unchanged.

## Operate

- **List** envs: `git worktree list`.
- The engine's **cardinal rules still hold**: after any restart/interruption,
  re-anchor (verify `pwd` + `git branch --show-current`); after `EnterWorktree`,
  derive every file-tool path from the worktree root, not a planning-phase
  main-checkout path (a reused absolute path silently writes to `main`).

## Tear down (what `environment-wrapup` runs)

There is no `destroy` command. To wrap up:

1. **Stop the preview**: kill the env's `theme dev` process —
   `pkill -f "theme dev.*--port <PORT>"` (or Ctrl-C if foreground).
2. **Confirm nothing is unpushed** (the engine's guard does this automatically;
   here you check by hand). Don't discard unpushed work.
3. **Remove the worktree** from the **main checkout**:
   `git worktree remove .claude/worktrees/<name>` (`--force` only after confirming
   nothing unpushed). Delete the merged branch (`git branch -d <branch>`).
4. **Dev themes** auto-expire after ~7 days of inactivity; to clean up now,
   `shopify theme list` then `shopify theme delete <id>` for the env's dev theme
   (optional).
