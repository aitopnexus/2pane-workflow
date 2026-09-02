# 07: Economy comparison, saving gate and cost reporting

**What to build:** The verdict layer of the economy suite: after E1 completes, its total Expert usage (all consultations summed) is compared against the cached Expert-only baseline to produce the saving percentage — median across E1 repeats versus the single immutable baseline token count — and the run is graded `economy-fail` unless both modes produced a correct answer and the saving meets `--min-expert-saving`. The gate is strictly post-run: nothing limits Expert during E1. Each economy result carries a baseline reference recording the immutable ID, fingerprint, raw-session hash and a usage snapshot, so any report shows exactly which expensive run it was compared against. Single-run comparisons are flagged `exploratory`. Reports show the full cost picture: Main tokens and cost, consultation count, total Expert usage, combined E1 cost, cached baseline cost, and Expert's share of tokens and cost — in both token and money terms, since token prices differ across models. The saving formula is unit-tested on synthetic usage covering zero, one and multiple consultations, positive and negative saving, and threshold behavior.

**Blocked by:** 06: Economy E1 two-pane driver with per-role continued sessions

**Status:** resolved

- [x] Saving percentage computed as median of per-run summed Expert total tokens against the immutable baseline count; single-run case equals that run's sum
- [x] `--min-expert-saving` enforced as a post-run gate; `economy-fail` when either mode answered incorrectly or the threshold is missed
- [x] Correct-but-empty/wrong answers never count as savings
- [x] Baseline reference (ID, fingerprint, session hash, usage snapshot) stored per result; `--baseline-id` pins a specific stored run and rejects mismatched fingerprints
- [x] `exploratory` marker on single-sample results
- [x] Cost report includes Main/Expert tokens and costs, consultation count, both modes' totals and Expert share
- [x] Formula self-tests on synthetic usage pass with zero model calls

## Comments

Implemented in `cmd_economy` on top of ticket 06's driver. Per-run `result.json` and `.runs.ndjson` rows carry Main/Expert token and cost totals; the verdict layer takes the median summed Expert `totalTokens` across non-infra runs (`econ_median`) and computes `expertSavingPercent = round2(100*(1-median/baseline))` via `econ_saving_percent` — both unit-tested on synthetic usage (zero/one/multiple consultations, positive/negative/equal saving, two-decimal rounding, threshold at-and-below behavior, zero baseline guard). The gate is strictly post-run (`economy-fail` unless every valid run passed and answered correctly AND saving ≥ `--min-expert-saving`); a wrong or empty answer never counts as a saving. `baseline-ref.json` pins the immutable id, fingerprint, raw-session sha256 and full usage snapshot per run; `--baseline-id` resolves a specific stored run and a stored-fingerprint mismatch is a usage error (exit 2), a missing one baseline-missing (exit 6). Single-run comparisons are flagged `exploratory` in summary.json/txt. The report prints both models, per-run consultation counts, median Expert tokens, saving vs threshold, Expert share of tokens and cost, and both modes' totals in token and money terms. Self-tests cover: threshold miss → economy-fail with runs still passing; an unrestricted hog-mode Expert run proving nothing stops Expert mid-run (negative saving graded post-run); badskip proving incorrect answers fail; baseline pinning (valid, missing, mismatched).
