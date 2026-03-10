#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# install-guardrails.sh — Install OpenClaw safety guardrails
# ═══════════════════════════════════════════════════════════════════════
#
# This script:
#   1. Creates the directory structure
#   2. Installs the safety shim at ~/bin/bash
#   3. Installs claw-clips at ~/bin/claw-clips
#   4. Sets correct file permissions
#   5. Seeds initial rules and skills registry
#   6. Verifies the installation
#
# Usage: bash install-guardrails.sh
#
# IMPORTANT: This replaces ~/bin/bash. Back up your existing shim first
# if you have modifications not captured here.
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[91m'; GREEN='\033[92m'; YELLOW='\033[93m'
CYAN='\033[96m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$HOME/.openclaw"
BIN_DIR="$HOME/bin"

info()  { echo -e "${GREEN}  ✓ $*${RESET}"; }
warn()  { echo -e "${YELLOW}  ! $*${RESET}"; }
err()   { echo -e "${RED}  ✗ $*${RESET}"; }
step()  { echo -e "\n${BOLD}$*${RESET}"; }

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  OpenClaw Safety Guardrails — Installer${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"

# ── Step 1: Check dependencies ─────────────────────────────────────

step "1. Checking dependencies"

for dep in jq bash; do
  if command -v "$dep" > /dev/null 2>&1; then
    info "$dep found: $(command -v "$dep")"
  else
    err "$dep not found. Install: sudo apt install $dep"
    exit 1
  fi
done

# ── Step 2: Create directory structure ─────────────────────────────

step "2. Creating directory structure"

mkdir -p "$OC_DIR/rules"
mkdir -p "$OC_DIR/prompts"
mkdir -p "$BIN_DIR"

info "$OC_DIR/rules/"
info "$OC_DIR/prompts/"
info "$BIN_DIR/"

# ── Step 3: Install files ─────────────────────────────────────────

step "3. Installing files"

# Back up existing shim if present
if [ -f "$BIN_DIR/bash" ]; then
  cp "$BIN_DIR/bash" "$BIN_DIR/bash.bak.$(date +%Y%m%d%H%M%S)"
  warn "Backed up existing ~/bin/bash"
fi

cp "$SRC_DIR/safety-shim.sh"   "$BIN_DIR/bash"
cp "$SRC_DIR/claw-clips.sh"      "$BIN_DIR/claw-clips"
cp "$SRC_DIR/onboard-prompt.md" "$OC_DIR/prompts/onboard.md"

info "~/bin/bash          (safety shim)"
info "~/bin/claw-clips      (CLI manager)"
info "~/.openclaw/prompts/onboard.md"

# ── Step 4: Seed rules and registry (only if not already present) ──

step "4. Seeding rules and registry"

if [ ! -s "$OC_DIR/rules/active.jsonl" ]; then
  cp "$SRC_DIR/rules/active.jsonl" "$OC_DIR/rules/active.jsonl"
  info "Seeded active.jsonl with initial rules"
else
  warn "active.jsonl already exists — skipping seed"
fi

if [ ! -s "$OC_DIR/rules/pending.jsonl" ]; then
  touch "$OC_DIR/rules/pending.jsonl"
  info "Created empty pending.jsonl"
else
  warn "pending.jsonl already exists — skipping"
fi

if [ ! -s "$OC_DIR/rules/skills.json" ]; then
  cp "$SRC_DIR/rules/skills.json" "$OC_DIR/rules/skills.json"
  info "Seeded skills.json with gog-secure"
else
  warn "skills.json already exists — skipping seed"
fi

# ── Step 5: Set permissions ────────────────────────────────────────

step "5. Setting file permissions"

# ── Executables ──
chmod 755 "$BIN_DIR/bash"
chmod 755 "$BIN_DIR/claw-clips"
info "~/bin/bash           755 (rwxr-xr-x)  — executable"
info "~/bin/claw-clips       755 (rwxr-xr-x)  — executable"

# ── Rules directory ──
# The agent runs as your user, so we can't use Unix permissions
# alone to enforce read-only on active.jsonl (same UID).
#
# Strategy: set active.jsonl to read-only. The shim and claw-clips run
# as your user too, but claw-clips explicitly chmod's when it needs to write.
# The agent (via the shim) never has a code path that writes to active.
#
# For real enforcement: the shim is the ONLY writer to active.jsonl,
# and it only does so via claw-clips commands (which are human-invoked).
# The agent can only append to pending.jsonl.

chmod 444 "$OC_DIR/rules/active.jsonl"
info "active.jsonl         444 (r--r--r--)  — read-only"
echo -e "  ${DIM}  The agent cannot modify this file. Only claw-clips can (with chmod).${RESET}"
echo -e "  ${DIM}  claw-clips promote/demote/delete temporarily chmod 644 then restores 444.${RESET}"

chmod 644 "$OC_DIR/rules/pending.jsonl"
info "pending.jsonl        644 (rw-r--r--)  — agent can append"

chmod 644 "$OC_DIR/rules/skills.json"
info "skills.json          644 (rw-r--r--)  — writable for onboarding"

chmod 644 "$OC_DIR/prompts/onboard.md"
info "onboard.md           644 (rw-r--r--)  — readable by agent"

# ── Audit log ──
touch "$OC_DIR/safety-audit.log"
chmod 644 "$OC_DIR/safety-audit.log"
info "safety-audit.log     644 (rw-r--r--)  — append by shim"

# ── Step 6: Patch claw-clips to handle read-only active.jsonl ────────

step "6. Verifying installation"

# Verify shim can be executed
if bash "$BIN_DIR/bash" -c "echo test" > /dev/null 2>&1; then
  info "Shim executes correctly"
else
  err "Shim failed to execute"
fi

# Verify claw-clips
if bash "$BIN_DIR/claw-clips" help > /dev/null 2>&1; then
  info "claw-clips help runs"
else
  err "claw-clips failed"
fi

# Verify jq can read skills.json
if jq -e '.' "$OC_DIR/rules/skills.json" > /dev/null 2>&1; then
  info "skills.json is valid JSON"
else
  err "skills.json is invalid"
fi

# Verify active.jsonl is read-only
if [ ! -w "$OC_DIR/rules/active.jsonl" ]; then
  info "active.jsonl is read-only"
else
  warn "active.jsonl is writable — expected read-only"
fi

# Count rules
active_count=$(grep -c . "$OC_DIR/rules/active.jsonl" 2>/dev/null || echo 0)
info "Active rules: $active_count"

# Show skills
echo ""
echo -e "${DIM}  Registered skills:${RESET}"
jq -r 'to_entries[] | "    \(.key): \(.value.status)"' "$OC_DIR/rules/skills.json"

# ── Summary ────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}File layout:${RESET}"
echo -e "  ~/bin/bash                          ${DIM}safety shim (755)${RESET}"
echo -e "  ~/bin/claw-clips                      ${DIM}CLI tool (755)${RESET}"
echo -e "  ~/.openclaw/rules/active.jsonl      ${DIM}enforced rules (444 read-only)${RESET}"
echo -e "  ~/.openclaw/rules/pending.jsonl     ${DIM}agent proposals (644)${RESET}"
echo -e "  ~/.openclaw/rules/skills.json       ${DIM}skill registry (644)${RESET}"
echo -e "  ~/.openclaw/prompts/onboard.md      ${DIM}onboarding prompt (644)${RESET}"
echo -e "  ~/.openclaw/safety-audit.log        ${DIM}audit trail (644)${RESET}"
echo ""
echo -e "  ${BOLD}Quick start:${RESET}"
echo -e "  claw-clips help                 ${DIM}show all commands${RESET}"
echo -e "  claw-clips list                 ${DIM}show all rules${RESET}"
echo -e "  claw-clips skills               ${DIM}show registered skills${RESET}"
echo -e "  claw-clips test \"some command\"  ${DIM}dry-run against rules${RESET}"
echo -e "  claw-clips tail                 ${DIM}recent audit log${RESET}"
echo ""
echo -e "  ${BOLD}To add MEMORY.md entry, add this to the agent's MEMORY.md:${RESET}"
echo ""
cat << 'MEMORY'
  ## Safety Shim

  All exec commands go through a safety shim at ~/bin/bash.
  If a skill hasn't been onboarded, the shim will block the command
  and tell you what to do. Follow the shim's instructions exactly.

  You can propose new deny rules by appending JSONL to:
    ~/.openclaw/rules/pending.jsonl
  You can read the onboarding template at:
    ~/.openclaw/prompts/onboard.md
  You can read the audit log at:
    ~/.openclaw/safety-audit.log

  You CANNOT modify ~/.openclaw/rules/active.jsonl — it is read-only.
  Only the human operator can promote, demote, or delete rules.
MEMORY
echo ""