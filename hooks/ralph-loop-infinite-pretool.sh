#!/bin/bash
# ralph-loop-infinite-pretool.sh — PreToolUse hook.
#
# v4.0.0 (F-08, F-09, F-15 remediation):
#   * Dangerous operations are checked BEFORE allowing missing/non-owner
#     sessions. While the gate is armed, missing-session or non-owner
#     Bash/Write/Edit/MultiEdit/NotebookEdit/Task/AskUserQuestion/MCP
#     execute/shell/read/search/glob tool calls touching protected roots
#     fail closed unless the surrounding hook process is a trusted internal
#     ralph-loop-infinite hook (env marker RALPH_INTERNAL_HOOK=1).
#   * Read/Grep/Glob/LS and MCP read-style tools are now first-class
#     PreToolUse subjects. The hook denies any read whose target falls
#     inside ~/.claude/secrets, the HMAC key, the manifest signing material,
#     the SQLite state DB, the ralph hook scripts, contracts, or settings.
#   * Path matching is canonicalised through ralph-loop-infinite-pathguard.py
#     (realpath, ~/$HOME, relative paths, symlinks, quoted variants). Shell
#     command strings are inspected for path arguments AND substring matches
#     against the protected denylist before regex matching.

set -uo pipefail

STATE_FILE="$HOME/.claude/state/ralph-loop-infinite.local"
LOG_FILE="$HOME/.claude/state/ralph-gate.log"
PATHGUARD="$HOME/.claude/hooks/ralph-loop-infinite-pathguard.py"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '[%s] [pretool] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

emit_deny() {
  local reason="$1"
  jq -n --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
}

HOOK_INPUT=$(cat)

# Gate inactive → allow everything.
if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# Internal hooks (verifier/bootstrap/session/stop/prompt invoking helpers)
# bypass this check by exporting RALPH_INTERNAL_HOOK=1. Tools called from
# real agent sessions never set this.
INTERNAL_HOOK="${RALPH_INTERNAL_HOOK:-0}"

