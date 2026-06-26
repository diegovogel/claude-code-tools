---
name: brainstorm-with-panel
description: "Attack a hard, open-ended design problem with fresh-context, cross-model divergent idea generation and deferred cross-model evaluation. Use when the user is stuck on or unsatisfied with an approach to a genuinely hard design/architecture/strategy problem, explicitly wants creative alternatives, says things like 'let this stew', 'I'm not happy with this solution', 'what else could we do', or when you detect real design uncertainty (not a well-specified or mechanical task). NOT for trivial questions, tasks with a known right answer, or pure implementation work."
---

# Brainstorm with Panel

A skill for attacking a hard, open-ended problem with a cross-model *panel*: several fresh-context generators produce genuinely different approaches, a different model evaluates them, and you decide.

## What this is (and what it deliberately is NOT)

This started as a "subconscious mode" idea (the brain solving problems in the background while you walk or sleep). We researched it first. Two things to keep in mind so nobody "improves" this skill in the wrong direction:

- **The over-time / background framing does not transfer to an LLM.** A human brain idling does free sub-threshold work; an idle model does zero forward passes and its weights do not change between now and next week. "Letting it stew for days" buys nothing. The cognitive-science effect the metaphor rests on (Dijksterhuis's Unconscious Thought Theory) also failed to replicate. **Do not add a cron loop, a multi-day scheduler, or any "run it in the background over time" machinery.** That is the part with no evidence and real cost (Gwern's "LLM Daydreaming" specced exactly that and didn't build it because of a ~20:1 cost tax).
- **What DOES transfer, and is what this skill actually does:** three levers with real support.
  1. **Fresh context** breaks anchoring. A model deep in a conversation rationalizes within its first framing; a clean context re-attacks the problem unbiased. (Mere repetition in the same context does not help; the blank slate is the win.)
  2. **Decorrelated sampling.** Independent attempts from different framings (and different model families) cover more of the idea space than one model at high temperature. Cross-model (Claude + Codex/GPT) is the strongest real decorrelation available.
  3. **Separating generation from evaluation.** A model is a weak judge of its own ideas, and same-model "debate" amplifies shared bias. So generation is tool-starved (no judging), and a *different model* does the evaluating, with the human as final arbiter.

The honest pitch: this is a structured, cross-model, fresh-eyes brainstorm with deferred evaluation. For a problem you can just sit and think about for two minutes, a single "give me 10 wildly different approaches, don't evaluate them" prompt captures most of the value. This skill earns its keep when the problem is hard enough that decorrelated breadth + cross-model judgment + a saved artifact are worth the extra passes.

## When to refuse (and say so)

This skill only helps after genuine engagement with a hard, divergent problem. If the request is:

- a well-specified task with a known right answer,
- a mechanical / implementation job,
- or something you can answer well in one shot,

then **say that plainly and just answer it.** Do not run the machinery for the sake of it. Burning four model passes to produce mediocre "alternatives" to a problem that didn't need them is exactly the failure mode this skill must avoid.

## Phase 0: Prepare the brief

The single most robust finding in the incubation literature is that the benefit scales with **preparation depth**, not elapsed time. A thin problem statement gives the panel nothing to work with. So load the problem properly first.

1. **Assemble what you know** from the conversation: the problem, the current/leading solution, why the user is unsatisfied, hard constraints, and what's already been ruled out (and why).
2. **If the brief is thin, ask 2-3 sharp clarifying questions before generating.** Good ones: "What's your current best solution and what specifically don't you like about it?", "What are the hard constraints (budget, stack, time, must-not-break)?", "What have you already tried or rejected?". Do not skip this; decorrelated ideas against a vague brief are just noise.
3. **Pick a kebab-case slug** for the problem (e.g. `wordpress-e2e-testing`).
4. **Choose the scratchpad location** and create it:
   - If inside a git repo: `<repo-root>/.claude/brainstorm-with-panel/<slug>/` (run `git rev-parse --show-toplevel` to find the root). Mention to the user they may want to gitignore or commit it.
   - Otherwise: `~/.claude/brainstorm-with-panel/<slug>/`.
5. **Write `brief.md`** to that directory: the problem, current solution, constraints, ruled-out options, and the success criterion ("a good idea here would be one that..."). This file is the shared input every generator and evaluator reads.

## Phase 1: Decorrelated generation (deferred evaluation)

Run several generators **in parallel**, each from a fresh context. Each generator's only job is to *produce* ideas: it must not evaluate, rank, or pick a winner among them (that is Phase 2's job, done by a *different* model), and it must stay **read-only** (no editing, running, or committing). But read-only is not blindfolded, and this distinction matters: a generator working from a thin mental model emits confident nonsense. **Equip generators to actually explore the code and problem space** before ideating, read the relevant files, and if the project exposes a codebase-understanding tool (Laravel Boost, an MCP server, etc.), tell them to use it. The constraint is "don't judge your own ideas," not "don't look." Each generator reads `brief.md` first, then grounds itself in the real code, then generates.

