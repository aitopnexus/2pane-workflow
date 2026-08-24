# Eval suite for the two-pane workflow

A self-contained runner/grader that answers two questions about the two-pane
workflow:

1. **Protocol** — does a cheap Main-Model follow the generated `SKILL.md`:
   route inbox actions only through `./2pane send` / `./2pane take`, never
   access runtime files directly, preserve a busy inbox and treat own-role
   messages correctly? Safe read-only diagnostics of fixture files/role are
   allowed; they are not inbox actions.
2. **Economy** — does routing the hard part through the two-pane Expert use
   fewer expensive-Expert tokens than running that Expert on the whole task
   alone?

Everything is deterministic: raw pi sessions (JSONL), tool-call results and
file state. There is no LLM judge. The one stochastic input is the model
itself, so every run pins and records the requested and actually-used model,
thinking level, usage and all run parameters.

Requirements: `bash`, `jq`, `pi` on `PATH`, and `docs/spec.md` +
`docs/adr/0001-single-slot-inbox.md` present in the checkout (economy
fixture inputs).

## Quick start

```bash
# 1. Protocol suite (cheap; four scenarios, fresh fixture each)
./evals/run.sh protocol --main-model openai-codex/gpt-5.6-luna:high

# 2. The ONE expensive command: create the Expert-only baseline once
./evals/run.sh baseline --expert-model openai-codex/gpt-5.6-sol:medium

# 3. Economy suite — reuses the cached baseline, never re-runs it
./evals/run.sh economy \
  --main-model openai-codex/gpt-5.6-luna:high \
  --expert-model openai-codex/gpt-5.6-sol:medium
```

Model specs are `provider/model[:thinking]`. The runner never uses your
default model: every pi process gets an explicit `--model`, and the report
always shows both, e.g. `main=openai-codex/gpt-5.6-luna:high` and
`expert=openai-codex/gpt-5.6-sol:medium`.

## The fixed eval workdir and the trust bootstrap

All runs happen in a **fixed workdir**, `/tmp/2pane-workflow-eval-workdir`,
which every run rebuilds from scratch: the current `2pane` helper is copied
in, `./2pane init` regenerates the pristine fixture, and the scenario seeds
the inbox. A lock directory refuses concurrent runners (they would share one
workdir and one inbox). Influencing environment variables (`AGENT_ROLE`,
session lookups, expert-launcher knobs) are reset before every pi process.

Pi normally gates project-local skills behind an interactive per-project
trust prompt. The eval sidesteps that deterministically: global extensions,
prompt templates, skills and context files are disabled, and exactly one
skill is force-loaded via `--no-skills --skill
<workdir>/.agents/skills/two-pane-workflow/SKILL.md`, with only the builtin
`bash` and `read` tools allowed. **No interactive approval is ever needed
for an eval run.** If you open pi interactively inside the fixed workdir
(e.g. to reproduce a run by hand), approve the project-trust prompt once —
that is the one-time trust bootstrap.

## Commands

### `protocol` — S1–S4

```bash
./evals/run.sh protocol --main-model SPEC [--runs N] [--timeout SEC]
```

Four scenarios, each from a freshly rebuilt and seeded fixture: S1
send-empty (a question is sent through the helper), S2 send-busy (the helper
must refuse and the seeded inbox survive byte-for-byte), S3 take (an expert
FYI is consumed and its marker reaches the final answer), S4 not-yours (a
take reports the message awaits the other role and nothing is consumed).
`summary.json` / `summary.txt` group results by the **actual** Main-model
observed in the sessions, with passed/N, protocol and infra failures per
scenario.

Bash calls are classified, not blanket-rejected: helper calls and safe
read-only diagnostics (`ls/find/grep/sed/head/tail/cat/wc/sort/pwd`,
fixture-only `cd`, `./2pane help|-h|--help`, narrow `echo AGENT_ROLE`) are
accepted. A helper may append only `; echo "EXIT:$?"`; its semantic status is
restored from the marker. Runtime paths, writes, network, mutation flags,
command substitution and paths outside the fixture remain protocol
violations; manifest/state checks are independent.

### `baseline` — the one expensive Expert-only run, cached

```bash
./evals/run.sh baseline --expert-model SPEC [--timeout SEC] [--refresh-baseline]
```