STATE_SESSION=$(grep '^session_id:' "$STATE_FILE" 2>/dev/null | sed 's/session_id: *//' | tr -d '[:space:]' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '
  .session_id // .sessionId // .sessionID // .metadata.session_id // .metadata.sessionId // ""
' 2>/dev/null || echo "")
TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // .tool // ""' 2>/dev/null || echo "")
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '
  .tool_input.file_path // .tool_input.path // .tool_input.notebook_path
  // .tool_input.target_file // .tool_input.filename
  // .tool_input.target // ""
' 2>/dev/null || echo "")

CMD=$(echo "$HOOK_INPUT" | jq -r '
  .tool_input // .input // {}
  | (.command // .cmd // .script // .input // .shell.command // .args // "")
  | if type == "array" then join(" ") else tostring end
' 2>/dev/null || echo "")
if [[ -z "$CMD" || "$CMD" == "null" ]]; then
  CMD=$(echo "$HOOK_INPUT" | jq -r '
    [(.tool_input // {}) | to_entries[] | select(.value | type == "string") | .value]
    | join(" ")
  ' 2>/dev/null || echo "")
fi

GREP_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.path // .tool_input.directory // .tool_input.glob // ""' 2>/dev/null || echo "")

# Decide ownership.
OWNER_MATCH=0
if [[ -n "$STATE_SESSION" && -n "$HOOK_SESSION" && "$STATE_SESSION" == "$HOOK_SESSION" ]]; then
  OWNER_MATCH=1
fi

# Helper to call the path guard. Returns 0=allow, 1=deny.
classify_path() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  if [[ -x "$PATHGUARD" ]]; then
    python3 "$PATHGUARD" classify-path "$p" >/dev/null 2>&1
    return $?
  fi
  return 0
}

classify_bash() {
  local cmd="$1"
  [[ -z "$cmd" ]] && return 0
  if [[ -x "$PATHGUARD" ]]; then
    python3 "$PATHGUARD" classify-bash "$cmd" >/dev/null 2>&1
    return $?
  fi
  return 0
}

# F-09: Read/Grep/Glob/LS/MCP read coverage. These tools never had a CMD,
# only a path/glob target, so we explicitly inspect the relevant field.
case "$TOOL" in
  Read|read|read_file|view_file|cat_file)
    if ! classify_path "$FILE_PATH"; then
      log "DENY pretool [$TOOL]: protected path read: $FILE_PATH"
      emit_deny "ralph-loop-infinite clause 99983: tool '$TOOL' attempted to read a protected path ($FILE_PATH). Reads of HMAC keys, state, manifest, hook scripts, and contract files are denied while gate is armed."
      exit 0
    fi
    ;;
  Grep|grep|search_file_content|search)
    if ! classify_path "$GREP_PATH"; then
      log "DENY pretool [$TOOL]: protected path Grep: $GREP_PATH"
      emit_deny "ralph-loop-infinite clause 99983: tool '$TOOL' attempted to grep a protected path ($GREP_PATH)."
      exit 0
    fi
    PATTERN=$(echo "$HOOK_INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")
    if echo "$PATTERN" | grep -E -q 'ralph-hmac\.key|signed_pass_b64|ralph-loop-infinite\.sqlite3'; then
      log "DENY pretool [$TOOL]: Grep pattern targets secret material"
      emit_deny "ralph-loop-infinite clause 99983: Grep pattern targets secret material."
      exit 0
    fi
    ;;
  Glob|glob|find_files)
    if ! classify_path "$GREP_PATH"; then
      log "DENY pretool [$TOOL]: protected path Glob: $GREP_PATH"
      emit_deny "ralph-loop-infinite clause 99983: tool '$TOOL' attempted to glob inside protected paths."
      exit 0
    fi
    GLOB_PATTERN=$(echo "$HOOK_INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")
    if echo "$GLOB_PATTERN" | grep -E -q 'secrets|ralph-hmac|signed_pass|ralph-loop-infinite\.sqlite'; then
      log "DENY pretool [$TOOL]: Glob pattern targets secret material"
      emit_deny "ralph-loop-infinite clause 99983: Glob pattern targets secret material."
      exit 0
    fi
    ;;
  LS|ls|list_directory)
    if ! classify_path "$FILE_PATH"; then
      log "DENY pretool [$TOOL]: protected path LS: $FILE_PATH"
      emit_deny "ralph-loop-infinite clause 99983: tool '$TOOL' attempted to list a protected directory."
      exit 0
    fi
    ;;
  mcp__*)
    # MCP read-style tools: read_file/search/grep/list/find/glob.
    if echo "$TOOL" | grep -E -q -i 'read_file|read|view|cat|grep|search|glob|find|list_dir|list_files'; then
      if ! classify_path "$FILE_PATH"; then
        log "DENY pretool [$TOOL]: MCP read targets protected path: $FILE_PATH"
        emit_deny "ralph-loop-infinite clause 99983: tool '$TOOL' attempted MCP read of protected path ($FILE_PATH)."
        exit 0
      fi
      if ! classify_path "$GREP_PATH"; then
        log "DENY pretool [$TOOL]: MCP search targets protected path: $GREP_PATH"
        emit_deny "ralph-loop-infinite clause 99983: tool '$TOOL' attempted MCP search of protected path."
        exit 0
      fi
    fi
    ;;
esac

# F-15: file_path-based write/edit checks. Canonicalised via pathguard.
if [[ -n "$FILE_PATH" ]]; then
  case "$TOOL" in
    Write|Edit|MultiEdit|NotebookEdit|str_replace_editor|str-replace-editor|create|insert|edit|write|delete|remove)
      if ! classify_path "$FILE_PATH"; then
        log "DENY pretool [$TOOL]: protected path write: $FILE_PATH"
        emit_deny "ralph-loop-infinite clause 99988: tool '$TOOL' attempted to write/edit a protected path ($FILE_PATH)."
        exit 0
      fi
      ;;
  esac
fi

# AskUserQuestion approval-seeking deny
if [[ "$TOOL" == "AskUserQuestion" ]]; then
  ASK_CONTENT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.question // .tool_input.questions // .tool_input.prompt // .tool_input // {} | tostring' 2>/dev/null || echo "")
  if echo "$ASK_CONTENT" | grep -E -i -q '\b(approve|approval|is[[:space:]]+(this|it|the)[[:space:]]+(ok|okay|fine|good|right|correct)|shall[[:space:]]+i[[:space:]]+(proceed|continue|deploy|ship)|would[[:space:]]+you[[:space:]]+like[[:space:]]+me|does[[:space:]]+this[[:space:]]+look|let[[:space:]]+me[[:space:]]+know|confirm|verify[[:space:]]+(this|the)|ready[[:space:]]+to[[:space:]]+(ship|deploy|merge|release))\b'; then
    log "DENY pretool [$TOOL]: approval-seeking AskUserQuestion"
    emit_deny "ralph-loop-infinite clause 99990: agent attempted to ask the user for approval via AskUserQuestion."
    exit 0
  fi
