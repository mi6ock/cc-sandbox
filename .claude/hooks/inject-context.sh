#!/bin/bash
# サブエージェント内ではスキップ（agent_idはサブエージェントでのみ存在）
INPUT=$(cat)
if echo "$INPUT" | grep -q '"agent_id"'; then
  echo "OK"
  exit 0
fi

# sourceを取得（compact / startup / resume）
SOURCE=$(echo "$INPUT" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4)

BRANCH=$(git branch --show-current 2>/dev/null | sed 's/\//-/g' || echo "unknown")
GOAL=".claude/goals/${BRANCH}.md"
PLAN=".claude/plans/${BRANCH}.md"

HAS_CONTENT=false

# compaction後はCLAUDE.mdとMEMORY.mdも再注入（通常起動時はClaude Codeが自動読み込みするため不要）
if [ "$SOURCE" = "compact" ]; then
  # グローバルCLAUDE.md
  if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    echo "================================================================"
    echo "CLAUDE.md (global)"
    echo "================================================================"
    cat "$HOME/.claude/CLAUDE.md"
    echo ""
    HAS_CONTENT=true
  fi

  # プロジェクトローカルCLAUDE.md
  if [ -f ".claude/CLAUDE.md" ]; then
    echo "================================================================"
    echo "CLAUDE.md (project)"
    echo "================================================================"
    cat ".claude/CLAUDE.md"
    echo ""
    HAS_CONTENT=true
  elif [ -f "CLAUDE.md" ]; then
    echo "================================================================"
    echo "CLAUDE.md (project root)"
    echo "================================================================"
    cat "CLAUDE.md"
    echo ""
    HAS_CONTENT=true
  fi

  # MEMORY.md（プロジェクト別の自動メモリ）
  PROJECT_DIR=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$PROJECT_DIR" ]; then
    MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_DIR" | sed 's|/|-|g')/memory"
    if [ -f "$MEMORY_DIR/MEMORY.md" ]; then
      echo "================================================================"
      echo "MEMORY.md"
      echo "================================================================"
      cat "$MEMORY_DIR/MEMORY.md"
      echo ""
      HAS_CONTENT=true
    fi
  fi
fi

# GOAL/PLANは常に注入（startup/resume/compact共通）
if [ -f "$GOAL" ]; then
  echo "================================================================"
  echo "GOAL (branch: ${BRANCH})"
  echo "================================================================"
  cat "$GOAL"
  echo ""
  HAS_CONTENT=true
fi

if [ -f "$PLAN" ]; then
  echo "================================================================"
  echo "PLAN (branch: ${BRANCH})"
  echo "================================================================"
  cat "$PLAN"
  echo ""
  HAS_CONTENT=true
fi

if [ "$HAS_CONTENT" = false ]; then
  echo "[INFO] branch ${BRANCH} に対応するGOAL/PLANファイルがありません。"
  echo "新規タスクの場合は .claude/goals/${BRANCH}.md と .claude/plans/${BRANCH}.md を作成してください。"
fi
