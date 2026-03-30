#!/bin/bash
# Install the Benchspan onboard-agent skill for your coding agent.
# Usage: curl -fsSL https://docs.benchspan.com/install-skill.sh | sh

set -euo pipefail

DOCS_BASE="https://docs.benchspan.com/skills/onboard-agent"
SKILL_FILES=(
  "SKILL.md"
  "references/runner-sh-interface.md"
  "references/runner-sh-examples.md"
  "references/common-gotchas.md"
  "references/trajectory-schema.md"
)

# Detect which coding agent(s) are installed
INSTALLED=""
[ -d "$HOME/.claude" ] && INSTALLED="$INSTALLED claude"
[ -d "$HOME/.cursor" ] && INSTALLED="$INSTALLED cursor"
[ -d "$HOME/.codex" ] && INSTALLED="$INSTALLED codex"
[ -d "$HOME/.windsurf" ] && INSTALLED="$INSTALLED windsurf"
[ -d "$HOME/.copilot" ] && INSTALLED="$INSTALLED copilot"

if [ -z "$INSTALLED" ]; then
  echo "No supported coding agent detected. Installing to ~/.claude/skills/ by default."
  INSTALLED="claude"
fi

download_skill() {
  local dest_dir="$1"
  mkdir -p "$dest_dir/references"
  for file in "${SKILL_FILES[@]}"; do
    curl -fsSL "$DOCS_BASE/$file" -o "$dest_dir/$file"
  done
  echo "  Installed to $dest_dir"
}

echo "Installing Benchspan onboard-agent skill..."

for agent in $INSTALLED; do
  case "$agent" in
    claude)
      download_skill "$HOME/.claude/skills/onboard-agent"
      ;;
    cursor)
      # Cursor reads Agent Skills from .cursor/skills/ or project .cursor/rules/
      download_skill "$HOME/.cursor/skills/onboard-agent"
      ;;
    codex)
      # Codex reads AGENTS.md — install as a skill reference
      download_skill "$HOME/.codex/skills/onboard-agent"
      ;;
    windsurf)
      download_skill "$HOME/.windsurf/skills/onboard-agent"
      ;;
    copilot)
      download_skill "$HOME/.copilot/skills/onboard-agent"
      ;;
  esac
done

echo ""
echo "Done! Run /onboard-agent in your coding agent to get started."
