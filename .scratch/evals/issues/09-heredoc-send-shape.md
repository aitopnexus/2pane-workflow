# 09: Grader recognizes stdin/heredoc helper sends

**What to build:** `helper_shape_sub` (evals/run.sh) accepts the documented stdin form of the helper as a valid send shape. Live observation (manual two-pane run, 2026-08-23): an Expert sending a long multi-line reply first tried `` ./2pane send "$(cat <<'EOF' … )" `` (bash quoting error), then recovered with `./2pane send <<'EOF' … EOF` — the helper's documented "standard input" mode (`send accepts one message argument or standard input`). Both calls are semantically pure helper invocations, but the shape rule rejects them: the second contains a leading input redirection (`<` is in `command_is_standalone`'s reject set), the first nests command substitution. Rule to implement: a bash call is helper-shaped when the last unquoted `&&`-segment reduces to `./2pane send|take` either standalone (as today) or as `./2pane send` followed by a single here-document (`<<[-]?('EOT'|'EOF') … terminator`) / a single input redirection feeding the helper's stdin. Output pipes, `;`, extra commands, and non-send/take subcommands stay rejected; the forbidden-path args scan still applies independently (see ticket 10 for its message-text caveat). The `$(cat <<'EOF'…)` wrapper can stay rejected — it failed at runtime anyway and the plain heredoc is the model's working fallback; keep the surface minimal. Self-tests: heredoc-send (both `<<` and `<<-` forms, single-quoted terminator) is a helper call; heredoc into a non-send command is not; `./2pane take <file` is not (take accepts no stdin message); output-piped heredoc send is not.

**Blocked by:** None

**Status:** ready-for-agent

## Acceptance

- [ ] `grader_helper_calls` counts `./2pane send <<'EOF'…EOF` as a send helper call
- [ ] `./2pane take` with input redirection, non-helper commands with heredocs, and piped variants stay rejected
- [ ] Self-tests added to the F5/F5b family; suite green with zero model calls
- [ ] Spec section «Запрет обхода helper» amended with the stdin-send allowance
