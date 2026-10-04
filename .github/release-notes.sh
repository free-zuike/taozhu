#!/usr/bin/env bash
# 更新说明起点：最近一个"已发布且带资产"的 tag。
# 失败/空壳 run 会残留 tag 但没有 release 资产（cleanup 只删 release 不清 tag），
# 若按"最近 tag"取起点，版本跳号后的更新说明就只剩失败修复，丢失真实功能内容。
# 从最近成功 tag 累计到 HEAD，使失败版本（及其前序未发布）的功能 commit 全部并入本次说明。
set -euo pipefail
VERSION="${1:-}"
git fetch --tags --quiet || true
BASE=""
for t in $(git tag --sort=-version:refname | grep -v "^taozhu-v${VERSION}$"); do
  assets=$(gh release view "$t" --repo "${GITHUB_REPOSITORY}" --json assets -q '.assets | length' 2>/dev/null || echo 0)
  if [ "${assets:-0}" -gt 0 ]; then
    BASE="$t"
    break
  fi
done
if [ -n "$BASE" ]; then
  git log --format='- %s' --no-merges "$BASE..HEAD"
else
  git log --format='- %s' --no-merges -8
fi