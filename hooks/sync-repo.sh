#!/usr/bin/env bash
# sync-repo.sh <repo-path>
#
# instyle-claude-{sasaki,team,mebius} を origin/main に追従させ、bootstrap --auto まで走らせる。
# check-sync.sh（SessionStart hook）が Claude に実行させる同期コマンドの本体。
#
# Dropbox 構成への耐性:
#   repo を Dropbox 配下に置き、作業ツリーは Dropbox で複数 Mac に共有・.git は Mac ごと
#   （xattr com.dropbox.ignored）という構成では、別 Mac の pull で作業ツリーだけが先に
#   最新化され、この Mac の `git pull` が "would be overwritten by merge" で止まる。
#   そこで pull が失敗したときは、作業ツリーが取り込み先とファイル内容まで完全一致し、
#   かつ手元にだけある commit が無い場合に限り、git の記録だけを合わせる
#   （git reset = mixed、ファイルは一切変更しない）。1 ファイルでも違えば何もせず停止する。
#   Dropbox を使わない通常の clone ではこの分岐に入らない。
#
# 終了コード: 0 = 同期 + bootstrap 完了 / 2 = 手動対応が必要（何も変更していない）/ その他 = bootstrap 等の失敗
set -euo pipefail

REPO="${1:?usage: sync-repo.sh <repo-path>}"
cd "$REPO"

# <dir> の作業ツリーが <ref> のツリーと完全一致するか（<ref> の全パスが同内容で存在するか）。
# 一時 index に <ref> を読み込んで作業ツリーと比較する。本物の index・HEAD には触れない。
# <ref> に無いローカル専用ファイルは比較対象外（reset しても残るため安全）。
worktree_matches() {
  local dir="$1" ref="$2" tmpdir rc=0
  tmpdir="$(mktemp -d)"
  GIT_INDEX_FILE="$tmpdir/index" git -C "$dir" read-tree "$ref"
  GIT_INDEX_FILE="$tmpdir/index" git -C "$dir" update-index -q --refresh >/dev/null 2>&1 || true
  GIT_INDEX_FILE="$tmpdir/index" git -C "$dir" diff --quiet --ignore-submodules || rc=$?
  rm -rf "$tmpdir"
  return "$rc"
}

# <dir> の HEAD を <ref> に合わせる。作業ツリーが一致し、HEAD が <ref> の祖先のときだけ。
align_record_if_identical() {
  local dir="$1" ref="$2"
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$ref"; then
    echo "STOP: $dir に origin に無い commit があります。手動対応が必要です: cd '$REPO' && git status" >&2
    exit 2
  fi
  if ! worktree_matches "$dir" "$ref"; then
    echo "STOP: $dir のファイルが取り込み先と異なります。手動対応が必要です: cd '$REPO' && git status" >&2
    exit 2
  fi
  git -C "$dir" reset -q "$ref"
  echo "aligned: $dir は取り込み先と同一内容だったため git の記録だけを合わせました（ファイル変更なし）"
}

# 1. 本体
if ! git pull --ff-only; then
  echo "pull --ff-only が失敗。作業ツリーが origin/main と同一か確認します" >&2
  git fetch -q origin main
  align_record_if_identical . origin/main
fi

# 2. submodule（common 等）。同じ理由で update が止まる場合に同じ判定で合わせる。
if [ -f .gitmodules ] && ! git submodule update --init --recursive -q 2>/dev/null; then
  while read -r sm_path sm_sha; do
    [ -n "$sm_path" ] || continue
    [ "$(git -C "$sm_path" rev-parse HEAD 2>/dev/null)" = "$sm_sha" ] && continue
    git -C "$sm_path" fetch -q origin || true
    align_record_if_identical "$sm_path" "$sm_sha"
  done < <(git submodule foreach --quiet 'echo "$sm_path $sha1"')
fi

echo "repo: $(git log -1 --oneline)"

# 3. 配置
./bootstrap.sh --auto
