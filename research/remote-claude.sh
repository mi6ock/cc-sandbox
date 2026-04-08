#!/bin/bash
#
# remote-claude.sh — リモートClaudeセッションの自動セットアップ
#
# 使い方:
#   bash ~/.claude/skills/remote-claude/remote-claude.sh start <ssh_host> [local_path]
#   bash ~/.claude/skills/remote-claude/remote-claude.sh send <ssh_host> "指示内容"
#   bash ~/.claude/skills/remote-claude/remote-claude.sh status <ssh_host>
#   bash ~/.claude/skills/remote-claude/remote-claude.sh wait <ssh_host>
#   bash ~/.claude/skills/remote-claude/remote-claude.sh attach <ssh_host>
#   bash ~/.claude/skills/remote-claude/remote-claude.sh stop <ssh_host>
#
# start だけで: mutagen同期 → tmuxセッション → claude起動 まで全自動。

set -euo pipefail

TMUX_SESSION="claude"
REMOTE_BASE_DIR="~/remote-claude"
SIGNAL_FILE="/tmp/claude-done-signal"
POLL_INTERVAL=5
DEBOUNCE=2

# ============================================================
# ユーティリティ
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

ssh_cmd() {
  local host="$1"; shift
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$host" "$@"
}

# ============================================================
# サブコマンド
# ============================================================

