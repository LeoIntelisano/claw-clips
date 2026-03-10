#!/bin/bash
# ~/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# OpenClaw Safety Shim
# ═══════════════════════════════════════════════════════════════════════
#
# Named 'bash' so node's child_process resolves it via PATH lookup.
# Scoped exclusively to the openclaw-gateway systemd service via drop-in:
#   Environment="PATH=$HOME/bin:..."
# Has zero effect on interactive WSL sessions which use their own PATH.
#
# Three enforcement layers:
#   1. Hard-coded sensitive/destructive patterns (zero deps, instant)
#   2. JSONL deny rules from active.jsonl + pending.jsonl
#   3. Skill onboarding gate (blocks unonboarded skills)
#
# Logs all exec calls to $OC_DIR/safety-audit.log.
# Everything else passes through to /bin/bash.
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
OC_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
RULES_DIR="$OC_DIR/rules"
AUDIT="$OC_DIR/safety-audit.log"
ACTIVE_RULES="$RULES_DIR/active.jsonl"
PENDING_RULES="$RULES_DIR/pending.jsonl"
SKILLS_REG="$RULES_DIR/skills.json"
ONBOARD_PROMPT="$OC_DIR/prompts/onboard.md"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CMD="$*"

# ── Bootstrap (first run creates dirs/files) ───────────────────────────
mkdir -p "$RULES_DIR" "$OC_DIR/prompts" "$(dirname "$AUDIT")"
[ -f "$SKILLS_REG" ]    || echo '{}' > "$SKILLS_REG"
[ -f "$ACTIVE_RULES" ]  || touch "$ACTIVE_RULES"
[ -f "$PENDING_RULES" ] || touch "$PENDING_RULES"

# ── Logging ────────────────────────────────────────────────────────────
log() { echo "$TIMESTAMP | $1 | $CMD" >> "$AUDIT"; }

# ── Pass through login/interactive shell invocations ───────────────────
case "${1:-}" in
  -i|-l|--login|--norc|--noprofile)
    log "PASSTHROUGH_SHELL"
    exec /bin/bash "$@"
    ;;
esac

# Empty command — just pass through
[ -z "$CMD" ] && exec /bin/bash "$@"

# ═══════════════════════════════════════════════════════════════════════
# LAYER 1: Hard-coded patterns (zero-dependency, always runs first)
# ═══════════════════════════════════════════════════════════════════════

SENSITIVE_PATTERNS=(
  '\.ssh[/\\]'
  '\.gnupg[/\\]'
  '\.netrc'
  '\.aws/credentials'
  '\.aws/config'
  'id_rsa'
  'id_ed25519'
  'id_ecdsa'
  '\.pem$'
  '\.key$'
  '\.p12$'
  '\.pfx$'
  '/secrets/'
  '\.env$'
  '\.env\.'
  'keychain'
  'openclaw\.json'
)

for pattern in "${SENSITIVE_PATTERNS[@]}"; do
  if echo "$CMD" | grep -qiE "$pattern"; then
    log "HARD_DENY_SENSITIVE pattern=$pattern"
    echo "[safety] BLOCKED: command touches sensitive path: $pattern" >&2
    exit 1
  fi
done

DESTRUCTIVE_PATTERNS=(
  'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f'
  'rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r'
  'dd[[:space:]]+if='
  'mkfs\.'
  'mkswap'
  ':[[:space:]]*\(\)[[:space:]]*\{'
  'chmod[[:space:]]+-R[[:space:]]+777'
  'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'
  'wget[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'
  'nc[[:space:]]+-e'
  'ncat[[:space:]]+-e'
  '/dev/sd[a-z][[:space:]]'
  '/dev/nvme'
)

for pattern in "${DESTRUCTIVE_PATTERNS[@]}"; do
  if echo "$CMD" | grep -qE "$pattern"; then
    log "HARD_DENY_DESTRUCTIVE pattern=$pattern"
    echo "[safety] BLOCKED: destructive pattern detected: $pattern" >&2
    exit 1
  fi
