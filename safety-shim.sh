#!/bin/bash
# ~/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Claw-Clips Safety Shim
# ═══════════════════════════════════════════════════════════════════════
#
# Named 'bash' so node's child_process resolves it via PATH lookup.
# Scoped exclusively to the agent's systemd service via drop-in:
#   Environment="PATH=$HOME/bin:..."
# Has zero effect on interactive shell sessions which use their own PATH.
#
# Three enforcement layers:
#   1. Hard-coded sensitive/destructive patterns (zero deps, instant)
#   2. JSONL deny rules from active.jsonl + pending.jsonl
#   3. Default-deny: skill gate + infrastructure allowlist
#      - Known skill + onboarded → allow (subject to deny rules)
#      - Known skill + hash changed → block (re-onboard required)
#      - Known skill + not onboarded → block with instructions
#      - Not a skill + on allowlist → allow (infrastructure commands)
#      - Not a skill + not on allowlist → BLOCK
#
# Logs all exec calls to $OC_DIR/safety-audit.log.
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
OC_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
CC_DIR="$OC_DIR/claw-clips"
RULES_DIR="$CC_DIR"
AUDIT="$CC_DIR/safety-audit.log"
ACTIVE_RULES="$RULES_DIR/active.jsonl"
PENDING_RULES="$RULES_DIR/pending.jsonl"
SKILLS_REG="$RULES_DIR/skills.json"
ALLOWLIST="$RULES_DIR/allowlist.jsonl"
ONBOARD_PROMPT="$CC_DIR/onboard.md"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CMD="$*"

# ── Bootstrap ──────────────────────────────────────────────────────────
mkdir -p "$CC_DIR" "$(dirname "$AUDIT")"
if [ ! -s "$SKILLS_REG" ]; then
  chmod 644 "$SKILLS_REG" 2>/dev/null || true
  echo '{}' > "$SKILLS_REG"
fi
[ -f "$ACTIVE_RULES" ]  || touch "$ACTIVE_RULES"
[ -f "$PENDING_RULES" ] || touch "$PENDING_RULES"
[ -f "$ALLOWLIST" ]     || touch "$ALLOWLIST"

# ── Logging ────────────────────────────────────────────────────────────
log() { echo "$TIMESTAMP | $1 | $CMD" >> "$AUDIT"; }

# ── Pass through login/interactive shell invocations ───────────────────
case "${1:-}" in
  -i|-l|--login|--norc|--noprofile)
    log "PASSTHROUGH_SHELL"
    exec /bin/bash "$@"
    ;;
esac

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

check_jsonl_rules() {
  local rules_file="$1"
  local source_label="$2"
  local min_severity="$3"
  local skill_filter="${4:-}"    # if set, only evaluate _meta + this skill's rules

  [ -f "$rules_file" ] || return 0
  [ -s "$rules_file" ] || return 0
  command -v jq > /dev/null 2>&1 || return 0

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    [[ "$rule" == \#* ]] && continue

    local action severity pattern ptype reason rule_id rule_skill
    action=$(echo "$rule"   | jq -r '.action   // empty' 2>/dev/null) || continue
    severity=$(echo "$rule" | jq -r '.severity // empty' 2>/dev/null) || continue
    pattern=$(echo "$rule"  | jq -r '.pattern  // empty' 2>/dev/null) || continue
    ptype=$(echo "$rule"    | jq -r '.type     // "contains"' 2>/dev/null)
    reason=$(echo "$rule"   | jq -r '.reason   // "no reason given"' 2>/dev/null)
    rule_id=$(echo "$rule"  | jq -r '.id       // "unknown"' 2>/dev/null)
    rule_skill=$(echo "$rule" | jq -r '.skill  // ""' 2>/dev/null)

    # Scope: if a skill filter is set, only check _meta rules and rules for that skill
    if [ -n "$skill_filter" ] && [ "$rule_skill" != "_meta" ] && [ "$rule_skill" != "$skill_filter" ]; then
      continue
    fi

    if [ "$action" = "flag" ]; then
     # Log but don't block
     log "FLAGGED_RULE source=$source_label id=$rule_id sev=$severity reason=$reason"
     continue
    fi

    [ "$action" = "deny" ] || continue
    [ -n "$pattern" ]      || continue

    case "$min_severity" in
      critical) [ "$severity" = "critical" ] || continue ;;
      high)     case "$severity" in critical|high) ;; *) continue ;; esac ;;
      *)        continue ;;
    esac

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

# ═══════════════════════════════════════════════════════════════════════
# SKILL DETECTION (run early so Layer 2 can scope rules by skill)
# ═══════════════════════════════════════════════════════════════════════

detect_skill() {
  command -v jq > /dev/null 2>&1 || return

  local cmd_lower
  cmd_lower=$(echo "$CMD" | tr '[:upper:]' '[:lower:]')

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
}

# Detect skill early so we can scope Layer 2 rules
DETECTED=$(detect_skill)

# ═══════════════════════════════════════════════════════════════════════
# LAYER 2: JSONL deny rules (scoped to _meta + detected skill)
# ═══════════════════════════════════════════════════════════════════════

