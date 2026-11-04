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
#
# opt-out:
#   `~/.config/instyle-claude-sync/off` を作れば hook が無音終了する。
#   復帰は `rm ~/.config/instyle-claude-sync/off`。
set -u

# ---- opt-out flag ----
if [ -f "$HOME/.config/instyle-claude-sync/off" ]; then
  exit 0
fi

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
# macOS には timeout(1) が標準で無いため、GNU coreutils の gtimeout があればそれを、
# 無ければタイムアウト無しでフォールバック（fetch 自体は --quiet でネットワーク断時に
# git が数秒で返すので実運用上の実害は小さい）。
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 5"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 5"
else
  TIMEOUT_CMD=""
fi
if ! $TIMEOUT_CMD git -C "$REPO" fetch --quiet origin main 2>/dev/null; then
  exit 0
fi

behind="$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
[ "${behind:-0}" -gt 0 ] || exit 0

log="$(git -C "$REPO" log --oneline --no-decorate HEAD..origin/main 2>/dev/null | head -10)"
repo_name="$(basename "$REPO")"

# JSON エンコード（python3 で安全に）
python3 - "$behind" "$log" "$repo_name" "$REPO" <<'PY'
import json, sys
behind, log, repo_name, repo_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

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
    "=== ユーザーへの応答手順（Claude が実行） ===\n\n"
    f"1. ユーザーに「`{repo_name}` に {behind} 件の未取得があります。同期しますか？」"
    "と 1 行で聞く（挨拶や説明は付けない）。\n\n"
    "2. ユーザーの返答が **Yes 系**（`はい` / `yes` / `Y` / `y` / `おk` / `お願い` / "
    "`OK` / `ok` / `同期して` / `pull して` / `やって` / `どうぞ`）なら、Bash tool で "
    "以下を **1 回の呼び出し**として実行する:\n\n"
    "   ```\n"
    f"   bash '{repo_path}/common/hooks/sync-repo.sh' '{repo_path}'\n"
    "   ```\n\n"
    "   （中身: `git pull --ff-only` → `./bootstrap.sh --auto`。Dropbox 共有で作業ツリーだけ先に"
    "最新化されている場合は、ファイルが完全一致するときに限り git の記録だけを合わせて続行する）\n\n"
    "   実行結果（成功 / 失敗 / stderr の要約）を **1〜2 行**でユーザーに報告する。\n"
    "   成功時は「✓ 同期完了（N commits 反映）。`~/.claude/` 配下の hook / skills / "
    "settings.json 変更は **次回 claude 起動時から有効** になります。」を末尾に付け加える。\n\n"
    "3. **No 系**（`いいえ` / `no` / `n` / `やめて` / `後で` / `skip` / `パス`）なら、"
    "「了解、スキップしました」とだけ返す。以降このセッション中は再度聞かない。\n\n"
    "4. **どちらとも取れない曖昧な返答**（新しいタスクの依頼 / 別の話題）が来たら、"
    "同期は保留してその新タスクを優先する。再度聞き直さない。\n\n"
    "5. スクリプトが **exit 2**（`STOP:` を出力）で終わったら、ローカルの内容が取り込み先と"
    "異なるため何も変更せず止まっている。`git stash` / `git reset --hard` / 手動 merge を "
    "Claude が勝手にやらない。「pull で conflict が出ました。手動対応が必要です: "
    f"`cd {repo_path} && git status`」と 1 行で報告して停止。\n\n"
    "6. それ以外の非 0 終了（`./bootstrap.sh --auto` の失敗等）なら、末尾 10 行の出力を"
    "そのまま貼って「bootstrap が失敗しました。手動確認が必要です」と報告して停止。\n\n"
    "=== 同期を毎回聞かれたくない場合 ===\n"
    "ユーザーが「今後聞かないで」「毎回聞くの面倒」と明示したら、以下を実行して "
    "この hook を無音化する:\n"
    "   ```\n"
    "   mkdir -p ~/.config/instyle-claude-sync && touch ~/.config/instyle-claude-sync/off\n"
    "   ```\n"
    "復帰は `rm ~/.config/instyle-claude-sync/off`。"
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": msg
    }
}, ensure_ascii=False))
PY
