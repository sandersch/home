#!/usr/bin/env bash
# Exercise restic-release.py against a disposable worktree of HEAD, replaying a
# Renovate branch: base update, release commit, re-runs, and later updates.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release="$script_dir/restic-release.py"
policy="$script_dir/image_policy.py"
tmp="$(mktemp -d)"
wt="$tmp/wt"
cleanup() { git -C "$script_dir" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
git -C "$script_dir" worktree add --quiet --detach "$wt" HEAD

version_file="$wt/containers/restic-backup/VERSION"
digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
digest_c="sha256:$(printf 'c%.0s' {1..64})"

expect() {
  [[ "$1" == "$2" ]] || { echo "expected $2, got $1" >&2; exit 1; }
}
version() { "$release" --root "$wt" version --base "$base"; }
commit() { git -C "$wt" -c user.name=test -c user.email=test@invalid commit --quiet -am "$1"; }
# Renovate moves every coupled restic/restic reference together.
set_base() {
  grep -rlE 'restic/restic:[0-9.]+@sha256:' "$wt/containers" "$wt/infrastructure" \
    | xargs sed -i -E "s/restic\/restic:[0-9.]+@sha256:[0-9a-f]{64}/restic\/restic:$1@$2/"
}

# Start from a consistent base (HEAD may be a Renovate commit whose VERSION lags).
set_base 98.0.0 "$digest_a"
echo 98.0.0-1 > "$version_file"
commit base
base="$(git -C "$wt" rev-parse HEAD)"

# Unchanged inputs leave VERSION alone; a digest-only rebuild takes the next revision.
expect "$(version)" 98.0.0-1
set_base 98.0.0 "$digest_b"
expect "$(version)" 98.0.0-2
git -C "$wt" checkout --quiet -- .

# Renovate's commit: a new upstream starts at revision 1, idempotently.
set_base 99.0.0 "$digest_a"
commit renovate
expect "$(version)" 99.0.0-1
expect "$(version)" 99.0.0-1
expect "$("$release" --root "$wt" next-revision)" 99.0.0-2
if "$release" --root "$wt" pin "ghcr.io/sandersch/restic-backup:99.0.0-1@$digest_b" >/dev/null 2>&1; then
  echo "pin accepted a tag that differs from VERSION" >&2
  exit 1
fi
"$release" --root "$wt" pin "ghcr.io/sandersch/restic-backup:99.0.0-2@$digest_b" >/dev/null
"$policy" check --quiet --root "$wt" >/dev/null
pins="$(grep -rhoE 'ghcr\.io/sandersch/restic-backup:[^@[:space:]]+@sha256:[0-9a-f]{64}' "$wt/infrastructure" "$wt/runbooks" | sort -u)"
expect "$pins" "ghcr.io/sandersch/restic-backup:99.0.0-2@$digest_b"
commit release

# Re-running on the released branch (an approved or re-run job) is a no-op.
expect "$(version)" 99.0.0-2
git -C "$wt" diff --quiet

# Later Renovate updates on top of the release are released again.
set_base 99.0.0 "$digest_c"
expect "$(version)" 99.0.0-3
git -C "$wt" checkout --quiet -- .
set_base 99.0.1 "$digest_c"
expect "$(version)" 99.0.1-1

echo "restic release helper passed"
