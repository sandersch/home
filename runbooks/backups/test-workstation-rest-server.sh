#!/usr/bin/env bash
# Disposable append-only, cross-credential, quota and recount integration fixture.
set -Eeuo pipefail
restic="${WORKSTATION_RESTIC:-restic}"
for command in docker curl jq; do command -v "$command" >/dev/null; done
fixture="$(mktemp -d)"
container="workstation-rest-server-test-$$"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf -- "$fixture"
}
trap cleanup EXIT
mkdir "$fixture/repository" "$fixture/source"
# renovate: datasource=docker depName=restic/rest-server
image=restic/rest-server:0.14.0@sha256:e117e428e511e3ffdeb6d0e578adf4b468803c77ad500993bb8f15038b2d9db3
printf 'fixture-http-password\n' | docker run --rm -i --entrypoint /usr/bin/htpasswd \
  "$image" -niB ryze >"$fixture/htpasswd"
docker run -d --name "$container" --user "$(id -u):$(id -g)" \
  -p 127.0.0.1::8000 -v "$fixture/repository:/repository" \
  -v "$fixture/htpasswd:/authentication/htpasswd:ro" \
  --entrypoint /usr/bin/rest-server "$image" --path /repository \
  --listen :8000 --htpasswd-file /authentication/htpasswd --append-only \
  --max-size 1048576 >/dev/null
port="$(docker port "$container" 8000/tcp | cut -d: -f2)"
endpoint="http://127.0.0.1:$port"
export RESTIC_PASSWORD=disposable-fixture-encryption-password
export RESTIC_REST_USERNAME=ryze RESTIC_REST_PASSWORD=fixture-http-password
export RESTIC_REPOSITORY="rest:$endpoint/"
wait_ready() {
  for _ in {1..30}; do
    curl -s --max-time 2 -o /dev/null "$endpoint" && return 0
    sleep 1
  done
  docker logs "$container" >&2
  echo 'fixture server did not become reachable' >&2
  return 1
}
wait_ready
"$restic" init
printf 'healthy fixture\n' >"$fixture/source/file"
"$restic" backup --host ryze "$fixture/source"
snapshot="$("$restic" snapshots --json | jq -r '.[0].id')"
if "$restic" forget "$snapshot"; then
  echo 'append-only endpoint allowed snapshot deletion' >&2
  exit 1
fi
[ "$(curl -s -o /dev/null -w '%{http_code}' -u m5c:wrong "$endpoint/config")" = 401 ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -u ryze:fixture-http-password -X DELETE "$endpoint/config")" = 403 ]
# Incompressible data exhausts the one-MiB fixture quota.
dd if=/dev/urandom of="$fixture/source/large" bs=1048576 count=2 status=none
if "$restic" backup --host ryze "$fixture/source"; then
  echo 'quota unexpectedly accepted an oversized backup' >&2
  exit 1
fi
"$restic" -r "$fixture/repository" forget "$snapshot"
"$restic" -r "$fixture/repository" prune
docker restart "$container" >/dev/null
port="$(docker port "$container" 8000/tcp | cut -d: -f2)"
endpoint="http://127.0.0.1:$port"
export RESTIC_REPOSITORY="rest:$endpoint/"
rm -- "$fixture/source/large"
wait_ready
"$restic" backup --host ryze "$fixture/source"
"$restic" check
echo 'append-only, credential isolation, quota and restart recount fixtures passed'
