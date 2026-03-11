## Skill: {{SKILL_NAME}}
## Capabilities: {{CAPABILITIES}}
## API Surface:
{{SKILL_DESCRIPTION}}

---

Analyze every action in this skill and generate safety deny rules for the shim.
Registration guidance (if needed) is handled by the shim — focus only on rule generation.

## Classification Guide

**SAFE** — read-only, idempotent, no side effects
  Examples: list, get, search, check status
  → No rule needed.

**REVERSIBLE** — creates or modifies data, but can be undone
  Examples: create event, send to trash, add label, update field
  → No rule needed for single-item actions.
  → Bulk reversible (--all, --bulk, or --max > 20): rule with severity "high".

**DESTRUCTIVE** — irreversible or high-blast-radius
  Examples: permanent delete, bulk delete, delete entire container,
            forward all email, share externally, auto-delete filters,
            revoke own access
  → Generate a deny rule. Severity: "critical".

**UNCERTAIN** — action could be destructive depending on parameters
  → Generate a rule with action: "flag" (logs without blocking).
  → Severity: "high".

## Rule Format

JSONL, one rule per line. Required fields:

  id       — "{skill}_{NNN}" e.g. "gog-secure_001"
             New skill: start at _001.
             Re-onboarding: continue from highest existing ID.
  pattern  — string matched against the exec command
  type     — "contains" | "regex" | "exact"
  skill    — "{{SKILL_NAME}}"
  severity — "critical" | "high"
  action   — "deny"  (blocks execution)
           | "flag"  (logs without blocking)
  reason   — one sentence: WHY this is dangerous
  added    — today's date (YYYY-MM-DD)
  author   — "agent"
  reviewed — false

| Type     | Matching                        | Use Case                             |
|----------|---------------------------------|--------------------------------------|
| exact    | Full command must match exactly | Very specific, single-command blocks |
| contains | Case-insensitive substring      | API method names, simple patterns    |
| regex    | Extended regex (grep -E)        | Complex patterns, parameter combos   |

## Pattern Quality

1. Be specific — avoid accidentally matching read/list operations
2. Self-check: would a normal single-item GET match this? If yes, narrow it.
3. Always explain WHY in the reason field — humans will review your reasoning
4. Aim for 8–20 rules per skill; fewer if read-heavy

## Detection Patterns (for `claw-clips skills add`)

Use SIMPLE SUBSTRINGS only — no regex.
Examples: "gog ", "searxng", "aws ec2 delete"
The shim checks: `if [[ "$CMD" == *"$pattern"* ]]`

## Output

### File Write
Write rules to `~/.openclaw/claw-clips/pending.jsonl`.
Overwrite any existing rules for this skill before writing new ones.
If the skill is safe, write nothing.

### Chat Response
After writing, tell the operator:
- Summary of rules generated and why
- `claw-clips list --pending` to review
- `claw-clips promote <rule_id|--all> [--skill NAME]` to approve

Then STOP. The human operator runs all claw-clips commands.

## Re-onboarding

Read existing rules from `~/.openclaw/claw-clips/active.jsonl` filtered by
this skill's ID. Only generate NEW rules for actions not already covered.
Continue rule ID numbering from the highest existing ID for this skill.