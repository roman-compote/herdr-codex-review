# Changelog

## 1.0.3
- `smoke-test.sh` no longer passes on a review that never mentions the code. Codex returned a
  Verdict even though all its tools had failed ("timed out negotiating with the code-mode host").
- SETUP.md: troubleshooting entry for Codex tools failing (Homebrew cask of codex-cli 0.163.0).

## 1.0.2
- codex-cli 0.163 asks the person to approve hooks before they run, which includes herdr's own
  agent-state hook. The script didn't recognise that screen and typed the prompt into it.
  It now stops with exit 3 and a hint, as it does for the folder-trust dialog.
- `smoke-test.sh` fails with a clear message when a hook needs approval. It never approves hooks itself.

## 1.0.1
- Never sends the review prompt into a Codex dialog. herdr can report Codex's first-run
  "Trust this folder?" dialog as `unknown` instead of `blocked`, and Enter would have accepted it.
  The script now checks the screen and stops with exit 3 and a clear hint.
- Reads the reviewer's screen from the pane itself, so dialog text is shown reliably.
- Refuses to run with the home folder (or `/`) as project root (exit 7), so Codex doesn't search
  your whole home folder. Override with `CODEX_REVIEW_ALLOW_HOME=1`. The skill asks which project a
  plan belongs to when started in `~`.

## 1.0.0
- First release.
