#!/bin/bash
# Goal/Plan Manager セットアップスクリプト
# プロジェクトルートで実行: bash /path/to/goal-plan-manager/scripts/setup.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(pwd)"

echo "=== Goal/Plan Manager セットアップ ==="
echo "プロジェクト: $PROJECT_ROOT"
echo "スキル: $SKILL_DIR"
echo ""

# 1. ディレクトリ作成
echo "[1/5] ディレクトリ作成..."
mkdir -p "$PROJECT_ROOT/.claude/goals"
mkdir -p "$PROJECT_ROOT/.claude/plans"
mkdir -p "$PROJECT_ROOT/.claude/hooks"

# 2. hookスクリプトをコピー
echo "[2/5] hookスクリプトをコピー..."
cp "$SKILL_DIR/scripts/inject-context.sh" "$PROJECT_ROOT/.claude/hooks/inject-context.sh"
cp "$SKILL_DIR/scripts/check-plan-goal.sh" "$PROJECT_ROOT/.claude/hooks/check-plan-goal.sh"
cp "$SKILL_DIR/scripts/verify-completion.sh" "$PROJECT_ROOT/.claude/hooks/verify-completion.sh"

# 3. テンプレートをコピー
echo "[3/5] テンプレートをコピー..."
cp "$SKILL_DIR/templates/goals/_example.md" "$PROJECT_ROOT/.claude/goals/_example.md"
cp "$SKILL_DIR/templates/plans/_example.md" "$PROJECT_ROOT/.claude/plans/_example.md"

# 4. 実行権限付与
echo "[4/5] 実行権限を付与..."
chmod +x "$PROJECT_ROOT/.claude/hooks/inject-context.sh"
chmod +x "$PROJECT_ROOT/.claude/hooks/check-plan-goal.sh"
chmod +x "$PROJECT_ROOT/.claude/hooks/verify-completion.sh"

# 5. settings.json にhook設定をマージ
echo "[5/5] settings.json にhook設定をマージ..."
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"

# hook設定のJSON
HOOK_CONFIG='{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/inject-context.sh"
          }
        ]
      },
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/inject-context.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/verify-completion.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/verify-completion.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/check-plan-goal.sh"
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
  # 既存のsettings.jsonにマージ（jqが必要）
  if command -v jq &> /dev/null; then
    # 既存の設定とhook設定をディープマージ
    MERGED=$(jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(echo "$HOOK_CONFIG"))
    echo "$MERGED" > "$SETTINGS_FILE"
    echo "  既存のsettings.jsonにマージしました"
  else
    echo "  [警告] jqが見つかりません。settings.jsonを手動で更新してください。"
    echo "  追加すべき設定:"
    echo "$HOOK_CONFIG"
  fi
else
  # 新規作成
  echo "$HOOK_CONFIG" > "$SETTINGS_FILE"
  echo "  settings.json を新規作成しました"
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "作成されたファイル:"
find "$PROJECT_ROOT/.claude" -type f | sort | while read -r f; do
  echo "  $(echo "$f" | sed "s|$PROJECT_ROOT/||")"
done
echo ""
echo "次のステップ:"
echo "  1. タスク用ブランチを切る"
echo "  2. .claude/goals/{ブランチ名}.md にゴールを定義"
echo "  3. .claude/plans/{ブランチ名}.md にプランを記述"
echo "  4. 実装開始"
