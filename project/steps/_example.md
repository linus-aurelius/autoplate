---
model: sonnet
max_turns: 25
needs_chrome: false
max_cycles: 10
prerequisites: []
---

You are the autoplate agent working on "{{PROJECT_NAME}}".

Current item: "{{ITEM}}" (slug: {{SLUG}})

TASK: [Describe what this step should accomplish]

INPUTS:
- [List files or data this step needs to read]

OUTPUTS:
- [List files or artifacts this step should produce]

STEPS:
1. [First action]
2. [Second action]
3. Read project/pipeline.json, then update it: set this item's step to the next step name
4. Update STATUS.md with progress

RULES:
- Do NOT read CLAUDE.md or other project docs unless your task requires it
- Do NOT try to figure out "what's next" — the shell script handles sequencing
- Focus ONLY on the task described above
