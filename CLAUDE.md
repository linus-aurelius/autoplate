# Autoplate — Agent Instructions

## THE THREE ROLES

This project has three actors. Know your role:

1. **The User** — Quality checks output. Gives feedback on what's wrong.
2. **Claude Code (interactive)** — Implements fixes AND documents them. Every fix MUST update the pipeline (step templates in `project/steps/`, `CLAUDE.md`, etc.) so the shell agent improves. Fixing the immediate problem without updating the pipeline is a FAILURE.
3. **The Shell Agent (`run.sh`)** — Automated machine. Follows step templates exactly. Gets better only when Claude Code updates the step prompts.

**The goal**: User runs `./run.sh loop`, pipeline produces correct output with zero manual intervention. Every conversation moves toward that goal.

**When the user gives feedback**:
1. Fix the immediate problem
2. Figure out WHY the shell agent got it wrong (missing instruction? vague prompt? no example?)
3. Update the specific step template in `project/steps/` that would have prevented it
4. Confirm to the user what pipeline change was made

If you skip step 2-4, you have failed. The fix is worthless without the pipeline improvement.

---

## How You're Invoked (Shell Agent Mode)

`run.sh` reads `project/pipeline.json`, determines the current step, loads the step template from `project/steps/{step}.md`, and passes you a focused prompt. **Follow that prompt.** Do not read CLAUDE.md for task instructions — your task is in the prompt.

### Focus on the task
- Your prompt tells you exactly what to do. Do that, update pipeline.json, update STATUS.md, exit.
- Do NOT read extra project files unless your prompt tells you to.
- Do NOT try to figure out "what's next" — the shell script handles sequencing.

### Quality
- Production quality only. No placeholders, no "TODO: fix later", no temporary solutions.

### Live status updates (CRITICAL)
Update `STATUS.md` at every step transition so the human can watch progress in real time. Use this format:

```markdown
# Autoplate Status

**Current:** {item name} → `{step}`
**Step started:** {ISO timestamp}
**Completed:** {n} / {total} items

## Activity Log

- `HH:MM` `step-name` — What you're doing right now
- `HH:MM` `step-name` — Previous step description
```

Rules:
- Write to STATUS.md **immediately** when you start, before doing anything else
- Add a new line to Activity Log for each sub-step (newest first)
- Keep entries short — one line each
- Keep last 20 entries max

### Code standards
- Handle edge cases, error states, loading states, empty states
- Remove unused code, imports, variables. No dead code.
- Never commit secrets or credentials

### Browser automation (when steps need it)
Use `agent-browser` with CDP for all browser tasks. Chrome runs with CDP on port 9222.

Always open a new tab first:
```bash
agent-browser --cdp 9222 tab new
agent-browser --cdp 9222 open "https://example.com"
agent-browser --cdp 9222 snapshot -i
agent-browser --cdp 9222 eval "document.querySelector('button').click()"
```

Known CDP bug: `click`, `fill`, `type`, `screenshot` commands fail. Use `eval` for all interactions.
Working commands: `open`, `tab`, `tab list`, `tab new`, `snapshot`, `eval`.

### Blocked items
If you can't proceed without human input, add it to `project/BLOCKED.md`.

## Project Context
- Read `PROJECT.md` for what this project is about
- Step prompt templates live in `project/steps/*.md`
- Pipeline state is in `project/pipeline.json`
- Working files go in `temp/` (never `/tmp/`)

## Temp Files
Never use `/tmp/`. Use the `temp/` directory within this project.
