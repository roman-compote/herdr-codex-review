# Changelog

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