done

# ═══════════════════════════════════════════════════════════════════════
# LAYER 2: JSONL deny rules
# ═══════════════════════════════════════════════════════════════════════
#
# active.jsonl  → enforces critical + high
# pending.jsonl → enforces ONLY critical (unreviewed agent proposals)
# ═══════════════════════════════════════════════════════════════════════

check_jsonl_rules() {
  local rules_file="$1"
  local source_label="$2"
  local min_severity="$3"

  [ -f "$rules_file" ] || return 0
  [ -s "$rules_file" ] || return 0
  command -v jq > /dev/null 2>&1 || return 0

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    [[ "$rule" == \#* ]] && continue

    local action severity pattern ptype reason rule_id
    action=$(echo "$rule"   | jq -r '.action   // empty' 2>/dev/null) || continue
    severity=$(echo "$rule" | jq -r '.severity // empty' 2>/dev/null) || continue
    pattern=$(echo "$rule"  | jq -r '.pattern  // empty' 2>/dev/null) || continue
    ptype=$(echo "$rule"    | jq -r '.type     // "contains"' 2>/dev/null)
    reason=$(echo "$rule"   | jq -r '.reason   // "no reason given"' 2>/dev/null)
    rule_id=$(echo "$rule"  | jq -r '.id       // "unknown"' 2>/dev/null)

    [ "$action" = "deny" ] || continue
    [ -n "$pattern" ]      || continue

    # Severity gate
    case "$min_severity" in
      critical) [ "$severity" = "critical" ] || continue ;;
      high)     case "$severity" in critical|high) ;; *) continue ;; esac ;;
      *)        continue ;;
    esac

    # Match
    local matched=false
    case "$ptype" in
      exact)    [[ "$CMD" == "$pattern" ]] && matched=true ;;
      contains) echo "$CMD" | grep -qi "$pattern" && matched=true ;;
      regex)    echo "$CMD" | grep -qE "$pattern" && matched=true ;;
    esac

    if $matched; then
      log "DENY_RULE source=$source_label id=$rule_id sev=$severity"
      echo "[safety] BLOCKED by $source_label rule [$rule_id]: $reason" >&2
      echo "[safety] Severity: $severity | Pattern: $pattern" >&2
      exit 1
    fi
  done < "$rules_file"
}

check_jsonl_rules "$ACTIVE_RULES"  "active"  "high"
check_jsonl_rules "$PENDING_RULES" "pending" "critical"

# ═══════════════════════════════════════════════════════════════════════
# LAYER 3: Skill onboarding gate
# ═══════════════════════════════════════════════════════════════════════
#
# Skill detection is DATA-DRIVEN from skills.json, not hardcoded.
#
# skills.json format:
# {
#   "gog-secure": {
#     "detect": ["gmail", "calendar", "google.mail", "events.list", ...],
#     "onboarded": "2026-03-10T14:22:00Z",
#     "status": "active",
#     "capabilities": ["email", "calendar"]
#   }
# }
#
# To add a new skill's detection patterns, use claw-clips:
#   claw-clips skills add myskill --detect "pattern1,pattern2,..."
#
# Unonboarded skills have no entry at all. The shim scans all
# registered skill detect patterns; if none match, the command
# passes through (it's a regular bash command, not a skill call).
# If one DOES match but the skill isn't marked onboarded, we block.
# ═══════════════════════════════════════════════════════════════════════

