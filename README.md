# OpenClaw Safety Guardrails

A self-restricting safety system for AI agent tool use. The agent proposes its own deny rules during skill onboarding, a deterministic shim enforces them, and a human reviews and promotes rules via CLI.

Built for [OpenClaw](https://github.com/your-repo/openclaw) but adaptable to any system where an AI agent executes shell commands.

## The Problem

When an AI agent has `exec` access (shell commands, API calls, tool use), you need guardrails that:

- **Block destructive actions** before they execute (not after)
- **Scale** as you add new tools/skills without writing rules by hand for each one
- **Let the agent self-restrict** — it knows what's dangerous in its own tool surface
- **Keep a human in the loop** — the agent proposes, the human approves
- **Work across sessions** — persist without relying on LLM memory
- **Cost zero context tokens** — rules live on disk, not in the prompt

## How It Works

### Three Enforcement Layers

```
Agent calls exec
  │
  ├─ Layer 1: Hard-coded patterns (zero deps, instant)
  │   Blocks sensitive paths (.ssh, .env, credentials)
  │   Blocks destructive commands (rm -rf, dd, curl|bash)
  │
  ├─ Layer 2: JSONL deny rules
  │   active.jsonl  → enforces critical + high severity (human-reviewed)
  │   pending.jsonl → enforces ONLY critical (agent-proposed, unreviewed)
  │
  ├─ Layer 3: Skill onboarding gate
  │   Detects which skill a command belongs to
  │   Blocks commands for unonboarded skills
  │   Agent must analyze risks and generate rules before first use
  │
  └─ All checks pass → command executes
```

### The Onboarding Flow

When the agent tries to use a new skill for the first time, the shim blocks it and says "onboard this skill first." The agent then:

1. Reads the skill's API surface
2. Classifies each action as safe / reversible / destructive
3. Generates JSONL deny rules for dangerous actions
4. Appends them to `pending.jsonl`
5. Registers the skill → enters **probation** (only critical rules enforce)

The human reviews with `claw-clips`, promotes good rules to `active.jsonl`, and activates the skill. This happens **once per skill, ever** — no LLM memory needed.

### Severity Enforcement Matrix

| Severity | In `active.jsonl` | In `pending.jsonl` |
|----------|-------------------|-------------------|
| critical | **DENY** (hard block) | **DENY** (hard block) |
| high | **DENY** (hard block) | flag only (logged) |
| medium | flag only (logged) | flag only (logged) |
| low | logged | logged |

Agent-proposed critical rules take effect **immediately** — even before human review. This ensures genuinely dangerous actions (bulk delete, data exfiltration) are blocked from the moment the agent identifies them.

## Installation

### Prerequisites

- **bash** 4.0+
- **jq** (`sudo apt install jq`)
- A systemd service or similar mechanism that routes agent exec calls through `~/bin/bash`

### Install

```bash
git clone https://github.com/your-repo/openclaw-guardrails.git
cd openclaw-guardrails
bash install-guardrails.sh
```

The installer:
1. Creates `~/.openclaw/rules/` and `~/.openclaw/prompts/`
2. Installs the safety shim at `~/bin/bash`
3. Installs the CLI at `~/bin/claw-clips`
4. Seeds initial rules and the skill registry
5. Sets file permissions (active.jsonl → read-only 444)
6. Verifies the installation

### File Layout After Install

```
~/bin/
├── bash                              Safety shim (755)
└── claw-clips                          CLI manager (755)

~/.openclaw/
├── rules/
│   ├── active.jsonl                  Enforced rules (444, read-only)
│   ├── pending.jsonl                 Agent proposals (644, append-only)
│   └── skills.json                   Skill registry (644)
├── prompts/
│   └── onboard.md                    Onboarding prompt template (644)
└── safety-audit.log                  Full exec audit trail (644)
```

### PATH Configuration

The shim works by being the first `bash` in PATH for your agent's service. For a systemd service:

```ini
# /etc/systemd/system/your-agent.service.d/override.conf
[Service]
Environment="PATH=/home/youruser/bin:/usr/local/bin:/usr/bin:/bin"
```

This scopes the shim to **only** the agent service. Your interactive shell uses its own PATH and is unaffected.

### Agent Memory Entry

Add this to your agent's persistent memory (MEMORY.md, system prompt, etc.):

```markdown
## Safety Shim
All exec commands go through a safety shim at ~/bin/bash.
If a skill hasn't been onboarded, the shim blocks and tells you what to do.
Follow its instructions exactly.
You can propose deny rules by appending JSONL to ~/.openclaw/rules/pending.jsonl
You can read the onboarding template at ~/.openclaw/prompts/onboard.md
You CANNOT modify ~/.openclaw/rules/active.jsonl — it is read-only.
```

~100 tokens. The shim handles everything else deterministically.

## Usage

### Onboarding a New Skill

**Example: onboarding a SearXNG search integration**

**Step 1: Register the skill with detection patterns**

```bash
claw-clips skills add searxng \
  --detect "searxng,searx,search.query,search.results" \
  --capabilities "web-search"
```

Detection patterns are substrings matched against every exec command. Choose patterns that appear in the skill's API calls but not in normal bash commands.

**Step 2: Have the agent generate safety rules**

Tell the agent:

> "I've registered the searxng skill. Read the onboarding prompt at
> ~/.openclaw/prompts/onboard.md, analyze the SearXNG API for destructive
> actions, and generate deny rules. Append them to
> ~/.openclaw/rules/pending.jsonl"

The agent will read the prompt template, analyze the API surface, and produce JSONL rules like:

```jsonl
{"id": "searxng_001", "pattern": "settings.update", "type": "contains", "skill": "searxng", "severity": "critical", "action": "deny", "reason": "Modifying search engine settings could redirect queries or disable safe search", "added": "2026-03-10", "author": "agent", "reviewed": false}
```

**Step 3: Complete onboarding**

```bash
claw-clips skills onboard searxng
```

The skill enters **probation**. Only critical rules are enforced; high-severity rules are flagged but not blocked.

**Step 4: Review the proposed rules**

```bash
claw-clips list --pending --skill searxng
```

Review each rule. If they look good:

```bash
claw-clips promote --all --skill searxng
```

Or promote individually:

```bash
claw-clips promote searxng_001
```

**Step 5: Activate the skill**

```bash
claw-clips skills set searxng active
```

Full enforcement. Done. The agent can now use SearXNG, constrained by the rules it helped write.

### Testing an Existing Skill

If a skill is already onboarded (like `gog-secure` for Gmail/Calendar), just use it. The shim checks rules silently on every exec call.

To verify what would happen for a specific command:

```bash
claw-clips test "some-tool gmail messages.batchDelete"
# → WOULD BLOCK by active rule [gmail_001]: Bulk message deletion is irreversible

claw-clips test "some-tool calendar events.list"
# → WOULD ALLOW — no blocking rules matched
```

### CLI Reference

```
claw-clips help                           Show all commands

RULE MANAGEMENT
  claw-clips list                         Show all rules
  claw-clips list --pending               Show only agent-proposed rules
  claw-clips list --active                Show only human-reviewed rules
  claw-clips list --skill gmail           Filter by skill
  claw-clips list --severity critical     Filter by severity
  claw-clips promote <id|--all> [--skill] Move pending → active
  claw-clips demote <id>                  Move active → pending
  claw-clips delete <id>                  Remove a rule permanently
  claw-clips edit <id>                    Open in $EDITOR

ANALYSIS
  claw-clips stats                        Counts by skill/severity/author
  claw-clips bloat                        Find overlapping rules

SKILL MANAGEMENT
  claw-clips skills                       List all registered skills
  claw-clips skills add <name>            Register (see above for flags)
    --detect "pat1,pat2,..."
    --capabilities "cap1,cap2,..."
  claw-clips skills onboard <name>        Mark as onboarded (probation)
  claw-clips skills set <name> <status>   Set active|probation|disabled

TESTING & AUDIT
  claw-clips test "<command>"             Dry-run against all rules
  claw-clips tail [N]                     Last N audit log entries
```

## Rule Format

Rules are stored as JSONL (one JSON object per line):

```jsonl
{"id": "gmail_001", "pattern": "batchDelete", "type": "contains", "skill": "gog-secure", "severity": "critical", "action": "deny", "reason": "Bulk message deletion is irreversible and could destroy entire inbox", "added": "2026-03-10", "author": "human", "reviewed": true}
```

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (format: `{skill}_{NNN}`) |
| `pattern` | String matched against the exec command |
| `type` | `contains` (substring), `regex` (ERE), or `exact` |
| `skill` | Which skill this rule belongs to |
| `severity` | `critical`, `high`, `medium`, or `low` |
| `action` | `deny` (block) or `flag` (log only) |
| `reason` | Why this is dangerous (preserved for human review) |
| `added` | Date the rule was created |
| `author` | `agent` or `human` |
| `reviewed` | `true` if a human has approved this rule |

## Test Suite

The test suite validates all three enforcement layers plus the full CLI:

```bash
bash test-guardrails.sh
```

### What's Tested

**Layer 1 — Hard-coded patterns (24 tests)**

| Test | Description |
|------|-------------|
| Block sensitive: .ssh | Blocks access to SSH key directories |
| Block sensitive: aws | Blocks AWS credential files |
| Block sensitive: gnupg | Blocks GPG key directories |
| Block sensitive: .env | Blocks dotenv files |
| Block sensitive: .env. | Blocks dotenv variant patterns |
| Block sensitive: ed25519 | Blocks SSH key files by name |
| Block sensitive: openclaw.json | Blocks agent config file |
| Block destructive: rm -rf | Blocks recursive force delete |
| Block destructive: rm -fr | Blocks force recursive delete (flag order variant) |
| Block destructive: dd if= | Blocks raw disk imaging |
| Block destructive: chmod 777 | Blocks recursive world-writable |
| Block destructive: nc reverse shell | Blocks netcat reverse shells |
| Block destructive: mkfs | Blocks filesystem formatting |
| Block destructive: /dev/sda | Blocks raw device writes |
| Block destructive: curl pipe bash | Blocks remote code execution via pipe |
| Block destructive: wget pipe sh | Blocks remote code execution via pipe |
| Allow safe: echo | Passes through safe echo commands |
| Allow safe: ls | Passes through directory listing |
| Allow safe: cat safe | Passes through safe file reads |
| Allow safe: python | Passes through python execution |
| Allow safe: date | Passes through date command |
| Audit: sensitive logged | Verifies deny events hit the audit log |
| Audit: destructive logged | Verifies deny events hit the audit log |
| Audit: allowed logged | Verifies allowed events hit the audit log |

**Layer 2 — JSONL deny rules (10 tests)**

| Test | Description |
|------|-------------|
| Active critical: block | Critical rules in active.jsonl block |
| → rule ID shown | Block message includes the rule ID |
| Active high: block | High-severity active rules block |
| Active regex: block | Regex-type patterns match correctly |
| Active medium: allow | Medium-severity rules flag but don't block |
| Pending critical: block | Critical rules in pending.jsonl block immediately |
| Pending high: allow | High-severity pending rules don't block (not yet promoted) |
| No match: allow | Commands matching no rules pass through |
| Malformed line: rule still works | Bad JSONL lines are skipped, valid rules still enforce |
| Malformed line: safe passes | Malformed rules don't cause false blocks |

**Layer 3 — Skill onboarding gate (7 tests)**

| Test | Description |
|------|-------------|
| Catch-all: block unregistered | Known API keywords without a registered skill are blocked |
| → mentions onboard | Block message includes onboarding instructions |
| Registered not onboarded: block | Skills in "registered" status are blocked |
| Probation: allow | Skills in "probation" status pass through |
| Active: allow | Skills in "active" status pass through |
| Disabled: block | Skills in "disabled" status are blocked |
| Non-skill: allow | Regular bash commands (no skill detected) pass through |

**claw-clips CLI (16 tests)**

| Test | Description |
|------|-------------|
| CLI: help | Help command runs without error |
| CLI: list | List shows both active and pending rules |
| → active/pending shown | Correct rules appear in output |
| CLI: --active/--pending | Source filters work correctly |
| CLI: promote | Moves rule from pending to active, sets reviewed=true |
| CLI: demote | Moves rule from active to pending, sets reviewed=false |
| CLI: delete | Removes rule from both files |
| CLI: stats | Statistics command runs |
| CLI: bloat | Overlap detection runs |
| CLI: test → would-block | Dry-run correctly identifies blocking rules |
| CLI: test → would-allow | Dry-run correctly identifies safe commands |
| CLI: skills add | Registers skill with detect patterns |
| CLI: skills onboard | Sets skill to probation status |
| CLI: skills set | Changes skill status |

### Running Tests

```bash
# Full suite (requires jq)
bash test-guardrails.sh

# Specify custom paths
bash test-guardrails.sh /path/to/safety-shim.sh /path/to/claw-clips.sh
```

Tests create an isolated temp environment (`$OPENCLAW_DIR` in `/tmp`) and clean up after themselves. They don't touch your real `~/.openclaw` directory.

## Security Notes

- **The shim is not a sandbox.** It's a pattern-matching filter. A sufficiently clever agent could craft commands to bypass pattern detection. It's a guardrail, not a cage.
- **`active.jsonl` is `chmod 444`** (read-only). The agent has no code path to write to it. Only `claw-clips` (human-invoked) temporarily unlocks it for promote/demote/delete operations.
- **`pending.jsonl` is append-only by convention.** The shim's onboarding message only tells the agent to append. The agent *could* overwrite it, but this only weakens its own proposed rules — it can't strengthen enforcement this way.
- **Skill detection uses substring matching**, not cryptographic verification. An agent could theoretically name a command to avoid detection. The catch-all keyword list mitigates this for known API patterns.
- **The audit log records everything.** Review `claw-clips tail` regularly.

## Architecture

```
┌─────────────────────────────────┐
│         Agent (OpenClaw)        │
│    exec("some tool command")    │
└──────────────┬──────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│       ~/bin/bash (shim)          │
│                                  │
│  ┌─ Layer 1: Hard-coded deny ──┐ │
│  │  .ssh, .env, rm -rf, etc.  │ │
│  └─────────────────────────────┘ │
│                                  │
│  ┌─ Layer 2: JSONL rules ──────┐ │
│  │  active.jsonl (crit+high)   │ │
│  │  pending.jsonl (crit only)  │ │
│  └─────────────────────────────┘ │
│                                  │
│  ┌─ Layer 3: Skill gate ───────┐ │
│  │  skills.json (detect+status)│ │
│  │  Block if not onboarded     │ │
│  └─────────────────────────────┘ │
│                                  │
│  ✓ All passed → exec /bin/bash   │
└──────────────────────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│  /bin/bash (real) → command runs │
└──────────────────────────────────┘

┌──────────────────────────────────┐
│       Human (claw-clips CLI)       │
│                                  │
│  claw-clips list / promote / test  │
│  claw-clips skills add / onboard   │
│  Review audit log                │
└──────────────────────────────────┘
```

## License

MIT