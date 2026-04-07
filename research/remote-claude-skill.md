---
name: remote-claude
description: SSH経由でリモートマシンのClaudeをtmux+mutagenで操作し、変更をリアルタイムにローカルと同期する
---

リモートマシンのtmux内で対話型Claude Codeを実行し、mutagenでファイルをリアルタイム同期するスキル。

## 引数

- **ssh_host** (必須): SSH接続先（例: `user@host`, `.ssh/config`のホスト名）
- **remote_path** (必須): リモートの作業ディレクトリ
- **local_path** (必須): ローカルのリポジトリパス
- **task** (任意): リモートClaudeに送る指示

引数が不足している場合は AskUserQuestion で確認する。

## セットアップ

### 1. SSH接続テスト

```bash
ssh <ssh_host> "echo 'ok' && which claude && which tmux"
```

- claude が見つからない → リモートにClaude Codeのインストールが必要
- SSH鍵認証が前提

### 2. Stop Hook の設定（初回のみ）

リモートのClaude Code設定にStop Hookを追加する。これが完了検知の**一次シグナル**になる:

```bash
ssh <ssh_host> 'mkdir -p ~/.claude && cat > /tmp/setup-hook.json << '"'"'HOOKEOF'"'"'
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "date +%s > /tmp/claude-done-signal"
      }]
    }]
  }
}
HOOKEOF
# 既存のsettings.jsonがあればマージ、なければ新規作成
if [ -f ~/.claude/settings.json ]; then
  echo "既存のsettings.jsonあり。手動でStop hookを追加してください"
  cat /tmp/setup-hook.json
else
  mv /tmp/setup-hook.json ~/.claude/settings.json
fi'
```

既存のsettings.jsonがある場合は、`hooks.Stop` セクションを手動でマージする。

### 3. mutagen同期の開始

ローカル→リモートの双方向同期を開始する:

```bash
mutagen daemon start 2>/dev/null
mutagen sync create \
  --name=remote-claude \
  --mode=two-way-resolved \
  --ignore-vcs \
  <ssh_host>:<remote_path> <local_path>
```

- `--ignore-vcs` で `.git/` を除外（必須）
- 必要に応じてビルド成果物も除外: `-i "build/" -i ".dart_tool/"` 等
- 同期状態の確認: `mutagen sync list`

### 4. リモートtmuxでClaude起動

```bash
ssh <ssh_host> "tmux new-session -d -s claude -c <remote_path> 'claude --dangerously-skip-permissions'"
```

- `--dangerously-skip-permissions` でツール承認をバイパス
- 初回はログインが必要な場合がある。`tmux capture-pane` でURLを取得し、ブラウザでログイン後コードを `tmux send-keys` で入力する
- effort選択などのプロンプトが出たら `tmux send-keys` で応答する

## 操作

### 指示の送信

```bash
ssh <ssh_host> "tmux send-keys -t claude -l '<指示内容>' && tmux send-keys -t claude Enter"
```

- テキストは `-l`（literal）で送る。特殊文字の誤解釈を防ぐ
- 改行は `tmux send-keys -t claude Enter` で別途送る

### 出力の確認

```bash
ssh <ssh_host> "tmux capture-pane -t claude -p"
```

- Claude Codeはalternate screen bufferを使うため、見えるのはビューポートのみ（スクロールバック不可）

### 完了検知（状態機械 + デバウンス）

バックグラウンドで完了を監視する。状態機械で誤検知を防ぐ:

