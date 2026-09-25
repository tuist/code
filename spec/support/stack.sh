#!/usr/bin/env bash
# Bring up the stack the end-to-end suite runs against: an S3-compatible
# object store (RustFS in place of the withdrawn MinIO OSS images), and two
# Code nodes clustered with each other.
#
# Two nodes rather than one, because most of what is interesting here happens
# between replicas. A single node cannot demonstrate that a push to A is
# immediately visible on B, which is the central claim of the design.
# Sourced by spec_helper for its constants, and run directly by `mise run e2e`
# to bring the stack up and down. No `set -e` at the top level: sourcing this
# must not change the shell options of whatever sourced it.

CODE_ROOT="${CODE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STACK_DIR="${CODE_ROOT}/tmp/e2e"

# A high port on purpose. The S3 API default of 9000, and the range around
# it, is the most contended real estate on a developer machine — ClickHouse in
# particular listens across it. Set E2E_S3_ENDPOINT to use an existing store.
export E2E_S3_PORT="${E2E_S3_PORT:-19010}"
export E2E_S3_ENDPOINT="${E2E_S3_ENDPOINT:-http://127.0.0.1:${E2E_S3_PORT}}"
export E2E_S3_BUCKET="${E2E_S3_BUCKET:-code-e2e}"
export E2E_S3_KEY="${E2E_S3_KEY:-code}"
export E2E_S3_SECRET="${E2E_S3_SECRET:-code-secret}"

# A git configuration of our own, so the suite cannot be influenced by — or
# blocked on — whatever the developer has configured. On macOS in particular,
# the keychain credential helper blocks storing a credential for a host it has
# not seen before, and the symptom is a git command that hangs forever with no
# output at all.
export E2E_GITCONFIG="${STACK_DIR:-${CODE_ROOT}/tmp/e2e}/gitconfig"
export GIT_CONFIG_GLOBAL="$E2E_GITCONFIG"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0

export E2E_TOKEN="e2e-token"
export E2E_ADMIN_TOKEN="e2e-admin-token"
# A second identity with no grant on the acme namespace at all, used to prove
# that authorization policy — not the token — is what lets it in.
export E2E_OUTSIDER_TOKEN="e2e-outsider-token"

export NODE1_GIT=4100 NODE1_HOOK=4101 NODE1_ADMIN=4102
export NODE2_GIT=4200 NODE2_HOOK=4201 NODE2_ADMIN=4202
export E2E_OIDC_PORT=4300 E2E_TLS_PORT=4443
export E2E_HTTPS_URL="https://127.0.0.1:${E2E_TLS_PORT}"
export E2E_TLS_CERT="${STACK_DIR}/tls/cert.pem"
export E2E_GIT_HELPER_DIR="${STACK_DIR}/bin"

export NODE1_URL="http://127.0.0.1:${NODE1_GIT}"
export NODE2_URL="http://127.0.0.1:${NODE2_GIT}"
export NODE1_ADMIN_URL="http://127.0.0.1:${NODE1_ADMIN}"
export NODE2_ADMIN_URL="http://127.0.0.1:${NODE2_ADMIN}"

