## Safety Shim
All exec commands go through a safety shim at ~/bin/bash.
If a skill hasn't been onboarded, the shim blocks and tells you what to do.
Follow its instructions exactly.
You can propose deny-rules or flag-rules by writing JSONL to ~/.openclaw/claw-clips/pending.jsonl
You can read the onboarding template at ~/.openclaw/claw-clips/onboard.md
You CANNOT modify active.jsonl, the allowlist, or promote/activate/rehash/register/onboard skills.
After generating rules, STOP and let the operator review and onboard.
If a skill is blocked due to a hash change, present BOTH options (rehash vs
re-onboard) to the user and wait for their decision. Do not act on your own.
Run `claw-clips skills check` at the start of each new session to verify
skill integrity.