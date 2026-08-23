#!/usr/bin/env bash
set -euo pipefail
ROOT=${1:?root}
PATCH=${2:?patch}
EXPECTED=${3:?expected-blob}

CURRENT=$(git -C "$ROOT" hash-object CLAUDE.md)
HEADBLOB=$(git -C "$ROOT" rev-parse HEAD:CLAUDE.md)
echo "current_blob=$CURRENT"
echo "head_blob=$HEADBLOB"

if [ "$CURRENT" = "$EXPECTED" ]; then
  echo "already_applied=true"
else
  echo "already_applied=false"
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT
if git -C "$ROOT" apply --check "$PATCH" >"$err" 2>&1; then
  echo "apply_check=true"
else
  echo "apply_check=false"
fi
