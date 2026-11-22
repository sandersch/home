#!/usr/bin/env bash
# Exercise restic-release.py against a disposable worktree of HEAD.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release="$script_dir/restic-release.py"
policy="$script_dir/image_policy.py"
tmp="$(mktemp -d)"
wt="$tmp/wt"
cleanup() { git -C "$script_dir" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
git -C "$script_dir" worktree add --quiet --detach "$wt" HEAD

containerfile="$wt/containers/restic-backup/Containerfile"
digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
IFS=- read -r base_upstream base_revision < "$wt/containers/restic-backup/VERSION"

expect() {
  [[ "$1" == "$2" ]] || { echo "expected $2, got $1" >&2; exit 1; }
}

# A digest-only base rebuild increments the revision.
sed -i -E "1s/@sha256:[0-9a-f]{64}/@$digest_a/" "$containerfile"
expect "$("$release" --root "$wt" version --base HEAD)" "$base_upstream-$((base_revision + 1))"
git -C "$wt" checkout --quiet -- containers

# Unchanged inputs leave VERSION alone.
expect "$("$release" --root "$wt" version --base HEAD)" "$base_upstream-$base_revision"

# A new upstream release starts at revision 1, and rerunning is idempotent.
# Renovate moves every coupled restic/restic reference together.
grep -rlE 'restic/restic:[0-9.]+@sha256:' "$wt/containers" "$wt/infrastructure" \
  | xargs sed -i -E "s/restic\/restic:[0-9.]+@sha256:[0-9a-f]{64}/restic\/restic:99.0.0@$digest_a/"
expect "$("$release" --root "$wt" version --base HEAD)" 99.0.0-1
expect "$("$release" --root "$wt" version --base HEAD)" 99.0.0-1
expect "$("$release" --root "$wt" next-revision)" 99.0.0-2

if "$release" --root "$wt" pin "ghcr.io/sandersch/restic-backup:99.0.0-1@$digest_b" >/dev/null 2>&1; then
  echo "pin accepted a tag that differs from VERSION" >&2
  exit 1
fi
"$release" --root "$wt" pin "ghcr.io/sandersch/restic-backup:99.0.0-2@$digest_b" >/dev/null
"$policy" check --quiet --root "$wt" >/dev/null
stale="$(grep -rhoE 'ghcr\.io/sandersch/restic-backup:[^@[:space:]]+@sha256:[0-9a-f]{64}' "$wt/infrastructure" "$wt/runbooks" | sort -u)"
expect "$stale" "ghcr.io/sandersch/restic-backup:99.0.0-2@$digest_b"

echo "restic release helper passed"
