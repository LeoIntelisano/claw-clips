#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# claw-clips — CLI for managing OpenClaw safety rules
# ═══════════════════════════════════════════════════════════════════════
#
# Install: cp claw-clips.sh ~/bin/claw-clips && chmod +x ~/bin/claw-clips
#
# This tool manages:
#   - JSONL deny rules (active + pending)
#   - Skill registration and onboarding
#   - Audit log viewing
#   - Rule overlap / bloat detection
#   - Testing (dry-run commands against rules)
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

OC_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
CC_DIR="$OC_DIR/claw-clips"
RULES_DIR="$CC_DIR"
ACTIVE="$RULES_DIR/active.jsonl"
PENDING="$RULES_DIR/pending.jsonl"
SKILLS_REG="$RULES_DIR/skills.json"
AUDIT="$CC_DIR/safety-audit.log"
ONBOARD_PROMPT="$CC_DIR/onboard.md"

RED='\033[91m'; YELLOW='\033[93m'; GREEN='\033[92m'
CYAN='\033[96m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

mkdir -p "$CC_DIR"
[ -f "$ACTIVE" ]     || touch "$ACTIVE"
[ -f "$PENDING" ]    || touch "$PENDING"
[ -f "$SKILLS_REG" ] || echo '{}' > "$SKILLS_REG"

# ── Helpers ────────────────────────────────────────────────────────────

die()  { echo -e "${RED}Error: $*${RESET}" >&2; exit 1; }
info() { echo -e "${GREEN}$*${RESET}"; }
warn() { echo -e "${YELLOW}$*${RESET}"; }

need_jq() { command -v jq > /dev/null 2>&1 || die "jq is required. Install: sudo apt install jq"; }

# active.jsonl and skills.json are set 444 (read-only) to prevent agent writes.
# claw-clips needs to temporarily unlock them for modifications.
unlock_active() { chmod 644 "$ACTIVE" 2>/dev/null || true; }
lock_active()   { chmod 444 "$ACTIVE" 2>/dev/null || true; }
unlock_skills() { chmod 644 "$SKILLS_REG" 2>/dev/null || true; }
lock_skills()   { chmod 444 "$SKILLS_REG" 2>/dev/null || true; }


severity_color() {
  case "$1" in
    critical) echo -e "${RED}$1${RESET}" ;;
    high)     echo -e "${YELLOW}$1${RESET}" ;;
    medium)   echo -e "${CYAN}$1${RESET}" ;;
    low)      echo -e "${DIM}$1${RESET}" ;;
    *)        echo "$1" ;;
  esac
}

source_color() {
  case "$1" in
    active)  echo -e "${GREEN}$1${RESET}" ;;
    pending) echo -e "${YELLOW}$1${RESET}" ;;
    *)       echo "$1" ;;
  esac
}

print_rule() {
  local rule="$1" source="$2"
  local id sev skill pattern reason author reviewed ptype
  id=$(echo "$rule"       | jq -r '.id // "?"')
  sev=$(echo "$rule"      | jq -r '.severity // "?"')
  skill=$(echo "$rule"    | jq -r '.skill // "?"')
  pattern=$(echo "$rule"  | jq -r '.pattern // "?"')
  reason=$(echo "$rule"   | jq -r '.reason // ""')
  author=$(echo "$rule"   | jq -r '.author // "?"')
  reviewed=$(echo "$rule" | jq -r '.reviewed // false')
  ptype=$(echo "$rule"    | jq -r '.type // "contains"')

  local rev_mark
  [ "$reviewed" = "true" ] && rev_mark="${GREEN}✓${RESET}" || rev_mark="${DIM}·${RESET}"

  printf "  %-14s %-10b %-10s %-10b %b  %-10s %s\n" \
    "$id" "$(severity_color "$sev")" "$skill" "$(source_color "$source")" \
    "$rev_mark" "[$ptype]" "$pattern"
  [ -n "$reason" ] && echo -e "  ${DIM}               └─ $reason${RESET}"
}

