---
description: Opens the env's PR if needed, merges it once CI is green, deletes the merged branch, then runs /environment-wrapup.
argument-hint: "[env-name]"
---

Land an agent environment's work: get its PRs merged, then hand off to `/environment-wrapup` to remove the env. Running this command is the user's go-ahead for every step below: opening the PR, merging it once CI passes (a merge can deploy), deleting the merged branch, and everything `/environment-wrapup` does. Don't ask again before those; stop only where a step says to.

The steps run scripts in `~/.claude/scripts/environment-wrapup/` (shared with `/environment-wrapup`). Each script's header documents its output and exit codes, so read it there rather than guessing.

**Scope: one env per run.** That covers every PR the env needs, one per repo it spans: a WordPress env with a sibling plugin has two, both on the same branch. It also covers a new PR from a branch whose earlier PR already merged, while a PR that's already open is reused. PRs from other envs are out of scope: run the command once per env, passing its name.

## 1. Status

From one of the env's worktrees (or from the repo's main checkout, passing the env's name):

```
~/.claude/scripts/environment-wrapup/env-status.sh $ARGUMENTS
```

Note `name` and each repo's `slug` and `base` from its JSON.

`base` is where that repo's work merges, and `base_source` says why. Usually it's the default branch. A WordPress env, though, starts from whatever its checkout had checked out, often a long-lived feature branch, and then that branch is the base (`started-from`). Then act on each repo's `action`:

- `create-pr`: open the PR into `base` with your standard, built-in PR-creation workflow; don't restate it here. Two adjustments:
  - Aim each command at the repo's `dir` (`git -C <dir>`, `gh pr create --repo <slug> --head <branch> --base <base>`). This matters for a WordPress sibling, or when you ran the script from the main checkout.
  - Write the PR body to a file in your scratchpad with the Write tool, then pass `--body-file <that file>`. While the session is bound to the worktree, the isolation refuses `$(cat <<EOF ...)`, and any heredoc containing a brace.

  If `merged_prs` isn't empty, an earlier PR from this branch already merged. Before opening the new one, fetch, merge `origin/<base>` into the branch and push, so the new PR shows only the new work. If this session's pre-PR workflow report left findings unfixed, list them in the PR body.
- `merge`: the PR already exists. If `unpushed` > 0, push first (`git -C <dir> push`), or the merge would leave those commits out.
- `cleanup`: the PR (`merged_prs[0]`) already merged, but its remote branch is still there. Step 2 runs on that PR anyway, and only deletes the branch.
- `nothing`: the base already has all of the branch, or the env made no commits in this repo. No PR.
- `unknown-base`: stop. The env started from a commit `base` doesn't have (`started_from`), so a PR into `base` would carry that work too. That commit is either a checkout's unpushed work, or a branch origin doesn't have. When `started_from` is null (git expired the record), the sign is commits that `base` lacks and another branch also has. Ask the user where the work belongs. If it's a branch only on their machine, they need to push it first. Then open the PR into the branch they name; the PR's base is what the scripts follow from then on.
- `multiple-prs`: stop and ask which one to merge.
- `blocked-dirty`: stop. Show `git -C <dir> status --short` and ask what to do with the changes. The pre-PR workflow commits as it goes, so this is unexpected.

If you opened any PR, rerun the script once to confirm every repo now says `merge`, `cleanup` or `nothing`.

## 2. Merge when green

Start one run per `merge` or `cleanup` PR, all at once, each as a background Bash task (`run_in_background: true`, `timeout: 3900000`):

```
~/.claude/scripts/environment-wrapup/merge-when-green.sh <slug> <pr-number>
```

Then wait for the completion notifications; don't poll, sleep or check on them meanwhile. The script waits for CI, merges the commit that passed, and deletes the remote branch. Never merge any other way instead: no `gh pr merge` by hand, no auto-merge, no `--admin`.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | Merged (stdout: merge commit, method, whether the branch was deleted and why not) | Next PR, or step 3 |
| 2 | A check failed (listed with its URL) | Read the failure (`gh run view <run-id> --repo <slug> --log-failed`; the run id is in the URL). If the cause is clear and the fix stays within the PR's scope, fix it in the env, run the relevant tests, commit, push, and rerun the script. Otherwise report and stop. |
| 3 | Timed out (default 60 min) | Report, and ask whether to keep waiting. |
| 4 | The repo normally runs CI, but none started on this PR | Report. Rerun with `--allow-no-checks` only if the user says to. |
| 5 | Not mergeable (the message says why) | Conflicts: fetch, merge `origin/<base>` into the env's branch, resolve, rerun the tests, commit, push, rerun the script. Draft, required review, branch rules or closed: report and stop. |
| 6 | Tool or usage error, or GitHub unreadable five polls in a row | Report and stop. |

Go on to step 3 only once every PR has merged. The env stays in place until then, ready for a fix.

## 3. Wrap up the env

Keep each PR's result: its link, its repo's `base` from step 1 (the branch it merged into), and from step 2 its merge commit and whether its branch was deleted. Then invoke `/environment-wrapup` with the Skill tool, passing the env's `name` as its argument. It rechecks the env, leaves it, tears it down, and runs `/session-wrapup`.

Its report is this command's last message. Lead it with the PR results you kept, saying so when a PR merged into a branch other than the default.