Runs the expensive Expert model alone over the economy task ("you are the
only agent…" + the verbatim task text), grades it with the same
answer-correctness gate as the economy suite, and on pass publishes it into
the persistent store under an immutable id. A matching cached baseline is
reused with **zero model calls**. `--refresh-baseline` forces a fresh run:
the new baseline gets a new immutable id, the active pointer is repointed
atomically, and the previous baseline is kept intact.

### `economy` — E1 two-pane vs the cached baseline

```bash
./evals/run.sh economy --main-model SPEC --expert-model SPEC \
  [--runs N] [--timeout SEC] [--run-timeout SEC] [--turn-cap N] \
  [--min-expert-saving PCT] [--baseline-id ID]
```

The driver is a pure human-router. A fresh Main session receives the mode
instruction ("Work on the following task as Main. Use the two-pane Expert
whenever you think it helps; you may also finish without consulting
Expert.") plus the verbatim task. After every pi turn the driver looks at
the inbox: a message `from: main` starts (or continues) the single Expert
session, a reply `from: expert` continues the Main session, and an empty
inbox after a Main turn ends the run. **How many consultations happen is
entirely Main's decision** — zero is legal, reported distinctly as
`expert-skipped`. Each role owns one session JSONL; continued turns resume
it (`pi --session`) so context and usage accumulate instead of resetting.
Expert turns run with `AGENT_ROLE=expert` (the only way `./2pane` addresses
the right pane). Nothing limits Expert during the run — the saving gate is
strictly post-run.

After the runs, the verdict layer compares the **median summed Expert
totalTokens across E1 runs** against the single immutable baseline count:

```
expertSavingPercent = 100 * (1 - median(E1 Expert token sums) / baseline tokens)
```

The suite grades `economy-fail` unless every valid E1 run produced a correct
answer (the exact two decision/invariant lines — a wrong or empty answer is
never a saving) **and** the saving meets `--min-expert-saving`. Every result
carries the baseline reference (immutable id, fingerprint, raw-session hash,
usage snapshot), so any report shows exactly which expensive run it was
compared against.

## Parameters

| Option | Applies to | Default | Meaning |
| --- | --- | --- | --- |
| `--main-model SPEC` | protocol, economy | — (required) | Cheap router model; SPEC is `provider/model[:thinking]` |
| `--expert-model SPEC` | baseline, economy | — (required) | Expensive consultant model |
| `--runs N` | protocol, economy | 1 | Repeats; every repeat starts from a fresh fixture |
| `--timeout SEC` | all | 180 | Per-pi-call timeout; exceeding it is infra-fail |
| `--refresh-baseline` | baseline | off | Force a new immutable baseline and repoint active |
| `--run-timeout SEC` | economy | 600 | Wall-clock rail for the whole E1 run (all turns) |
| `--turn-cap N` | economy | 8 | Rail on pi turns per E1 run; hitting it is infra-fail, never a fake saving |
| `--min-expert-saving PCT` | economy | 0 | Post-run gate on `expertSavingPercent` |
| `--baseline-id ID` | economy | active | Pin a specific stored baseline; a fingerprint mismatch is refused |

The rails (`--run-timeout`, `--turn-cap`) are emergency brakes against a
runaway loop, not a token budget and not an economy criterion.

## Baseline lifecycle

- **Creation** — `baseline` runs the Expert-only session once, grades it,
  and publishes it only on pass: `evals/baselines/<fingerprint>/<baseline-id>/`
  with `session.jsonl`, `answer.txt`, `prompt.txt`, `metadata.json`,
  `usage.json`, `checks.txt`, `fixture-manifest.sha256`, plus an `active`
  marker. The fingerprint hashes everything that defines the comparison:
  eval task + assertion version, store format, Expert model (incl. thinking
  level), pi version, verbatim prompt bytes, fixture manifest and pinned
  environment. It deliberately excludes the Main model (any cheap Main can
  reuse an Expert baseline) and the raw git commit (only fixture content
  invalidates).
- **Reuse** — an `economy` run with a matching fingerprint resolves the
  stored baseline and makes no Expert-only model call. Two economy runs
  with different Main models share one baseline id; the second creates no
  new Expert-only session.
- **Refresh** — `--refresh-baseline` creates a new immutable baseline and
  atomically repoints `active`. Old baselines are never modified or deleted,
  so older reports stay verifiable.
- **It never expires silently** — the report always shows which baseline id
  a result used, when it was created and what it cost. A stale baseline is
  visible, not hidden. `--baseline-id` pins a specific stored run and
  refuses one whose stored fingerprint no longer matches.

## Reading results

Exit codes: `0` pass · `1` protocol-fail · `2` usage error · `3` infra-fail ·
`4` lock busy · `5` economy-fail · `6` baseline-missing.

Every assertion is printed as `ok - …` / `not ok - …` in the run's
`checks.txt`, with the classification appended.

- **pass** — all assertions held.
- **protocol-fail** — the model violated the workflow contract (helper
  bypass, busy-inbox clobber, wrong final answer, …). This is model
  quality.
- **infra-fail** — the run machinery failed: pi crash, per-call timeout,
  missing/invalid/duplicate session JSONL, requested-vs-actual model
  mismatch (including mid-session changes), unexpected loaded resources,
  the wall-clock rail or the turn cap. Infra failures never mix into model
  quality: they are counted separately, and protocol checks are skipped
  when they fire.
- **economy-fail** — both modes ran but the saving gate failed (an
  incorrect answer in either mode, or `expertSavingPercent` below
  `--min-expert-saving`).
- **baseline-missing** — no cached baseline matches the current
  fingerprint; the command exits before any model call and prints the exact
  `baseline` command to create one.

Two markers to read carefully:

- **`expert-skipped`** — Main finished with zero consultations. Legal, and
  reported distinctly; it measures that a cheap Main did not spend the
  Expert on a simple task. It does not prove consultations are useful.
- **`exploratory`** — a single-sample economy comparison. Model answers are
  stochastic, so one run's saving is an indication, not a statistic; the
  verdict layer medians across `--runs N` repeats precisely so a report can
  stop being exploratory. Treat single-run savings as anecdotal.

## Artifacts and cleanup

Run artifacts live under `evals/results/<timestamp>-pid/` (per-run
directories with `session.jsonl` copies, per-turn logs and prompts,
`usage.json`, `metadata.json`, `checks.txt`, manifests; `summary.json` /
`summary.txt` at the root; economy runs add `baseline-ref.json`, per-turn
`turns/TNN-<role>/` dirs and per-run `result.json`). Both `evals/results/`
and `evals/baselines/` are gitignored, and they are independent: you can
delete `evals/results/` wholesale without touching the baseline store — the
next economy run reuses the cached baseline without a model call.

## Validating the eval itself

```bash
bash -n evals/run.sh     # syntax
./evals/run.sh self-test # grader + harness + cache + economy-formula
                         # self-tests on synthetic fixtures: zero model calls
tests/test-*.sh          # repository behavior tests
```

The self-tests pin the pi session-JSONL shapes the grader relies on, so a
pi update that changes the format fails loudly here instead of silently
grading nothing.
