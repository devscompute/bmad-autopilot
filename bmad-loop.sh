#!/usr/bin/env bash
# =============================================================================
# BMAD Autopilot — bmad-loop.sh
# Autonomous implementation loop for Claude Code CLI
# =============================================================================
# Usage: ./bmad-loop.sh [--dry-run] [--max-loops N] [--no-color]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (relative to project root, resolved at startup)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SPRINT_STATUS="$PROJECT_ROOT/_bmad-output/implementation-artifacts/sprint-status.yaml"
PROMPT_TEMPLATE="$SCRIPT_DIR/bmad-prompt.md"
CONTROL_FILE="$SCRIPT_DIR/control"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/bmad-auto-$(date +%Y-%m-%d).log"

WORKFLOW_BASE="$PROJECT_ROOT/_bmad/bmm/workflows/4-implementation"
WORKFLOW_ENGINE="$PROJECT_ROOT/_bmad/core/tasks/workflow.xml"
BMM_CONFIG="$PROJECT_ROOT/_bmad/bmm/config.yaml"

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
DRY_RUN=false
MAX_LOOPS=100
MAX_EPICS=0   # 0 = unlimited; N = pause after N completed epics
QUALITY_PASS=false  # --quality-pass: run quick-spec+quick-dev fix pass after each epic retro
USE_COLOR=true
WORKFLOW_TIMEOUT_MINS=0  # 0 = no timeout; N = kill workflow after N minutes (uses macos_timeout)
CORRECTION_MODE=false

# ---------------------------------------------------------------------------
# OpenClaw webhook — direct ping to Devs when an epic is done
# Devs will then send Mr. T a Telegram message
# ---------------------------------------------------------------------------
OPENCLAW_HOOK_URL="http://127.0.0.1:18789/hooks/agent"
OPENCLAW_HOOK_TOKEN="cc27836aca3d3fbbaabdd2c18b451b0c45ef031c741f8e29"

# ---------------------------------------------------------------------------
# Dropbox retrospective archive
# ---------------------------------------------------------------------------
DROPBOX_RETRO_DIR="$HOME/Library/CloudStorage/Dropbox/Shared/03 Projects/oneshot-v2/epic-retrospectives"
DROPBOX_QP_DIR="$HOME/Library/CloudStorage/Dropbox/Shared/03 Projects/oneshot-v2/quality-passes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true ;;
    --no-color)       USE_COLOR=false ;;
    --correction-mode) CORRECTION_MODE=true ;;
    --quality-pass)    QUALITY_PASS=true ;;
    --max-loops)
      if [[ -n "${2:-}" ]]; then
        MAX_LOOPS="$2"; shift
      else
        echo "Error: --max-loops requires a value" >&2; exit 1
      fi
      ;;
    --max-loops=*) MAX_LOOPS="${1#*=}" ;;
    --max-epics)
      if [[ -n "${2:-}" ]]; then
        MAX_EPICS="$2"; shift
      else
        echo "Error: --max-epics requires a value" >&2; exit 1
      fi
      ;;
    --max-epics=*) MAX_EPICS="${1#*=}" ;;
    --timeout-mins)
      if [[ -n "${2:-}" ]]; then
        WORKFLOW_TIMEOUT_MINS="$2"; shift
      else
        echo "Error: --timeout-mins requires a value" >&2; exit 1
      fi
      ;;
    --timeout-mins=*) WORKFLOW_TIMEOUT_MINS="${1#*=}" ;;
  esac
  shift
done

if ! [[ "$MAX_LOOPS" =~ ^[0-9]+$ ]] || [[ "$MAX_LOOPS" -eq 0 ]]; then
  echo "Error: --max-loops must be a positive integer (got: '$MAX_LOOPS')" >&2
  exit 1
fi

if ! [[ "$MAX_EPICS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-epics must be a non-negative integer (got: '$MAX_EPICS')" >&2
  exit 1
fi

if ! [[ "$WORKFLOW_TIMEOUT_MINS" =~ ^[0-9]+$ ]]; then
  echo "Error: --timeout-mins must be a non-negative integer (got: '$WORKFLOW_TIMEOUT_MINS')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if $USE_COLOR && [ -t 1 ]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'
  C_CYAN='\033[0;36m'
  C_MAGENTA='\033[0;35m'
  C_GRAY='\033[0;90m'
else
  C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW=''
  C_BLUE='' C_CYAN='' C_MAGENTA='' C_GRAY=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $msg" >> "$LOG_FILE"

  case "$level" in
    INFO)    echo -e "${C_CYAN}[INFO]${C_RESET}  $msg" ;;
    OK)      echo -e "${C_GREEN}[OK]${C_RESET}    $msg" ;;
    WARN)    echo -e "${C_YELLOW}[WARN]${C_RESET}  $msg" ;;
    ERROR)   echo -e "${C_RED}[ERROR]${C_RESET} $msg" ;;
    STEP)    echo -e "${C_BOLD}${C_BLUE}[STEP]${C_RESET}  $msg" ;;
    HALT)    echo -e "${C_BOLD}${C_RED}[HALT]${C_RESET}  $msg" ;;
    EPIC)    echo -e "${C_BOLD}${C_MAGENTA}[EPIC]${C_RESET}  $msg" ;;
    DEBUG)   echo -e "${C_GRAY}[DEBUG]${C_RESET} $msg" ;;
    *)       echo -e "[$level] $msg" ;;
  esac
}

