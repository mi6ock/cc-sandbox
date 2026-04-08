---
name: remote-claude
description: リモートマシンでClaudeを透過的に実行し、git/ghはローカルで動作、ファイルはmutagenで同期
---

ローカルからコマンド一発でリモートClaudeセッションに接続。ファイル操作はリモート、git/ghコマンドはローカルで透過的に実行される。

## 前提

- ローカル: mutagen (`brew install mutagen-io/mutagen/mutagen`)
- リモート: claude, tmux, python3
- SSH鍵認証

## 初回セットアップ

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh setup <ssh_host>
```

リモートに git/gh ラッパーをデプロイする（一度だけ）。

## 使い方

### セッション開始

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh <ssh_host> [local_path]
```

これだけで:
1. ローカルコマンドエージェント起動（git/gh転送用TCP server）
2. mutagen双方向同期開始（.git除外）
3. SSH逆トンネル付きでリモートに接続
4. tmux内でclaude起動（`--dangerously-skip-permissions`）

ユーザーはリモートのClaudeを普通に操作する。git/ghコマンドは自動的にローカルで実行される。

### その他コマンド

```bash
remote-claude stop [local_path]  # 全停止
remote-claude status             # 状態表示
remote-claude setup <ssh_host>   # リモートセットアップ
```

## アーキテクチャ

```
[ローカル]                              [リモート]
local-agent.py (TCP:9999)  ←─ SSH -R ─→  git/gh ラッパー → cmd-forwarder.py
     │                                        │
     ├── git/gh をローカルで実行              ├── ファイル操作はリモートで
     └── mutagen ←──── 双方向同期 ────→ mutagen
```

- **local-agent.py**: TCPサーバー。git/ghのみ許可。トークン認証。
- **cmd-forwarder.py**: リモート側クライアント。コマンドをTCP経由でローカルに転送。
- **git/gh ラッパー**: リモートの `~/bin/` に配置。cmd-forwarder.pyを呼ぶシェルスクリプト。
- **プロトコル**: 長さプレフィクス付きJSON（4バイトBE + JSON）

## 設定

`~/.claude/skills/remote-claude/config.json`:

```json
{
  "default_host": "salmon-river-kose.exe.xyz",
  "agent_port": 9999,
  "remote_base_dir": "~/remote-claude",
  "exclude_patterns": ["build/", ".dart_tool/", "node_modules/", ".gradle/"]
}
```

## 注意事項

- `.git/` はmutagenで同期しない。git操作は常にローカル
- リモートでgit cloneは不要。mutagenがローカルからファイルを同期する
- セッション外でリモートのgitを使うには `/usr/bin/git` を直接指定
