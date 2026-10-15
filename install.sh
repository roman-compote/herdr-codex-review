#!/usr/bin/env bash
# Install the codex-review skill for Claude Code (user level, works in every project).
#
#   ./install.sh                 check prerequisites, install/update the skill
#   ./install.sh --permissions   also add the two allow rules to ~/.claude/settings.json (backup kept)
#
# Safe to re-run: an existing install is backed up before it is replaced.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
DEST=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/codex-review
SETTINGS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
RULES='["Bash(herdr:*)","Bash(bash ~/.claude/skills/codex-review/scripts/codex-review.sh:*)"]'

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; missing=1; }

echo "Prerequisites"
missing=
for dep in claude codex herdr jq git; do
  if command -v "$dep" >/dev/null; then ok "$dep ($("$dep" --version 2>/dev/null | head -1))"
  else fail "$dep not found"; fi
done
[ -z "$missing" ] || { echo "Install the missing tools first (see SETUP.md, step 1)."; exit 1; }

echo "herdr integrations"
for agent in claude codex; do
  line=$(herdr integration status 2>/dev/null | grep -E "^$agent:" || true)
  case "$line" in
    *current*) ok "$line" ;;
    *) warn "${line:-$agent: unknown} → run: herdr integration install $agent" ;;
  esac
done

echo "Skill"
if [ -d "$DEST" ]; then
  # Keep backups OUTSIDE skills/, or Claude would load them as a second codex-review skill.
  bak="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/backups/codex-review-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$(dirname "$bak")"; mv "$DEST" "$bak"; ok "previous install moved to $bak"
fi
mkdir -p "$(dirname "$DEST")"
cp -R "$KIT/skill/codex-review" "$DEST"
chmod +x "$DEST/scripts/codex-review.sh"
bash -n "$DEST/scripts/codex-review.sh"
ok "installed to $DEST (version $(cat "$KIT/VERSION" 2>/dev/null || echo unknown))"

echo "Permissions"
have=$( [ -f "$SETTINGS" ] && jq --argjson r "$RULES" '[$r[] as $x | (.permissions.allow // []) | index($x)] | all(. != null)' "$SETTINGS" 2>/dev/null || echo false)
if [ "$have" = true ]; then
  ok "allow rules already present in $SETTINGS"
elif [ "${1:-}" = --permissions ]; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" || { fail "$SETTINGS is not valid JSON; fix it first"; exit 1; }
  cp "$SETTINGS" "$SETTINGS.bak-codex-review"
  tmp=$(mktemp)
  jq --argjson r "$RULES" '.permissions.allow = (((.permissions.allow // []) + $r) | unique)' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  ok "added allow rules (backup: $SETTINGS.bak-codex-review)"
else
  warn "not added. Re-run with --permissions, or add to permissions.allow in $SETTINGS:"
  echo "      \"Bash(herdr:*)\","
  echo "      \"Bash(bash ~/.claude/skills/codex-review/scripts/codex-review.sh:*)\""
fi

echo
echo "Done. Start a NEW Claude session inside a herdr pane and ask it to prepare a plan."
