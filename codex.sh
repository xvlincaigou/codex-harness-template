#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

HARNESS_DIR="${HARNESS_DIR:-$ROOT/.harness}"
PROMPTS_DIR="$HARNESS_DIR/prompts"
STATE_DIR="$HARNESS_DIR/state"
LOG_DIR="$HARNESS_DIR/logs"

DISCUSS_PROMPT_FILE="${DISCUSS_PROMPT_FILE:-$PROMPTS_DIR/discuss.md}"
RUN_PROMPT_FILE="${RUN_PROMPT_FILE:-$PROMPTS_DIR/run.md}"

SPEC_FILE="${SPEC_FILE:-$STATE_DIR/spec.md}"
FEATURE_FILE="${FEATURE_FILE:-$STATE_DIR/feature_list.json}"
PROGRESS_FILE="${PROGRESS_FILE:-$STATE_DIR/codex-progress.md}"

DISCUSS_LOCK_FILE="${DISCUSS_LOCK_FILE:-$STATE_DIR/discussion.lock}"
LAST_THREAD_FILE="${LAST_THREAD_FILE:-$STATE_DIR/last_thread_id.txt}"
DECISIONS_FILE="${DECISIONS_FILE:-$STATE_DIR/decisions-needed.md}"

MODEL="${MODEL:-gpt-5.4}"
SANDBOX="${SANDBOX:-workspace-write}"
APPROVAL="${APPROVAL:-on-failure}"
ENABLE_SEARCH="${ENABLE_SEARCH:-0}"

MAX_ITERS="${MAX_ITERS:-9999}"
BACKOFF_MIN_SECONDS="${BACKOFF_MIN_SECONDS:-60}"
BACKOFF_MAX_SECONDS="${BACKOFF_MAX_SECONDS:-3600}"
SUCCESS_PAUSE_SECONDS="${SUCCESS_PAUSE_SECONDS:-1}"
AUTO_LOCK_AFTER_DISCUSS="${AUTO_LOCK_AFTER_DISCUSS:-0}"

DECISION_GATE="${DECISION_GATE:-1}"
HARNESS_PROTECT="${HARNESS_PROTECT:-1}"
PROTECTED_FILES="${PROTECTED_FILES:-codex.sh .harness/prompts/discuss.md .harness/prompts/run.md}"
PROTECT_BASELINE_FILE="${PROTECT_BASELINE_FILE:-$STATE_DIR/harness-protected.snapshot}"
PROTECT_ALERT_FILE="${PROTECT_ALERT_FILE:-$STATE_DIR/harness-protect-alert.md}"

export CODEX_HOME="${CODEX_HOME:-$ROOT/.codex-home}"

usage() {
  cat <<'TXT'
Usage:
  bash codex.sh              # only run interactive discuss phase (default)
  bash codex.sh discuss      # only run interactive discuss phase
  bash codex.sh run          # only run continuous exec phase
  bash codex.sh status       # show harness status
  bash codex.sh unlock       # remove discuss lock
  bash codex.sh clear-decisions  # clear decision gate file
  bash codex.sh protect-refresh  # refresh harness protection baseline
  bash codex.sh reset-logs   # clear .harness/logs
TXT
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing command: $cmd" >&2
    exit 1
  fi
}

write_decisions_clear() {
  cat > "$DECISIONS_FILE" <<TXT
# Decisions Needed
status: clear
updated_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

items:
- (none)
TXT
}

bootstrap() {
  mkdir -p "$PROMPTS_DIR" "$STATE_DIR" "$LOG_DIR" "$CODEX_HOME"

  if [[ ! -f "$SPEC_FILE" ]]; then
    cat > "$SPEC_FILE" <<'TXT'
# Product Spec
- 背景：
- 目标：
- 非目标：
- 用户故事：
- 验收标准：
TXT
  fi

  if [[ ! -f "$FEATURE_FILE" ]]; then
    cat > "$FEATURE_FILE" <<'TXT'
[
  {
    "id": "F-001",
    "title": "生成并维护完整 feature list",
    "passes": false,
    "notes": ""
  }
]
TXT
  fi

  if [[ ! -f "$PROGRESS_FILE" ]]; then
    cat > "$PROGRESS_FILE" <<'TXT'
# Codex Progress

## Session Notes
TXT
  fi

  if [[ ! -f "$DECISIONS_FILE" ]]; then
    write_decisions_clear
  fi

  if [[ ! -f "$DISCUSS_PROMPT_FILE" ]]; then
    cat > "$DISCUSS_PROMPT_FILE" <<'TXT'
你现在是需求澄清代理，目标是先讨论清楚再执行。

要求：
1) 连续提问澄清需求，直到可执行。
2) 把澄清结果更新到 .harness/state/spec.md。
3) 生成或更新 .harness/state/feature_list.json，结构为数组，每项至少包含：
   - id
   - title
   - passes (初始 false)
   - notes
