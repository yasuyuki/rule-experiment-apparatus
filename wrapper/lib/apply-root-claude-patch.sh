#!/usr/bin/env bash
set -euo pipefail
ROOT=${1:?root}
PATCH=${2:?patch}
EXPECTED=${3:?expected-blob}
MESSAGE=${4:?commit-message}

CURRENT=$(git -C "$ROOT" hash-object CLAUDE.md)
if [ "$CURRENT" = "$EXPECTED" ]; then
  echo "working_blob=$CURRENT"
  echo "already_applied=true"
  echo "error=CLAUDE.md already matches expected blob; refusing re-apply" >&2
  exit 2
fi

git -C "$ROOT" apply --check "$PATCH"
git -C "$ROOT" apply "$PATCH"
BLOB=$(git -C "$ROOT" hash-object CLAUDE.md)
echo "working_blob=$BLOB"
test "$BLOB" = "$EXPECTED"
git -C "$ROOT" add CLAUDE.md
git -C "$ROOT" commit -m "$MESSAGE"
echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
git -C "$ROOT" status --porcelain=v1
