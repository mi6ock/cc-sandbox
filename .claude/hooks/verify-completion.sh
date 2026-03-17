#!/bin/bash
# サブエージェント内ではスキップ（agent_idはサブエージェントでのみ存在）
INPUT=$(cat)
if echo "$INPUT" | grep -q '"agent_id"'; then
  exit 0
fi

BRANCH=$(git branch --show-current 2>/dev/null | sed 's/\//-/g' || echo "unknown")
GOAL=".claude/goals/${BRANCH}.md"
PLAN=".claude/plans/${BRANCH}.md"

if [ ! -f "$GOAL" ] && [ ! -f "$PLAN" ]; then
  exit 0
fi

BLOCK=false

# --- Check GOAL must items ---
if [ -f "$GOAL" ]; then
  # Extract lines between "### must" and the next "###" or "## " heading
  MUST_PENDING=$(awk '/^### must$/{f=1; next} /^##/{f=0} f && /^- \[ \]/' "$GOAL")
  MUST_COUNT=$(echo "$MUST_PENDING" | grep -c '^\- \[ \]' || true)

  if [ "$MUST_COUNT" -gt 0 ]; then
    echo "================================================================" >&2
    echo "GOAL [must] 未達成が ${MUST_COUNT} 件あります" >&2
    echo "================================================================" >&2
    echo "$MUST_PENDING" >&2
    echo "" >&2
    BLOCK=true
  fi
fi

# --- Check PLAN items ---
if [ -f "$PLAN" ]; then
  PLAN_PENDING=$(grep -c '^\- \[ \]' "$PLAN" || true)
  if [ "$PLAN_PENDING" -gt 0 ]; then
    echo "================================================================" >&2
    echo "PLAN 未完了ステップが ${PLAN_PENDING} 件あります" >&2
    echo "================================================================" >&2
    grep '^\- \[ \]' "$PLAN" >&2
    echo "" >&2
    BLOCK=true
  fi
fi

# --- Check GOAL want items (warning only) ---
if [ -f "$GOAL" ]; then
  WANT_PENDING=$(awk '/^### want$/{f=1; next} /^##/{f=0} f && /^- \[ \]/' "$GOAL")
  WANT_COUNT=$(echo "$WANT_PENDING" | grep -c '^\- \[ \]' || true)

  if [ "$WANT_COUNT" -gt 0 ]; then
    echo "================================================================" >&2
    echo "GOAL [want] 未達成が ${WANT_COUNT} 件あります（警告のみ）" >&2
    echo "================================================================" >&2
    echo "$WANT_PENDING" >&2
    echo "" >&2
  fi
fi

if [ "$BLOCK" = true ]; then
  # 連続ブロック回数を記録（ブランチ単位）
  BLOCK_COUNT_FILE="/tmp/claude-stop-block-${BRANCH}"
  PREV_COUNT=0
  if [ -f "$BLOCK_COUNT_FILE" ]; then
    PREV_COUNT=$(cat "$BLOCK_COUNT_FILE" 2>/dev/null || echo 0)
  fi
  NEW_COUNT=$((PREV_COUNT + 1))
  echo "$NEW_COUNT" > "$BLOCK_COUNT_FILE"

  if [ "$NEW_COUNT" -ge 10 ]; then
    echo "[警告] ${NEW_COUNT}回連続で停止がブロックされています。エージェントが進捗できない可能性があります。" >&2
    echo "停止を許可します。ユーザーは状況を確認してください。" >&2
    rm -f "$BLOCK_COUNT_FILE"
    exit 0
  fi

  echo "[ブロック] must未達成またはPLAN未完了があるため停止をブロックします。続行してください。(${NEW_COUNT}/10回目で停止許可)" >&2
  exit 2
fi

# 正常終了時はカウンタをリセット
BLOCK_COUNT_FILE="/tmp/claude-stop-block-${BRANCH}"
rm -f "$BLOCK_COUNT_FILE"

exit 0