4) 在需求未清楚前，不要开始大规模实现。
5) 如果需求矛盾，优先提出最小化决策问题。
TXT
  fi

  if [[ ! -f "$RUN_PROMPT_FILE" ]]; then
    cat > "$RUN_PROMPT_FILE" <<'TXT'
你现在是连续执行代理。每一轮必须严格遵循：

1) 先阅读这些文件：
   - .harness/state/spec.md
   - .harness/state/feature_list.json
   - .harness/state/codex-progress.md
   - .harness/state/decisions-needed.md
   - git log --oneline -n 20

2) 选择一个当前最高优先级且 passes=false 的 feature 实现。
3) 完成后执行必要验证（测试/构建/启动/静态检查中与改动最相关的一组）。
4) 验证通过后，必须执行 git add -A 和 git commit，提交信息格式：
   - feat(<feature-id>): <feature-title>
   - 如果不是新功能，也可用 fix/chore，但必须包含本轮 feature id
5) 仅在验证通过且 commit 成功后，将该 feature 的 passes 改为 true。
6) 更新 .harness/state/codex-progress.md，记录：本轮改动、验证结果、提交哈希、下一步、阻塞点。
7) 如果阻塞，明确记录阻塞原因和建议，不要伪完成。
8) 保持每轮改动小、可回滚、可继续。
9) 如果需要人类决策：
   - 将 .harness/state/decisions-needed.md 写成 status: pending
   - 在 items 下列出决策问题、可选项、推荐项
   - 输出标记词 DECISION_REQUIRED
   - 本轮停止继续实现，等待人类输入
10) 不要修改以下 harness 文件：
   - codex.sh
   - .harness/prompts/discuss.md
   - .harness/prompts/run.md
TXT
  fi
}

all_features_passed() {
  jq -e 'type == "array" and length > 0 and all(.[]; (.passes // false) == true)' "$FEATURE_FILE" >/dev/null 2>&1
}

extract_thread_id_from_log() {
  local log_file="$1"
  grep -E '^\{"type":"thread\.started"' "$log_file" 2>/dev/null | tail -n 1 | jq -r '.thread_id' 2>/dev/null || true
}

is_retryable_error() {
  local log_file="$1"
  grep -Eqi 'rate[ -]?limit|insufficient[_ ]quota|quota|429|network error|stream disconnected|temporar|timeout|overloaded|reconnecting' "$log_file"
}

auto_commit_iteration() {
  local iteration="$1"
  local has_changes=1

  if [[ -z "$(git -C "$ROOT" status --porcelain)" ]]; then
    has_changes=0
  fi

  local ts msg
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  msg="chore(harness): checkpoint iteration $iteration @ $ts"

  if [[ "$has_changes" -eq 1 ]]; then
    git -C "$ROOT" add -A
    if git -C "$ROOT" commit -m "$msg" >/dev/null; then
      log "auto-commit succeeded: $msg"
      return 0
    fi
  else
    if git -C "$ROOT" commit --allow-empty -m "$msg (empty)" >/dev/null; then
      log "auto-commit succeeded (empty): $msg"
      return 0
    fi
  fi


  log "auto-commit failed"
  return 1
}

extract_retry_after_seconds() {
  local log_file="$1"
  local hint
  hint="$(grep -Eoi 'retry[- ]?after[^0-9]*[0-9]+' "$log_file" | tail -n 1 || true)"
  if [[ -n "$hint" ]]; then
    echo "$hint" | grep -Eo '[0-9]+' | tail -n 1
    return 0
  fi
  echo "$BACKOFF_MIN_SECONDS"
}

hash_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo "MISSING"
  fi
}

refresh_protect_baseline() {
  if [[ "$HARNESS_PROTECT" != "1" ]]; then
    return 0
  fi

  : > "$PROTECT_BASELINE_FILE"

  local rel
  for rel in $PROTECTED_FILES; do
    printf '%s\t%s\n' "$rel" "$(hash_file "$ROOT/$rel")" >> "$PROTECT_BASELINE_FILE"
  done

  rm -f "$PROTECT_ALERT_FILE"
}