count_lines() { grep -c . "$1" 2>/dev/null || echo 0; }

# ═══════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════

# ── list ───────────────────────────────────────────────────────────────

cmd_list() {
  need_jq
  local show_active=true show_pending=true
  local filter_skill="" filter_severity=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --active)   show_pending=false; shift ;;
      --pending)  show_active=false;  shift ;;
      --skill)    filter_skill="$2";  shift 2 ;;
      --severity) filter_severity="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  echo ""
  echo -e "${BOLD}  ID             Severity   Skill      Source     Rev Type       Pattern${RESET}"
  echo "  ──────────────────────────────────────────────────────────────────────────"

  local count=0
  local _filter_and_print='
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      [[ "$rule" == \#* ]] && continue
      if [ -n "$filter_skill" ]; then
        [ "$(echo "$rule" | jq -r ".skill // \"\"")" = "$filter_skill" ] || continue
      fi
      if [ -n "$filter_severity" ]; then
        [ "$(echo "$rule" | jq -r ".severity // \"\"")" = "$filter_severity" ] || continue
      fi
      print_rule "$rule" "$1"
      ((count++))
    done < "$2"
  '

  if $show_active && [ -s "$ACTIVE" ]; then
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      [[ "$rule" == \#* ]] && continue
      if [ -n "$filter_skill" ]; then
        [ "$(echo "$rule" | jq -r '.skill // ""')" = "$filter_skill" ] || continue
      fi
      if [ -n "$filter_severity" ]; then
        [ "$(echo "$rule" | jq -r '.severity // ""')" = "$filter_severity" ] || continue
      fi
      print_rule "$rule" "active"
      ((count++)) || true
    done < "$ACTIVE"
  fi

  if $show_pending && [ -s "$PENDING" ]; then
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      [[ "$rule" == \#* ]] && continue
      if [ -n "$filter_skill" ]; then
        [ "$(echo "$rule" | jq -r '.skill // ""')" = "$filter_skill" ] || continue
      fi
      if [ -n "$filter_severity" ]; then
        [ "$(echo "$rule" | jq -r '.severity // ""')" = "$filter_severity" ] || continue
      fi
      print_rule "$rule" "pending"
      ((count++)) || true
    done < "$PENDING"
  fi

  echo ""
  echo -e "  ${DIM}$count rules shown${RESET}"
  echo ""
}

# ── promote ────────────────────────────────────────────────────────────

cmd_promote() {
  need_jq
  local target="${1:-}"
  local filter_skill=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skill) filter_skill="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -n "$target" ] || die "Usage: claw-clips promote <rule_id|--all> [--skill NAME]"

  unlock_active


  local promoted=0
  local temp
  temp=$(mktemp)

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    local rid rskill
    rid=$(echo "$rule" | jq -r '.id // ""')
    rskill=$(echo "$rule" | jq -r '.skill // ""')

    local dominated=false
    if [ "$target" = "--all" ]; then
      if [ -z "$filter_skill" ] || [ "$rskill" = "$filter_skill" ]; then
        do_promote=true
      else
        do_promote=false
      fi
    else
      [ "$rid" = "$target" ] && do_promote=true || do_promote=false
    fi

    if $do_promote; then
      echo "$rule" | jq -c '.reviewed = true' >> "$ACTIVE"
      ((promoted++)) || true
    else
      echo "$rule" >> "$temp"
    fi
  done < "$PENDING"

  mv "$temp" "$PENDING"
  lock_active
  info "Promoted $promoted rule(s) to active."
}

# ── demote ─────────────────────────────────────────────────────────────

cmd_demote() {
  need_jq
  local target="${1:-}"
  [ -n "$target" ] || die "Usage: claw-clips demote <rule_id>"

  unlock_active


  local found=false temp
  temp=$(mktemp)

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    local rid
    rid=$(echo "$rule" | jq -r '.id // ""')
    if [ "$rid" = "$target" ]; then
      echo "$rule" | jq -c '.reviewed = false' >> "$PENDING"
      found=true
    else
      echo "$rule" >> "$temp"
    fi
  done < "$ACTIVE"

  mv "$temp" "$ACTIVE"
  lock_active
  $found && info "Demoted $target to pending." || die "Rule $target not found in active."
}

# ── delete ─────────────────────────────────────────────────────────────

cmd_delete() {
  need_jq
  local target="${1:-}"
  [ -n "$target" ] || die "Usage: claw-clips delete <rule_id>"

  unlock_active


  local found=false
  for f in "$ACTIVE" "$PENDING"; do
    local temp
    temp=$(mktemp)
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      local rid
      rid=$(echo "$rule" | jq -r '.id // ""')
      if [ "$rid" = "$target" ]; then
        found=true
        local src
        [ "$f" = "$ACTIVE" ] && src="active" || src="pending"
        warn "Deleted $target from $src."
      else
        echo "$rule" >> "$temp"
      fi
    done < "$f"
    mv "$temp" "$f"
  done

  lock_active
  $found || die "Rule $target not found."
}

# ── edit ───────────────────────────────────────────────────────────────

cmd_edit() {
  need_jq
  local target="${1:-}"
  [ -n "$target" ] || die "Usage: claw-clips edit <rule_id>"

  unlock_active


  for f in "$ACTIVE" "$PENDING"; do
    if grep -q "\"$target\"" "$f" 2>/dev/null; then
      local temp_edit
      temp_edit=$(mktemp --suffix=.json)
      grep "\"$target\"" "$f" | head -1 | jq '.' > "$temp_edit"
      ${EDITOR:-vim} "$temp_edit"

      # Validate JSON
      jq '.' "$temp_edit" > /dev/null 2>&1 || die "Invalid JSON after edit."
      local new_rule
      new_rule=$(jq -c '.' "$temp_edit")

      local temp_file
      temp_file=$(mktemp)
      while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        local rid
        rid=$(echo "$rule" | jq -r '.id // ""' 2>/dev/null)
        if [ "$rid" = "$target" ]; then
          echo "$new_rule" >> "$temp_file"
        else
          echo "$rule" >> "$temp_file"
        fi
      done < "$f"
      mv "$temp_file" "$f"
      rm -f "$temp_edit"
      lock_active
      info "Updated rule $target."
      return
    fi
  done
  die "Rule $target not found."
}

# ── stats ──────────────────────────────────────────────────────────────

cmd_stats() {
  need_jq
  echo ""
  echo -e "${BOLD}  Rule Statistics${RESET}"
  echo "  ──────────────────────────────────────"
  echo -e "  Active rules:   ${GREEN}$(count_lines "$ACTIVE")${RESET}"
  echo -e "  Pending rules:  ${YELLOW}$(count_lines "$PENDING")${RESET}"

  echo ""
  echo -e "  ${BOLD}By skill:${RESET}"
  cat "$ACTIVE" "$PENDING" 2>/dev/null | jq -r '.skill // "?"' | \
    sort | uniq -c | sort -rn | while read -r cnt sk; do
      printf "    %-14s %s\n" "$sk" "$cnt"
    done

  echo ""
  echo -e "  ${BOLD}By severity:${RESET}"
  cat "$ACTIVE" "$PENDING" 2>/dev/null | jq -r '.severity // "?"' | \
    sort | uniq -c | sort -rn | while read -r cnt sv; do
      printf "    %-14b %s\n" "$(severity_color "$sv")" "$cnt"
    done

  echo ""
  echo -e "  ${BOLD}By author:${RESET}"
  cat "$ACTIVE" "$PENDING" 2>/dev/null | jq -r '.author // "?"' | \
    sort | uniq -c | sort -rn | while read -r cnt au; do
      printf "    %-14s %s\n" "$au" "$cnt"
    done
  echo ""
}

# ── bloat ──────────────────────────────────────────────────────────────

cmd_bloat() {
  need_jq
  echo ""
  echo -e "${BOLD}  Checking for overlapping rules...${RESET}"
  echo ""

  local all_rules=()
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    all_rules+=("$rule")
  done < <(cat "$ACTIVE" "$PENDING" 2>/dev/null)

  local issues=0
  local total=${#all_rules[@]}

  for ((i=0; i<total; i++)); do
    local p1 s1 id1
    p1=$(echo "${all_rules[$i]}" | jq -r '.pattern // ""')
    s1=$(echo "${all_rules[$i]}" | jq -r '.skill // ""')
    id1=$(echo "${all_rules[$i]}" | jq -r '.id // ""')

    for ((j=i+1; j<total; j++)); do
      local p2 s2 id2
      p2=$(echo "${all_rules[$j]}" | jq -r '.pattern // ""')
      s2=$(echo "${all_rules[$j]}" | jq -r '.skill // ""')
      id2=$(echo "${all_rules[$j]}" | jq -r '.id // ""')

      [ "$s1" = "$s2" ] || continue

      if [[ "$p1" == *"$p2"* ]] || [[ "$p2" == *"$p1"* ]]; then
        echo -e "  ${YELLOW}Overlap:${RESET} $id1 ↔ $id2  (skill: $s1)"
        echo -e "    ${DIM}$id1: $p1${RESET}"
        echo -e "    ${DIM}$id2: $p2${RESET}"
        ((issues++)) || true
      fi
    done
  done

  [ "$issues" -eq 0 ] && info "  No overlaps found." || warn "  $issues overlap(s) found."
  echo ""
}

# ── skills ─────────────────────────────────────────────────────────────

cmd_skills() {
  need_jq
  local subcmd="${1:-list}"
  shift || true

  case "$subcmd" in

    list)
      echo ""
      echo -e "${BOLD}  Onboarded Skills${RESET}"
      echo "  ──────────────────────────────────────────────────────────"

      local skill_count
      skill_count=$(jq 'length' "$SKILLS_REG")

      if [ "$skill_count" = "0" ]; then
        echo -e "  ${DIM}No skills registered yet.${RESET}"
        echo -e "  ${DIM}Use: claw-clips skills add <name> --detect \"pat1,pat2\"${RESET}"
      else
        jq -r 'to_entries[] |
          "\(.key)\t\(.value.status // "registered")\t\(.value.onboarded // "-")\t\(.value.capabilities // [] | join(","))\t\(.value.detect // [] | length)"' \
          "$SKILLS_REG" | \
        while IFS=$'\t' read -r name status onboarded caps ndetect; do
          local sc
          case "$status" in
            active)     sc="${GREEN}$status${RESET}" ;;
            probation)  sc="${YELLOW}$status${RESET}" ;;
            disabled)   sc="${RED}$status${RESET}" ;;
            registered) sc="${DIM}$status${RESET}" ;;
            *)          sc="$status" ;;
          esac
          printf "  %-14s %-18b onboarded: %-22s caps: %-16s detect: %s patterns\n" \
            "$name" "$sc" "$onboarded" "${caps:--}" "$ndetect"
        done
      fi
      echo ""
      ;;

    add)
      local skill_name="${1:-}"
      shift || true
      local detect_str="" caps_str="" skill_file=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --detect)       detect_str="$2"; shift 2 ;;
          --capabilities) caps_str="$2";   shift 2 ;;
          --skill-file)   skill_file="$2"; shift 2 ;;
          *) shift ;;
        esac
      done

      [ -n "$skill_name" ] || die "Usage: claw-clips skills add <n> --detect \"pat1,pat2\" [--capabilities \"a,b\"] [--skill-file /path/to/SKILL.md]"
      [ -n "$detect_str" ] || die "Must provide --detect patterns"

      local detect_json caps_json
      detect_json=$(echo "$detect_str" | tr ',' '\n' | jq -R -s 'split("\n") | map(select(. != ""))')
      caps_json=$(echo "${caps_str:-}" | tr ',' '\n' | jq -R -s 'split("\n") | map(select(. != ""))')

      local sf_arg="" hash_arg=""
      if [ -n "$skill_file" ] && [ -f "$skill_file" ]; then
        sf_arg=$(realpath "$skill_file" 2>/dev/null || echo "$skill_file")
        hash_arg=$(sha256sum "$sf_arg" 2>/dev/null | cut -d' ' -f1)
      fi

      unlock_skills
      jq --arg s "$skill_name" \
         --argjson d "$detect_json" \
         --argjson c "$caps_json" \
         --arg sf "$sf_arg" \
         --arg h "$hash_arg" \
         '.[$s] = (.[$s] // {}) + {"detect": $d, "capabilities": $c, "status": "registered", "skill_file": $sf, "hash": $h}' \
         "$SKILLS_REG" > "$SKILLS_REG.tmp" && mv "$SKILLS_REG.tmp" "$SKILLS_REG"
      lock_skills

      info "Registered skill '$skill_name' with $(echo "$detect_json" | jq 'length') detection patterns."
      [ -n "$hash_arg" ] && echo -e "${DIM}  Tracking: $sf_arg (hash: ${hash_arg:0:16}...)${RESET}"
      echo -e "${DIM}  Status: registered (not yet onboarded)${RESET}"
      echo -e "${DIM}  Next: generate safety rules, then run: claw-clips skills onboard $skill_name${RESET}"
      ;;

    onboard)
      local skill_name="${1:-}"
      [ -n "$skill_name" ] || die "Usage: claw-clips skills onboard <skill_name>"

      # Verify skill exists in registry
      local exists
      exists=$(jq -r --arg s "$skill_name" 'has($s)' "$SKILLS_REG")
      [ "$exists" = "true" ] || die "Skill '$skill_name' not found. Register first: claw-clips skills add ..."

      # Count pending rules for this skill
      local rule_count=0
      if [ -s "$PENDING" ]; then
        rule_count=$(jq -r --arg s "$skill_name" \
          'select(.skill == $s) | .id' "$PENDING" 2>/dev/null | wc -l)
      fi

      local ts
      ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

      unlock_skills
      jq --arg s "$skill_name" --arg t "$ts" --arg rc "$rule_count" \
        '.[$s].onboarded = $t | .[$s].status = "probation" | .[$s].rules_count = ($rc | tonumber)' \
        "$SKILLS_REG" > "$SKILLS_REG.tmp" && mv "$SKILLS_REG.tmp" "$SKILLS_REG"
      lock_skills

      info "Skill '$skill_name' onboarded successfully."
      echo -e "  Status: ${YELLOW}probation${RESET}"
      echo -e "  Pending rules: $rule_count"
      echo -e "  ${DIM}Only critical rules enforced during probation.${RESET}"
      echo -e "  ${DIM}To activate: claw-clips skills set $skill_name active${RESET}"
      ;;

    set)
      local skill_name="${1:-}" new_status="${2:-}"
      [ -n "$skill_name" ] && [ -n "$new_status" ] || \
        die "Usage: claw-clips skills set <skill> <active|probation|disabled>"

      case "$new_status" in
        active|probation|disabled) ;;
        *) die "Status must be: active, probation, or disabled" ;;
      esac

      unlock_skills
      jq --arg s "$skill_name" --arg st "$new_status" \
        '.[$s].status = $st' "$SKILLS_REG" > "$SKILLS_REG.tmp" \
        && mv "$SKILLS_REG.tmp" "$SKILLS_REG"
      lock_skills
      info "Set $skill_name → $new_status"
      ;;

    rehash)
      local skill_name="${1:-}"
      [ -n "$skill_name" ] || die "Usage: claw-clips skills rehash <skill_name>"

      local skill_file
      skill_file=$(jq -r --arg s "$skill_name" '.[$s].skill_file // empty' "$SKILLS_REG")
      [ -n "$skill_file" ] || die "No skill_file tracked for '$skill_name'. Re-register with --skill-file."
      [ -f "$skill_file" ] || die "Skill file not found: $skill_file"

      local new_hash
      new_hash=$(sha256sum "$skill_file" 2>/dev/null | cut -d' ' -f1)

      unlock_skills
      jq --arg s "$skill_name" --arg h "$new_hash" \
        '.[$s].hash = $h' "$SKILLS_REG" > "$SKILLS_REG.tmp" \
        && mv "$SKILLS_REG.tmp" "$SKILLS_REG"
      lock_skills
      info "Rehashed $skill_name: ${new_hash:0:16}..."
      ;;

    check)
      echo ""
      echo -e "${BOLD}  Skill Hash Verification${RESET}"
      echo "  ──────────────────────────────────────"
      local issues=0

      jq -r 'to_entries[] | "\(.key)\t\(.value.skill_file // "")\t\(.value.hash // "")"' "$SKILLS_REG" | \
      while IFS=$'\t' read -r name sfile shash; do
        if [ -z "$sfile" ] || [ -z "$shash" ]; then
          echo -e "  %-14s ${DIM}no hash tracked${RESET}" "$name"
          continue
        fi
        if [ ! -f "$sfile" ]; then
          echo -e "  ${RED}$name${RESET}  file missing: $sfile"
          ((issues++)) || true
          continue
        fi
        local current
        current=$(sha256sum "$sfile" 2>/dev/null | cut -d' ' -f1)
        if [ "$current" = "$shash" ]; then
          echo -e "  ${GREEN}$name${RESET}  hash OK"
        else
          echo -e "  ${RED}$name${RESET}  CHANGED — re-onboard required"
          echo -e "    ${DIM}stored: ${shash:0:16}...${RESET}"
          echo -e "    ${DIM}current: ${current:0:16}...${RESET}"
          ((issues++)) || true
        fi
      done
      echo ""
      ;;

    *)
      die "Unknown skills subcommand: $subcmd"
      ;;
  esac
}