fi

# Task subagent escape deny
if [[ "$TOOL" == "Task" || "$TOOL" == "task" ]]; then
  TASK_PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // .tool_input.description // .tool_input.task // ""' 2>/dev/null || echo "")
  if echo "$TASK_PROMPT" | grep -E -i -q '\b(disarm[[:space:]]+ralph|skip[[:space:]]+(the[[:space:]]+)?(gate|loop|verifier)|bypass[[:space:]]+(the[[:space:]]+)?(gate|loop|verifier)|approve[[:space:]]+(the[[:space:]]+)?(gate|loop|output)|self[-[:space:]]?approve|circumvent|allowed_workers|ralph-loop-infinite\.local|\.claude/state|reclassif(y|ying|ied)|convert[^\n]{0,120}FAIL[^\n]{0,120}(NA|PASS))'; then
    log "DENY pretool [$TOOL]: subagent prompt contains gate-bypass/state-tamper language"
    emit_deny "ralph-loop-infinite clause 99985: Task tool dispatch contains gate-bypass, state-tamper, or requirement-reclassification language."
    exit 0
  fi
fi

# Write/Edit completion-claim deny (file content scan).
# Mirrors the Stop hook's PASSED_ACK_RX so paraphrases like
# "Production Validation — PASSED" or
# "Ralph-loop-infinite verifier: PASSED" cannot be Write-tampered into
# a file before the verifier signs an HMAC PASS.
if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" || "$TOOL" == "MultiEdit" || "$TOOL" == "NotebookEdit" ]]; then
  CONTENT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.content // .tool_input.new_string // .tool_input.text // .tool_input.value // ""' 2>/dev/null || echo "")
  COMPLETION_CLAIM_RX='<promise>[[:space:]]*(DONE|COMPLETE)[[:space:]]*</promise>|\bralph[-[:space:]]?loop[-[:space:]]?infinite[[:space:]]+(gate|verifier|verification|loop)[[:space:]]*[:=-]?[[:space:]]*PASSED\b|\bProduction[[:space:]]+Validation[[:space:]]*[-—:][[:space:]]*PASSED\b|\bverifier[-[:space:]]?PASS[[:space:]]+(signed|issued|granted|complete)\b'
  if echo "$CONTENT" | grep -E -i -q "$COMPLETION_CLAIM_RX"; then
    VPASS=$(grep '^verifier_pass:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_pass: *//' | tr -d '[:space:]' || echo "false")
    if [[ "$VPASS" != "true" ]]; then
      log "DENY pretool [$TOOL]: completion claim in file content without verifier-PASS"
      emit_deny "ralph-loop-infinite clause 99988: tool would write a completion claim before verifier-PASS."
      exit 0
    fi
  fi
fi