check_harness_integrity() {
  if [[ "$HARNESS_PROTECT" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "$PROTECT_BASELINE_FILE" ]]; then
    refresh_protect_baseline
    return 0
  fi

  local changed=0
  : > "$PROTECT_ALERT_FILE"

  local rel old_hash current_hash
  while IFS=$'\t' read -r rel old_hash || [[ -n "${rel:-}" ]]; do
    [[ -n "${rel:-}" ]] || continue
    current_hash="$(hash_file "$ROOT/$rel")"
    if [[ "$current_hash" != "$old_hash" ]]; then
      changed=1
      printf -- '- %s (expected: %s, current: %s)\n' "$rel" "$old_hash" "$current_hash" >> "$PROTECT_ALERT_FILE"
    fi
  done < "$PROTECT_BASELINE_FILE"

  if [[ "$changed" -eq 1 ]]; then
    {
      echo
      echo "If you intentionally changed harness files, run:"
      echo "  bash codex.sh protect-refresh"
    } >> "$PROTECT_ALERT_FILE"
    return 1
  fi

  rm -f "$PROTECT_ALERT_FILE"
  return 0
}

is_decision_pending() {
  if [[ "$DECISION_GATE" != "1" ]]; then
    return 1
  fi
  [[ -f "$DECISIONS_FILE" ]] || return 1
  grep -Eqi '^[[:space:]]*status:[[:space:]]*pending([[:space:]]|$)' "$DECISIONS_FILE"
}

decision_marker_in_log() {
  local log_file="$1"
  grep -Eqi 'DECISION_REQUIRED|awaiting user decision|needs human decision|blocked on decision' "$log_file"
}

seed_decision_file_from_log() {
  local log_file="$1"
  cat > "$DECISIONS_FILE" <<TXT
# Decisions Needed
status: pending
updated_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

items:
- question: 请查看执行日志并补充需要你拍板的决策项
  options:
    - option A
    - option B
  recommendation: option A (placeholder)

source_log: $log_file
TXT
}