cmd_start() {
  local host="${1:?ssh_host が必要です}"
  local local_path="${2:-$(pwd)}"
  local project_name
  project_name=$(basename "$local_path")
  local remote_path="${REMOTE_BASE_DIR}/${project_name}"
  local sync_name="remote-claude-${project_name}"

  log "=== リモートClaude セットアップ開始 ==="
  log "Host: $host"
  log "Local: $local_path"
  log "Remote: $remote_path"
  log "Sync name: $sync_name"

  # --- 1. SSH接続テスト ---
  log "SSH接続テスト..."
  if ! ssh_cmd "$host" "echo ok" >/dev/null 2>&1; then
    err "SSH接続失敗: $host"
    exit 1
  fi
  log "SSH接続 OK"

  # --- 2. リモートの前提チェック ---
  log "リモート環境チェック..."
  local check
  check=$(ssh_cmd "$host" "
    echo claude=\$(which claude 2>/dev/null || echo 'NOT_FOUND')
    echo tmux=\$(which tmux 2>/dev/null || echo 'NOT_FOUND')
  ")
  if echo "$check" | grep -q "claude=NOT_FOUND"; then
    err "リモートに claude がインストールされていません"
    exit 1
  fi
  if echo "$check" | grep -q "tmux=NOT_FOUND"; then
    err "リモートに tmux がインストールされていません"
    exit 1
  fi
  log "リモート環境 OK (claude, tmux あり)"

  # --- 3. リモートディレクトリ作成 ---
  ssh_cmd "$host" "mkdir -p $remote_path"

  # --- 4. mutagen同期 ---
  log "mutagen同期セットアップ..."
  mutagen daemon start 2>/dev/null || true

  # 既存の同期セッションがあれば再利用
  if mutagen sync list 2>/dev/null | grep -q "Name: ${sync_name}"; then
    log "既存のmutagen同期セッション '${sync_name}' を再利用"
  else
    mutagen sync create \
      --name="$sync_name" \
      --mode=two-way-resolved \
      --ignore-vcs \
      -i "build/" \
      -i ".dart_tool/" \
      -i "node_modules/" \
      -i ".gradle/" \
      "$host:$remote_path" "$local_path"
    log "mutagen同期開始"
  fi

  # 同期完了を待つ
  log "初回同期待ち..."
  local wait_count=0
  while true; do
    local status
    status=$(mutagen sync list --name="$sync_name" 2>/dev/null | grep "Status:" | head -1 || echo "")
    if echo "$status" | grep -q "Watching for changes"; then
      break
    fi
    wait_count=$((wait_count + 1))
    if [ $wait_count -gt 120 ]; then
      err "mutagen同期がタイムアウト（10分）"
      exit 1
    fi
    sleep 5
  done
  log "mutagen同期完了"

  # --- 5. tmuxセッション + claude起動 ---
  log "リモートtmuxセッション起動..."
  if ssh_cmd "$host" "tmux has-session -t $TMUX_SESSION 2>/dev/null"; then
    log "既存のtmuxセッション '$TMUX_SESSION' あり。再利用します"
  else
    ssh_cmd "$host" "tmux new-session -d -s $TMUX_SESSION -c $remote_path 'claude --dangerously-skip-permissions'"
    log "tmuxセッション '$TMUX_SESSION' を起動し、claude を開始しました"
  fi

  # --- 6. 起動確認 ---
  sleep 3
  local pane_output
  pane_output=$(ssh_cmd "$host" "tmux capture-pane -t $TMUX_SESSION -p" 2>/dev/null || echo "")
  log "=== セットアップ完了 ==="
  log ""
  log "操作方法:"
  log "  指示送信:   bash $0 send $host \"指示内容\""
  log "  状態確認:   bash $0 status $host"
  log "  完了待ち:   bash $0 wait $host"
  log "  直接接続:   bash $0 attach $host"
  log "  停止:       bash $0 stop $host"
  log ""
  log "現在のリモート画面:"
  echo "$pane_output" | tail -15
}

cmd_send() {
  local host="${1:?ssh_host が必要です}"
  local task="${2:?指示内容が必要です}"

  log "指示送信: ${task:0:80}..."
  ssh_cmd "$host" "tmux send-keys -t $TMUX_SESSION -l '$task' && tmux send-keys -t $TMUX_SESSION Enter"
  log "送信完了"
}

cmd_status() {
  local host="${1:?ssh_host が必要です}"
  local output
  output=$(ssh_cmd "$host" "tmux capture-pane -t $TMUX_SESSION -p" 2>/dev/null)

  if echo "$output" | grep -qi "to interrupt"; then
    log "状態: 処理中"
  elif echo "$output" | grep -q "\[y/n\]\|\[Y/n\]"; then
    log "状態: 確認待ち"
  else
    log "状態: アイドル（入力待ち）"
  fi
  echo "---"
  echo "$output"
}

cmd_wait() {
  local host="${1:?ssh_host が必要です}"

  log "完了待機開始..."

  # Stop Hookシグナルの初期値
  local initial_signal
  initial_signal=$(ssh_cmd "$host" "cat $SIGNAL_FILE 2>/dev/null || echo 0")

  local state="SENT"
  local idle_count=0

  sleep 3

  while true; do
    local output
    output=$(ssh_cmd "$host" "tmux capture-pane -t $TMUX_SESSION -p" 2>/dev/null)
    local rc=$?

    # SSH失敗
    if [ $rc -ne 0 ] || [ -z "$output" ]; then
      log "SSH接続エラー、リトライ..."
      sleep 10
      continue
    fi

    # --- 一次シグナル: Stop Hook ---
    local current_signal
    current_signal=$(ssh_cmd "$host" "cat $SIGNAL_FILE 2>/dev/null || echo 0")
    if [ "$state" = "WORKING" ] && [ "$current_signal" != "$initial_signal" ]; then
      log "完了! (Stop Hook検知)"
      echo "$output"
      return 0
    fi

    # --- 二次シグナル: 画面パターン ---
    local has_interrupt has_confirm has_error
    has_interrupt=$(echo "$output" | grep -ci "to interrupt" || true)
    has_confirm=$(echo "$output" | grep -c "\[y/n\]\|\[Y/n\]" || true)
    has_error=$(echo "$output" | grep -ci "error\|rate limit\|overloaded" || true)

    if [ "$has_interrupt" -gt 0 ]; then
      state="WORKING"
      idle_count=0
      log "処理中..."

    elif [ "$has_confirm" -gt 0 ]; then
      log "確認待ち — 手動対応が必要"
      echo "$output" | tail -5
      return 1

    elif [ "$has_error" -gt 0 ] && [ "$state" = "WORKING" ]; then
      log "エラー検出"
      echo "$output" | tail -10
      return 1

    elif [ "$state" = "WORKING" ]; then
      idle_count=$((idle_count + 1))
      if [ $idle_count -ge $DEBOUNCE ]; then
        log "完了! (デバウンス確認済み)"
        echo "$output"
        return 0
      fi
      log "完了確認中... ($idle_count/$DEBOUNCE)"

    elif [ "$state" = "SENT" ]; then
      log "処理開始待ち..."
    fi

    sleep $POLL_INTERVAL
  done
}

cmd_attach() {
  local host="${1:?ssh_host が必要です}"
  log "tmuxセッションに接続します (Ctrl+B D でデタッチ)"
  ssh -t "$host" "tmux attach -t $TMUX_SESSION"
}

cmd_stop() {
  local host="${1:?ssh_host が必要です}"
  local local_path="${2:-$(pwd)}"
  local project_name
  project_name=$(basename "$local_path")
  local sync_name="remote-claude-${project_name}"

  log "リモートClaude停止..."

  # claude終了
  ssh_cmd "$host" "tmux send-keys -t $TMUX_SESSION -l '/exit' && tmux send-keys -t $TMUX_SESSION Enter" 2>/dev/null || true
  sleep 2

  # tmuxセッション削除
  ssh_cmd "$host" "tmux kill-session -t $TMUX_SESSION" 2>/dev/null || true
  log "tmuxセッション終了"

  # mutagen同期停止
  if mutagen sync list 2>/dev/null | grep -q "Name: ${sync_name}"; then
    mutagen sync terminate "$sync_name"
    log "mutagen同期停止"
  fi

  # シグナルファイル削除
  ssh_cmd "$host" "rm -f $SIGNAL_FILE" 2>/dev/null || true

  log "クリーンアップ完了"
}

# ============================================================
# メイン
# ============================================================

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    start)  cmd_start "$@" ;;
    send)   cmd_send "$@" ;;
    status) cmd_status "$@" ;;
    wait)   cmd_wait "$@" ;;
    attach) cmd_attach "$@" ;;
    stop)   cmd_stop "$@" ;;
    *)
      echo "使い方:"
      echo "  $0 start  <ssh_host> [local_path]  — セットアップ（mutagen + tmux + claude）"
      echo "  $0 send   <ssh_host> \"指示\"         — リモートClaudeに指示送信"
      echo "  $0 status <ssh_host>                — 現在の状態確認"
      echo "  $0 wait   <ssh_host>                — 完了まで待機"
      echo "  $0 attach <ssh_host>                — tmuxに直接接続"
      echo "  $0 stop   <ssh_host> [local_path]   — 全停止・クリーンアップ"
      ;;
  esac
}

main "$@"