# Bash / MCP-shell scope check. Even without a CMD, we already covered
# Read/Grep/Glob/LS above. If a CMD exists, fully inspect it.
if [[ -n "$CMD" && "$CMD" != "null" ]]; then
  # Scope: Bash always; MCP tools with shell/execute/exec/bash/command/cmd/script.
  IN_SCOPE=0
  case "$TOOL" in
    Bash|bash) IN_SCOPE=1 ;;
    mcp__*)
      if echo "$TOOL" | grep -E -q -i 'shell|execute|exec|bash|command|cmd|script|run_code|run_js|sandbox_exec|console_execute'; then
        IN_SCOPE=1
      fi
      ;;
  esac

  if [[ $IN_SCOPE -eq 1 ]]; then
    # F-09/F-15: canonical bash inspection via pathguard (realpath, ~, $HOME, redirections).
    if ! classify_bash "$CMD"; then
      CMD_PREVIEW=$(echo "$CMD" | head -c 200)
      log "DENY pretool [$TOOL]: pathguard rejected: $CMD_PREVIEW"
      emit_deny "ralph-loop-infinite clause 99983/99988: tool '$TOOL' command references a protected path or secret. Command preview: $CMD_PREVIEW"
      exit 0
    fi

    # Legacy state/allowlist workaround patterns (kept as belt-and-braces).
    if echo "$CMD" | grep -E -i -q '(allowed_workers|ralph-loop-(outsiders|monitors)|echo[^\n]{0,160}>>[^\n]{0,160}\.claude/state|ralph-loop-infinite\.local)'; then
      CMD_PREVIEW=$(echo "$CMD" | head -c 200)
      log "DENY pretool [$TOOL]: state/allowlist tamper workaround: $CMD_PREVIEW"
      emit_deny "ralph-loop-infinite clause 99981: tool '$TOOL' attempted a state/allowlist workaround. Command: $CMD_PREVIEW"
      exit 0
    fi

    # H-1 dangerous deployment patterns
    DANGEROUS_RX='\bgit[[:space:]]+push\b|\bnpm[[:space:]]+publish\b|\byarn[[:space:]]+publish\b|\bpnpm[[:space:]]+publish\b|\bbun[[:space:]]+publish\b|\bvercel[[:space:]]+(deploy|--prod)\b|\bnetlify[[:space:]]+deploy\b|\bgh[[:space:]]+release[[:space:]]+create\b|\bcap[[:space:]]+(production|prod)[[:space:]]+deploy\b|\brsync[[:space:]]+.*\b(production|prod|hostinger|live)\b|\bscp[[:space:]]+.*\b(production|prod|hostinger|live)\b|\bfly(ctl)?[[:space:]]+deploy\b|\brailway[[:space:]]+up\b|\bsst[[:space:]]+deploy\b|\bcdk[[:space:]]+deploy\b|\bterraform[[:space:]]+apply\b|\bansible-playbook\b.*\bproduction\b|\bkubectl[[:space:]]+(apply|create|replace|delete|rollout)\b|\bhelm[[:space:]]+(upgrade|install|rollback|uninstall)\b|\bfirebase[[:space:]]+deploy\b|\bwrangler[[:space:]]+(publish|deploy)\b|\bgcloud[[:space:]]+(functions|run|app|deploy|compute)[[:space:]]+.*\bdeploy\b|\bgcloud[[:space:]]+app[[:space:]]+deploy\b|\baws[[:space:]]+s3[[:space:]]+sync\b.*\b(prod|production|live)\b|\baws[[:space:]]+(deploy|cloudformation|cdk|amplify[[:space:]]+publish)\b|\beb[[:space:]]+deploy\b|\bserverless[[:space:]]+deploy\b|\bdocker[[:space:]]+push\b.*(prod|production|latest)|\bssh[[:space:]]+[^[:space:]]*@[^[:space:]]*\b(prod|production|live)\b|\bansible[[:space:]]+.*\b(prod|production)\b|\bpulumi[[:space:]]+up\b|\bsupabase[[:space:]]+(db[[:space:]]+push|functions[[:space:]]+deploy)\b|\bnpx[[:space:]]+vercel[[:space:]]+(deploy|--prod)\b|\bnpx[[:space:]]+netlify[[:space:]]+deploy\b|\bcap[[:space:]]+deploy\b|\brender[[:space:]]+deploy\b|\bheroku[[:space:]]+(deploy|releases:create)\b'
    if echo "$CMD" | grep -E -q "$DANGEROUS_RX"; then
      CMD_PREVIEW=$(echo "$CMD" | head -c 160)
      log "DENY pretool [$TOOL]: deployment-adjacent command: $CMD_PREVIEW"
      emit_deny "ralph-loop-infinite gate ACTIVE — deployment-adjacent command blocked via tool '$TOOL': $CMD_PREVIEW. Produce the §3 exit report with evidenced numbers, OR run /ralph-loop-infinite-disarm to remove the gate, then retry."
      exit 0
    fi
  fi
fi

# F-08: now decide ownership. Only AFTER dangerous-operation checks above.
# If we reach here, the call is either innocuous, owner-matched, or an
# internal helper. For non-owner/missing-session calls targeting any of the
# tool families we already enforced (and which would have already denied
# above), this is allow-by-falling-through. Anything else: log noop and exit.
if [[ -z "$STATE_SESSION" || -z "$HOOK_SESSION" ]]; then
  if [[ "$INTERNAL_HOOK" == "1" ]]; then
    exit 0
  fi
  log "ALLOW pretool (post-checks): missing state/hook session (state=${STATE_SESSION:-missing} hook=${HOOK_SESSION:-missing} tool=$TOOL)"
  exit 0
fi
if [[ $OWNER_MATCH -eq 0 ]]; then
  if [[ "$INTERNAL_HOOK" == "1" ]]; then
    exit 0
  fi
  log "ALLOW pretool (post-checks): non-owner session passed dangerous checks (state=$STATE_SESSION hook=$HOOK_SESSION tool=$TOOL)"
  exit 0
fi

exit 0