run_discuss_phase() {
  if [[ -f "$DISCUSS_LOCK_FILE" ]]; then
    log "discussion already locked, skipping discuss phase"
    return 0
  fi

  log "starting discuss phase (interactive)"

  local -a cmd
  cmd=(codex -C "$ROOT" -m "$MODEL" -s "$SANDBOX" -a "$APPROVAL")
  if [[ "$ENABLE_SEARCH" == "1" ]]; then
    cmd+=(--search)
  fi
  cmd+=("$(cat "$DISCUSS_PROMPT_FILE")")

  "${cmd[@]}"

  if [[ "$AUTO_LOCK_AFTER_DISCUSS" == "1" ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DISCUSS_LOCK_FILE"
    log "discussion locked automatically"
    return 0
  fi

  read -r -p "需求是否已澄清完成并锁定进入执行阶段？[y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DISCUSS_LOCK_FILE"
    log "discussion locked"
  else
    log "discussion not locked; you can rerun discuss later"
    return 0
  fi
}

run_exec_iteration() {
  local iteration="$1"
  local log_file="$LOG_DIR/iter-$(printf '%05d' "$iteration")-$(date +%Y%m%dT%H%M%S).log"

  log "iteration $iteration"
  log "log file: $log_file"

  local -a cmd
  # NOTE: `codex exec` does not support `-a/--ask-for-approval`.
  # Approval policy for exec should be managed via Codex config/profiles.
  cmd=(codex exec --json -C "$ROOT" -m "$MODEL" -s "$SANDBOX")
  if [[ "$ENABLE_SEARCH" == "1" ]]; then
    cmd+=(--search)
  fi
  cmd+=(-)

  set +e
  "${cmd[@]}" < "$RUN_PROMPT_FILE" 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e

  local thread_id
  thread_id="$(extract_thread_id_from_log "$log_file")"
  if [[ -n "$thread_id" ]]; then
    printf '%s\n' "$thread_id" > "$LAST_THREAD_FILE"
  fi

  if ! check_harness_integrity; then
    log "harness protection triggered; see $PROTECT_ALERT_FILE"
    return 30
  fi

  if [[ "$DECISION_GATE" == "1" ]]; then
    if decision_marker_in_log "$log_file" && ! is_decision_pending; then
      seed_decision_file_from_log "$log_file"
    fi

    if is_decision_pending; then
      log "decision gate triggered; see $DECISIONS_FILE"
      return 20
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if ! auto_commit_iteration "$iteration"; then
      return 1
    fi

    if all_features_passed; then
      log "all features passed"
      return 100
    fi

    log "iteration succeeded"
    return 0
  fi

  if is_retryable_error "$log_file"; then
    log "iteration failed with retryable error"
    return 10
  fi

  log "iteration failed with non-retryable error"
  return 1
}

run_exec_loop() {
  local backoff="$BACKOFF_MIN_SECONDS"
  local i=1

  if [[ "$DECISION_GATE" == "1" ]] && is_decision_pending; then
    log "decision gate already pending before run; clear $DECISIONS_FILE first"
    return 0
  fi

  refresh_protect_baseline

  while [[ "$i" -le "$MAX_ITERS" ]]; do
    if run_exec_iteration "$i"; then
      local state=0
    else
      local state=$?
    fi

    if [[ "$state" -eq 100 ]]; then
      return 0
    fi

    if [[ "$state" -eq 20 ]]; then
      log "paused for human decision"
      return 0
    fi

    if [[ "$state" -eq 30 ]]; then
      log "paused because protected harness files changed"
      return 1
    fi

    if [[ "$state" -eq 0 ]]; then
      backoff="$BACKOFF_MIN_SECONDS"
      sleep "$SUCCESS_PAUSE_SECONDS"
      i=$((i + 1))
      continue
    fi

    if [[ "$state" -eq 10 ]]; then
      local latest_log retry_after
      latest_log="$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -n 1 || true)"

      if [[ -n "$latest_log" ]]; then
        retry_after="$(extract_retry_after_seconds "$latest_log")"
      else
        retry_after="$backoff"
      fi

      if [[ -z "$retry_after" ]]; then
        retry_after="$backoff"
      fi
      if [[ "$retry_after" -lt "$backoff" ]]; then
        retry_after="$backoff"
      fi
      if [[ "$retry_after" -gt "$BACKOFF_MAX_SECONDS" ]]; then
        retry_after="$BACKOFF_MAX_SECONDS"
      fi

      log "sleeping ${retry_after}s before retry"
      sleep "$retry_after"

      backoff=$((backoff * 2))
      if [[ "$backoff" -gt "$BACKOFF_MAX_SECONDS" ]]; then
        backoff="$BACKOFF_MAX_SECONDS"
      fi

      i=$((i + 1))
      continue
    fi

    return 1
  done

  log "reached MAX_ITERS=$MAX_ITERS"
  return 0
}

show_status() {
  local total="0"
  local passed="0"

  if [[ -f "$FEATURE_FILE" ]]; then
    total="$(jq 'length' "$FEATURE_FILE" 2>/dev/null || echo 0)"
    passed="$(jq '[.[] | select((.passes // false) == true)] | length' "$FEATURE_FILE" 2>/dev/null || echo 0)"
  fi

  echo "ROOT=$ROOT"
  echo "CODEX_HOME=$CODEX_HOME"
  echo "SANDBOX=$SANDBOX"
  echo "APPROVAL=$APPROVAL"
  echo "LOCKED=$([[ -f "$DISCUSS_LOCK_FILE" ]] && echo yes || echo no)"
  echo "FEATURES_PASSED=${passed}/${total}"
  echo "LAST_THREAD_ID=$(cat "$LAST_THREAD_FILE" 2>/dev/null || echo '-')"
  echo "DECISION_GATE=$DECISION_GATE"
  echo "DECISION_PENDING=$([[ "$DECISION_GATE" == "1" ]] && is_decision_pending && echo yes || echo no)"
  echo "DECISIONS_FILE=$DECISIONS_FILE"
  echo "HARNESS_PROTECT=$HARNESS_PROTECT"
  echo "PROTECT_BASELINE_FILE=$PROTECT_BASELINE_FILE"
  echo "PROTECT_ALERT_FILE=$PROTECT_ALERT_FILE"
}

main() {
  local mode="${1:-discuss}"

  require_cmd codex
  require_cmd jq
  require_cmd git
  require_cmd shasum

  bootstrap

  case "$mode" in
    all)
      echo "mode 'all' is disabled. Use: bash codex.sh discuss, then bash codex.sh run" >&2
      exit 1
      ;;
    discuss)
      run_discuss_phase
      ;;
    run)
      run_exec_loop
      ;;
    status)
      show_status
      ;;
    unlock)
      rm -f "$DISCUSS_LOCK_FILE"
      log "discussion unlocked"
      ;;
    clear-decisions)
      write_decisions_clear
      log "decisions cleared"
      ;;
    protect-refresh)
      refresh_protect_baseline
      log "harness protection baseline refreshed"
      ;;
    reset-logs)
      rm -f "$LOG_DIR"/*.log 2>/dev/null || true
      log "logs cleared"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "unknown mode: $mode" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