```bash
HOST=<ssh_host>
SIGNAL_FILE="/tmp/claude-done-signal"
DEBOUNCE=2  # 連続idle回数の閾値
POLL_INTERVAL=5

# Stop Hookのシグナルファイルの初期タイムスタンプを記録
initial_signal=$(ssh "$HOST" "cat $SIGNAL_FILE 2>/dev/null || echo 0")

state="SENT"    # SENT → WORKING → IDLE/WAITING/ERROR
idle_count=0

sleep 3  # 処理開始を待つ

while true; do
  output=$(ssh "$HOST" "tmux capture-pane -t claude -p" 2>/dev/null)
  rc=$?

  # SSH接続失敗
  if [ $rc -ne 0 ] || [ -z "$output" ]; then
    echo "$(date): SSH接続エラー、リトライ..."
    sleep 10
    continue
  fi

  # --- 一次シグナル: Stop Hook ---
  current_signal=$(ssh "$HOST" "cat $SIGNAL_FILE 2>/dev/null || echo 0")
  if [ "$state" = "WORKING" ] && [ "$current_signal" != "$initial_signal" ]; then
    echo "$(date): 完了! (Stop Hook検知)"
    echo "$output"
    break
  fi

  # --- 二次シグナル: 画面パターン解析 ---
  has_interrupt=$(echo "$output" | grep -ci "to interrupt")
  has_confirm=$(echo "$output" | grep -c "\[y/n\]\|\[Y/n\]")
  has_error=$(echo "$output" | grep -ci "error\|rate limit\|overloaded")

  if [ "$has_interrupt" -gt 0 ]; then
    # 処理中
    state="WORKING"
    idle_count=0
    echo "$(date): 処理中..."

  elif [ "$has_confirm" -gt 0 ]; then
    # 確認プロンプト（[y/n]）が出ている
    echo "$(date): 確認待ち — 手動対応が必要"
    echo "$output" | tail -5
    break

  elif [ "$has_error" -gt 0 ] && [ "$state" = "WORKING" ]; then
    # エラー発生
    echo "$(date): エラー検出"
    echo "$output" | tail -10
    break

  elif [ "$state" = "WORKING" ]; then
    # WORKINGからinterruptが消えた → 完了の可能性
    # デバウンス: 連続で確認してから完了と判定（ツール間の隙間を誤検知しない）
    idle_count=$((idle_count + 1))
    if [ $idle_count -ge $DEBOUNCE ]; then
      echo "$(date): 完了! (デバウンス確認済み)"
      echo "$output"
      break
    fi
    echo "$(date): 完了確認中... ($idle_count/$DEBOUNCE)"

  elif [ "$state" = "SENT" ]; then
    # まだ処理が始まっていない
    echo "$(date): 処理開始待ち..."
  fi

  sleep $POLL_INTERVAL
done
```

**状態遷移:**
```
SENT → (interruptを検出) → WORKING → (interruptが消滅 × DEBOUNCE回) → 完了
                                    → (Stop Hook発火) → 完了
                                    → ([y/n]を検出) → 確認待ち
                                    → (error検出) → エラー
```

**検知の優先順位:**
1. **Stop Hook** (一次) — Claudeが応答完了時にhookがファイルにタイムスタンプを書く。最も確実
2. **画面パターン + デバウンス** (二次) — `"to interrupt"` の有無で判定。デバウンスでツール間の隙間での誤検知を防止
3. **確認/エラー検知** — `[y/n]` プロンプトやエラーメッセージを検知して報告

Bashの `run_in_background` で実行し、完了通知を受け取る。

## 結果の取得

mutagen が自動でファイルを同期するため、完了後はローカルで:

```bash
cd <local_path> && git diff
```

で変更を確認できる。

## セッション管理

### tmuxに直接接続（対話操作）

```bash
ssh -t <ssh_host> "tmux attach -t claude"
```

`Ctrl+B D` でデタッチ。SSHが切れてもtmux内のClaudeは動き続ける。

### セッション終了

```bash
ssh <ssh_host> "tmux send-keys -t claude -l '/exit' && tmux send-keys -t claude Enter"
```

### クリーンアップ

```bash
# tmuxセッション削除
ssh <ssh_host> "tmux kill-session -t claude"

# mutagen同期停止
mutagen sync terminate remote-claude

# シグナルファイル削除
ssh <ssh_host> "rm -f /tmp/claude-done-signal"
```

## 注意事項

- `.git/` は絶対に同期しない。各側で独立したgit状態を持つ
- ローカルでコミットする場合、リモート側の `.git/` は存在しない（mutagenで同期したため）。ローカルの `.git/` を使う
- リモートにgit cloneが必要な場合は、`ssh -A`（Agent転送）でローカルのSSH鍵を使うか、mutagenでローカルから同期する（後者が簡単）
- mutagen未インストール時は `brew install mutagen-io/mutagen/mutagen`
- Stop Hookが設定されていない場合、二次シグナル（画面パターン）のみで動作するが、信頼性は下がる
