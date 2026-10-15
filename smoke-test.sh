#!/usr/bin/env bash
# End-to-end check of the installed skill, without touching your real herdr session.
# Starts a throwaway herdr session + a tiny git repo, runs ONE real Codex review round
# (uses ~1 minute of Codex quota), checks the result, then deletes everything it created.
#
#   ./smoke-test.sh
set -euo pipefail

SCRIPT=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/codex-review/scripts/codex-review.sh
SESSION=codex-review-smoke-$$
WORK=$(mktemp -d)
WORK_REAL=$(cd "$WORK" && pwd -P)   # the path Codex records (e.g. /private/var/... on macOS)
CODEX_CFG=${CODEX_HOME:-$HOME/.codex}/config.toml
cleanup() {
  herdr session stop "$SESSION" --json >/dev/null 2>&1 || true
  herdr session delete "$SESSION" --json >/dev/null 2>&1 || true
  rm -rf "$WORK"
  # Accepting Codex's trust prompt saved this temp folder in its config; remove exactly that entry.
  if [ -f "$CODEX_CFG" ] && grep -qF "[projects.\"$WORK_REAL\"]" "$CODEX_CFG"; then
    awk -v h="[projects.\"$WORK_REAL\"]" '
      $0 == h { skip = 1; next }
      skip && /^\[/ { skip = 0 }
      !skip' "$CODEX_CFG" > "$CODEX_CFG.smoke-tmp" && mv "$CODEX_CFG.smoke-tmp" "$CODEX_CFG"
  fi
}
trap cleanup EXIT

[ -f "$SCRIPT" ] || { echo "skill not installed: $SCRIPT (run ./install.sh)"; exit 1; }

# A tiny repo with a deliberately weak plan.
cd "$WORK" && git init -q
printf 'def divide(a, b):\n    return a / b\n' > calc.py
mkdir -p .claude/plans
printf '# Plan: safe divide\n## Goal\nMake divide() not crash on b == 0.\n## Steps\n1. Return 0 when b == 0.\n## Verification\nNone.\n' \
  > .claude/plans/smoke.md
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm init

echo "Starting throwaway herdr session '$SESSION'..."
(nohup herdr --session "$SESSION" server >/dev/null 2>&1 &)
for _ in $(seq 1 20); do herdr --session "$SESSION" workspace list >/dev/null 2>&1 && break; sleep 0.5; done
PANE=$(herdr --session "$SESSION" workspace create --cwd "$WORK" --no-focus | jq -r .result.root_pane.pane_id)
sleep 2

n=0
run_round() {
  n=$((n + 1))   # a fresh marker per run, so output of an earlier run never matches
  herdr --session "$SESSION" pane run "$PANE" "clear; bash '$SCRIPT' .claude/plans/smoke.md 1; echo SMOKE${n}_RC=\$?"
  herdr --session "$SESSION" pane wait-output "$PANE" --regex "SMOKE${n}_RC=[0-9]+" --timeout 600000 >/dev/null || true
  out=$(herdr --session "$SESSION" pane read "$PANE" --source recent-unwrapped --lines 200)
}
echo "Running one review round (Codex opens in a pane of the throwaway session)..."
run_round
# Codex asks whether to trust a folder it hasn't seen. This folder was created by this test
# a moment ago, so trusting it is safe: pick "Trust and continue" and run the round again.
if grep -q 'Trust this folder' <<<"$out"; then
  echo "Codex asked to trust the throwaway test folder; accepting for this folder only and retrying..."
  herdr --session "$SESSION" agent send-keys "codex-review-$(tr ':' '-' <<<"$PANE" | tr 'A-Z' 'a-z')" enter >/dev/null
  sleep 3
  run_round
fi
echo "$out" | sed -n '/\[codex-review\]/,$p'

rc=$(echo "$out" | grep -o "SMOKE${n}_RC=[0-9]*" | tail -1 | cut -d= -f2)
review=$WORK/.claude/plans/smoke.review-r1.md
changed=$(git -C "$WORK" status --porcelain | grep -v '^?? .claude/plans/smoke.review-r1.md$' || true)

echo
if [ "$rc" = 0 ] && grep -q '^## Verdict' "$review" 2>/dev/null && [ -z "$changed" ]; then
  echo "PASS: Codex reviewed the plan, the review was saved, and no other file changed."
else
  echo "FAIL: rc=${rc:-none}, review present: $([ -f "$review" ] && echo yes || echo no), other changes: ${changed:-none}"
  exit 1
fi