# ---------------------------------------------------------------------------
# YAML parsing (yq preferred, fallback to grep/awk)
# ---------------------------------------------------------------------------
HAS_YQ=false
if command -v yq &>/dev/null; then
  HAS_YQ=true
fi

# Get a scalar value from the sprint-status YAML
# Usage: yaml_get_key "some-key"  → prints value or empty string
yaml_get_key() {
  local key="$1"
  if $HAS_YQ; then
    yq e ".development_status.\"$key\" // \"\"" "$SPRINT_STATUS" 2>/dev/null || true
  else
    # grep-based fallback: look for "  key: value" under development_status
    awk -v k="$key" '
      /^development_status:/{in_block=1; next}
      in_block && /^[^ ]/{in_block=0}
      in_block && $0 ~ "^[[:space:]]+"k":" {
        gsub(/.*:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit
      }
    ' "$SPRINT_STATUS" 2>/dev/null || true
  fi
}

# Get ALL keys under development_status as "key=value" lines
yaml_get_all_status() {
  if $HAS_YQ; then
    yq e '.development_status | to_entries | .[] | .key + "=" + .value' "$SPRINT_STATUS" 2>/dev/null || true
  else
    awk '
      /^development_status:/{in_block=1; next}
      in_block && /^[^ ]/{in_block=0}
      in_block && /^[[:space:]]+[^#]/ {
        line=$0
        gsub(/^[[:space:]]+/, "", line)
        gsub(/:[[:space:]]+/, "=", line)
        gsub(/[[:space:]]+$/, "", line)
        print line
      }
    ' "$SPRINT_STATUS" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CONSECUTIVE_FAILURES=0
MAX_FAILURES=3
LAST_COMPLETED_EPIC=""
LOOP_COUNT=0
EPICS_COMPLETED=0
INTERRUPTED=false
CONTROL_ACTION=""
WORKFLOW_TIMED_OUT=false

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
cleanup() {
  INTERRUPTED=true
  echo ""
  log WARN "Interrupt received — will stop after current workflow completes."
}
trap cleanup SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Control file helpers
# ---------------------------------------------------------------------------
check_control() {
  CONTROL_ACTION=""
  [ -f "$CONTROL_FILE" ] || return 0
  local cmd
  cmd="$(tr '[:upper:]' '[:lower:]' < "$CONTROL_FILE" | xargs)"

  case "$cmd" in
    pause)
      log WARN "Control: PAUSE requested. Waiting for you to remove/change the control file."
      log WARN "  → Edit $CONTROL_FILE to 'resume' or delete it to continue."
      while [ -f "$CONTROL_FILE" ] && grep -qi "^pause" "$CONTROL_FILE" 2>/dev/null; do
        sleep 5
      done
      log OK "Control: Resumed."
      ;;
    skip)
      log WARN "Control: SKIP requested. Current story will be set to backlog."
      rm -f "$CONTROL_FILE"
      CONTROL_ACTION="SKIP"
      ;;
    status)
      rm -f "$CONTROL_FILE"
      print_sprint_summary
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Sprint summary printer
# ---------------------------------------------------------------------------
print_sprint_summary() {
  echo ""
  echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}   BMAD Sprint Status Summary${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════${C_RESET}"

  local entries
  entries="$(yaml_get_all_status)"

  if [ -z "$entries" ]; then
    log WARN "No development_status entries found."
    return
  fi

  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    local icon="?"
    case "$val" in
      done)         icon="✅" ;;
      in-progress)  icon="🔄" ;;
      review)       icon="🔍" ;;
      ready-for-dev) icon="🚀" ;;
      backlog)      icon="📋" ;;
      optional)     icon="📝" ;;
    esac
    printf "  %s  %-40s %s\n" "$icon" "$key" "$val"
  done <<< "$entries"
  echo ""
}

# ---------------------------------------------------------------------------
# Parse story key into epic_num and story_num
# Key format: "1-2-some-slug" or "epic-1" or "epic-1-retrospective"
# ---------------------------------------------------------------------------
parse_story_nums() {
  local key="$1"
  # Story key: first two numeric segments
  local epic_num story_num
  epic_num="$(echo "$key" | grep -oE '^[0-9]+' || echo "9999")"
  story_num="$(echo "$key" | sed 's/^[0-9]*-//' | grep -oE '^[0-9]+' || echo "9999")"
  echo "$epic_num $story_num"
}

is_story_key() {
  # True if key starts with digit (e.g., "1-2-user-auth")
  [[ "$1" =~ ^[0-9]+-[0-9]+ ]]
}

is_epic_key() {
  [[ "$1" =~ ^epic-[0-9]+$ ]]
}

is_retro_key() {
  [[ "$1" =~ ^epic-[0-9]+-retrospective$ ]]
}

epic_num_from_story() {
  echo "$1" | grep -oE '^[0-9]+'
}

epic_num_from_epic_key() {
  echo "$1" | grep -oE '[0-9]+$'
}

