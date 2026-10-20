#!/usr/bin/env bash
# Send a plan file to a Codex reviewer and print the review.
#
#   codex-review.sh <plan-file> [round]
#
# Codex always runs READ-ONLY (sandbox read-only, never asks for approval): it cannot change
# any file. It returns the review in its reply; this script saves it to
# <repo>/.claude/plans/<plan-name>.review-r<round>.md and prints it.
#
# Inside herdr (HERDR_ENV=1): reuses a live Codex agent named $CODEX_REVIEW_AGENT
# (default "codex-review-<caller pane>", so parallel Claude sessions get their own reviewer),
# or splits a pane to the right of the caller and starts one.
# The same Codex session is kept across rounds, so it remembers its earlier review.
# Outside herdr: falls back to a one-shot `codex exec`.
#
# Exit codes: 0 review printed · 2 usage · 3 reviewer blocked at a dialog
#             4 no review came back · 5 could not start Codex · 6 missing dependency
#             7 refused: the project root would be the home folder (or /)
#
# Env: CODEX_REVIEW_AGENT (agent name) · CODEX_REVIEW_TIMEOUT_MS (per round, default 15 min)
#      CODEX_REVIEW_CODEX_ARGS (extra Codex args, e.g. "-m gpt-5")
#      CODEX_REVIEW_ALLOW_HOME=1 (allow the home folder as project root; Codex may then search all of it)
set -euo pipefail

PLAN=${1:?usage: codex-review.sh <plan-file> [round]}
ROUND=${2:-1}
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { echo "round must be a positive integer" >&2; exit 2; }
TIMEOUT_MS=${CODEX_REVIEW_TIMEOUT_MS:-900000}
IDLE_GIVE_UP_S=90   # reviewer idle this long after the prompt without answering -> give up

for dep in codex jq; do command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 6; }; done

# read-only sandbox + never ask: Codex cannot change files and never stops at an approval dialog.
# The nudge popup ("switch to a cheaper model?") would otherwise swallow the next prompt.
CODEX_ARGS=(-s read-only -a never -c notice.hide_rate_limit_model_nudge=true)
# Newer Codex builds start through a shared background server that can fail to come up;
# --no-daemon avoids it. Only pass it where it exists.
codex --help 2>/dev/null | grep -q -- '--no-daemon' && CODEX_ARGS=(--no-daemon "${CODEX_ARGS[@]}")
# shellcheck disable=SC2206
[ -n "${CODEX_REVIEW_CODEX_ARGS:-}" ] && CODEX_ARGS+=(${CODEX_REVIEW_CODEX_ARGS})

