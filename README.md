# instyle-claude-common

sasaki / team / mebius 各配布の **共通 hook スクリプト**を単一の source of truth に集約するための repo。3 repo 間の重複コピー運用（同じ変更を 3 箇所 push）を消すために切り出した。

## 消費側

以下の 3 repo が本 repo を **git submodule** として `common/` に配置する:

- `sasaki-ta-instyle/instyle-claude-sasaki` — sasaki 個人配布
- `sasaki-ta-instyle/instyle-claude-team` — INSTYLE GROUP チーム配布
- `sasaki-ta-instyle/instyle-claude-mebius` — メビウス製薬チーム配布

## 現在の内容

### `hooks/`

Claude Code の hook スクリプト（3 repo で完全一致するもの）。

| ファイル | 呼ばれる場面 | 役割 |
|---|---|---|
| `continuity-hint.sh` | SessionStart | cwd に `_conversation-logs/` があれば「続きを」トリガー hint を Claude に注入 |
| `save-conversation-log.py` | Stop | 直近ターンを `_conversation-logs/YYYY-MM-DD.md` に追記（1 日 1 ファイル形式） |
| `check-sync.sh` | SessionStart | 所属 repo に未取得 commit があれば通知（auto-detect 対応） |

すべて `~/.claude/<file>` へ symlink される想定。各 repo の `bootstrap.sh` が `$ROOT/common/hooks/<file>` を symlink 先として使う。

## 管理者と push 権限

- **sasaki**（`sasaki-ta-instyle`）が唯一の管理者
- 内容の追加・修正は sasaki が判断し、各消費側の `git submodule update --remote` で反映される

## 追加候補（未移行）

将来 common に寄せる余地があるもの:

- `home-claude/skills/itaco/` — team のみ配布中だが、mebius にも入れる需要が出れば移す
- `memory/reference_conversation_logs.md` — 3 repo で一致している一般化された参照。ただし repo ごとに frontmatter 微差あり
- その他汎用 hook が増えたとき（例: 通知系）

移行判断は 5 点プレースホルダー化チェック（個人名 / 固定パス / 個別アカウント / クライアント名 / メイン・サブ Mac 表記）を通したものだけ。

## submodule 導入手順（消費側）

```bash
# 初回追加
cd ~/instyle-claude-<name>
git submodule add https://github.com/sasaki-ta-instyle/instyle-claude-common.git common
git commit -m "chore: add instyle-claude-common as submodule"

# 消費側の bootstrap.sh は $ROOT/common/hooks/<file> を symlink する
# 例: symlink_home_claude "$ROOT/common/hooks/continuity-hint.sh" "$HOME/.claude/continuity-hint.sh"

# 別 Mac / チームメンバーがクローンするとき
git clone --recurse-submodules https://github.com/sasaki-ta-instyle/instyle-claude-<name>.git
# または既存 clone に対して
git submodule update --init --recursive

# common 側に更新が入った時
git submodule update --remote common
git add common && git commit -m "chore: bump common submodule"
```
