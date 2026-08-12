#!/usr/bin/env bash
# SessionStart hook: 所属の instyle-claude-{sasaki,team,mebius} repo に
# 未取得のコミットがあれば Claude にコンテキストとして通知する。
# ネットワーク失敗時は無音終了、repo が見つからなくても無音終了。
#
# 検出順:
#   1. 環境変数 INSTYLE_CLAUDE_REPO が指すディレクトリ（明示指定）
#   2. $HOME/instyle-claude-sasaki  (sasaki 個人 Mac)
#   3. $HOME/instyle-claude-team    (team メンバー Mac)
#   4. $HOME/instyle-claude-mebius  (メビウス社員 Mac)
# それぞれ .git の存在で有効性を判定する。sasaki Mac は sasaki を指す、
# team メンバーは team を指す、というふうに 1 台 1 repo で当たる想定。
set -u

REPO=""
if [ -n "${INSTYLE_CLAUDE_REPO:-}" ] && [ -d "$INSTYLE_CLAUDE_REPO/.git" ]; then
  REPO="$INSTYLE_CLAUDE_REPO"
else
  for candidate in \
    "$HOME/instyle-claude-sasaki" \
    "$HOME/instyle-claude-team" \
    "$HOME/instyle-claude-mebius"; do
    if [ -d "$candidate/.git" ]; then
      REPO="$candidate"
      break
    fi
  done
fi

[ -n "$REPO" ] || exit 0

# fetch（5 秒タイムアウト）。失敗してもセッション開始を妨げない。
if ! timeout 5 git -C "$REPO" fetch --quiet origin main 2>/dev/null; then
  exit 0
fi

behind="$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
[ "${behind:-0}" -gt 0 ] || exit 0

log="$(git -C "$REPO" log --oneline --no-decorate HEAD..origin/main 2>/dev/null | head -10)"
repo_name="$(basename "$REPO")"

# JSON エンコード（python3 で安全に）
python3 - "$behind" "$log" "$repo_name" <<'PY'
import json, sys
behind, log, repo_name = sys.argv[1], sys.argv[2], sys.argv[3]

# repo 名で notification 文言を出し分ける（1 台 1 repo の想定）
if repo_name == "instyle-claude-sasaki":
    origin_note = "別 Mac から push された可能性"
elif repo_name == "instyle-claude-team":
    origin_note = "チームの誰かが push した可能性"
elif repo_name == "instyle-claude-mebius":
    origin_note = "sasaki が push した可能性"
else:
    origin_note = "誰かが push した可能性"

msg = (
    f"[{repo_name} 同期通知] origin/main に未取得の変更が {behind} 件あります "
    f"（{origin_note}）。\n\n"
    f"{log}\n\n"
    f"反映する場合: `cd ~/{repo_name} && git pull && ./bootstrap.sh`\n\n"
    f"ユーザーに同期するか確認してください。"
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": msg
    }
}, ensure_ascii=False))
PY