# If no skill detected, only _meta rules apply (Layer 1 already covers
# hard-coded sensitive/destructive patterns for infra commands).
RULE_SCOPE="${DETECTED:-_meta}"

check_jsonl_rules "$ACTIVE_RULES"  "active"  "high"    "$RULE_SCOPE"
check_jsonl_rules "$PENDING_RULES" "pending" "critical" "$RULE_SCOPE"

# ═══════════════════════════════════════════════════════════════════════
# LAYER 3: Default-deny with skill gate + infrastructure allowlist
# ═══════════════════════════════════════════════════════════════════════

check_allowlist() {
  [ -f "$ALLOWLIST" ] || return 1
  [ -s "$ALLOWLIST" ] || return 1

  local check_cmd="$CMD"
  if [[ "$check_cmd" == -c\ * ]]; then
    check_cmd="${check_cmd#-c }"
  fi

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    [[ "$rule" == \#* ]] && continue

    local pattern ptype
    if command -v jq > /dev/null 2>&1; then
      pattern=$(echo "$rule" | jq -r '.pattern // empty' 2>/dev/null) || continue
      ptype=$(echo "$rule" | jq -r '.type // "regex"' 2>/dev/null)
    else
      continue
    fi

    [ -n "$pattern" ] || continue

    case "$ptype" in
      exact)    [[ "$check_cmd" == "$pattern" ]] && return 0 ;;
      contains) echo "$check_cmd" | grep -qi "$pattern" && return 0 ;;
      regex)    echo "$check_cmd" | grep -qE "$pattern" && return 0 ;;
    esac
  done < "$ALLOWLIST"

  return 1
}

check_skill_hash() {
  # Verify a skill's definition file hasn't changed since onboarding.
  # Returns 0 if hash matches or no hash stored, 1 if changed.
  local skill_name="$1"
  command -v jq > /dev/null 2>&1 || return 0

  local stored_hash skill_file
  stored_hash=$(jq -r --arg s "$skill_name" '.[$s].hash // empty' "$SKILLS_REG" 2>/dev/null)
  skill_file=$(jq -r --arg s "$skill_name" '.[$s].skill_file // empty' "$SKILLS_REG" 2>/dev/null)

  # No hash stored or no file tracked → skip check (backward compatible)
  [ -n "$stored_hash" ] || return 0
  [ -n "$skill_file" ]  || return 0
  [ -f "$skill_file" ]  || return 0

  local current_hash
  current_hash=$(sha256sum "$skill_file" 2>/dev/null | cut -d' ' -f1)

  [ "$stored_hash" = "$current_hash" ]
}

if [ -n "$DETECTED" ]; then
  skill_status=$(jq -r --arg s "$DETECTED" \
    '.[$s].status // "unregistered"' "$SKILLS_REG" 2>/dev/null)

  case "$skill_status" in
    active|probation)
      # Check if skill definition has changed since onboarding
      if ! check_skill_hash "$DETECTED"; then
        log "BLOCKED_HASH_CHANGED skill=$DETECTED"
        cat >&2 << EOF
[safety] BLOCKED: Skill '$DETECTED' definition has changed since onboarding.
[safety]
[safety] The skill file has been modified since this skill was last onboarded.
[safety] This could be a minor formatting change or a significant capability addition.
[safety]
[safety] ASK THE USER which action to take:
[safety]
[safety]   Option A — Minor/cosmetic change (no new capabilities):
[safety]     The operator runs: claw-clips skills rehash $DETECTED
[safety]     This updates the stored hash and resumes normal operation.
[safety]
[safety]   Option B — Significant change (new capabilities or permissions):
[safety]     The operator runs: claw-clips skills set $DETECTED registered
[safety]     Then complete the full onboarding process again to generate
[safety]     deny rules covering the new capabilities.
[safety]
[safety] Do NOT attempt to rehash or re-onboard yourself. Present both
[safety] options to the user and wait for their decision.
EOF
        exit 1
      fi
      log "ALLOWED skill=$DETECTED"
      exec /bin/bash "$@"
      ;;
    disabled)
      log "BLOCKED_DISABLED_SKILL skill=$DETECTED"
      echo "[safety] BLOCKED: Skill '$DETECTED' is disabled." >&2
      exit 1
      ;;
    *)
      log "BLOCKED_NOT_ONBOARDED skill=$DETECTED"
      cat >&2 << EOF
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
EOF
      exit 1
      ;;
  esac

else
  if check_allowlist; then
    log "ALLOWED infra"
    exec /bin/bash "$@"
  else
    log "BLOCKED_DEFAULT_DENY"
    cat >&2 << 'EOF'
[safety] BLOCKED: Command not recognized as a registered skill or
[safety] allowed infrastructure command.
[safety]
[safety] If this is a new tool/skill:
[safety]   claw-clips skills add <name> --detect "pattern1,pattern2"
[safety]   Then complete the onboarding process.
[safety]
[safety] If this is a safe infrastructure command:
[safety]   Ask the operator to add it to the allowlist.
EOF
    exit 1
  fi
fi