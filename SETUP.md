# Setup guide for an AI agent: codex-review (Claude plans → Codex reviews → Claude revises)

You are a coding agent (e.g. Claude Code) setting this up for the person you are working with.
Follow the steps in order. Run every check yourself, and only ask the person when a step says so.
Never skip a failed check. Stop and report it with the exact output.

## What gets installed

A user-level Claude Code skill, `codex-review`, in `~/.claude/skills/codex-review/`, so it works in
every project. When the person asks Claude to "prepare a plan", Claude:

1. Writes the plan to `<repo>/.claude/plans/<date>-<slug>.md`.
2. Runs `scripts/codex-review.sh`. Inside herdr, this opens a pane to the right of Claude's pane, starts
   Codex there (agent name `codex-review-<pane>`) and sends it the plan. Outside herdr, it runs a
   one-shot `codex exec` instead.
3. Codex reads the plan and the code **read-only** and replies with: Verdict (APPROVE/REVISE),
   Blocking, Should fix, Suggestions, Questions. The script saves the reply as `…review-r<N>.md`.
4. Claude checks each point against the code, accepts or rejects it with a reason, updates the plan and
   adds a `## Review log` table. It repeats for up to 3 rounds, reusing the same Codex session.
5. Claude shows the final plan and waits for the go-ahead before implementing.

Repo contents: `skill/codex-review/` (the skill), `install.sh`, `smoke-test.sh`, `README.md`, `LICENSE`, this file.

## Step 1: check prerequisites

```bash
for t in claude codex herdr jq git; do printf '%-7s ' $t; command -v $t >/dev/null && ($t --version 2>/dev/null | head -1) || echo MISSING; done
```

Versions this was tested with: herdr 0.9.0–0.9.5, codex-cli 0.162.1–0.163.0, current Claude Code, on macOS.
With codex-cli 0.163+, Codex asks once before it runs a hook, including herdr's own. Have the person
run `codex` once and approve it before step 5.
Older versions may work; herdr must have `agent start/prompt/read` (`herdr agent --help`).

If something is missing, tell the person and propose an install command. Don't install without asking.

