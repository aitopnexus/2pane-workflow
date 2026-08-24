# 11: Safe read-only diagnostics are not protocol violations

**What to build:** Classify bash calls as `helper`, `safe-diagnostic` or `violation`. Safe diagnostics are read-only inspection of non-runtime fixture files (`ls/find/grep/sed/head/tail/cat/wc/sort/pwd`, fixture-only `cd`, `./2pane help|-h|--help`, chains/pipelines of those) plus a narrow `echo` for `AGENT_ROLE` or visual separators. A helper may append only `; echo "EXIT:$?"`; restore helper status from the marker. Keep direct runtime access, writes/redirections, network, mutation-capable flags, command substitution and paths outside fixture as violations. Protocol/economy pass when every bash call is helper or diagnostic and the independent forbidden-path + manifest gates pass.

**Blocked by:** None

**Status:** resolved

## Acceptance

- [x] Synthetic JSONL classifies the six real safe diagnostic shapes
- [x] Runtime access, writes, network, `find -delete/-exec`, `sed -i`, outside paths stay violations
- [x] Helper and diagnostic classifiers are disjoint
- [x] Protocol/economy checks report bash/helper/diagnostic counts
- [x] Stored deepseek S4 and glm 2026-08-23 economy sessions re-grade as classified
- [x] Live deepseek protocol passes 4/4; live glm economy passes harmless runs
- [x] Stored and fresh glm direct-runtime/self-routing runs remain failures
- [x] Spec and README describe the relaxed-but-bounded contract

## Comments

- 2026-08-23 initial decision was `wontfix`: preserve the original helper-only bash surface. The owner reversed this on 2026-08-24 after deepseek-v4-flash showed the same harmless uncertainty diagnostic (`echo AGENT_ROLE`) and reiterated that both deepseek and glm work correctly in real two-pane usage. The eval should measure workflow correctness, not penalize harmless diagnostic tool choice.

- Implementation seam: `session.jsonl` → `grader_diagnostic_calls`. `diagnostic_command_shape` is a pragmatic deep module: callers only count helper + diagnostic vs all bash calls; the implementation owns allowlisted command families, physical/literal fixture path normalization, benign stderr suppression, mutation/network/substitution rejection and pipeline segmentation. It is not a shell security boundary; the spec still excludes deliberate obfuscation.

- TDD F12 synthetic fixture: safe real shapes (`echo AGENT_ROLE`, physical-path `ls && sed 2>/dev/null`, grep|head, find|sort&&ls, cat helper source, pwd) plus negative runtime/write/mutation/network/outside/helper cases. Red: 241/243; first green: 243/243. Code review added quoted outside-path negatives (`cat '/etc/passwd'`, `cat '../secret'`).

- Live deepseek runs added two shapes. F13 pins `cd … && ./2pane take; echo "EXIT:$?"` as helper + status diagnostic; the trailing echo makes shell exit 0, so grader restores helper status from `EXIT:N` (red 245/248, green 248/248). F12 was extended with fixture-only `cd` + read-only `./2pane help`; `init/expert/send/take` stay out of diagnostic classification. Final live deepseek protocol `20260824T080230Z` passes 4/4.

- Fresh glm economy `20260824T080306Z`: 4/5 pass. The sole r2 failure is deliberately preserved: direct `ls .2pane`, polling `sleep 20; ./2pane take`, and no Main consume after Expert reply — real runtime/self-routing violations, not diagnostics. This is the intended separation.
