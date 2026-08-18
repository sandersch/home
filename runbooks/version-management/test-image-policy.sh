#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/image_policy.py"
fixtures="$script_dir/fixtures"

"$validator" check --quiet --root "$fixtures/accepted"

for fixture in latest floating tag-only bad-digest digest-only indirection unannotated-shell coupled-drift; do
  if "$validator" check --quiet --root "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "fixture unexpectedly passed: $fixture" >&2
    exit 1
  fi
done

echo "image policy fixtures passed"
