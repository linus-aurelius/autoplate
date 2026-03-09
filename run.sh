#!/bin/bash
# Autoplate — generic autonomous pipeline engine
#
# Architecture:
# - Shell reads project/pipeline.json to determine current state
# - Reads step prompt templates from project/steps/{step}.md
# - Builds a focused, step-specific prompt for Claude Code
# - Adjusts --max-turns and --model per step (from frontmatter)
# - Handles stuck detection, blocking, and adaptive cooldown
#
# Usage:
#   ./run.sh setup    Interactive project setup (generates pipeline + step templates)
#   ./run.sh once     Run a single cycle then exit
#   ./run.sh loop     Run continuously (loop with cooldown)
#   ./run.sh dev      Run continuously, stop on first stuck step
#   ./run.sh stop     Stop a running loop
#   ./run.sh add-step Add a new step template

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIPELINE="$PROJECT_DIR/project/pipeline.json"
STEPS_DIR="$PROJECT_DIR/project/steps"
LOG_DIR="$PROJECT_DIR/temp/logs"
PID_FILE="$PROJECT_DIR/temp/autoplate.pid"
CLAUDE="$(which claude 2>/dev/null || echo "$HOME/.local/bin/claude")"
COOLDOWN=120
CDP_PORT=9222

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

mkdir -p "$LOG_DIR"
cd "$PROJECT_DIR"

# --- Utilities ---

notify() {
  osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" 2>/dev/null
}

log() {
  echo "[$(date +%H:%M:%S)] $1"
}

ensure_chrome_cdp() {
  if curl -s "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    return 0
  fi

  if pgrep -f "Google Chrome" > /dev/null 2>&1; then
    log "Chrome running without CDP. Restarting with CDP on port $CDP_PORT..."
    pkill -f "Google Chrome"
    sleep 2
  fi

  log "Starting Chrome with CDP on port $CDP_PORT..."
  if [ -f "$PROJECT_DIR/scripts/launch-chrome.sh" ]; then
    bash "$PROJECT_DIR/scripts/launch-chrome.sh"
  else
    open -a "Google Chrome" --args --remote-debugging-port=$CDP_PORT
  fi

  local attempts=0
  while [ $attempts -lt 15 ]; do
    if curl -s "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
      log "Chrome CDP ready"
      return 0
    fi
    sleep 2
    attempts=$((attempts + 1))
  done

  log "ERROR: Chrome CDP not available after 30s"
  return 1
}

# --- Step Frontmatter Parsing ---
# Parses YAML frontmatter from step template files.
# No external dependencies — pure Python.

parse_frontmatter() {
  local step_file="$1" field="$2" default="$3"
  python3 - "$step_file" "$field" "$default" << 'PYEOF'
import sys, re

step_file, field, default = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(step_file) as f:
        content = f.read()
except FileNotFoundError:
    print(default)
    sys.exit(0)

# Extract frontmatter between --- markers
m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not m:
    print(default)
    sys.exit(0)

fm = m.group(1)

# Simple YAML parsing (key: value on single lines)
for line in fm.split('\n'):
    line = line.strip()
    if line.startswith(field + ':'):
        val = line[len(field) + 1:].strip()
        # Strip quotes if present
        if val and val[0] in ('"', "'") and val[-1] == val[0]:
            val = val[1:-1]
        print(val)
        sys.exit(0)

print(default)
PYEOF
}

parse_prerequisites() {
  # Returns prerequisites as tab-separated lines: path\tmin_size
  local step_file="$1"
  python3 - "$step_file" << 'PYEOF'
import sys, re

step_file = sys.argv[1]

try:
    with open(step_file) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)

m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not m:
    sys.exit(0)

fm = m.group(1)