# ── tail ───────────────────────────────────────────────────────────────

cmd_tail() {
  local n="${1:-20}"
  echo ""
  echo -e "${BOLD}  Last $n audit entries${RESET}"
  echo "  ──────────────────────────────────────────────────────────"

  [ -f "$AUDIT" ] || { echo -e "  ${DIM}No audit log yet.${RESET}"; return; }

  tail -n "$n" "$AUDIT" | while IFS='|' read -r ts action cmd; do
    ts=$(echo "$ts" | xargs)
    action=$(echo "$action" | xargs)
    cmd=$(echo "$cmd" | xargs)
    case "$action" in
      *DENY*|*BLOCK*) echo -e "  ${RED}$ts  $action${RESET}" ;;
      ALLOWED)        echo -e "  ${DIM}$ts  ${GREEN}$action${RESET}" ;;
      *)              echo -e "  $ts  $action" ;;
    esac
    echo -e "  ${DIM}  $cmd${RESET}"
  done
  echo ""
}

# ── test (dry-run a command against all rules) ─────────────────────────

cmd_test() {
  need_jq
  local test_cmd="$*"
  [ -n "$test_cmd" ] || die "Usage: claw-clips test <command to test>"

  echo ""
  echo -e "${BOLD}  Testing command against all rules${RESET}"
  echo -e "  Command: ${DIM}$test_cmd${RESET}"
  echo "  ──────────────────────────────────────────────────────────"

  local blocked=false

  for f in "$ACTIVE" "$PENDING"; do
    [ -f "$f" ] && [ -s "$f" ] || continue
    local source
    [ "$f" = "$ACTIVE" ] && source="active" || source="pending"

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      local pattern ptype action severity rule_id reason
      pattern=$(echo "$rule"  | jq -r '.pattern  // ""')
      ptype=$(echo "$rule"    | jq -r '.type     // "contains"')
      action=$(echo "$rule"   | jq -r '.action   // ""')
      severity=$(echo "$rule" | jq -r '.severity // ""')
      rule_id=$(echo "$rule"  | jq -r '.id       // "?"')
      reason=$(echo "$rule"   | jq -r '.reason   // ""')

      local matched=false
      case "$ptype" in
        exact)    [[ "$test_cmd" == "$pattern" ]] && matched=true ;;
        contains) echo "$test_cmd" | grep -qi "$pattern" && matched=true ;;
        regex)    echo "$test_cmd" | grep -qE "$pattern" && matched=true ;;
      esac

      if $matched; then
        local would_block=false
        # Replicate actual enforcement logic
        if [ "$source" = "active" ] || [ "$f" = "$ACTIVE" ]; then
          case "$severity" in critical|high) would_block=true ;; esac
        else
          [ "$severity" = "critical" ] && would_block=true
        fi

        if $would_block && [ "$action" = "deny" ]; then
          echo -e "  ${RED}WOULD BLOCK${RESET} [$source] $rule_id ($(severity_color "$severity"))"
          echo -e "    ${DIM}$reason${RESET}"
          blocked=true
        else
          echo -e "  ${YELLOW}MATCH (flag only)${RESET} [$source] $rule_id ($(severity_color "$severity"))"
          echo -e "    ${DIM}$reason${RESET}"
        fi
      fi
    done < "$f"
  done

  if ! $blocked; then
    echo -e "  ${GREEN}WOULD ALLOW${RESET} — no blocking rules matched."
  fi
  echo ""
}

