# Claw-Clips

A default-deny safety shim for AI agent tool use. The agent proposes its own deny rules during skill onboarding, a deterministic bash shim enforces them, and a human reviews and promotes rules via CLI.

Built for AI agents that execute shell commands (like [OpenClaw](https://github.com/leolivier/openclaw)), but adaptable to any system where an AI agent has `exec` access.

## Why

When an AI agent can run shell commands, you need guardrails that:

- **Block destructive actions** before they execute, not after
- **Default to deny** — unknown commands are blocked, not allowed
- **Let the agent self-restrict** — it analyzes new tools and proposes safety rules
- **Keep a human in the loop** — the agent proposes, the human approves
- **Detect skill drift** — if a tool's definition changes, it requires re-onboarding
- **Work across sessions** — rules persist on disk, not in LLM memory
- **Cost zero context tokens** — the entire system runs at the bash level

## How It Works

```
Agent calls exec
  │
  ├─ Layer 1: Hard-coded patterns (zero deps)
  │   Blocks .ssh, .env, rm -rf, curl|bash, etc.
  │
  ├─ Layer 2: JSONL deny rules
  │   active.jsonl  → critical + high enforced
  │   pending.jsonl → critical only (agent proposals)
  │
  ├─ Layer 3: Default-deny
  │   ├─ Matches registered skill? → check status
  │   │   ├─ active/probation → allow (rules already checked)
  │   │   ├─ hash changed → block (re-onboard required)
  │   │   ├─ disabled → block
  │   │   └─ registered → block (onboard first)
  │   │
  │   ├─ Matches infrastructure allowlist? → allow
  │   │   (echo, ls, cat, python3 -c, jq, etc.)
  │   │
  │   └─ Nothing matches → BLOCK
  │
  └─ All checks pass → exec /bin/bash
```

The shim is named `bash` and placed in `~/bin/` so the agent's service resolves it via PATH. Interactive shells are unaffected — they use their own PATH.

## Installation

### Prerequisites

- bash 4.0+
- jq (`sudo apt install jq`)

### Install

```bash
git clone https://github.com/youruser/claw-clips.git
cd claw-clips
bash install-guardrails.sh
```

### File Layout

```
~/bin/
├── bash                              Safety shim (755)
└── claw-clips                        CLI manager (755)

~/.openclaw/
├── rules/
│   ├── active.jsonl                  Enforced rules (444, read-only)
│   ├── pending.jsonl                 Agent proposals (644)
│   ├── skills.json                   Skill registry (644)
│   └── allowlist.jsonl               Infrastructure commands (444, read-only)
├── prompts/
│   └── onboard.md                    Onboarding prompt template
└── safety-audit.log                  Full exec audit trail
```

### Service Configuration

Add to your agent's systemd service (or equivalent):

```ini
[Service]
Environment="PATH=/home/youruser/bin:/usr/local/bin:/usr/bin:/bin"
```

Then restart:

```bash
sudo systemctl restart your-agent-service
```

## Quick Start

### 1. Register a Skill

Look at the actual exec commands your agent runs for the skill. From the audit log:

```
python3 ~/.openclaw/skills/searxng/scripts/search.py "query" -n 5
```

Register with detection patterns that match:

```bash
claw-clips skills add searxng \
  --detect "searxng/scripts/search.py" \
  --capabilities "web-search" \
  --skill-file ~/.openclaw/skills/searxng/SKILL.md
```

The `--skill-file` flag stores a SHA-256 hash. If the file changes later, the shim blocks the skill until you rehash or re-onboard.

### 2. Have the Agent Onboard It

Tell the agent:

> "Try using the searxng skill."

The shim blocks with onboarding instructions. The agent reads the prompt at `~/.openclaw/prompts/onboard.md`, analyzes the skill's API surface, generates deny rules, appends them to `pending.jsonl`, and runs `claw-clips skills onboard searxng`.

The skill enters **probation** — only critical deny rules are enforced.

### 3. Review and Activate

```bash
# See what the agent proposed
claw-clips list --pending --skill searxng

# Promote rules you agree with
claw-clips promote --all --skill searxng

# Activate the skill
claw-clips skills set searxng active
```

### 4. Monitor

```bash
# Live audit log
tail -f ~/.openclaw/safety-audit.log

# Recent entries
claw-clips tail 20

# Check for skill drift
claw-clips skills check
```

## Onboarding a Skill With Destructive Actions

For a tool like a Google Workspace CLI (`gog`) that can read email, create calendar events, and delete files:

```bash
claw-clips skills add gog-secure \
  --detect "gog " \
  --capabilities "email,calendar,drive" \
  --skill-file /path/to/gog-secure/SKILL.md
```

Tell the agent to onboard. It will analyze the API surface and propose rules like:

```jsonl
{"id": "gog_001", "pattern": "gog gmail send", "type": "contains", "skill": "gog-secure", "severity": "critical", "action": "deny", "reason": "Sending email is irreversible — wrong recipient means permanent mistake"}
{"id": "gog_002", "pattern": "gog drive delete", "type": "contains", "skill": "gog-secure", "severity": "critical", "action": "deny", "reason": "Permanent drive file deletion is irreversible"}
```

Review, promote, and activate as above. You can also seed your own rules before the agent onboards — any rules in `active.jsonl` take precedence.

## Skill Drift Detection

When you register a skill with `--skill-file`, claw-clips stores a SHA-256 hash. If someone modifies the SKILL.md (adding new capabilities, changing permissions, or even just reformatting), the shim detects the mismatch and blocks the skill:

```
[safety] BLOCKED: Skill 'gog-secure' definition has changed since onboarding.
```

The shim tells the agent to **ask the user** which path to take — it does not auto-rehash or auto-re-onboard. The user decides:

**Minor change** (reformatting, typo fix, no new capabilities):
```bash
claw-clips skills rehash gog-secure
```
Updates the stored hash. The skill resumes immediately.

**Significant change** (new APIs, new permissions, capability additions):
```bash
claw-clips skills set gog-secure registered
# Then have the agent re-onboard to generate rules for new capabilities
```

Check all skills for drift at any time:
```bash
claw-clips skills check
```

It's good practice to run `claw-clips skills check` after updating any skill files, and to encourage the agent to run it when its context resets (e.g., new session).

## Meta Rules: Preventing Agent Self-Promotion

The seed `active.jsonl` includes rules that block the agent from modifying the safety system:

| Rule | What It Blocks |
|------|---------------|
| `meta_001` | `claw-clips skills set` — agent can't activate skills |
| `meta_002` | `claw-clips promote` — agent can't promote rules |
| `meta_003` | `claw-clips delete` — agent can't delete rules |
| `meta_004` | `claw-clips allowlist` — agent can't modify allowlist |
| `meta_005` | `claw-clips demote` — agent can't demote rules |
| `meta_006` | `claw-clips edit` — agent can't edit rules |
| `meta_007` | `claw-clips skills rehash` — agent can't rehash skills |

The agent CAN: `claw-clips skills onboard` (probation), append to `pending.jsonl`, and read with `claw-clips list/stats/tail/test`.

## Agent Memory Entry

Add to your agent's persistent memory (~130 tokens):

```markdown
## Safety Shim
All exec commands go through a safety shim at ~/bin/bash.
If a skill hasn't been onboarded, the shim blocks and tells you what to do.
Follow its instructions exactly.
You can propose deny rules by appending JSONL to ~/.openclaw/rules/pending.jsonl
You can read the onboarding template at ~/.openclaw/prompts/onboard.md
You CANNOT modify active.jsonl, the allowlist, or promote/activate/rehash skills.
After onboarding to probation, stop and let the operator review.
If a skill is blocked due to a hash change, present BOTH options (rehash vs
re-onboard) to the user and wait for their decision. Do not act on your own.
Run `claw-clips skills check` at the start of each new session to verify
skill integrity.
```

## CLI Reference

```
claw-clips help                              Show all commands

RULE MANAGEMENT
  list [--pending|--active] [--skill N] [--severity L]
  promote <id|--all> [--skill N]             Pending → active
  demote <id>                                Active → pending
  delete <id>                                Remove permanently
  edit <id>                                  Open in $EDITOR

ANALYSIS
  stats                                      Counts by skill/severity/author
  bloat                                      Find overlapping rules

SKILL MANAGEMENT
  skills                                     List all skills
  skills add <n> --detect "p1,p2"            Register a new skill
    [--capabilities "a,b"]
    [--skill-file /path/to/SKILL.md]
  skills onboard <n>                         Enter probation
  skills set <n> <active|probation|disabled> Change status
  skills rehash <n>                          Update stored hash
  skills check                               Verify all hashes

TESTING & AUDIT
  test "<command>"                           Dry-run against all rules
  tail [N]                                   Last N audit log entries
```

## Rule Format

```jsonl
{"id": "gog_001", "pattern": "gog gmail send", "type": "contains", "skill": "gog-secure", "severity": "critical", "action": "deny", "reason": "Sending email is irreversible", "added": "2026-03-10", "author": "human", "reviewed": true}
```

| Field | Values |
|-------|--------|
| `type` | `contains`, `regex`, `exact` |
| `severity` | `critical`, `high`, `medium`, `low` |
| `action` | `deny` (block), `flag` (log only) |
| `author` | `agent`, `human` |

### Severity Enforcement

| Severity | active.jsonl | pending.jsonl |
|----------|-------------|--------------|
| critical | **DENY** | **DENY** |
| high | **DENY** | flag only |
| medium | flag only | flag only |

## Test Suite

```bash
bash test-guardrails.sh
```

Tests all three layers, the CLI, skill detection, allowlist matching, and default-deny behavior. Creates isolated temp environments — never touches your real `~/.openclaw`.

## Security Notes

- **Default-deny model**: unknown commands are blocked, not allowed
- **The shim is a guardrail, not a sandbox**: it pattern-matches command strings. A deliberately evasive agent could craft bypass commands (e.g., `python3 -c "subprocess.run(...)"`)
- **`active.jsonl` and `allowlist.jsonl` are chmod 444**: the agent has no code path to modify them
- **Meta rules block agent self-promotion**: the agent can propose but not approve
- **Skill hash tracking**: detects when tool definitions change after onboarding
- **All exec calls are audited**: every allow, deny, and passthrough is logged with timestamp

## License

MIT