# ---------------------------------------------------------------------------
# Auto-detect correction mode
# If done stories exist in higher-numbered epics than any pending (non-done)
# story, this is a corrected-course project, not greenfield development.
# In greenfield flow, stories are processed strictly in order — later epics
# never have done stories while earlier epics still have pending work.
# ---------------------------------------------------------------------------
auto_detect_correction_mode() {
  local entries highest_done_epic=0 lowest_pending_epic=99999
  entries="$(yaml_get_all_status)"

  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    is_story_key "$key" || continue
    local epic
    epic="$(epic_num_from_story "$key")"
    if [ "$val" = "done" ]; then
      [ "$epic" -gt "$highest_done_epic" ] && highest_done_epic="$epic"
    else
      [ "$epic" -lt "$lowest_pending_epic" ] && lowest_pending_epic="$epic"
    fi
  done <<< "$entries"

  # Correction mode: done stories exist in later epics than pending stories
  [ "$highest_done_epic" -gt "$lowest_pending_epic" ]
}

# ---------------------------------------------------------------------------
# Determine next action from sprint-status.yaml
# Returns: "WORKFLOW|KEY|STATUS" or "DONE" or "RETRO|key" or "NONE"
# ---------------------------------------------------------------------------
determine_next_action() {
  local entries
  entries="$(yaml_get_all_status)"

  if [ -z "$entries" ]; then
    echo "NONE"
    return
  fi

  # Collect story entries sorted by epic_num, story_num
  local in_progress_key="" in_progress_status=""
  local review_key="" review_status=""
  local ready_key="" ready_status=""
  local backlog_key="" backlog_status=""

  # We'll build sorted lists
  local -a story_keys=()
  local -a story_vals=()

  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    if is_story_key "$key"; then
      # Safety guard: NEVER queue a story that is already done.
      # This protects correction-mode runs where done stories coexist with new backlog stories.
      [ "$val" = "done" ] && continue
      story_keys+=("$key")
      story_vals+=("$val")
    fi
  done <<< "$entries"

  # Sort stories by epic then story number
  local n="${#story_keys[@]}"
  # Simple insertion sort (small arrays)
  for (( i=1; i<n; i++ )); do
    local k="${story_keys[$i]}"
    local v="${story_vals[$i]}"
    local nums
    nums="$(parse_story_nums "$k")"
    local ei si
    ei=$(echo "$nums" | awk '{print $1}')
    si=$(echo "$nums" | awk '{print $2}')
    local j=$((i-1))
    while (( j >= 0 )); do
      local nums_j
      nums_j="$(parse_story_nums "${story_keys[$j]}")"
      local ej sj
      ej=$(echo "$nums_j" | awk '{print $1}')
      sj=$(echo "$nums_j" | awk '{print $2}')
      if (( ej > ei )) || (( ej == ei && sj > si )); then
        story_keys[$((j+1))]="${story_keys[$j]}"
        story_vals[$((j+1))]="${story_vals[$j]}"
        j=$((j-1))
      else
        break
      fi
    done
    story_keys[$((j+1))]="$k"
    story_vals[$((j+1))]="$v"
  done

  # Apply priority rules on sorted list
  for (( i=0; i<n; i++ )); do
    local key="${story_keys[$i]}"
    local val="${story_vals[$i]}"
    case "$val" in
      in-progress)
        [ -z "$in_progress_key" ] && in_progress_key="$key" && in_progress_status="$val"
        ;;
      review)
        [ -z "$review_key" ] && review_key="$key" && review_status="$val"
        ;;
      ready-for-dev)
        [ -z "$ready_key" ] && ready_key="$key" && ready_status="$val"
        ;;
      backlog)
        [ -z "$backlog_key" ] && backlog_key="$key" && backlog_status="$val"
        ;;
    esac
  done

  # Priority 1
  if [ -n "$in_progress_key" ]; then
    echo "dev-story|$in_progress_key|in-progress"
    return
  fi

  # Priority 2
  if [ -n "$review_key" ]; then
    echo "code-review|$review_key|review"
    return
  fi

  # Priority 3
  if [ -n "$ready_key" ]; then
    echo "dev-story|$ready_key|ready-for-dev"
    return
  fi

  # Priority 4
  if [ -n "$backlog_key" ]; then
    echo "create-story|$backlog_key|backlog"
    return
  fi

  # Priority 5: all stories done — check retrospectives
  local retro_key="" retro_val=""
  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    if is_retro_key "$key" && [ "$val" = "optional" ]; then
      retro_key="$key"
      retro_val="$val"
      break
    fi
  done <<< "$entries"

  if [ -n "$retro_key" ]; then
    echo "retro-prompt|$retro_key|optional"
    return
  fi

  echo "DONE"
}

