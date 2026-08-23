# 11: Read-only bash inspection of fixture files — wontfix

**What to build:** (proposed, not built) Relax the eval's bash-is-helper-only rule to allow read-only inspection of non-runtime fixture files (`grep`/`sed`/`cat`/`ls` on `./2pane`, docs) — motivated by glm-5.3:high failing 5/5 economy runs solely for inspecting the helper's source via bash instead of the `read` tool.

**Blocked by:** None

**Status:** wontfix

## Comments

- 2026-08-23 decision (owner): keep the eval strict. glm is the primary working model and behaves correctly in real two-pane usage — the eval's bash-for-helper-only contract is deliberately narrower than real-world requirements, and read-only `grep`/`sed` on fixture files doesn't harm real workflows. The eval keeps measuring against its strict protocol surface; a model failing it is a signal about eval-contract compliance, not about usability.

- Evidence trail: economy series 2026-08-23T061757Z (glm-5.3:high ×5, new baseline bl-20260823T055607Z) — 5/5 protocol-fail on "every bash call is a helper invocation", but **zero runtime violations in all runs** (the new skill line "Never inspect `.2pane/` directly" eliminated every direct-access slip seen in the 2026-08-22 series: `cat .2pane/INBOX.md`, `ls -R .2pane`, `env`). All five answers correct, all expert-skipped. Revisit only if a future Main candidate is otherwise viable and this rule is the sole blocker — and prefer teaching the model (`read` for file inspection) over softening the grader.