detect_skill() {
  command -v jq > /dev/null 2>&1 || return

  local cmd_lower
  cmd_lower=$(echo "$CMD" | tr '[:upper:]' '[:lower:]')

  # Iterate registered skills and their detect patterns
  local skill_names
  skill_names=$(jq -r 'keys[]' "$SKILLS_REG" 2>/dev/null) || return

  for skill_name in $skill_names; do
    local patterns
    patterns=$(jq -r --arg s "$skill_name" \
      '.[$s].detect // [] | .[]' "$SKILLS_REG" 2>/dev/null) || continue

    for pat in $patterns; do
      if [[ "$cmd_lower" == *"$pat"* ]]; then
        echo "$skill_name"
        return
      fi
    done
  done

  # ── Catch-all: unregistered skill keywords ────────────────────────
  # If the command contains known API-like patterns but NO registered
  # skill matched, treat it as an unknown skill that needs onboarding.
  # This list is intentionally broad — better to gate than to miss.
  local CATCH_ALL=(
    "gmail" "calendar" "drive" "sheets" "docs" "slack"
    "asana" "jira" "github" "notion" "discord" "trello"
    "messages.list" "messages.send" "messages.delete"
    "events.list" "events.insert" "events.delete"
    "files.list" "files.create" "files.delete"
  )
  for pat in "${CATCH_ALL[@]}"; do
    if [[ "$cmd_lower" == *"$pat"* ]]; then
      echo "__unknown__:$pat"
      return
    fi
  done
}

DETECTED=$(detect_skill)

if [ -n "$DETECTED" ]; then
  if [[ "$DETECTED" == __unknown__:* ]]; then
    # Matched a catch-all but no registered skill — block
    matched_pat="${DETECTED#__unknown__:}"
    log "BLOCKED_UNKNOWN_SKILL matched=$matched_pat"
    cat >&2 << 'EOF'
[safety] ═══════════════════════════════════════════════════════════════
[safety] BLOCKED: This command matches a known API/skill pattern but
[safety] no registered skill was found for it.
[safety]
[safety] Before using any new tool integration, you must:
[safety]
[safety]   1. Register the skill with detection patterns:
[safety]      Run: claw-clips skills add <skill_name> --detect "pattern1,pattern2"
[safety]
[safety]   2. Analyze the skill for safety risks by reading the onboarding
[safety]      prompt at: ~/.openclaw/prompts/onboard.md
[safety]      Generate JSONL deny rules and append them (one per line) to:
[safety]      ~/.openclaw/rules/pending.jsonl
[safety]
[safety]   3. Complete onboarding:
[safety]      Run: claw-clips skills onboard <skill_name>
[safety]
[safety] This is a ONE-TIME process per skill. After onboarding, all
[safety] commands for this skill will be allowed (subject to deny rules).
[safety] ═══════════════════════════════════════════════════════════════
EOF
    exit 1

  else
    # Known skill — check onboarded status
    skill_status=$(jq -r --arg s "$DETECTED" \
      '.[$s].status // "unregistered"' "$SKILLS_REG" 2>/dev/null)

    case "$skill_status" in
      active|probation)
        # Onboarded — proceed (rules already checked in Layer 2)
        ;;
      disabled)
        log "BLOCKED_DISABLED_SKILL skill=$DETECTED"
        echo "[safety] BLOCKED: Skill '$DETECTED' is disabled." >&2
        exit 1
        ;;
      *)
        # Registered but not onboarded
        log "BLOCKED_NOT_ONBOARDED skill=$DETECTED"
        cat >&2 << EOF
[safety] ═══════════════════════════════════════════════════════════════
[safety] BLOCKED: Skill '$DETECTED' is registered but not yet onboarded.
[safety]
[safety] To complete onboarding:
[safety]   1. Read the onboarding prompt at: $ONBOARD_PROMPT
[safety]   2. Analyze the skill's API surface for destructive actions
[safety]   3. Generate deny rules and append to: $PENDING_RULES
[safety]   4. Run: claw-clips skills onboard $DETECTED
[safety]
[safety] This is a ONE-TIME process. The skill will start in 'probation'
[safety] status where only critical rules are enforced.
[safety] ═══════════════════════════════════════════════════════════════
EOF
        exit 1
        ;;
    esac
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# ALL CHECKS PASSED
# ═══════════════════════════════════════════════════════════════════════

log "ALLOWED"
exec /bin/bash "$@"