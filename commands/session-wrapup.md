Is there anything from this session we should add to CLAUDE.md or your memory?
* Lessons learned.
* Architecture decisions.
* Workarounds
* Outside context.

I want to keep noise to a minimum, but if there's anything that will be helpful context in the future, let's add it.

Also, is there anything currently in project-level CLAUDE.md and memory that no longer applies and needs to be removed or updated?

IMPORTANT: Review files referenced by CLAUDE.md (e.g., @docs/... includes) as well, not just CLAUDE.md itself. Check that referenced docs are still accurate and suggest updates if they've drifted from reality.

IMPORTANT: When updating CLAUDE.md (or any repo-tracked doc), edit ONLY the canonical copy in the main checkout. If the project uses git worktrees for parallel agents (e.g. `.claude/worktrees/<name>/`), those directories contain their own copies of CLAUDE.md belonging to other agents' in-flight branches. Never edit them — doing so dirties another agent's working tree and can collide with their branch. A grep for stale text will surface those copies; leave them alone (they pick up your change when their branch syncs/rebases). Only the main-checkout CLAUDE.md is yours to touch.