# ---------------------------------------------------------------------------
# Epic boundary check
# Returns "true" if we should pause at this epic boundary
# ---------------------------------------------------------------------------
check_epic_boundary() {
  local next_story_key="$1"
  [ -z "$LAST_COMPLETED_EPIC" ] && return 1

  local next_epic
  next_epic="$(epic_num_from_story "$next_story_key")"
  [ "$next_epic" = "$LAST_COMPLETED_EPIC" ] && return 1

  # Check if all stories in LAST_COMPLETED_EPIC are done
  local entries
  entries="$(yaml_get_all_status)"
  local all_done=true

  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    if is_story_key "$key"; then
      local epic
      epic="$(epic_num_from_story "$key")"
      if [ "$epic" = "$LAST_COMPLETED_EPIC" ] && [ "$val" != "done" ]; then
        all_done=false
        break
      fi
    fi
  done <<< "$entries"

  if $all_done; then
    # Check if retro is optional (not already done)
    local retro_status
    retro_status="$(yaml_get_key "epic-${LAST_COMPLETED_EPIC}-retrospective")"
    if [ "$retro_status" = "optional" ]; then
      return 0  # yes, pause
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Build the prompt for claude -p
# ---------------------------------------------------------------------------
build_prompt() {
  local workflow_name="$1"
  local story_key="$2"
  local story_status="$3"
  local workflow_path="$WORKFLOW_BASE/$workflow_name/workflow.yaml"

  # Load template and substitute placeholders
  local template
  template="$(cat "$PROMPT_TEMPLATE")"

  template="${template//\{\{WORKFLOW_NAME\}\}/$workflow_name}"
  template="${template//\{\{WORKFLOW_PATH\}\}/$workflow_path}"
  template="${template//\{\{STORY_KEY\}\}/$story_key}"
  template="${template//\{\{STORY_STATUS\}\}/$story_status}"
  template="${template//\{\{PROJECT_ROOT\}\}/$PROJECT_ROOT}"
  template="${template//\{\{SPRINT_STATUS_PATH\}\}/$SPRINT_STATUS}"
  template="${template//\{\{WORKFLOW_ENGINE_PATH\}\}/$WORKFLOW_ENGINE}"
  template="${template//\{\{BMM_CONFIG_PATH\}\}/$BMM_CONFIG}"

  printf '%s\n' "$template"
}

# ---------------------------------------------------------------------------
# macOS-compatible timeout (Perl, available by default on macOS)
# Usage: macos_timeout <seconds> cmd [args...]
# Exits 124 on timeout, otherwise forwards the command's exit code.
# ---------------------------------------------------------------------------
macos_timeout() {
  local secs=$1; shift
  perl -e '
    my ($secs, @cmd) = @ARGV;
    my $pid = fork // die "fork failed: $!";
    if ($pid == 0) { exec @cmd; die "exec failed: $!"; }
    local $SIG{ALRM} = sub {
      kill "TERM", $pid; sleep 3; kill "KILL", $pid; exit 124;
    };
    alarm $secs;
    waitpid $pid, 0;
    alarm 0;
    exit 124 if $? == -1;
    exit($? >> 8);
  ' -- "$secs" "$@"
}

# ---------------------------------------------------------------------------
# Execute a workflow via claude -p
# ---------------------------------------------------------------------------
run_workflow() {
  local workflow_name="$1"
  local story_key="$2"
  local story_status="$3"

  local prompt
  prompt="$(build_prompt "$workflow_name" "$story_key" "$story_status")"

  log STEP "Running workflow: ${C_BOLD}$workflow_name${C_RESET} for story: ${C_BOLD}$story_key${C_RESET} (status: $story_status)"
  log INFO "Launching: claude -p ..."

  local ts_start
  ts_start="$(date +%s)"

  local run_log="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S)-${workflow_name}-${story_key}.log"

  if $DRY_RUN; then
    log WARN "[DRY RUN] Would execute: claude -p \"<prompt>\""
    log WARN "[DRY RUN] Prompt preview (first 5 lines):"
    echo "$prompt" | head -5 | sed 's/^/  > /' >&2
    return 0
  fi

  # Run claude and stream output to both terminal and log
  # To enable timeouts: pass --timeout-mins N (uses macos_timeout; exit code 124 = timed out)
  local exit_code=0
  if [ "$WORKFLOW_TIMEOUT_MINS" -gt 0 ]; then
    local timeout_secs=$((WORKFLOW_TIMEOUT_MINS * 60))
    printf '%s\n' "$prompt" | macos_timeout "$timeout_secs" claude -p --dangerously-skip-permissions --permission-mode bypassPermissions --model claude-opus-4-6 2>&1 | tee "$run_log" || exit_code=$?
  else
    printf '%s\n' "$prompt" | claude -p --dangerously-skip-permissions --permission-mode bypassPermissions --model claude-opus-4-6 2>&1 | tee "$run_log" || exit_code=$?
  fi

  # claude -p exits 0 even on some errors; check for explicit failure
  if [ $exit_code -ne 0 ]; then
    local ts_end
    ts_end="$(date +%s)"
    if [ $exit_code -eq 124 ]; then
      WORKFLOW_TIMED_OUT=true
      log ERROR "claude timed out after ${WORKFLOW_TIMEOUT_MINS}m (exit 124)"
      log WARN "The workflow may have done real work before hanging — check sprint-status.yaml before retrying"
    else
      WORKFLOW_TIMED_OUT=false
      log ERROR "claude exited with code $exit_code after $((ts_end - ts_start))s"
    fi
    log ERROR "Log saved to: $run_log"
    return $exit_code
  fi
  WORKFLOW_TIMED_OUT=false

  local ts_end
  ts_end="$(date +%s)"
  log OK "Workflow $workflow_name completed in $((ts_end - ts_start))s"
  log INFO "Full output saved to: $run_log"
  return 0
}

# ---------------------------------------------------------------------------
# Update a story's status directly in sprint-status.yaml
# ---------------------------------------------------------------------------
update_story_status() {
  local story_key="$1"
  local new_status="$2"

  if $HAS_YQ; then
    yq e ".development_status.\"$story_key\" = \"$new_status\"" -i "$SPRINT_STATUS"
  else
    # sed-based fallback
    sed -i.bak "s/^\([[:space:]]*\)${story_key}:.*$/\1${story_key}: ${new_status}/" "$SPRINT_STATUS"
    rm -f "${SPRINT_STATUS}.bak"
  fi
  log INFO "Updated $story_key → $new_status in sprint-status.yaml"
}

# ---------------------------------------------------------------------------
# Prompt user yes/no (returns 0=yes, 1=no)
# ---------------------------------------------------------------------------
ask_yes_no() {
  local question="$1"
  local default="${2:-y}"
  local prompt_str

  if [ "$default" = "y" ]; then
    prompt_str="[Y/n]"
  else
    prompt_str="[y/N]"
  fi

  # If not a TTY (e.g., piped), use default
  if [ ! -t 0 ]; then
    log INFO "Non-interactive mode — using default: $default"
    [ "$default" = "y" ] && return 0 || return 1
  fi

  while true; do
    echo -en "${C_BOLD}${C_YELLOW}❓ $question $prompt_str:${C_RESET} "
    read -r answer
    answer="${answer:-$default}"
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo "Please answer y or n." ;;
    esac
  done
}


# ---------------------------------------------------------------------------
# Quality Pass — quick-spec + quick-dev fix pass after each epic retrospective
# Enabled via --quality-pass flag
# ---------------------------------------------------------------------------
run_quality_pass() {
  local epic_num="$1"
  local retro_file="$2"
  local BMM_CONFIG_PATH="$BMM_CONFIG"

  log STEP "Quality Pass: launching quick-spec for Epic $epic_num..."
  log INFO  "Retro source: $retro_file"

  local qs_workflow="$PROJECT_ROOT/_bmad/bmm/workflows/bmad-quick-flow/quick-spec/workflow.md"
  local qs_log="$LOG_DIR/quality-spec-$(date +%Y%m%d-%H%M%S)-epic-${epic_num}.log"

  local qs_prompt
  qs_prompt="$(cat << QSEOF
# BMAD Autopilot — Quality Pass (quick-spec)

You are an autonomous BMAD spec engineer operating in YOLO mode.
Your task: analyze the Epic ${epic_num} retrospective and produce a tech-spec that fixes ALL issues, regressions, and improvement opportunities identified in it.

## Context & File Locations

- Project root: ${PROJECT_ROOT}
- BMM config: ${BMM_CONFIG_PATH}
- quick-spec workflow: ${qs_workflow}
- Retrospective file: ${retro_file}

## Your Goal

Read the retrospective at \`${retro_file}\`. Identify every issue, missed acceptance criterion, quality problem, or improvement action item. Produce a comprehensive tech-spec to address them all in one pass.

## YOLO Mode Rules (NO EXCEPTIONS)

- Auto-select [C] (Continue) at every workflow menu — never pause for user input
- Auto-select the most comprehensive, highest-quality option at every decision point
- Do NOT ask questions — make expert decisions and document assumptions
- Run the ENTIRE workflow start to finish without stopping
- At the final menu, select [D] (Done) after the spec is finalized

## Execution

1. Load and fully read: \`${qs_workflow}\`
2. Follow it exactly with YOLO mode rules above
3. Your spec topic: "Epic ${epic_num} retrospective fix pass — address all issues from the retro"
4. When complete, output the final line in EXACTLY this format (required for automation):
   \`\`\`
   QUALITY_DEV_CMD: quick-dev _bmad-output/implementation-artifacts/tech-spec-<slug>.md
   \`\`\`

Begin now. Load the workflow and execute.
QSEOF
)"

  local exit_code=0
  printf '%s\n' "$qs_prompt" | \
    claude -p --dangerously-skip-permissions --permission-mode bypassPermissions \
    --model claude-opus-4-6 2>&1 | tee "$qs_log" || exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log ERROR "quick-spec failed (exit $exit_code) — skipping quality pass"
    log ERROR "Log: $qs_log"
    return 1
  fi

  # Parse the quick-dev file path from the output
  local spec_file
  spec_file=$(grep -oE 'QUALITY_DEV_CMD: quick-dev [_a-zA-Z0-9/. -]+\.md' "$qs_log" \
    | tail -1 | sed 's/QUALITY_DEV_CMD: quick-dev //')

  # Fallback: grep for any quick-dev reference in the log
  if [ -z "$spec_file" ]; then
    spec_file=$(grep -oE 'quick-dev [_a-zA-Z0-9/. -]+\.md' "$qs_log" \
      | tail -1 | sed 's/quick-dev //')
  fi

  if [ -z "$spec_file" ]; then
    log WARN "Could not extract quick-dev file from quick-spec output — skipping quick-dev"
    log WARN "Review log for details: $qs_log"
    return 1
  fi

  log OK "quick-spec done. Spec file: $spec_file"
  log STEP "Quality Pass: launching quick-dev with $spec_file..."

  local qd_workflow="$PROJECT_ROOT/_bmad/bmm/workflows/bmad-quick-flow/quick-dev/workflow.md"
  local qd_log="$LOG_DIR/quality-dev-$(date +%Y%m%d-%H%M%S)-epic-${epic_num}.log"

  local qd_prompt
  qd_prompt="$(cat << QDEOF
# BMAD Autopilot — Quality Pass (quick-dev)

You are an autonomous BMAD developer operating in YOLO mode.
Your task: implement the tech-spec at \`${spec_file}\` in full.

## Context & File Locations

- Project root: ${PROJECT_ROOT}
- BMM config: ${BMM_CONFIG_PATH}
- quick-dev workflow: ${qd_workflow}
- Tech-spec to implement: ${PROJECT_ROOT}/${spec_file}

## YOLO Mode Rules (NO EXCEPTIONS)

- Auto-select [C] (Continue) at every workflow menu — never pause for user input
- Implement ALL tasks in the spec completely
- Do NOT run builds or test executables (headless environment — see CLAUDE.md)
- Write tests from spec, do not execute them
- Commit changes per the project git workflow in CLAUDE.md

## Execution

1. Load and fully read: \`${qd_workflow}\`
2. Load and fully read the tech-spec: \`${PROJECT_ROOT}/${spec_file}\`
3. Implement everything. Follow YOLO mode rules.
4. When done, output a structured completion report.

Begin now.
QDEOF
)"

  exit_code=0
  printf '%s\n' "$qd_prompt" | \
    claude -p --dangerously-skip-permissions --permission-mode bypassPermissions \
    --model claude-opus-4-6 2>&1 | tee "$qd_log" || exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log ERROR "quick-dev failed (exit $exit_code)"
    log ERROR "Log: $qd_log"
  else
    log OK "Quality pass complete! Spec implemented."
    mkdir -p "$DROPBOX_QP_DIR"
    local qp_dest="$DROPBOX_QP_DIR/epic-${epic_num}-quality-pass.md"
    cp "$spec_file" "$qp_dest" && log OK "Quality pass spec copied to Dropbox: $qp_dest" || log WARN "Could not copy quality pass to Dropbox"

    log INFO "Log: $qd_log"
  fi

  log INFO "Cooling down 20 minutes before resuming the main loop..."
  sleep 1200
  log OK "Cooldown done. Resuming."
}


# ---------------------------------------------------------------------------
# Notify Devs (OpenClaw) that an epic is done → Devs sends Telegram to Mr. T
# Also copies retrospective file to Dropbox
# ---------------------------------------------------------------------------
notify_epic_done() {
  local epic_num="$1"
  local retro_key="epic-${epic_num}-retrospective"
  local today
  today="$(date +%Y-%m-%d)"

  # --- Copy retro to Dropbox ---
  local retro_src
  retro_src="$(find "$PROJECT_ROOT/_bmad-output/implementation-artifacts" -maxdepth 1 -name "epic-${epic_num}-retro*.md" 2>/dev/null | sort | tail -1)"

  if [ -n "$retro_src" ]; then
    mkdir -p "$DROPBOX_RETRO_DIR"
    local retro_dest="$DROPBOX_RETRO_DIR/$(basename "$retro_src")"
    cp "$retro_src" "$retro_dest"
    log OK "Retro copied to Dropbox: $retro_dest"
  else
    log WARN "No retro file found for epic $epic_num — skipping Dropbox copy"
    retro_src="(not found)"
  fi

  # --- Ping OpenClaw gateway (Devs) to send Telegram to Mr. T ---
  local retro_basename
  retro_basename="$(basename "${retro_src:-}")"
  local hook_msg
  hook_msg="Epic ${epic_num} of the oneshot-v2 project is complete and the retrospective is done. Send Mr. T a Telegram message letting him know. Mention the retro file: ${retro_basename}. The autopilot is now paused and waiting for him to say go."

  if command -v curl &>/dev/null && [ -n "$OPENCLAW_HOOK_TOKEN" ]; then
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "$OPENCLAW_HOOK_URL" \
      -H "Authorization: Bearer $OPENCLAW_HOOK_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"message\": \"$hook_msg\", \"name\": \"bmad-autopilot\", \"deliver\": true, \"channel\": \"telegram\"}" 2>/dev/null)
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "202" ]]; then
      log OK "Devs notified via OpenClaw webhook → Telegram message to Mr. T incoming"
    else
      log WARN "Webhook ping failed (HTTP $http_code) — Devs not notified"
    fi
  else
    log WARN "curl not available or no hook token — skipping Devs notification"
  fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
  echo ""
  echo -e "${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}║     BMAD Autopilot — Claude Code CLI          ║${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════╝${C_RESET}"
  echo ""
  log INFO "Project root: $PROJECT_ROOT"
  log INFO "Sprint status: $SPRINT_STATUS"
  log INFO "Log file: $LOG_FILE"
  $DRY_RUN && log WARN "DRY RUN mode — no claude invocations will happen"
  echo ""

  # Sanity checks
  if [ ! -f "$SPRINT_STATUS" ]; then
    log HALT "sprint-status.yaml not found at: $SPRINT_STATUS"
    log HALT "Run sprint planning first, then re-run this script."
    exit 1
  fi

  if [ ! -f "$PROMPT_TEMPLATE" ]; then
    log HALT "Prompt template not found at: $PROMPT_TEMPLATE"
    exit 1
  fi

  if ! $DRY_RUN && ! command -v claude &>/dev/null; then
    log HALT "claude CLI not found in PATH. Install it with: npm install -g @anthropic-ai/claude-code"
    exit 1
  fi

  log INFO "YAML parser: $(if $HAS_YQ; then echo "yq"; else echo "grep/awk fallback"; fi)"

  # Auto-detect correction mode if not explicitly set via --correction-mode
  if ! $CORRECTION_MODE; then
    if auto_detect_correction_mode; then
      CORRECTION_MODE=true
      log WARN "Auto-detected CORRECTION MODE: Done stories found in later epics than pending work."
      log WARN "This looks like a corrected-course project. Epic pauses will be disabled."
    fi
  fi
  if $CORRECTION_MODE; then
    log WARN "CORRECTION MODE active: Epic pauses disabled. Done stories will never be touched."
  fi
  echo ""

  # ── Main loop ────────────────────────────────────────────────────────────
  while true; do
    LOOP_COUNT=$((LOOP_COUNT + 1))

    if [ $LOOP_COUNT -gt $MAX_LOOPS ]; then
      log HALT "Reached max loop count ($MAX_LOOPS). Stopping safety."
      exit 0
    fi

    if $INTERRUPTED; then
      log WARN "Gracefully stopped by user signal."
      exit 0
    fi

    # ── Check control file ──────────────────────────────────────────────
    check_control

    # ── Determine next action ───────────────────────────────────────────
    local action_str
    action_str="$(determine_next_action)"
    log DEBUG "Next action: $action_str"

    if [ "$action_str" = "DONE" ]; then
      echo ""
      echo -e "${C_BOLD}${C_GREEN}🎉🎉🎉  ALL STORIES COMPLETE!  🎉🎉🎉${C_RESET}"
      echo ""
      echo -e "${C_GREEN}Congratulations! Every story in the sprint is done.${C_RESET}"
      print_sprint_summary
      log OK "Sprint complete. All stories done."
      exit 0
    fi

    if [ "$action_str" = "NONE" ]; then
      log WARN "No actionable stories found in sprint-status.yaml."
      print_sprint_summary
      exit 0
    fi

    # Parse action string: "workflow|key|status"
    local workflow_name story_key story_status
    workflow_name="$(echo "$action_str" | cut -d'|' -f1)"
    story_key="$(echo "$action_str" | cut -d'|' -f2)"
    story_status="$(echo "$action_str" | cut -d'|' -f3)"

    # ── Handle retrospective prompt ────────────────────────────────────
    if [ "$workflow_name" = "retro-prompt" ]; then
      echo ""
      log EPIC "All stories done! A retrospective is available: ${C_BOLD}$story_key${C_RESET}"
      echo ""
      local retro_done=false
      workflow_name="retrospective"
      story_status="optional"
      local run_ok=true
      run_workflow "$workflow_name" "$story_key" "$story_status" || run_ok=false

      if $run_ok; then
        CONSECUTIVE_FAILURES=0
        update_story_status "$story_key" "done"
        retro_done=true
      else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log ERROR "Retrospective failed (failure $CONSECUTIVE_FAILURES/$MAX_FAILURES)"
        if [ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES ]; then
          log HALT "Too many consecutive failures. Halting."
          exit 2
        fi
      fi

      # ── Notify + pause for human review before next epic ───────────────
      if $retro_done; then
        local epic_num_done
        epic_num_done="$(echo "$story_key" | grep -oE '[0-9]+')"
        log EPIC "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log EPIC "Epic $epic_num_done fully wrapped up."
        log EPIC "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        EPICS_COMPLETED=$((EPICS_COMPLETED + 1))
        # Notify Devs → Telegram to Mr. T + copy retro to Dropbox
        notify_epic_done "$epic_num_done"
        # Quality pass (--quality-pass flag)
        if $QUALITY_PASS; then
          local retro_src_qp
          retro_src_qp="$(find "$PROJECT_ROOT/_bmad-output/implementation-artifacts" -maxdepth 1 -name "epic-${epic_num_done}-retro*.md" 2>/dev/null | sort | tail -1)"
          [ -n "$retro_src_qp" ] && run_quality_pass "$epic_num_done" "$retro_src_qp"
        fi
        # Check --max-epics cap
        if [ "$MAX_EPICS" -gt 0 ] && [ "$EPICS_COMPLETED" -ge "$MAX_EPICS" ]; then
          log HALT "Reached --max-epics cap ($MAX_EPICS). Pausing autopilot."
          echo "pause" > "$CONTROL_FILE"
        elif [ "$epic_num_done" -ge 2 ] && ! $CORRECTION_MODE; then
          # Epic 2+ — pause and request human review (normal mode only)
          echo "Epic $epic_num_done complete — autopilot paused for your review. Reply to resume." \
            > "$SCRIPT_DIR/epic-review-pending"
          echo "pause" > "$CONTROL_FILE"
          log WARN "⏸  Autopilot paused after Epic $epic_num_done. Devs will ping you on Telegram."
          log WARN "    To resume: tell Devs, or delete $CONTROL_FILE"
        else
          # Epic 1, or any epic in correction mode — notify and continue automatically
          echo "Epic $epic_num_done complete — continuing automatically." \
            > "$SCRIPT_DIR/epic-review-pending"
          log INFO "📬 Epic $epic_num_done done — continuing to next work item."
        fi
      fi

      continue
    fi

    # ── Check if skip was requested ────────────────────────────────────
    if [ "$CONTROL_ACTION" = "SKIP" ]; then
      log WARN "Skipping story: $story_key"
      update_story_status "$story_key" "backlog"
      CONTROL_ACTION=""
      continue
    fi

    # ── Epic boundary check ────────────────────────────────────────────
    if is_story_key "$story_key"; then
      local next_epic
      next_epic="$(epic_num_from_story "$story_key")"

      if check_epic_boundary "$story_key"; then
        echo ""
        log EPIC "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log EPIC "Epic $LAST_COMPLETED_EPIC complete! Moving to Epic $next_epic"
        log EPIC "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        local retro_key="epic-${LAST_COMPLETED_EPIC}-retrospective"
        log INFO "Running retrospective for Epic $LAST_COMPLETED_EPIC autonomously..."
        local retro_ok=true
        run_workflow "retrospective" "$retro_key" "optional" && \
          update_story_status "$retro_key" "done" || \
          { log WARN "Retrospective failed — continuing anyway"; retro_ok=false; }

        # Notify Devs + copy retro to Dropbox
        notify_epic_done "$LAST_COMPLETED_EPIC"
        EPICS_COMPLETED=$((EPICS_COMPLETED + 1))
        # Quality pass (--quality-pass flag)
        if $QUALITY_PASS; then
          local retro_src_qp2
          retro_src_qp2="$(find "$PROJECT_ROOT/_bmad-output/implementation-artifacts" -maxdepth 1 -name "epic-${LAST_COMPLETED_EPIC}-retro*.md" 2>/dev/null | sort | tail -1)"
          [ -n "$retro_src_qp2" ] && run_quality_pass "$LAST_COMPLETED_EPIC" "$retro_src_qp2"
        fi
        # Pause after every completed epic (Epic 2+) — skipped in correction mode
        # Also pause if --max-epics cap reached
        if { [ "$MAX_EPICS" -gt 0 ] && [ "$EPICS_COMPLETED" -ge "$MAX_EPICS" ]; } || \
           { [ "$LAST_COMPLETED_EPIC" -ge 2 ] && ! $CORRECTION_MODE; }; then
          echo "Epic $LAST_COMPLETED_EPIC complete — autopilot paused for your review. Reply to resume." \
            > "$SCRIPT_DIR/epic-review-pending"
          echo "pause" > "$CONTROL_FILE"
          log WARN "⏸  Autopilot paused after Epic $LAST_COMPLETED_EPIC. Devs will ping you on Telegram."
          log WARN "    To resume: tell Devs, or delete $CONTROL_FILE"
          # continue so check_control at the top of the next iteration picks up the pause
          # before any story from the new epic is started
          continue
        fi
      fi
    fi

    # ── Announce what we're doing ──────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}${C_BLUE}┌─────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│  Loop #$LOOP_COUNT                                    ${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│  Workflow : $workflow_name${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│  Story    : $story_key${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│  Status   : $story_status${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}└─────────────────────────────────────────────┘${C_RESET}"
    echo ""

    # ── Run workflow ───────────────────────────────────────────────────
    local run_ok=true
    run_workflow "$workflow_name" "$story_key" "$story_status" || run_ok=false

    if $run_ok; then
      CONSECUTIVE_FAILURES=0
      # Track which epic we just worked in (for boundary detection)
      if is_story_key "$story_key"; then
        LAST_COMPLETED_EPIC="$(epic_num_from_story "$story_key")"
      fi
    else
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      log ERROR "Workflow failed. Consecutive failures: $CONSECUTIVE_FAILURES/$MAX_FAILURES"

      if [ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES ]; then
        log HALT "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log HALT "SAFETY HALT: $MAX_FAILURES consecutive failures."
        log HALT "Manual intervention required."
        log HALT "Check logs in: $LOG_DIR"
        log HALT "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 2
      fi

      # If the workflow timed out but already advanced the story status,
      # auto-skip without prompting — the real work was done.
      local current_story_status
      current_story_status="$(yaml_get_key "$story_key")"
      local status_was_advanced=false
      if [ -n "$current_story_status" ] && [ "$current_story_status" != "$story_status" ]; then
        status_was_advanced=true
      fi

      if $WORKFLOW_TIMED_OUT && $status_was_advanced; then
        log WARN "Timeout: story $story_key was already advanced to '$current_story_status' — auto-skipping, preserving status."
        CONSECUTIVE_FAILURES=0
      elif ask_yes_no "Workflow failed. Retry this story?"; then
        log INFO "Retrying..."
        continue
      else
        # Check if the workflow advanced the story status before failing.
        # If so, preserve it — don't blindly reset work that was already done.
        if $status_was_advanced; then
          log WARN "Story $story_key was advanced to '$current_story_status' during the workflow — preserving status (not resetting to backlog)."
        else
          log WARN "Skipping failed story: $story_key (resetting to backlog)"
          update_story_status "$story_key" "backlog"
        fi
        CONSECUTIVE_FAILURES=0
      fi
    fi

    # ── Brief pause to let sprint-status.yaml settle ───────────────────
    sleep 1

  done
}

main "$@"