stack::storage_up() {
  if docker ps --filter name=code-e2e-storage --format '{{.Names}}' 2>/dev/null | grep -q code-e2e-storage; then
    echo "storage: already running at ${E2E_S3_ENDPOINT}"
    return 0
  fi

  # A responsive endpoint alone is not proof it is *ours*: another stack may
  # have taken the port, and quietly using its storage is worse than failing.
  # RustFS answers 403 to an unauthenticated GET on `/`, which is still proof
  # of an S3-compatible service.
  if curl -sS -o /dev/null "${E2E_S3_ENDPOINT}/" 2>/dev/null; then
    if [ -n "${E2E_S3_EXTERNAL:-}" ]; then
      echo "storage: using the store already at ${E2E_S3_ENDPOINT}"
      return 0
    fi

    echo "something is already serving ${E2E_S3_ENDPOINT}, but it is not our RustFS." >&2
    echo "Set E2E_S3_PORT to a free port, or E2E_S3_EXTERNAL=1 to use it deliberately." >&2
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required to run the end-to-end suite (it provides the object store)." >&2
    echo "Set E2E_S3_ENDPOINT to point at an existing S3-compatible store instead." >&2
    return 1
  fi

  # Fail early and legibly rather than spending sixty seconds discovering that
  # something else already answers on this port.
  if lsof -nP -iTCP:"${E2E_S3_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port ${E2E_S3_PORT} is already in use by something that is not our RustFS." >&2
    echo "Set E2E_S3_PORT to a free port, or E2E_S3_ENDPOINT to an existing store." >&2
    return 1
  fi

  echo "storage: starting on :${E2E_S3_PORT}"
  # RustFS speaks the S3 API on 9000. It replaced MinIO here after MinIO's
  # OSS `minio/minio` and `minio/mc` images stopped being served by public
  # registries. Pinned rather than a floating tag because the suite asserts
  # on conditional-write behaviour that shifts between releases.
  docker run -d --rm --name code-e2e-storage \
    -p "${E2E_S3_PORT}:9000" \
    -e RUSTFS_ACCESS_KEY="${E2E_S3_KEY}" \
    -e RUSTFS_SECRET_KEY="${E2E_S3_SECRET}" \
    rustfs/rustfs:v1.0.0-rc.5 >/dev/null

  # Any HTTP response is proof the S3 service is answering; connection errors
  # fail with a non-zero exit and the loop keeps waiting.
  stack::wait_for_http "${E2E_S3_ENDPOINT}/" 60 "storage"
}

stack::bucket() {
  # Reached over the host port rather than by joining a container, so this also
  # works when E2E_S3_ENDPOINT points at a store we did not start.
  #
  # Verified rather than best-effort. A silently missing bucket does not fail
  # here; it fails much later as a repository that cannot be created, which is
  # a considerably worse place to find out.
  stack::aws s3api create-bucket --bucket "${E2E_S3_BUCKET}" 2>/dev/null || true

  stack::aws s3api head-bucket --bucket "${E2E_S3_BUCKET}" || {
    echo "bucket ${E2E_S3_BUCKET} is not readable after creation" >&2
    return 1
  }

  echo "storage: bucket ${E2E_S3_BUCKET} ready"
}

stack::aws() {
  # The vanilla AWS CLI works against RustFS and against real S3 and is
  # anonymously pullable, unlike MinIO's `mc`.
  docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -e AWS_ACCESS_KEY_ID="${E2E_S3_KEY}" \
    -e AWS_SECRET_ACCESS_KEY="${E2E_S3_SECRET}" \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli:2.37.3 \
    --endpoint-url "http://host.docker.internal:${E2E_S3_PORT}" \
    "$@" >/dev/null 2>&1
}

stack::mise_prefix() {
  if command -v elixir >/dev/null 2>&1; then
    echo ""
  elif command -v mise >/dev/null 2>&1; then
    echo "mise exec --"
  else
    echo "neither elixir nor mise is on PATH; run 'mise install' first" >&2
    return 1
  fi
}

