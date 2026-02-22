# BMAD Autopilot

Autonomous implementation loop for the BMAD framework, using Claude Code CLI (`claude -p`) to execute workflows without manual intervention.

---

## Installation

```bash
# Clone the repo
git clone git@github.com:devscompute/bmad-autopilot.git

# Install into any BMAD project
./bmad-autopilot/install.sh /path/to/your/bmad-project
```

## Quick Start

```bash
# From project root
./.scripts/bmad-auto/bmad-loop.sh

# Dry run (shows what would happen, no claude invocations)
./.scripts/bmad-auto/bmad-loop.sh --dry-run

# Limit iterations (safety cap, default 100)
./.scripts/bmad-auto/bmad-loop.sh --max-loops 10

# No terminal colors
./.scripts/bmad-auto/bmad-loop.sh --no-color
```

---

## How It Works

1. **Reads** `_bmad-output/implementation-artifacts/sprint-status.yaml`
2. **Picks the next action** using this priority order:
   | Priority | Story Status | Workflow Run |
   |----------|-------------|--------------|
   | 1 | `in-progress` | `dev-story` (resume) |
   | 2 | `review` | `code-review` |
   | 3 | `ready-for-dev` | `dev-story` |
   | 4 | `backlog` | `create-story` |
   | 5 | all done | retrospective prompt → congratulate |
3. **Executes** the workflow by calling `claude -p` with a self-contained prompt
4. **Loops** — re-reads sprint-status.yaml and picks the next action
5. **Pauses at epic boundaries** to optionally run retrospectives

---

## Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `claude` CLI | ✅ Yes | Runs workflows via `claude -p` |
| `yq` | Optional | YAML parsing (falls back to grep/awk if missing) |
| `bash` 4+ | ✅ Yes | Script runtime |

### Install claude CLI
```bash
npm install -g @anthropic-ai/claude-code
```

### Install yq (recommended)
```bash
brew install yq
```

---

## Sprint Status Format

The script reads `_bmad-output/implementation-artifacts/sprint-status.yaml`:

```yaml
development_status:
  epic-1: in-progress
  1-1-user-authentication: done
  1-2-account-management: ready-for-dev
  1-3-plant-data-model: backlog
  epic-1-retrospective: optional

  epic-2: backlog
  2-1-personality-system: backlog
  epic-2-retrospective: optional
```

**Valid story statuses:** `backlog` | `ready-for-dev` | `in-progress` | `review` | `done`
**Valid epic statuses:** `backlog` | `in-progress` | `done`
**Retrospective statuses:** `optional` | `done`

---

## Control File

Create `.scripts/bmad-auto/control` to control a running loop:

```bash
# Pause the loop after the current workflow completes
echo "pause" > .scripts/bmad-auto/control

# Skip the current story (marks it backlog)
echo "skip" > .scripts/bmad-auto/control

# Print sprint summary without stopping
echo "status" > .scripts/bmad-auto/control

# Resume after pause
rm .scripts/bmad-auto/control
```

---

## Logs

All runs are logged to `.scripts/bmad-auto/logs/`:

| File | Contents |
|------|----------|
| `bmad-auto-YYYY-MM-DD.log` | Main loop log with timestamps |
| `run-TIMESTAMP-WORKFLOW-STORY.log` | Full claude output per workflow run |

---

## Safety Rails

| Trigger | Action |
|---------|--------|
| 3 consecutive `claude` failures | **HALT** — manual intervention required |
| `sprint-status.yaml` missing | **HALT** — run sprint planning first |
| `claude` not in PATH | **HALT** — install claude CLI |
| `--max-loops` exceeded | Stop gracefully |
| `Ctrl+C` | Stop gracefully after current workflow |

---

## Prompt Template

`bmad-prompt.md` is the template for all `claude -p` invocations. It uses these placeholders:

| Placeholder | Value |
|-------------|-------|
| `{{WORKFLOW_NAME}}` | e.g., `dev-story` |
| `{{WORKFLOW_PATH}}` | Full path to workflow.yaml |
| `{{STORY_KEY}}` | e.g., `1-2-account-management` |
| `{{STORY_STATUS}}` | e.g., `ready-for-dev` |
| `{{PROJECT_ROOT}}` | Absolute project root path |
| `{{SPRINT_STATUS_PATH}}` | Full path to sprint-status.yaml |
| `{{WORKFLOW_ENGINE_PATH}}` | Full path to workflow.xml |
| `{{BMM_CONFIG_PATH}}` | Full path to config.yaml |

---

## File Structure

```
.scripts/bmad-auto/
├── bmad-loop.sh        ← Main automation script (run this)
├── bmad-prompt.md      ← Prompt template for claude -p
├── README.md           ← This file
├── control             ← Optional: write "pause"/"skip"/"status"
└── logs/
    ├── bmad-auto-2025-01-15.log
    └── run-20250115-143022-dev-story-1-2-account-management.log
```

---

## Epic Boundary Behavior

When all stories in an epic are `done` and a retrospective is `optional`:

1. The loop **pauses** and asks:
   > `Run retrospective for epic-1-retrospective now? [Y/n]`
2. If **yes** → runs retrospective, marks it done, continues
3. If **no** → marks it done (skipped), continues to next epic

---

## YOLO Mode

Each `claude -p` invocation runs in **YOLO mode**, meaning Claude:
- Skips all interactive prompts
- Auto-continues through template checkpoints
- Makes decisions autonomously (most productive option)
- Never stops mid-implementation to ask questions
- Logs decisions to `.bmad-decisions.md` when truly ambiguous

---

## Troubleshooting

**"sprint-status.yaml not found"**
→ Run sprint planning first to generate the status file.

**"claude CLI not found"**
→ `npm install -g @anthropic-ai/claude-code` and ensure it's in PATH.

**Loop halted after 3 failures**
→ Check `logs/` for the failing workflow output. Fix the issue, then restart the loop.

**Story stuck in `in-progress`**
→ The previous claude invocation may have failed to update sprint-status.yaml. Manually update the status to `ready-for-dev` to retry, or `done` if it was actually completed.
