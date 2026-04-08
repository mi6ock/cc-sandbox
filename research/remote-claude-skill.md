---
name: remote-claude
description: SSH経由でリモートマシンのClaudeをtmux+mutagenで操作し、変更をリアルタイムにローカルと同期する
---

リモートマシンのtmux内で対話型Claude Codeを実行し、mutagenでファイルをリアルタイム同期するスキル。

## 前提

- ローカルに mutagen がインストール済み（`brew install mutagen-io/mutagen/mutagen`）
- リモートに claude, tmux がインストール済み
- SSH鍵認証が設定済み

## 引数

- **ssh_host** (必須): SSH接続先
- **local_path** (任意): ローカルのリポジトリパス（省略時はカレントディレクトリ）

## スクリプト

すべての操作は `~/.claude/skills/remote-claude/remote-claude.sh` で実行する。

### セットアップ（一発起動）

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh start <ssh_host> [local_path]
```

これだけで以下が全自動で実行される:
1. SSH接続テスト
2. リモート環境チェック（claude, tmux）
3. mutagen双方向同期の開始（.git, build成果物は除外）
4. 初回同期の完了待ち
5. リモートtmuxセッションでclaude起動（`--dangerously-skip-permissions`）

### 指示送信

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh send <ssh_host> "指示内容"
```

### 状態確認

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh status <ssh_host>
```

### 完了待機（ポーリング）

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh wait <ssh_host>
```

状態機械 + デバウンスで堅牢に完了検知する:
- **SENT → WORKING**: `"to interrupt"` を検出したら処理中
- **WORKING → 完了**: Stop Hookシグナル検知、またはinterrupt消滅がDEBOUNCE回連続
- **→ 確認待ち**: `[y/n]` プロンプト検出
- **→ エラー**: error/rate limit 検出

Bashの `run_in_background` で実行し、完了通知を受け取る。

### 直接接続

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh attach <ssh_host>
```

tmuxセッションに直接入る。`Ctrl+B D` でデタッチ。

### 停止・クリーンアップ

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh stop <ssh_host> [local_path]
```

tmux終了 + mutagen停止 + シグナルファイル削除。

## ローカルClaudeからの使い方

スキル実行時は以下の流れで操作する:

1. `start` でセットアップ
2. ログインが必要なら `status` で画面を確認し、URLをブラウザで開く → コードを `send` で入力
3. `send` で指示を送信
4. `wait` をバックグラウンドで実行して完了を待つ
5. 完了後、ローカルで `git diff` して変更を確認
6. 終わったら `stop` でクリーンアップ

## 注意事項

- `.git/` は同期しない。ローカルの `.git/` でコミットする
- リモートにgit cloneは不要。mutagenでローカルからファイルを同期する
- Stop Hookを設定するとwaitの信頼性が上がる（リモートの `~/.claude/settings.json` に `Stop` hookで `date +%s > /tmp/claude-done-signal` を追加）