# Find prerequisites section
in_prereqs = False
for line in fm.split('\n'):
    stripped = line.strip()
    if stripped.startswith('prerequisites:'):
        in_prereqs = True
        # Check for empty list: prerequisites: []
        if '[]' in stripped:
            sys.exit(0)
        continue
    if in_prereqs:
        if stripped.startswith('- '):
            # Could be "- path: ..." format
            pass
        elif not stripped.startswith('path:') and not stripped.startswith('min_size:') and stripped and not stripped.startswith('-'):
            break  # New top-level key

        if 'path:' in stripped:
            path = stripped.split('path:')[1].strip().strip('"').strip("'")
            # Look for min_size on next line or same entry
            min_size = "0"
        elif 'min_size:' in stripped:
            min_size = stripped.split('min_size:')[1].strip()
            print(f"{path}\t{min_size}")
PYEOF
}

get_step_body() {
  # Returns the prompt body (everything after frontmatter)
  local step_file="$1"
  python3 - "$step_file" << 'PYEOF'
import sys, re

step_file = sys.argv[1]

try:
    with open(step_file) as f:
        content = f.read()
except FileNotFoundError:
    print(f"ERROR: Step file not found: {step_file}")
    sys.exit(1)

# Remove frontmatter
content = re.sub(r'^---\s*\n.*?\n---\s*\n', '', content, count=1, flags=re.DOTALL)
print(content.strip())
PYEOF
}

# --- Pipeline State ---

get_project_name() {
  python3 -c "import json; print(json.load(open('$PIPELINE')).get('projectName', 'Unnamed Project'))" 2>/dev/null
}

get_steps_list() {
  # Returns space-separated list of step names
  python3 -c "import json; print(' '.join(json.load(open('$PIPELINE')).get('steps', [])))" 2>/dev/null
}

get_next_step() {
  # Given current step, return the next step in the sequence
  local current_step="$1"
  python3 - "$PIPELINE" "$current_step" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    d = json.load(f)

current = sys.argv[2]
steps = d.get('steps', [])

if current in steps:
    idx = steps.index(current)
    if idx + 1 < len(steps):
        print(steps[idx + 1])
    else:
        print('__done__')
else:
    print(steps[0] if steps else '__done__')
PYEOF
}

read_pipeline_state() {
  # Outputs tab-separated: status, slug, name, step, stepData(json), mode
  python3 - "$PIPELINE" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    d = json.load(f)

current = d.get('current')
mode = d.get('mode', 'pipeline')
steps = d.get('steps', [])

if not current:
    # Pick in-progress items first, then pending
    for item in d.get('items', []):
        if item['status'] == 'in-progress':
            sd = json.dumps(item.get('stepData', {}))
            print(f"{item['status']}\t{item['slug']}\t{item['name']}\t{item.get('step','none')}\t{sd}\t{mode}")
            sys.exit(0)
    for item in d.get('items', []):
        if item['status'] == 'pending':
            print(f"pending\t{item['slug']}\t{item['name']}\tnone\t{{}}\t{mode}")
            sys.exit(0)
    print(f"done\t\t\tnone\t{{}}\t{mode}")
    sys.exit(0)

for item in d.get('items', []):
    if item['slug'] == current:
        sd = json.dumps(item.get('stepData', {}))
        print(f"{item['status']}\t{item['slug']}\t{item['name']}\t{item.get('step','none')}\t{sd}\t{mode}")
        sys.exit(0)

print(f"error\t\t\tnone\t{{}}\t{mode}")
PYEOF
}