# Agent names must match [a-z][a-z0-9_-]{0,31}.
DEFAULT_AGENT=codex-review-$(printf '%s' "${HERDR_PANE_ID:-x}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-')
AGENT=${CODEX_REVIEW_AGENT:-${DEFAULT_AGENT:0:32}}

[ -f "$PLAN" ] || { echo "plan file not found: $PLAN" >&2; exit 2; }
PLAN=$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")
ROOT=$(git -C "$(dirname "$PLAN")" rev-parse --show-toplevel 2>/dev/null || pwd)
# With the home folder (or /) as the root, Codex would search everything in it: slow, and it
# exposes unrelated private files to the reviewer. Plans belong to a project.
real() { (cd "$1" 2>/dev/null && pwd -P); }
if { [ "$(real "$ROOT")" = "$(real "$HOME")" ] || [ "$(real "$ROOT")" = / ]; } && [ "${CODEX_REVIEW_ALLOW_HOME:-}" != 1 ]; then
  echo "[codex-review] refusing to review: the project root would be $ROOT, so Codex would search that whole folder." >&2
  echo "[codex-review] Start Claude inside the project the plan is for (or set CODEX_REVIEW_ALLOW_HOME=1)." >&2
  exit 7
fi
REVIEW_DIR="$ROOT/.claude/plans"; mkdir -p "$REVIEW_DIR"
BASE=$(basename "$PLAN" .md)
REVIEW=$REVIEW_DIR/$BASE.review-r${ROUND}.md
PREV=$REVIEW_DIR/$BASE.review-r$((ROUND - 1)).md
rm -f "$REVIEW"
# Per-run markers, so a review from an earlier round still on screen is never picked up.
NONCE=$(date +%s)$RANDOM
OPEN="<<<REVIEW-$NONCE"; CLOSE="REVIEW-$NONCE>>>"

read -r -d '' PROMPT <<EOF || true
You are reviewing an implementation plan (round ${ROUND}) for the repository at ${ROOT}. The plan is in ${PLAN}. Read it, then read whatever code it touches so your review is grounded in the actual repository. Look for: wrong assumptions about the code, missing steps or files, ordering/dependency problems, risks (data loss, migrations, security, concurrency, backwards compatibility), missing tests or verification, and scope creep or over-engineering. $( [ "$ROUND" -gt 1 ] && echo "The plan was revised after your previous review$( [ -f "$PREV" ] && echo " (saved in ${PREV})" ); first check whether each earlier point was resolved, then review the changes." ) You are a reviewer only: do not modify any file. Reply with the review as Markdown, starting with a line containing only ${OPEN} and ending with a line containing only ${CLOSE}, with exactly these sections in between: '## Verdict' (one line: APPROVE or REVISE), '## Blocking' (numbered; each with evidence such as file:line), '## Should fix' (numbered), '## Suggestions' (numbered), '## Questions' (numbered). Write 'None' in an empty section.
EOF

# Print the last complete block between marker lines (a marker line may carry the TUI's "• " / indent).
extract() {
  awk -v o="$OPEN" -v c="$CLOSE" '
    { t=$0; sub(/^[ \t•]+/, "", t); sub(/[ \t]+$/, "", t) }
    t==o { buf=""; f=1; next }
    t==c && f { out=buf; got=1; f=0; next }
    f { line=$0; sub(/^  /, "", line); buf=buf line "\n" }
    END { if (got) printf "%s", out; else exit 1 }'
}
save_review() {
  local text; text=$(extract <<<"$1") || return 1
  [ -n "${text//[[:space:]]/}" ] || return 1
  printf '%s\n' "$text" > "$REVIEW"
}
# Last resort: keep a reply that came back without markers, but say so.
save_raw() {
  [ -n "${1//[[:space:]]/}" ] || return 1
  echo "[codex-review] warning: reviewer did not use the review markers; saving its whole reply" >&2
  printf '%s\n' "$1" > "$REVIEW"
}
pane_text() { herdr agent read "$AGENT" --source recent-unwrapped --lines 1000 2>/dev/null; }

finish() { echo "[codex-review] review: $REVIEW"; cat "$REVIEW"; exit 0; }

# ---------- fallback: not inside herdr ----------
if [ "${HERDR_ENV:-}" != 1 ]; then
  echo "[codex-review] not inside herdr; running one-shot codex exec (no session memory between rounds)" >&2
  OUT=$(mktemp)
  codex exec -C "$ROOT" -s read-only --skip-git-repo-check -o "$OUT" "$PROMPT" >/dev/null 2>&1 || true
  reply=$(cat "$OUT" 2>/dev/null || true)
  save_review "$reply" || save_raw "$reply" || { rm -f "$OUT"; echo "codex exec produced no review" >&2; exit 4; }
  rm -f "$OUT"; finish
fi

# ---------- herdr: make sure the reviewer exists ----------
command -v herdr >/dev/null || { echo "missing dependency: herdr" >&2; exit 6; }
if ! herdr agent get "$AGENT" >/dev/null 2>&1; then
  echo "[codex-review] starting read-only Codex reviewer '$AGENT' in a new pane" >&2
  PANE=$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --cwd "$ROOT" --no-focus \
           | jq -r '.result.pane.pane_id')
  [ -n "$PANE" ] && [ "$PANE" != null ] || { echo "pane split failed" >&2; exit 5; }
  herdr pane rename "$PANE" "$AGENT" >/dev/null 2>&1 || true
  # The new shell needs a moment to reach its prompt; retry agent start a few times.
  ok=
  for _ in 1 2 3 4 5; do
    if herdr agent start "$AGENT" --kind codex --pane "$PANE" --timeout 60000 \
         -- "${CODEX_ARGS[@]}" >/dev/null 2>&1; then ok=1; break; fi
    herdr agent get "$AGENT" >/dev/null 2>&1 && { ok=1; break; }   # started but e.g. agent_not_ready
    sleep 2
  done
  [ -n "$ok" ] && herdr agent get "$AGENT" >/dev/null 2>&1 || ok=
  [ -n "$ok" ] || { echo "could not start codex in $PANE" >&2; herdr pane read "$PANE" --source recent-unwrapped --lines 40 >&2 || true; exit 5; }
  herdr agent wait "$AGENT" --timeout 120000 >/dev/null 2>&1 || true
fi