**Default fleet: 3 Claude generators (parallel `Agent` calls) + 1 Codex generator (read-only).** Tune the count to problem difficulty. Each Claude generator gets a **different forced lens** so they decorrelate instead of converging:

- **First-principles lens:** ignore every existing and standard approach. Derive a solution from the raw constraints as if no prior art existed.
- **Constraint-inversion lens:** forbid the obvious/default tool or assumption (name it explicitly in the prompt, e.g. "you may not use a real browser" / "you may not stand up a full WordPress install"). Solve it anyway.
- **Cross-domain transplant lens:** find how an analogous problem is solved in a completely different field or ecosystem, and steal that approach wholesale.
- (Optional 4th, **extremes lens:** solve it twice, once assuming unlimited budget/time/infra and once assuming near-zero, and report what each extreme reveals.)

Spawn the Claude generators with the `Agent` tool (general-purpose), all in one message so they run concurrently. Each prompt must include: the full brief, the assigned lens, an instruction to first **ground themselves by reading the relevant code/files read-only** (and using any codebase-understanding tooling the project exposes), an instruction to then produce divergent ideas **without filtering for feasibility** (wild/impractical is welcome; that's the point), an explicit "do NOT rank, score, or recommend, do NOT edit or run anything," and the output schema below.

**Codex generator** (cross-model decorrelation; GPT has different priors). Run read-only (no `--write`):

```bash
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:$PATH"
node "$(ls -t ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | head -1)" task "$(cat <PATH>/brief.md)

You are a pure idea generator. Read the brief above. Produce 4-6 genuinely different approaches to this problem. Be divergent: unconventional, even impractical ideas are welcome. Do NOT evaluate, rank, or recommend any of them. Do NOT edit or run anything. For each idea output exactly this schema:
- id: <short-slug>
- one-liner: <one sentence>
- sketch: <2-4 sentences on how it would work>
- assumes: <what must be true for it to work>
- would-break: <what it sacrifices or risks> (describe, do not judge)"
```

If `which codex` fails (Codex not installed), skip the Codex generator, tell the user you're degrading to Claude-only decorrelated generation, and add one extra Claude lens to partly compensate.

**Parsing Codex output:** the `[codex] ...` lines are progress on stderr; the idea cards (and later the evaluation) are the final assistant message on stdout. Read the assistant message, not the progress lines. Don't redirect stderr away, leave it visible so a Codex error doesn't turn into silent empty output.

**Idea card schema** (every generator, both models, uses this):

```
- id: <short-slug>
- one-liner: <one sentence>
- sketch: <2-4 sentences>
- assumes: <what must be true>
- would-break: <what it sacrifices / risks — descriptive, not a verdict>
```

Collect every card. Write the raw pool to `ideas.md`, tagging each card with its generator (`claude:first-principles`, `codex`, etc.) so provenance is preserved for cross-model evaluation.

**Then cluster before evaluating (do not skip this step).** Group the cards into a handful of thematic clusters, and for each cluster note which generators landed in it. Lightly merge exact/near-duplicates (note the merge), but do not drop anything for being "bad" yet. Clustering is not cosmetic: a cluster that several *independent* generators converged on (especially across model families) is itself a signal, and the clusters, not the raw 20-plus cards, are the unit the evaluators and your synthesis will reason over. Put the cluster map at the top of `ideas.md`.

## Phase 2: Cross-model evaluation

Now, and only now, evaluate. The rule that makes this real: **an idea should be judged by a model that did not generate it.** So both models evaluate the full pool, and in synthesis you weight each model's verdict on the *other* model's ideas, and treat agreement across models as a stronger signal than either alone.

**Evaluators must check feasibility against reality, not vibes.** Instruct each evaluator to read the actual codebase / docs / constraints behind the top ideas and confirm they are genuinely buildable *before* scoring them, rather than judging from the brief alone. This is not optional polish: in this skill's first real run, the single most valuable finding (a fixture the whole approach depended on did not exist yet) surfaced *only* because the evaluator read the code. Design that catch in.

1. **Codex evaluation pass** (read-only). Feed it `brief.md` + the full `ideas.md` pool:

```bash
node "$(ls -t ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | head -1)" task "$(cat <PATH>/brief.md)

--- IDEAS ---
$(cat <PATH>/ideas.md)

You are an evaluator. For each idea above, score it on: novelty (is it genuinely different from the current solution, or a rephrase?), feasibility (in the stated constraints), and payoff (if it works). Where feasibility depends on the actual codebase, READ the relevant files to verify before scoring (do not guess). Give each a one-line biggest-risk / what-would-kill-it. Then nominate the 2-3 most worth pursuing and say why. If none of them beat the current solution, say so plainly — do not manufacture a winner. Do NOT edit or run anything."
```

Codex's `task` reads from its current working directory, so run the Codex evaluation **from the relevant repo root** (or pass key file paths in the prompt) so it can actually read the code, not just the brief. The Claude evaluator can be pointed at absolute paths directly.

2. **Claude evaluation pass.** Spawn one `Agent` (general-purpose, fresh context) with the same brief + pool and the same rubric, and explicitly tell it to **read the relevant repo files read-only to sanity-check feasibility** of the top ideas before scoring (do NOT edit or run anything). Keeping it a separate agent (not the main thread that may have helped frame things) preserves the context separation.

3. Write both verdicts to `evaluation.md`.

## Phase 3: Surface to the user (you are not the arbiter; they are)

Synthesize a short, honest shortlist. The default is **silence over noise**: if the evaluation didn't surface anything that genuinely beats the current approach, lead with that ("The panel didn't turn up anything better than what you've got, here's why, here's the closest contender") rather than dressing up a weak result.

Otherwise present **at most 3-5 ideas**, each with:

- the one-liner,
- why it's interesting / what it unlocks,
- **cross-model verdict:** consensus (both models rated it highly = stronger signal) vs split (one loved it, one dismissed it = high-variance, worth a look), explicitly noting it was cross-checked by the model that didn't generate it,
- its biggest risk,
- a **cheap concrete next step** to test it (the smallest experiment that would prove or kill it).

End with a clear recommendation (your top pick and why), framed as a recommendation, not a decision. Then offer to (a) deep-dive any idea into a real plan, or (b) run one more round with a new constraint or lens the user adds. Print the saved artifact paths (`brief.md`, `ideas.md`, `evaluation.md`).

**Required, even on a strong run: an honest marginal-value line.** State plainly what the cross-model / decorrelated structure actually bought over a single good one-shot prompt for *this* problem ("the fresh-context evaluator caught X a one-shot likely would have missed"), or, when it's true, admit "a one-shot brainstorm would have gotten you most of this." This is the skill holding itself to the same bar it applies to ideas: if it keeps reporting low marginal value for a class of problem, that is the signal to stop reaching for it there. Do not skip this to look more useful.

## Cost and noise controls (non-negotiable)

- **Bounded by default:** one round, a fixed small fleet (≈4 generators). No open-ended loops. No cron. No "background over time."
- **Default to silence on weak runs.** Tune for precision over recall. A skill that occasionally surfaces one genuinely good reframe and otherwise says "nothing better than what you have" is net-positive; one that always produces enthusiastic mediocre "insights" is net-negative and will get ignored.
- **Dedup across rounds.** If the user runs another round, read the prior `ideas.md` and `rejected.md` (if present) and instruct generators not to resurface those. Append newly-rejected ideas to `rejected.md`.
- **Honesty about marginal value.** If, partway in, it's clear the problem was well-specified enough that a one-shot answer would do, say so and stop rather than completing the ceremony.

## Why cross-model (Claude + Codex)

The whole feature rests on decorrelation and on not letting a model grade its own homework. Two different model families (Claude and GPT/Codex) have genuinely different training and priors, so: ideas from both cover more ground than one model alone, and each model judging the other's ideas avoids the self-evaluation degradation and shared-bias amplification that sink same-model generate-and-critique. That is the real mechanism here. If you ever strip Codex out, you lose the strongest part of the design, not just a nice-to-have.
