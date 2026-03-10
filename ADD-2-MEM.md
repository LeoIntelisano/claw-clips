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