| Tool | Install (macOS) | Notes |
|---|---|---|
| herdr | `brew install herdr` or see https://herdr.dev/docs/install/ | terminal workspace manager for AI agents |
| codex | `npm i -g @openai/codex` (or the person's usual method) | must be **logged in**: run `codex login` |
| jq | `brew install jq` | |
| claude | https://claude.com/claude-code | |

Check that Codex is logged in and works. This takes a few seconds and uses a tiny bit of quota:

```bash
codex exec -s read-only --skip-git-repo-check "Reply with just: OK"
```

**Data note for the person:** in the review step, Codex reads the plan and the relevant code and sends
it to OpenAI under their Codex account. Mention this once; if their employer restricts which AI
providers may see the code, they should confirm before using it on such repos.

## Step 2: herdr agent integrations

These hooks let herdr report each agent's real state (idle/working/blocked) instead of guessing it
from the screen. The review script depends on them.

```bash
herdr integration status
herdr integration install claude   # only if not "current"
herdr integration install codex    # only if not "current"
```

## Step 3: install the skill

From the repo folder (clone it first if needed):

```bash
./install.sh
```

It checks prerequisites again, moves any previous install to `~/.claude/backups/`, copies the skill,
and reports whether the permission rules are present.

## Step 4: permissions (ask the person first)

The skill runs `herdr …` and the review script via Bash. Without allow rules, Claude may ask for
permission each time. **Ask the person** whether to add these two rules to `~/.claude/settings.json`
under `permissions.allow`:

```json
"Bash(herdr:*)",
"Bash(bash ~/.claude/skills/codex-review/scripts/codex-review.sh:*)"
```

If they agree, run `./install.sh --permissions`. It merges the rules with jq and keeps a backup as
`settings.json.bak-codex-review`. If your own permission system blocks you from editing your settings,
don't work around it: give the person the snippet above to paste and verify afterwards with
`jq .permissions ~/.claude/settings.json`.

## Step 5: verify end to end

```bash
./smoke-test.sh
```

This starts a **throwaway** herdr session (the person's own session is not touched), creates a tiny
repo with a weak plan, runs one real Codex review round (about 1 minute of quota), and checks three
things: the review was saved, it has a Verdict, and no other file changed. Codex asks whether to trust
the new temp folder; the test accepts for that folder only, because it created it moments before. It
then deletes everything it created, including that trust entry in `~/.codex/config.toml`. Expect `PASS`.

If your Bash tool runs in a sandbox, the throwaway herdr server inherits it, and Codex then fails with
`app server did not become ready`. Run `smoke-test.sh` outside the sandbox, or ask the person to run
`! ./smoke-test.sh`.

## Step 6: hand over

Tell the person:

1. Start `herdr`, `cd` into a project, and start a **new** `claude` session there (not in `~`).
2. Ask: *"Prepare a plan for …"*, or use `/codex-review …`.
3. A Codex pane opens on the right; reviews land in `.claude/plans/`. The first time in each repo,
   Codex asks whether to trust the folder; they answer that in the Codex pane. Optionally add `.claude/plans/`
   to the project's `.gitignore`.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `CODEX_REVIEW_AGENT` | `codex-review-<caller pane>` | Use a specific herdr agent name as the reviewer |
| `CODEX_REVIEW_TIMEOUT_MS` | `900000` (15 min) | Max time per review round |
| `CODEX_REVIEW_CODEX_ARGS` | empty | Extra Codex args, e.g. `-m <model>` |
| `CODEX_REVIEW_ALLOW_HOME` | unset | `1` allows the home folder as project root (refused by default) |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "not inside herdr; running one-shot codex exec" | Claude wasn't started from a herdr pane (`echo $HERDR_ENV` should print `1`). It still works, but without a pane or memory between rounds. |
| Exit 5, `app server did not become ready` | The Codex background server failed. The script already passes `--no-daemon` when Codex supports it; check that `codex --no-daemon` starts by hand. Also check you're not running inside a sandbox. |
| Exit 3, "Codex has not seen this folder before" | Expected the first time in each repo. The person picks *Trust and continue* (or *Quit*) in the Codex pane, then Claude re-runs the round. To avoid it, run `codex` once in the repo beforehand. |
| Exit 3, "Codex wants a hook approved" | Codex 0.163+ asks once before running a hook, e.g. herdr's agent-state hook in `~/.codex/hooks.json`. The person reviews it in the Codex pane (`t` trusts all, Enter reviews), then Claude re-runs the round. To avoid it, run `codex` once after `herdr integration install codex`. |
| Review says Codex couldn't read files, e.g. "timed out negotiating with the code-mode host" | Codex's own tools fail, which isn't caused by this skill. Seen with the Homebrew cask of codex-cli 0.163.0 on a Mac mini: every shell call timed out, while the standalone install worked. Check with `codex exec -s read-only --skip-git-repo-check 'Run: ls'`. Fix: use Codex's standalone install instead of the cask. |
| Exit 3, other dialog | Codex is waiting in its pane (e.g. login). The person handles it, then Claude re-runs the round. |
| Exit 4, "no review came back" | Codex never answered (e.g. hit its usage limit). Look at the Codex pane. |
| Exit 6 | A dependency is missing from PATH. |
| Exit 7, "refusing to review: the project root would be …" | Claude was started in the home folder. Start it inside the project the plan is for. Otherwise Codex would search the whole home folder. |
| Skill doesn't trigger | Start a new Claude session after installing; or use `/codex-review` explicitly. |
| Codex pane left over | It's reused for the next plan from the same Claude pane. Close it to start fresh. |

## Uninstall

```bash
rm -rf ~/.claude/skills/codex-review
# and remove the two allow rules from ~/.claude/settings.json if they were added
```