stack::node_up() {
  local name=$1 git_port=$2 hook_port=$3 admin_port=$4
  local log="${STACK_DIR}/${name}.log"

  mkdir -p "${STACK_DIR}/${name}"

  if curl -fsS "http://127.0.0.1:${admin_port}/health" >/dev/null 2>&1; then
    echo "${name}: already running"
    return 0
  fi

  echo "${name}: starting on :${git_port}"

  (
    cd "${CODE_ROOT}"
    CODE_S3_BUCKET="${E2E_S3_BUCKET}" \
    CODE_S3_ENDPOINT="${E2E_S3_ENDPOINT}" \
    CODE_S3_ACCESS_KEY_ID="${E2E_S3_KEY}" \
    CODE_S3_SECRET_ACCESS_KEY="${E2E_S3_SECRET}" \
    CODE_S3_REGION="us-east-1" \
    CODE_S3_PATH_STYLE="true" \
    CODE_S3_PREFIX="${CODE_S3_PREFIX:-}" \
    CODE_NODE_ID="${name}" \
    CODE_DATA_DIR="${STACK_DIR}/${name}/repositories" \
    CODE_GIT_PORT="${git_port}" \
    CODE_HOOK_PORT="${hook_port}" \
    CODE_ADMIN_PORT="${admin_port}" \
    CODE_ADMIN_TOKEN="${E2E_ADMIN_TOKEN}" \
    CODE_AUTH_BACKEND="static" \
    CODE_AUTH_TOKENS="${E2E_TOKEN}=acme:read,write,execute;${E2E_OUTSIDER_TOKEN}=outsider:read" \
    CODE_POLICY_STALENESS_BUDGET_MS="500" \
    CODE_DEFAULT_REPLICAS="2" \
    CODE_CLUSTER_STRATEGY="epmd" \
    CODE_PEERS="code-e2e-1@127.0.0.1,code-e2e-2@127.0.0.1" \
    CODE_PUBLIC_URL="http://127.0.0.1:${git_port}" \
    RELEASE_COOKIE="code-e2e-cookie" \
      ${MISE_PREFIX} elixir --name "${name}@127.0.0.1" --cookie code-e2e-cookie \
        -S mix run --no-halt >"${log}" 2>&1 &
    echo $! > "${STACK_DIR}/${name}.pid"
  )

  if ! stack::wait_for "http://127.0.0.1:${admin_port}/health" 90 "${name}"; then
    echo "--- ${name} log ---" >&2
    tail -40 "${log}" >&2
    return 1
  fi
}