# ── help ───────────────────────────────────────────────────────────────

cmd_help() {
  cat << 'EOF'

  claw-clips — OpenClaw Safety Rules Manager

  RULE MANAGEMENT
    list [--pending|--active] [--skill NAME] [--severity LEVEL]
        Show rules. Filter by source, skill, or severity.

    promote <rule_id|--all> [--skill NAME]
        Move rule(s) from pending → active (sets reviewed=true).

    demote <rule_id>
        Move rule from active → pending (sets reviewed=false).

    delete <rule_id>
        Permanently remove a rule from active or pending.

    edit <rule_id>
        Open rule in $EDITOR for manual editing.

  ANALYSIS
    stats           Show counts by skill, severity, and author.
    bloat           Find overlapping or redundant rules.

  SKILL MANAGEMENT
    skills                  List all registered skills and status.
    skills add <name> --detect "pat1,pat2" [--capabilities "email,cal"]
                            Register a new skill with detection patterns.
    skills onboard <name>   Mark skill as onboarded (enters probation).
    skills set <name> <active|probation|disabled>
                            Change skill enforcement status.

  TESTING & AUDIT
    test <command>  Dry-run a command against all rules (no exec).
    tail [N]        Show last N audit log entries (default: 20).

  EXAMPLES
    claw-clips skills add gog-secure --detect "gmail,calendar,events,messages" \
                                   --capabilities "email,calendar"
    claw-clips skills onboard gog-secure
    claw-clips list --skill gog-secure --severity critical
    claw-clips test "some-tool gmail messages.batchDelete"
    claw-clips promote --all --skill gog-secure
    claw-clips skills set gog-secure active

  FILES
    ~/.openclaw/claw-clips/active.jsonl    Enforced rules (human-owned)
    ~/.openclaw/claw-clips/pending.jsonl   Agent-proposed rules
    ~/.openclaw/claw-clips/skills.json     Skill registry
    ~/.openclaw/claw-clips/safety-audit.log      All exec call history
    ~/.openclaw/claw-clips/onboard.md    Onboarding prompt template

EOF
}

# ═══════════════════════════════════════════════════════════════════════
# DISPATCH
# ═══════════════════════════════════════════════════════════════════════

case "${1:-help}" in
  list)     shift; cmd_list "$@" ;;
  promote)  shift; cmd_promote "$@" ;;
  demote)   shift; cmd_demote "$@" ;;
  delete)   shift; cmd_delete "$@" ;;
  edit)     shift; cmd_edit "$@" ;;
  stats)    cmd_stats ;;
  bloat)    cmd_bloat ;;
  skills)   shift; cmd_skills "$@" ;;
  tail)     shift; cmd_tail "$@" ;;
  test)     shift; cmd_test "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "Unknown command: $1. Run 'claw-clips help' for usage." ;;
esac