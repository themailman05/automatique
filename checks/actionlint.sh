#!/usr/bin/env bash
# Validate all workflow files with actionlint (ignoring shellcheck info/style)
set -euo pipefail

ERRORS=$(actionlint .github/workflows/*.yml 2>&1 | grep -v 'shellcheck.*:info:' | grep -v 'shellcheck.*:style:' | grep -E '^\.' || true)

if [[ -n "$ERRORS" ]]; then
  echo "❌ actionlint found issues:"
  echo "$ERRORS"
  exit 1
fi

echo "✅ actionlint passed (no errors beyond shellcheck info/style)"
