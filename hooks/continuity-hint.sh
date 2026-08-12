#!/usr/bin/env bash
# SessionStart hook: cwd に `_conversation-logs/` があれば
# 「続きを」トリガーによる path-drop 復帰フローの hint を Claude のコンテキストに注入する。
#
# 目的:
#   Zed / VS Code / エディタの再起動で agent panel のスレッドが空になった時、
#   ユーザーが「続きを」「再開」「続きから」等と発話すれば、cwd の
#   `_conversation-logs/YYYY-MM-DD.md` を Read して復帰する運用がある。
#   その存在を Claude に思い出させ、継続表現をトリガーとして正確に発火させる。
#
# 設計:
#   - 会話ログの中身自体は injection しない（2026-05-22 の「SessionStart 自動注入は無し」方針を維持）。
#   - 存在通知＋発動条件＋実行手順だけを Claude 側に渡す。
#   - 継続表現が無い発話には反応しないよう「no-op if not asked」を明記。
#   - 失敗時は無音で終了する（session 起動を妨げない）。
set -u

# save-conversation-log.py と同じ skip 条件で誤発火を防ぐ:
#   - $HOME 直下 / Workspace ルート / _templates 配下は「プロジェクトではない」ので skip
PWD_REAL=$(cd "$PWD" 2>/dev/null && pwd -P) || exit 0
HOME_REAL=$(cd "$HOME" 2>/dev/null && pwd -P) || exit 0
[ "$PWD_REAL" = "$HOME_REAL" ] && exit 0
[ "$(basename "$PWD_REAL")" = "Workspace" ] && exit 0
case "$PWD_REAL" in
  */_templates|*/_templates/*) exit 0 ;;
esac

LOG_DIR="$PWD/_conversation-logs"
[ -d "$LOG_DIR" ] || exit 0

# .md ファイル数（連番形式 legacy と 1 日 1 ファイル形式の両方をカウント）
count=$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || exit 0

latest=$(ls -1t "$LOG_DIR"/*.md 2>/dev/null | head -1)
[ -n "$latest" ] || exit 0
latest_name=$(basename "$latest")
proj=$(basename "$PWD")

python3 - "$proj" "$count" "$latest_name" <<'PY'
import json, sys

proj, count_str, latest = sys.argv[1], sys.argv[2], sys.argv[3]

msg = (
    "[Continuity — 会話ログによる復帰]\n"
    f"`{proj}` (cwd) に過去の会話ログが {count_str} 件あります "
    f"(最新: `_conversation-logs/{latest}`)。\n"
    "Zed / エディタ再起動で agent panel のスレッドが空になった時、"
    "ユーザーが「続きを」「続きから」「再開」「前回の続き」「あれ進めて」等の"
    "継続表現を発したら、以下を行う:\n"
    "\n"
    f"1. `_conversation-logs/{latest}` を Read（必要なら 1〜2 日分遡って全体像を掴む）\n"
    "2. プロジェクト直下の `CLAUDE.md` / `docs/RESUMING.md` があれば併読\n"
    "3. 「〜の状態を読み込みました。<次の作業>から良いですか？」と 1〜2 行で要約して着手\n"
    "   （挨拶・定型確認は省く。あたかも前セッションの続きであるかのように振る舞う）\n"
    "\n"
    "**継続表現が無い発話**（新しいタスクの依頼等）ではこの hint を無視し、"
    "log は Read せず通常の新規会話として応答する。"
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": msg
    }
}, ensure_ascii=False))
PY
