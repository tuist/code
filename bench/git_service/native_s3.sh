#!/usr/bin/env bash
# Optional isolated real-S3 holdout; not a replacement for the clustered e2e suite.
set -euo pipefail
cd "$(dirname "$0")/../.."
MINIO_BIN=${MINIO_BIN:-$(command -v minio || true)}
[[ -n "$MINIO_BIN" && -x "$MINIO_BIN" ]] || { echo 'Set MINIO_BIN to a native MinIO executable.' >&2; exit 1; }
root=$(mktemp -d "${TMPDIR:-/tmp}/code-native-s3.XXXXXX")
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
export AUTO_S3_ENDPOINT="http://127.0.0.1:$port" AUTO_S3_ROOT="$root"
MINIO_ROOT_USER=code MINIO_ROOT_PASSWORD=code-secret "$MINIO_BIN" server "$root/store" --address "127.0.0.1:$port" --console-address "127.0.0.1:0" >"$root/minio.log" 2>&1 &
pid=$!
ready=0
for _ in {1..100}; do
  kill -0 "$pid" 2>/dev/null || { tail -40 "$root/minio.log"; exit 1; }
  if curl -fsS "$AUTO_S3_ENDPOINT/minio/health/ready" >/dev/null 2>&1; then ready=1; break; fi
  sleep .1
done
[[ "$ready" == 1 ]] || { tail -40 "$root/minio.log"; exit 1; }
# An answering endpoint is not enough: only this child may own the listener.
lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null
CODE_GIT_PORT=0 CODE_HOOK_PORT=0 CODE_ADMIN_PORT=0 CODE_NODE_ID="native-s3-$pid" CODE_DATA_DIR="$root/startup" \
  MIX_ENV=test mise exec -- mix run bench/git_service/native_s3.exs
