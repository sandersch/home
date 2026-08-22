#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$script_dir/01-install-k3s.sh"

# shellcheck source=runbooks/phase2/lib.sh
source "$script_dir/lib.sh"

[ "$K3S_VERSION" = "v1.36.2+k3s1" ] \
  || die "unexpected canonical k3s version: $K3S_VERSION"
[ "$(grep -Fc 'sudo env INSTALL_K3S_VERSION="$K3S_VERSION" sh -s -' "$installer")" -eq 1 ] \
  || die "installer does not pass the canonical version through INSTALL_K3S_VERSION"

mock_k3s_version="$K3S_VERSION"
k3s() {
  printf 'k3s version %s (mock-build)\n' "$mock_k3s_version"
}

assert_k3s_version >/dev/null
mock_k3s_version="v1.36.3+k3s1"
if (assert_k3s_version >/dev/null 2>&1); then
  die "version assertion accepted an unexpected k3s release"
fi

ok "k3s installer pin and active-version guard passed"