info()   { herdr agent get "$AGENT" 2>/dev/null; }
status() { info | jq -r '.result.agent.agent_status // "unknown"'; }
# The reviewer's screen. Read the pane itself: an agent read can come back empty while Codex
# is still at a startup dialog.
screen() {
  local pane; pane=$(info | jq -r '.result.agent.pane_id // empty')
  { [ -n "$pane" ] && herdr pane read "$pane" --source visible --lines 60 2>/dev/null; } \
    || herdr agent read "$AGENT" --source recent-unwrapped --lines 60 2>/dev/null || true
}
# Codex asks once per folder whether to trust it, and (since 0.163) once per hook whether to run it.
# herdr may report these dialogs as "unknown" rather than "blocked", so look at the screen too.
DIALOG_RE='trust this folder|needs? review before (it|they) can run'
dialog_prompt() { grep -qiE "$DIALOG_RE" <<<"$(screen)"; }
# Explain a blocked reviewer. Trusting a folder or a hook is the person's decision, never answer it here.
explain_block() {
  local text; text=$(screen)
  printf '%s\n' "$text" >&2
  if grep -qi 'trust this folder' <<<"$text"; then
    echo "[codex-review] Codex has not seen this folder before and asks whether to trust it." >&2
    echo "[codex-review] Ask the user to choose in the '$AGENT' pane, then run this round again." >&2
  elif grep -qiE 'needs? review before (it|they) can run' <<<"$text"; then
    echo "[codex-review] Codex wants a hook approved before it runs (e.g. herdr's agent-state hook in ~/.codex/hooks.json)." >&2
    echo "[codex-review] Ask the user to review it in the '$AGENT' pane ('t' trusts all, Enter reviews), then run this round again." >&2
  fi
}

# Codex's on-disk transcript for this session; its task_complete events carry each turn's final reply.
transcript() {
  local sid; sid=$(info | jq -r '.result.agent.agent_session.value // empty')
  [ -n "$sid" ] && ls -t "${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*"$sid".jsonl 2>/dev/null | head -1
}
completed_turns() { local f n=0; f=$(transcript) || true; [ -n "$f" ] && n=$(grep -c '"task_complete"' "$f" || true); echo "${n:-0}"; }
last_reply() {
  local f; f=$(transcript) || true; [ -n "$f" ] || return 0
  jq -rs '[.[] | select(.payload.type? == "task_complete")] | last | .payload.last_agent_message // empty' "$f"
}

# Never type the prompt into a dialog: Enter would pick its highlighted option (e.g. "Trust and continue").
if [ "$(status)" = blocked ] || dialog_prompt; then
  echo "[codex-review] reviewer '$AGENT' is waiting at a dialog; resolve it in its pane, then re-run." >&2
  explain_block; exit 3
fi

# ---------- send the plan, wait for the turn to complete ----------
before=$(completed_turns)
if ! res=$(herdr agent prompt "$AGENT" "$PROMPT" --wait --timeout "$TIMEOUT_MS" 2>&1); then
  echo "[codex-review] prompt returned: $res" >&2
  case "$res" in
    *agent_blocked*) explain_block; exit 3 ;;
  esac
fi

# --wait returns on the first settled state, so poll until the closing marker shows up.
# The transcript holds the exact text but Codex only flushes it when the turn closes;
# the pane shows the reply as soon as it is printed.
from_transcript() {
  [ "$(completed_turns)" -gt "$before" ] || return 1
  local reply; reply=$(last_reply)
  save_review "$reply" || save_raw "$reply"
}
deadline=$(( $(date +%s) + TIMEOUT_MS / 1000 ))
idle_since=
while [ "$(date +%s)" -lt "$deadline" ]; do
  from_transcript && finish
  if [ "$(status)" != working ] && extract <<<"$(pane_text)" >/dev/null; then
    for _ in 1 2 3 4 5; do sleep 2; from_transcript && finish; done
    save_review "$(pane_text)" && { echo "[codex-review] (review read from the pane)" >&2; finish; }
  fi
  case "$(status)" in
    blocked)
      echo "[codex-review] reviewer '$AGENT' is blocked at a dialog:" >&2
      explain_block; exit 3 ;;
    working) idle_since=; herdr agent wait "$AGENT" --timeout 30000 >/dev/null 2>&1 || true ;;
    *)
      dialog_prompt && { echo "[codex-review] reviewer '$AGENT' is waiting at a dialog:" >&2; explain_block; exit 3; }
      # Idle with no answer for a while: the prompt probably never landed. Don't wait 15 minutes.
      idle_since=${idle_since:-$(date +%s)}
      [ $(( $(date +%s) - idle_since )) -ge "$IDLE_GIVE_UP_S" ] && break
      sleep 3 ;;
  esac
done
echo "[codex-review] no review came back; last reviewer output:" >&2
screen >&2
exit 4
