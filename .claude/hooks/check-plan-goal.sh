#!/bin/bash
# サブエージェント内ではスキップ（agent_idはサブエージェントでのみ存在）
INPUT=$(cat)
if echo "$INPUT" | grep -q '"agent_id"'; then
  exit 0
fi

BRANCH=$(git branch --show-current 2>/dev/null | sed 's/\//-/g' || echo "unknown")
GOAL=".claude/goals/${BRANCH}.md"
PLAN=".claude/plans/${BRANCH}.md"

if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  echo "[警告] main/masterブランチで直接作業しています。タスク用ブランチを切ることを推奨します。" >&2
  exit 0
fi

WARNINGS=""

if [ ! -f "$GOAL" ]; then
  WARNINGS="${WARNINGS}[GOAL未作成] ${GOAL} が存在しません。ゴールを定義してください。\n"
fi

if [ ! -f "$PLAN" ]; then
  WARNINGS="${WARNINGS}[PLAN未作成] ${PLAN} が存在しません。プランを書き出してください。\n"
fi

if [ -n "$WARNINGS" ]; then
  echo -e "$WARNINGS" >&2
fi
