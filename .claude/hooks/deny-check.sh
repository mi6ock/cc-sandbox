#!/bin/bash
#
# Claude Code PreToolUse Hook: deny-check.sh
# Bashコマンド実行前に危険なコマンドをブロックする
# ref: https://wasabeef.jp/blog/claude-code-secure-bash
#
# exit 0 = 許可
# exit 2 = ブロック（stdoutにJSON出力）
#

# set -euo pipefail は jq/grep の非ゼロ終了でクラッシュするため使用しない

# stdin から JSON を読み取る
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Bash 以外はスキップ
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# --- ハードコードされた拒否パターン（フォールバック） ---
DENY_PATTERNS=(
  # ファイルシステム破壊
  'rm -rf /'
  'rm -rf /*'
  'rm -rf ~'
  'rm -rf ~/*'
  'rm -rf .'
  'rm -rf ..'
  # パーミッション変更
  'chmod 777'
  'chmod -R 777'
  # git 設定改ざん
  'git config'
  # git 破壊的操作
  'git push --force'
  'git push -f'
  'git reset --hard'
  'git clean -fd'
  'git checkout -- .'
  # パッケージ管理（意図しないインストール防止）
  'brew install'
  'brew upgrade'
  # リポジトリ削除
  'gh repo delete'
  # フォークボム
  ':(){ :|:& };:'
  # ディスク書き込み破壊
  'dd if=/dev/zero'
  'dd if=/dev/random'
  'mkfs.'
  # ネットワーク系の危険コマンド
  'nc -l'
  'ncat -l'
  # 環境変数・認証情報の漏洩
  'printenv'
  'env > '
  'cat ~/.ssh'
  'cat /etc/passwd'
  'cat /etc/shadow'
  # sudo による権限昇格
  'sudo rm'
  'sudo chmod'
  'sudo chown'
  'sudo mkfs'
  'sudo dd '
  # リモートスクリプト実行
  'curl*|*sh'
  'curl*|*bash'
  'wget*|*sh'
  'wget*|*bash'
  # シェル操作
  'exec /bin/sh'
  'exec /bin/bash'
  '/dev/tcp/'
  '/dev/udp/'
)

# --- settings.json からも拒否パターンを読み取り（二重防御） ---
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
  EXTRA_PATTERNS=$(jq -r '
    .permissions.deny[]
    | select(startswith("Bash("))
    | gsub("^Bash\\("; "")
    | gsub("\\)$"; "")
  ' "$SETTINGS_FILE" 2>/dev/null || true)

  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    DENY_PATTERNS+=("$pat")
  done <<< "$EXTRA_PATTERNS"
fi

# --- マッチング関数 ---
matches_deny_pattern() {
  local cmd="$1"
  local pattern="$2"

  # 前後の空白を除去
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"

  # glob パターンマッチング（ワイルドカード対応）
  # shellcheck disable=SC2053
  if [[ "$cmd" == $pattern ]]; then
    return 0
  fi

  # 部分一致（固定文字列）もチェック
  if echo "$cmd" | grep -qiF "$pattern" 2>/dev/null; then
    return 0
  fi

  return 1
}

# --- ブロック処理 ---
block_command() {
  local matched_pattern="$1"
  local matched_cmd="$2"
  # stdoutにJSON出力してexit 2でブロック
  echo "{\"decision\":\"block\",\"reason\":\"危険なコマンドがブロックされました: '${matched_cmd}' (パターン: '${matched_pattern}')\"}"
  exit 2
}

# --- コマンド全体をチェック ---
for PATTERN in "${DENY_PATTERNS[@]}"; do
  [[ -z "$PATTERN" ]] && continue
  if matches_deny_pattern "$COMMAND" "$PATTERN"; then
    block_command "$PATTERN" "$COMMAND"
  fi
done

# --- コマンドをセミコロン・&&・|| で分割して各部分もチェック ---
IFS=$'\n'
SUBCOMMANDS=$(echo "$COMMAND" | sed 's/[;]\|&&\|||/\n/g')

for SUB in $SUBCOMMANDS; do
  # 前後の空白を除去
  SUB=$(echo "$SUB" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$SUB" ]] && continue

  for PATTERN in "${DENY_PATTERNS[@]}"; do
    [[ -z "$PATTERN" ]] && continue
    if matches_deny_pattern "$SUB" "$PATTERN"; then
      block_command "$PATTERN" "$SUB"
    fi
  done
done

# 許可
exit 0