advance_pipeline() {
  local slug="$1" new_step="$2" new_step_data="${3:-{\}}"
  python3 - "$PIPELINE" "$slug" "$new_step" "$new_step_data" << 'PYEOF'
import json, sys

pipeline_path, slug, new_step, new_step_data = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(pipeline_path) as f:
    d = json.load(f)

for item in d.get('items', []):
    if item['slug'] == slug:
        item['step'] = new_step
        item['stepData'] = json.loads(new_step_data)
        break

with open(pipeline_path, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
}

start_item() {
  local slug="$1"
  local first_step
  first_step=$(python3 -c "import json; print(json.load(open('$PIPELINE')).get('steps', ['none'])[0])" 2>/dev/null)

  python3 - "$PIPELINE" "$slug" "$first_step" << 'PYEOF'
import json, sys

pipeline_path, slug, first_step = sys.argv[1], sys.argv[2], sys.argv[3]

with open(pipeline_path) as f:
    d = json.load(f)

d['current'] = slug
for item in d.get('items', []):
    if item['slug'] == slug:
        item['status'] = 'in-progress'
        item['step'] = first_step
        item['stepData'] = {}
        break

with open(pipeline_path, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
}

complete_item() {
  local slug="$1"
  python3 - "$PIPELINE" "$slug" << 'PYEOF'
import json, sys

pipeline_path, slug = sys.argv[1], sys.argv[2]

with open(pipeline_path) as f:
    d = json.load(f)

d['current'] = None
for item in d.get('items', []):
    if item['slug'] == slug:
        item['status'] = 'completed'
        item['step'] = None
        item['stepData'] = {}
        break

with open(pipeline_path, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
}

# --- STATUS.md ---

update_status_file() {
  local item_name="$1" step="$2" message="$3"
  local status_file="$PROJECT_DIR/STATUS.md"
  local now
  now=$(date +%H:%M)
  local completed
  completed=$(python3 -c "import json; d=json.load(open('$PIPELINE')); print(sum(1 for k in d.get('items',[]) if k['status']=='completed'))" 2>/dev/null)
  local total
  total=$(python3 -c "import json; d=json.load(open('$PIPELINE')); print(len(d.get('items',[])))" 2>/dev/null)

  python3 - "$status_file" "$now" "${item_name:-idle}" "${step:---}" "$message" "$completed" "$total" << 'PYEOF'
import os, re, sys

status_file = sys.argv[1]
now = sys.argv[2]
item_name = sys.argv[3]
step = sys.argv[4]
message = sys.argv[5]
completed = sys.argv[6]
total = sys.argv[7]

entry = f'- `{now}` `{step}` — {message}'

if not os.path.exists(status_file):
    content = f"""# Autoplate Status

**Current:** {item_name} → `{step}`
**Step started:** —
**Completed:** {completed} / {total} items

## Activity Log

{entry}
"""
else:
    with open(status_file) as f:
        content = f.read()
    content = re.sub(r'\*\*Current:\*\*.*', f'**Current:** {item_name} → `{step}`', content)
    content = re.sub(r'\*\*Completed:\*\*.*', f'**Completed:** {completed} / {total} items', content)

    log_marker = '## Activity Log'
    if log_marker in content:
        parts = content.split(log_marker, 1)
        lines = parts[1].strip().split('\n')
        new_log = '\n\n' + entry + '\n' + '\n'.join(lines[:19])
        content = parts[0] + log_marker + new_log + '\n'

with open(status_file, 'w') as f:
    f.write(content)
PYEOF
}

# --- Stuck Detection & Recovery ---

get_stuck_count() {
  local slug="$1" step="$2"
  local stuck_file="$PROJECT_DIR/temp/.stuck_state"
  local current_state="${slug}|${step}"

  if [ -f "$stuck_file" ]; then
    local prev_state prev_count
    prev_state=$(head -1 "$stuck_file")
    prev_count=$(tail -1 "$stuck_file")
    if [ "$current_state" = "$prev_state" ]; then
      echo "$prev_count"
      return
    fi
  fi
  echo "0"
}

increment_stuck() {
  local slug="$1" step="$2"
  local stuck_file="$PROJECT_DIR/temp/.stuck_state"
  local current_state="${slug}|${step}"
  local count

  if [ -f "$stuck_file" ]; then
    local prev_state prev_count
    prev_state=$(head -1 "$stuck_file")
    prev_count=$(tail -1 "$stuck_file")
    if [ "$current_state" = "$prev_state" ]; then
      count=$((prev_count + 1))
    else
      count=1
    fi
  else
    count=1
  fi

  echo "$current_state" > "$stuck_file"
  echo "$count" >> "$stuck_file"
  echo "$count"
}

reset_stuck() {
  rm -f "$PROJECT_DIR/temp/.stuck_state"
}

block_item() {
  local slug="$1" step="$2" reason="$3"
  local blocked_file="$PROJECT_DIR/project/BLOCKED.md"

  # Append to BLOCKED.md
  echo "- **$slug** at \`$step\`: $reason ($(date -u +%Y-%m-%dT%H:%M:%SZ))" >> "$blocked_file"

  # Reset item to pending, clear current
  python3 - "$PIPELINE" "$slug" << 'PYEOF'
import json, sys

pipeline_path, slug = sys.argv[1], sys.argv[2]

with open(pipeline_path) as f:
    d = json.load(f)

d['current'] = None
for item in d.get('items', []):
    if item['slug'] == slug:
        item['status'] = 'pending'
        item['step'] = None
        item['stepData'] = {}
        break

with open(pipeline_path, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF

  reset_stuck
  notify "Autoplate — Blocked" "$slug: $reason"
  update_status_file "$slug" "$step" "BLOCKED: $reason — skipping to next item"
  log "BLOCKED $slug at $step: $reason"
}

# --- Prerequisite Verification ---

verify_prerequisites() {
  local slug="$1" step="$2"
  local step_file="$STEPS_DIR/${step}.md"

  if [ ! -f "$step_file" ]; then
    return 0  # No step file = no prerequisites to check
  fi

  local prereqs
  prereqs=$(parse_prerequisites "$step_file")

  if [ -z "$prereqs" ]; then
    return 0
  fi

  while IFS=$'\t' read -r path min_size; do
    # Replace template variables in path
    path=$(echo "$path" | sed "s|{{SLUG}}|$slug|g" | sed "s|{{PROJECT_DIR}}|$PROJECT_DIR|g")

    # Make relative paths absolute
    if [[ "$path" != /* ]]; then
      path="$PROJECT_DIR/$path"
    fi

    if [ ! -f "$path" ]; then
      log "VERIFY FAIL: prerequisite $path does not exist"
      return 1
    fi

    if [ "$min_size" -gt 0 ] 2>/dev/null; then
      local actual_size
      actual_size=$(wc -c < "$path" 2>/dev/null || echo 0)
      if [ "$actual_size" -lt "$min_size" ]; then
        log "VERIFY FAIL: $path is $actual_size bytes (need >= $min_size)"
        return 1
      fi
    fi
  done <<< "$prereqs"

  return 0
}

# --- Prompt Building ---

build_prompt() {
  local step="$1" slug="$2" item_name="$3" step_data="$4"
  local step_file="$STEPS_DIR/${step}.md"

  if [ ! -f "$step_file" ]; then
    echo "ERROR: Step template not found: $step_file. Create it or run './run.sh add-step $step'."
    return 1
  fi

  local project_name
  project_name=$(get_project_name)

  local next_step
  next_step=$(get_next_step "$step")

  local body
  body=$(get_step_body "$step_file")

  # Replace template variables
  echo "$body" | sed \
    -e "s|{{ITEM}}|$item_name|g" \
    -e "s|{{SLUG}}|$slug|g" \
    -e "s|{{STEP_DATA}}|$step_data|g" \
    -e "s|{{PROJECT_DIR}}|$PROJECT_DIR|g" \
    -e "s|{{PROJECT_NAME}}|$project_name|g" \
    -e "s|{{NEXT_STEP}}|$next_step|g" \
    -e "s|{{STEP}}|$step|g"
}

# --- Main Cycle ---

run_cycle() {
  local LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"

  # Write heartbeat for external monitoring
  date +%s > "$PROJECT_DIR/temp/.heartbeat"

  # Read pipeline state
  local state
  state=$(read_pipeline_state)
  local status slug item_name step step_data mode
  status=$(echo "$state" | cut -f1)
  slug=$(echo "$state" | cut -f2)
  item_name=$(echo "$state" | cut -f3)
  step=$(echo "$state" | cut -f4)
  step_data=$(echo "$state" | cut -f5)
  mode=$(echo "$state" | cut -f6)

  log "State: status=$status slug=$slug step=$step mode=$mode"

  if [ "$status" = "done" ]; then
    log "All items completed!"
    notify "Autoplate — Complete" "All items completed!"

    # In iteration mode, cycle back: reset the single item to pending with step=first
    if [ "$mode" = "iteration" ]; then
      log "Iteration mode: cycling back to first step"
      python3 - "$PIPELINE" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    d = json.load(f)

for item in d.get('items', []):
    if item['status'] == 'completed':
        item['status'] = 'pending'
        item['step'] = None
        item['stepData'] = {}

d['current'] = None

with open(sys.argv[1], 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
      return 0
    fi

    return 0
  fi

  if [ "$status" = "error" ]; then
    log "Error reading pipeline state"
    return 1
  fi

  # For pending items, start them in pipeline.json
  if [ "$status" = "pending" ]; then
    start_item "$slug"
    step=$(python3 -c "import json; print(json.load(open('$PIPELINE')).get('steps', ['none'])[0])" 2>/dev/null)
    reset_stuck
  fi

  # Check if this step is the completion marker
  if [ "$step" = "__done__" ]; then
    log "Item $slug completed all steps"
    complete_item "$slug"
    update_status_file "$item_name" "done" "All steps completed"
    return 0
  fi

  local step_file="$STEPS_DIR/${step}.md"

  # Check step template exists
  if [ ! -f "$step_file" ]; then
    log "ERROR: No step template at $step_file"
    update_status_file "$item_name" "$step" "ERROR: missing step template $step_file"
    return 1
  fi

  # Verify previous step produced its artifacts
  if ! verify_prerequisites "$slug" "$step"; then
    log "Prerequisites missing. Will retry next cycle."
    update_status_file "$item_name" "$step" "Waiting — prerequisites not met"
    return 0
  fi

  # Stuck detection
  local stuck_count max_cycles
  stuck_count=$(increment_stuck "$slug" "$step")
  max_cycles=$(parse_frontmatter "$step_file" "max_cycles" "10")

  if [ "$stuck_count" -ge "$max_cycles" ]; then
    block_item "$slug" "$step" "Stuck for $stuck_count cycles (limit: $max_cycles)"
    return 0
  fi

  # Read step config from frontmatter
  local max_turns model needs_chrome
  max_turns=$(parse_frontmatter "$step_file" "max_turns" "25")
  model=$(parse_frontmatter "$step_file" "model" "sonnet")
  needs_chrome=$(parse_frontmatter "$step_file" "needs_chrome" "false")

  # Build prompt from step template
  local prompt
  prompt=$(build_prompt "$step" "$slug" "$item_name" "$step_data")

  if [ $? -ne 0 ]; then
    log "ERROR building prompt: $prompt"
    return 1
  fi

  log "Spawning Claude: step=$step model=$model max_turns=$max_turns stuck=$stuck_count/$max_cycles → $LOG_FILE"
  update_status_file "$item_name" "$step" "Starting cycle (model=$model, stuck=$stuck_count/$max_cycles)"

  # Ensure Chrome CDP is running for browser steps
  if [ "$needs_chrome" = "true" ]; then
    if ! ensure_chrome_cdp; then
      log "ERROR: Chrome CDP not available. Skipping cycle."
      update_status_file "$item_name" "$step" "ERROR: Chrome CDP not available"
      return 1
    fi
  fi

  # Run Claude
  local -a cmd=("$CLAUDE" -p "$prompt" --model "$model" --permission-mode bypassPermissions --max-turns "$max_turns" --verbose --output-format stream-json)

  "${cmd[@]}" > "$LOG_FILE" 2>&1
  local exit_code=$?

  log "Cycle complete (exit=$exit_code)"
  update_status_file "$item_name" "$step" "Cycle complete (exit=$exit_code)"
}

# --- Setup Command ---

run_setup() {
  log "Starting interactive project setup..."

  if [ ! -f "$PROJECT_DIR/PROJECT.md" ]; then
    echo "ERROR: PROJECT.md not found. Create it first with your project description."
    echo "See PROJECT.md template in the repo."
    exit 1
  fi

  local project_desc
  project_desc=$(cat "$PROJECT_DIR/PROJECT.md")

  local prompt
  read -r -d '' prompt << 'SETUP_PROMPT'
You are the autoplate setup agent. Your job is to set up an autonomous pipeline for a new project.

Read the user's project description below, then:

1. ASK CLARIFYING QUESTIONS about anything unclear:
   - What exactly should each step produce?
   - What tools/CLIs are available?
   - What quality checks matter?
   - For pipeline mode: confirm the items list
   - For iteration mode: what does "done" look like for each cycle?

2. After getting answers, GENERATE these files:

   a. project/pipeline.json — with:
      - projectName filled in
      - mode ("pipeline" or "iteration")
      - steps array (ordered list of step names)
      - items array (each with name, slug, status: "pending")
      For iteration mode: single item with the project name

   b. project/steps/{step-name}.md — one file per step, each with:
      - YAML frontmatter: model, max_turns, needs_chrome, max_cycles, prerequisites
      - Detailed prompt template using {{ITEM}}, {{SLUG}}, {{PROJECT_NAME}}, {{NEXT_STEP}}, {{STEP_DATA}}
      - The prompt should tell Claude exactly what to do, what to read, what to produce
      - Include quality checks and validation steps
      - End with: "Update pipeline.json step" and "Update STATUS.md"

3. Verify:
   - All step files referenced in pipeline.json exist in project/steps/
   - Prerequisites chain correctly (step 2's prereqs are step 1's outputs)
   - Each prompt is self-contained (agent shouldn't need to read other docs)

PROJECT DESCRIPTION:
SETUP_PROMPT

  prompt="$prompt

$project_desc"

  echo ""
  echo "=== Autoplate Setup ==="
  echo "Launching interactive Claude session to configure your pipeline."
  echo "Claude will ask you questions about your project, then generate step templates."
  echo ""

  "$CLAUDE" -p "$prompt" --model "sonnet" --permission-mode default --max-turns 50 --verbose
}

# --- Add Step Command ---

add_step() {
  local step_name="$1"

  if [ -z "$step_name" ]; then
    echo "Usage: ./run.sh add-step <step-name>"
    echo "Example: ./run.sh add-step research"
    exit 1
  fi

  local step_file="$STEPS_DIR/${step_name}.md"

  if [ -f "$step_file" ]; then
    echo "Step already exists: $step_file"
    exit 1
  fi

  cat > "$step_file" << TEMPLATE
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
3. Read project/pipeline.json, then update it: set this item's step to "{{NEXT_STEP}}"
4. Update STATUS.md with progress

RULES:
- Do NOT read CLAUDE.md or other project docs unless your task requires it
- Do NOT try to figure out "what's next" — the shell script handles sequencing
- Focus ONLY on the task described above
TEMPLATE

  echo "Created step template: $step_file"
  echo "Edit it to define what this step should do."

  # Add to pipeline.json steps array if not already there
  python3 - "$PIPELINE" "$step_name" << 'PYEOF'
import json, sys

pipeline_path, step_name = sys.argv[1], sys.argv[2]

with open(pipeline_path) as f:
    d = json.load(f)

if step_name not in d.get('steps', []):
    d.setdefault('steps', []).append(step_name)
    with open(pipeline_path, 'w') as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print(f"Added '{step_name}' to pipeline.json steps")
else:
    print(f"'{step_name}' already in pipeline.json steps")
PYEOF
}

# --- Entry Points ---

case "${1:-help}" in
  setup)
    run_setup
    ;;
  add-step)
    add_step "$2"
    ;;
  once)
    if [ ! -f "$PIPELINE" ] || [ "$(python3 -c "import json; d=json.load(open('$PIPELINE')); print(len(d.get('items',[])))" 2>/dev/null)" = "0" ]; then
      echo "No items in pipeline. Run './run.sh setup' first."
      exit 1
    fi
    run_cycle
    ;;
  dev)
    if [ ! -f "$PIPELINE" ] || [ "$(python3 -c "import json; d=json.load(open('$PIPELINE')); print(len(d.get('items',[])))" 2>/dev/null)" = "0" ]; then
      echo "No items in pipeline. Run './run.sh setup' first."
      exit 1
    fi

    echo "[$(date)] Dev mode started — will stop on first stuck step"
    while true; do
      _before_state=$(read_pipeline_state)
      _before_step=$(echo "$_before_state" | cut -f4)
      _before_slug=$(echo "$_before_state" | cut -f2)
      _before_status=$(echo "$_before_state" | cut -f1)

      if [ "$_before_status" = "done" ]; then
        _mode=$(echo "$_before_state" | cut -f6)
        if [ "$_mode" = "iteration" ]; then
          echo "Iteration cycle complete — restarting"
        else
          echo "ALL DONE — all items completed"
          break
        fi
      fi

      echo "[$(date)] Running cycle: $_before_slug @ $_before_step"
      run_cycle

      _after_state=$(read_pipeline_state)
      _after_step=$(echo "$_after_state" | cut -f4)
      _after_slug=$(echo "$_after_state" | cut -f2)
      _after_status=$(echo "$_after_state" | cut -f1)

      if [ "$_after_slug" != "$_before_slug" ] || [ "$_after_step" != "$_before_step" ] || [ "$_after_status" != "$_before_status" ]; then
        echo "[$(date)] ADVANCED: $_before_slug/$_before_step → $_after_slug/$_after_step"
        sleep 10
      else
        echo ""
        echo "============================================"
        echo "  STUCK: $_before_slug @ $_before_step"
        echo "  Step did not advance after this cycle."
        echo "  Latest log: $(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)"
        echo "============================================"
        break
      fi
    done
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      PID=$(cat "$PID_FILE")
      if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        rm "$PID_FILE"
        echo "Stopped autoplate (PID $PID)"
      else
        rm "$PID_FILE"
        echo "Process $PID not running (stale PID file removed)"
      fi
    else
      echo "No running autoplate found"
    fi
    ;;
  loop)
    if [ ! -f "$PIPELINE" ] || [ "$(python3 -c "import json; d=json.load(open('$PIPELINE')); print(len(d.get('items',[])))" 2>/dev/null)" = "0" ]; then
      echo "No items in pipeline. Run './run.sh setup' first."
      exit 1
    fi

    if [ -f "$PID_FILE" ]; then
      OLD_PID=$(cat "$PID_FILE")
      if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Autoplate already running (PID $OLD_PID). Use './run.sh stop' first."
        exit 1
      fi
      rm "$PID_FILE"
    fi

    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; echo "[$(date)] Autoplate stopped"; exit 0' INT TERM

    echo "[$(date)] Autoplate started (PID $$, cooldown ${COOLDOWN}s)"
    while true; do
      run_cycle
      echo "[$(date)] Cooling down ${COOLDOWN}s..."
      sleep "$COOLDOWN"
    done
    ;;
  help|*)
    cat << 'USAGE'
Autoplate — Generic Autonomous Pipeline Engine

Usage:
  ./run.sh setup      Interactive project setup (generates pipeline + step templates)
  ./run.sh once       Run a single cycle then exit
  ./run.sh loop       Run continuously (loop with cooldown)
  ./run.sh dev        Run continuously, stop on first stuck step
  ./run.sh stop       Stop a running loop
  ./run.sh add-step   Add a new step template

Getting started:
  1. Edit PROJECT.md with your project description
  2. Run ./run.sh setup — Claude will ask questions and generate your pipeline
  3. Run ./run.sh dev — watch it work, fix issues, iterate

Project structure:
  PROJECT.md              Your project description
  project/pipeline.json   State machine (items + steps)
  project/steps/*.md      Step prompt templates (one per step)
  project/BLOCKED.md      Items that got stuck
  STATUS.md               Live progress (auto-generated)
  temp/logs/              Execution logs
USAGE
    ;;
esac
