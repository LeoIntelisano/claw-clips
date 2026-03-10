You are analyzing a new skill/tool integration for safety risks.
Your job is to identify ALL destructive or irreversible actions and
generate deny rules that will be enforced by a safety shim.

## Skill: {{SKILL_NAME}}
## Capabilities: {{CAPABILITIES}}

## API Surface:
{{SKILL_DESCRIPTION}}

## Classification Guide

For each endpoint, action, or capability in this skill, classify as:

**SAFE** — read-only, idempotent, no side effects
  Examples: list items, get details, search, check status
  → No rule needed.

**REVERSIBLE** — creates or modifies data, but can be undone
  Examples: create event (can delete), send to trash (can restore),
            add label (can remove), update field (can revert)
  → Generate a rule only if dangerous AT SCALE (bulk). Use severity "high".

**DESTRUCTIVE** — irreversible data loss, bulk mutation, permission
  escalation, data exfiltration, or silent side effects
  Examples: permanent delete (bypassing trash), bulk delete,
            delete entire container (calendar, folder, label),
            forward all email, share with external parties,
            create auto-delete filters, revoke own access
  → Generate a deny rule. Use severity "critical".

## Think About These Attack Surfaces

- Bulk operations: anything that operates on "all" of a resource type
- Permanent vs trash: APIs that skip the trash/recycle bin
- Permission changes: sharing, forwarding, delegation to external parties
- Silent side effects: filters, rules, automations that act LATER
- Container deletion: deleting a calendar/folder/label destroys contents
- Escalation: actions that grant MORE access than currently exists
- Exfiltration: forwarding, sharing, or exporting data externally
- Cascading: deleting a recurring event series, removing all labels

## Rule Format

Output ONLY valid JSONL, one rule per line. No markdown, no commentary.

Required fields:
  id       — format: "{skill}_{NNN}" (e.g. "gog-secure_001")
  pattern  — string to match against the exec command
  type     — "contains" | "regex" | "exact"
  skill    — "{{SKILL_NAME}}"
  severity — "critical" | "high"
  action   — "deny" | "flag"
  reason   — one sentence: WHY this is dangerous
  added    — today's date (YYYY-MM-DD)
  author   — "agent"
  reviewed — false

## Rules for Good Patterns

1. Be specific: avoid matching read/list operations by accident
2. Prefer "contains" for API method names — simpler, less fragile
3. Use "regex" only when matching parameter combinations matters
4. Always explain WHY — humans will review your reasoning
5. Aim for 8-20 rules per skill. Fewer if it's read-heavy.
6. Self-check: would a normal single-item GET match this? If yes, narrow it.

## Output

ONLY the JSONL rules, one per line. Nothing else.