stack::oidc_up() {
  mkdir -p "${STACK_DIR}/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=127.0.0.1' \
    -addext 'subjectAltName=IP:127.0.0.1' \
    -keyout "${STACK_DIR}/tls/key.pem" -out "${STACK_DIR}/tls/cert.pem" >/dev/null 2>&1

  MIX_ENV=test mix run -e "Code.E2EOIDCIssuer.run(${E2E_OIDC_PORT}, \"${STACK_DIR}/oidc-token\")" \
    >"${STACK_DIR}/oidc.log" 2>&1 &
  echo $! > "${STACK_DIR}/oidc.pid"

  # The issuer runs in the test environment so it can share the real JSON Web
  # Token implementation. A cold continuous-integration runner may need to
  # compile the test support path before Bandit can listen.
  stack::wait_for "http://127.0.0.1:${E2E_OIDC_PORT}/issuer/keys" 90 "OIDC issuer"
  export E2E_OIDC_TOKEN="$(cat "${STACK_DIR}/oidc-token")"
  export CURL_CA_BUNDLE="$E2E_TLS_CERT"

  printf '%s\n' \
    'version=1' \
    "issuer=${E2E_HTTPS_URL}/issuer" \
    "authorization_endpoint=${E2E_HTTPS_URL}/issuer/authorize" \
    "token_endpoint=${E2E_HTTPS_URL}/issuer/token" \
    "registration_endpoint=${E2E_HTTPS_URL}/issuer/register" \
    'redirect_uri=http://127.0.0.1' \
    'scopes=openid profile' \
    'username=oauth2' > "${STACK_DIR}/git-auth-metadata"

  cat > "${STACK_DIR}/Caddyfile" <<EOF
:${E2E_TLS_PORT} {
  tls /work/tls/cert.pem /work/tls/key.pem
  handle /.well-known/code-git-auth {
    root * /work
    rewrite * /git-auth-metadata
    header Content-Type text/plain
    file_server
  }
  @issuer path /issuer/*
  reverse_proxy @issuer host.docker.internal:${E2E_OIDC_PORT}
  reverse_proxy host.docker.internal:${NODE1_GIT}
}
EOF
  docker run -d --rm --name code-e2e-tls --add-host=host.docker.internal:host-gateway \
    -p "${E2E_TLS_PORT}:4443" -v "${STACK_DIR}:/work:ro" \
    caddy:2.10.2-alpine caddy run --config /work/Caddyfile --adapter caddyfile >/dev/null
  stack::wait_for "${E2E_HTTPS_URL}/issuer/keys" 30 "TLS proxy"
}

stack::wait_for() {
  local url=$1 attempts=${2:-60} what=${3:-service}
  local i=0

  while [ "$i" -lt "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  echo "${what}: did not become ready at ${url} after ${attempts}s" >&2
  return 1
}

# Like stack::wait_for but treats any HTTP response as "up". Used for S3
# services that reply 4xx to an unauthenticated probe: the response proves
# the service is answering; only connection errors count as not ready.
stack::wait_for_http() {
  local url=$1 attempts=${2:-60} what=${3:-service}
  local i=0

  while [ "$i" -lt "$attempts" ]; do
    if curl -sS -o /dev/null "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  echo "${what}: did not become ready at ${url} after ${attempts}s" >&2
  return 1
}

stack::gitconfig() {
  mkdir -p "$(dirname "$E2E_GITCONFIG")"

  cat > "$E2E_GITCONFIG" <<'GITCONFIG'
[credential]
	helper =
[user]
	name = Code E2E
	email = e2e@example.com
[init]
	defaultBranch = main
[protocol]
	version = 2
GITCONFIG
}

stack::credential_manager() {
  mkdir -p "$E2E_GIT_HELPER_DIR"

  cat > "${E2E_GIT_HELPER_DIR}/git-credential-manager" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) exit 0 ;;
  get)
    cat >/dev/null
    printf 'username=oauth2\npassword=%s\n\n' "$E2E_TOKEN"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${E2E_GIT_HELPER_DIR}/git-credential-manager"
}

stack::up() {
  mkdir -p "${STACK_DIR}"
  stack::gitconfig
  stack::credential_manager
  stack::storage_up
  stack::bucket

  MISE_PREFIX="$(stack::mise_prefix)"
  export MISE_PREFIX

  # Compile once up front so the two nodes do not race on _build.
  (cd "${CODE_ROOT}" && ${MISE_PREFIX} mix compile >/dev/null 2>&1) || true

  stack::oidc_up
  stack::node_up code-e2e-1 "$NODE1_GIT" "$NODE1_HOOK" "$NODE1_ADMIN"
  stack::node_up code-e2e-2 "$NODE2_GIT" "$NODE2_HOOK" "$NODE2_ADMIN"
}

stack::down() {
  if [ -f "${STACK_DIR}/oidc.pid" ]; then
    kill "$(cat "${STACK_DIR}/oidc.pid")" 2>/dev/null || true
    rm -f "${STACK_DIR}/oidc.pid"
  fi
  docker rm -f code-e2e-tls >/dev/null 2>&1 || true
  for name in code-e2e-1 code-e2e-2; do
    if [ -f "${STACK_DIR}/${name}.pid" ]; then
      kill "$(cat "${STACK_DIR}/${name}.pid")" 2>/dev/null || true
      rm -f "${STACK_DIR}/${name}.pid"
    fi
  done

  # Erlang nodes spawn a child beam.smp that outlives the launcher.
  pkill -f "code-e2e-[12]@127.0.0.1" 2>/dev/null || true

  if [ "${E2E_KEEP_STORAGE:-${E2E_KEEP_MINIO:-0}}" != "1" ]; then
    docker rm -f code-e2e-storage >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Entry point when run directly.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail

  case "${1:-up}" in
    up) stack::up ;;
    down) stack::down ;;
    restart) stack::down; stack::up ;;
    logs) tail -f "${STACK_DIR}"/*.log ;;
    *) echo "usage: $0 {up|down|restart|logs}" >&2; exit 1 ;;
  esac
fi
