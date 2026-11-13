#!/usr/bin/env bash
# install_omnisdocrag.sh — idempotent, Docker-free runtime install of OmnisDocRAG on Debian 13 (trixie).
# Complements setup_project.sh (developer bootstrap with in-repo venvs); it does not call it: this script
# installs system packages, PostgreSQL + pgvector, the DB schema, builds the data and installs systemd services.
#
# The repository ships NO Omnis documentation and no embeddings (they are (c) Omnis Software Ltd). The data is
# built from YOUR licensed copies: extract -> chunk -> validate -> embed -> import (scripts/pipeline.py build).
# On a CPU the embedding step takes hours; run the script inside tmux/screen. Re-runs are incremental.
#
# Topology installed (the "local" topology of the project, MCP front-end over HTTP):
#   MCP client --HTTP--> omnisdocrag-mcp (FastMCP, :3000) --> omnisdocrag-rag (FastAPI, 127.0.0.1:7071) --> PostgreSQL + pgvector
#
# Usage (as root):   OMNIS_PDF_DIR=/path/with/the/3/pdfs [OMNISDOC_PACK=/path/to/pack] bash install_omnisdocrag.sh
#   Without OMNIS_PDF_DIR (and without PDFs already in "Omnis PDF/") everything is installed but the database
#   stays empty; run the script again with OMNIS_PDF_DIR to build the data.
# Re-run any time:   it converges to the same state, restarts services only when something changed.
#
# Optional environment overrides (all have defaults, see CONSTANTS):
#   REPO_URL=<git url of the repo to install (default: this fork)>  REPO_REF=main  MCP_BIND_HOST=127.0.0.1  MCP_PORT=3000  RAG_PORT=7071
#   TORCH_INDEX=https://download.pytorch.org/whl/cpu   (use ".../cu126" etc. for NVIDIA GPU)
#   OMNIS_PDF_DIR  folder with CommandRef.pdf, FunctionRef.pdf, Programming_Omnis.pdf (copied to "Omnis PDF/", git-ignored)
#   OMNISDOC_PACK  optional doc pack folder (readable by user omnisrag: not under /root or /home with mode 700)
#   EMBED_THREADS=<n>  CPU threads for embedding
#   SKIP_MODEL_DOWNLOAD=1   FORCE_BUILD=1   ALLOW_NON_DEBIAN13=1

set -Eeuo pipefail

# ── CONSTANTS ────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/efrembaraldohelinext/OmnisDocRAG.git}"
REPO_REF="${REPO_REF:-main}"

APP_USER="omnisrag"
BASE_DIR="/opt/omnisdocrag"
SRC_DIR="${BASE_DIR}/src"
VENV_RAG="${BASE_DIR}/venv-rag"
VENV_MCP="${BASE_DIR}/venv-mcp"
VENV_PIPE="${BASE_DIR}/venv-pipeline"
STATE_DIR="/var/lib/omnisdocrag"
HF_HOME_DIR="${STATE_DIR}/hf"
STAMP_DIR="${STATE_DIR}/stamps"
CONF_DIR="/etc/omnisdocrag"
SECRETS_FILE="${CONF_DIR}/secrets.env"   # root:root 600 — DB passwords
RAG_ENV_FILE="${CONF_DIR}/rag.env"       # root:omnisrag 640 — rag-server config
MCP_ENV_FILE="${CONF_DIR}/mcp.env"       # root:omnisrag 640 — mcp-server config
UNIT_DIR="/etc/systemd/system"

DB_NAME="ragdb"
DB_HOST="127.0.0.1"
DB_PORT="5432"
EMBED_MODEL="BAAI/bge-m3"                # the schema is vector(1024): do not change

RAG_PORT="${RAG_PORT:-7071}"
MCP_PORT="${MCP_PORT:-3000}"
MCP_BIND_HOST="${MCP_BIND_HOST:-0.0.0.0}"   # the MCP endpoint has no authentication; use 127.0.0.1 if not on a trusted LAN
RAG_W_DENSE="${RAG_W_DENSE:-1.0}"
RAG_W_FTS="${RAG_W_FTS:-0.3}"
RAG_RRF_K="${RAG_RRF_K:-60}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cpu}"
OMNIS_PDF_DIR="${OMNIS_PDF_DIR:-}"
OMNISDOC_PACK="${OMNISDOC_PACK:-}"
EMBED_THREADS="${EMBED_THREADS:-}"
PDF_NAMES=(CommandRef.pdf FunctionRef.pdf Programming_Omnis.pdf)   # fixed in scripts/extract.py
HEALTH_TIMEOUT_S=600                     # first model load on a slow CPU can take minutes

APT_PACKAGES=(git ca-certificates curl openssl iproute2 python3 python3-venv python3-pip postgresql)

CHANGED_RAG=0
CHANGED_MCP=0
PGMAJOR=""
RAG_REQ_FILE=""
MCP_REQ_FILE=""
PIPE_REQ_FILE=""
HAVE_PDFS=0   # set by stage_pdfs

# ── FUNCTIONS ────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[omnisdocrag]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[omnisdocrag] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[omnisdocrag] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

as_postgres() { (cd / && runuser -u postgres -- "$@"); }
as_app()      { (cd / && runuser -u "${APP_USER}" -- "$@"); }

# Write $2 (content) to file $1 with mode $3 and owner:group $4. Returns 0 if the file changed, 1 if not.
write_if_changed() {
  local path="$1" content="$2" mode="$3" owner="$4" tmp
  tmp="$(mktemp)"
  printf '%s\n' "${content}" > "${tmp}"
  if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
    rm -f "${tmp}"
    chmod "${mode}" "${path}"; chown "${owner}" "${path}"
    return 1
  fi
  install -m "${mode}" -o "${owner%%:*}" -g "${owner##*:}" "${tmp}" "${path}"
  rm -f "${tmp}"
  return 0
}

check_prerequisites() {
  [[ ${EUID} -eq 0 ]] || die "run as root (sudo bash $0)"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
    [[ "${ALLOW_NON_DEBIAN13:-0}" == "1" ]] || die "Debian 13 expected, found ${PRETTY_NAME:-unknown}. Set ALLOW_NON_DEBIAN13=1 to continue anyway."
    warn "not Debian 13 (${PRETTY_NAME:-unknown}): continuing on request"
  fi
  command -v systemctl >/dev/null || die "systemd is required"
  [[ "${MCP_PORT}" =~ ^[0-9]+$ && "${RAG_PORT}" =~ ^[0-9]+$ ]] || die "MCP_PORT/RAG_PORT must be numeric"
}

install_apt_packages() {
  local missing=() p
  for p in "${APT_PACKAGES[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    log "apt: installing ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
  PGMAJOR="$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -n1)"
  [[ -n "${PGMAJOR}" ]] || die "PostgreSQL binaries not found in /usr/lib/postgresql"
  if ! dpkg -s "postgresql-${PGMAJOR}-pgvector" >/dev/null 2>&1; then
    log "apt: installing postgresql-${PGMAJOR}-pgvector"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends "postgresql-${PGMAJOR}-pgvector"
  fi
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || die "Python 3.10+ required"
}

ensure_user_and_dirs() {
  if ! id "${APP_USER}" >/dev/null 2>&1; then
    log "creating system user ${APP_USER}"
    useradd --system --home-dir "${STATE_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
  fi
  install -d -m 755 "${BASE_DIR}"
  install -d -m 750 -o "${APP_USER}" -g "${APP_USER}" "${STATE_DIR}" "${HF_HOME_DIR}"
  install -d -m 755 "${STAMP_DIR}"
  install -d -m 755 "${CONF_DIR}"
}

sync_repo() {
  local before=""
  [[ -d "${SRC_DIR}/.git" ]] && before="$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ ! -d "${SRC_DIR}/.git" ]]; then
    log "git: cloning ${REPO_URL}"
    git clone "${REPO_URL}" "${SRC_DIR}"
  fi
  log "git: updating to ${REPO_REF}"
  git -C "${SRC_DIR}" fetch --tags origin
  # Hard reset: the install tree is not a working copy, local edits would be lost anyway.
  if git -C "${SRC_DIR}" rev-parse -q --verify "origin/${REPO_REF}" >/dev/null; then
    git -C "${SRC_DIR}" checkout -q -f -B "${REPO_REF}" "origin/${REPO_REF}"
  else
    git -C "${SRC_DIR}" checkout -q -f "${REPO_REF}"
  fi
  if [[ "${before}" != "$(git -C "${SRC_DIR}" rev-parse HEAD)" ]]; then CHANGED_RAG=1; CHANGED_MCP=1; fi
  log "git: HEAD $(git -C "${SRC_DIR}" rev-parse --short HEAD) ($(git -C "${SRC_DIR}" log -1 --format=%cI))"
  RAG_REQ_FILE="${SRC_DIR}/docker_mcp-rag/rag-server/requirements.txt"
  MCP_REQ_FILE="${SRC_DIR}/docker_mcp-rag/mcp-server/requirements.txt"
  PIPE_REQ_FILE="${SRC_DIR}/scripts/requirements.txt"
}

# Create the venv if missing; reinstall only when the requirements (or the extra key) changed.
ensure_venv() {
  local venv="$1" req="$2" extra_key="$3" name="$4" torch="${5:-0}" stamp want
  stamp="${STAMP_DIR}/${name}.sha256"
  want="$(cat "${req}" <(printf '%s' "${extra_key}") | sha256sum | cut -d' ' -f1)"
  [[ -x "${venv}/bin/python" ]] || { log "venv: creating ${venv}"; python3 -m venv "${venv}"; }
  if [[ -f "${stamp}" && "$(cat "${stamp}")" == "${want}" ]]; then
    log "venv ${name}: up to date"
    return 1
  fi
  log "venv ${name}: installing dependencies"
  "${venv}/bin/pip" install --quiet --upgrade pip
  # torch first, from the chosen index: otherwise pip pulls the multi-GB CUDA build.
  if [[ "${torch}" == "1" ]]; then
    "${venv}/bin/pip" install --quiet torch --index-url "${TORCH_INDEX}"
  fi
  "${venv}/bin/pip" install --quiet -r "${req}"
  printf '%s' "${want}" > "${stamp}"
  return 0
}

ensure_secrets() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    log "generating DB passwords in ${SECRETS_FILE}"
    (
      umask 077
      {
        echo "RAG_DB_OWNER_PASS=$(openssl rand -hex 24)"
        echo "RAG_DB_PASS=$(openssl rand -hex 24)"
        echo "RAG_DB_RO_PASS=$(openssl rand -hex 24)"
      } > "${SECRETS_FILE}"
    )
  fi
  chmod 600 "${SECRETS_FILE}"; chown root:root "${SECRETS_FILE}"
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  : "${RAG_DB_OWNER_PASS:?}" "${RAG_DB_PASS:?}" "${RAG_DB_RO_PASS:?}"
}

setup_database() {
  log "postgresql: starting service"
  systemctl enable --now postgresql >/dev/null
  local i
  for i in $(seq 1 30); do pg_isready -q -h /var/run/postgresql && break; sleep 1; done
  pg_isready -q -h /var/run/postgresql || die "PostgreSQL is not ready"

  local sqldir="${SRC_DIR}/docker_mcp-rag-pg/postgres-init/sql" tmp
  tmp="$(mktemp -d)"
  chmod 755 "${tmp}"
  # Passwords go through a 600 file owned by postgres, not through argv (visible in ps).
  install -m 600 -o postgres -g postgres /dev/null "${tmp}/vars.sql"
  cat > "${tmp}/vars.sql" <<EOF
\set rag_owner_pass '${RAG_DB_OWNER_PASS}'
\set rag_app_pass '${RAG_DB_PASS}'
\set rag_ro_pass '${RAG_DB_RO_PASS}'
\i ${sqldir}/20-rag-bootstrap.sql
EOF
  log "postgresql: roles (create or update passwords)"
  as_postgres psql -X -q -v ON_ERROR_STOP=1 -d postgres -f "${tmp}/vars.sql" >/dev/null
  rm -rf "${tmp}"

  if [[ "$(as_postgres psql -X -Atq -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" != "1" ]]; then
    log "postgresql: creating database ${DB_NAME}"
    as_postgres createdb -O rag_owner "${DB_NAME}"
  fi
  as_postgres psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "ALTER DATABASE ${DB_NAME} OWNER TO rag_owner" >/dev/null

  log "postgresql: schema and ranking functions (idempotent SQL from the repo)"
  as_postgres psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" -f "${sqldir}/30-rag-schema.sql" >/dev/null
  as_postgres psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" -f "${sqldir}/40-rag-ranking.sql" >/dev/null

  PGPASSWORD="${RAG_DB_PASS}" psql -X -Atq -h "${DB_HOST}" -p "${DB_PORT}" -U rag_app -d "${DB_NAME}" -c 'SELECT 1' >/dev/null \
    || die "rag_app cannot log in over TCP ${DB_HOST}:${DB_PORT} (check pg_hba.conf / listen_addresses)"
}

write_configs() {
  local rag_cfg mcp_cfg
  rag_cfg="RAG_DB_HOST=${DB_HOST}
RAG_DB_PORT=${DB_PORT}
RAG_DB_NAME=${DB_NAME}
RAG_DB_USER=rag_app
RAG_DB_PASS=${RAG_DB_PASS}
EMBED_MODEL=${EMBED_MODEL}
PORT=${RAG_PORT}
STRICT_PORT=false
RAG_W_DENSE=${RAG_W_DENSE}
RAG_W_FTS=${RAG_W_FTS}
RAG_RRF_K=${RAG_RRF_K}
HF_HOME=${HF_HOME_DIR}
PYTHONUNBUFFERED=1"
  mcp_cfg="RAG_SERVER_URL=http://127.0.0.1:${RAG_PORT}
MCP_HOST=${MCP_BIND_HOST}
MCP_PORT=${MCP_PORT}
PYTHONUNBUFFERED=1"
  write_if_changed "${RAG_ENV_FILE}" "${rag_cfg}" 640 "root:${APP_USER}" && CHANGED_RAG=1 || true
  write_if_changed "${MCP_ENV_FILE}" "${mcp_cfg}" 640 "root:${APP_USER}" && CHANGED_MCP=1 || true
}

# Copy the user's PDFs into "Omnis PDF/" (git-ignored) and set HAVE_PDFS=1 when all three are present.
stage_pdfs() {
  local dst="${SRC_DIR}/Omnis PDF" f
  if [[ -n "${OMNIS_PDF_DIR}" ]]; then
    [[ -d "${OMNIS_PDF_DIR}" ]] || die "OMNIS_PDF_DIR is not a directory: ${OMNIS_PDF_DIR}"
    for f in "${PDF_NAMES[@]}"; do
      [[ -f "${OMNIS_PDF_DIR}/${f}" ]] || die "missing ${OMNIS_PDF_DIR}/${f}"
      if ! cmp -s "${OMNIS_PDF_DIR}/${f}" "${dst}/${f}" 2>/dev/null; then
        log "pdf: copying ${f}"
        install -m 644 "${OMNIS_PDF_DIR}/${f}" "${dst}/${f}"
      fi
    done
  fi
  HAVE_PDFS=1
  for f in "${PDF_NAMES[@]}"; do
    [[ -f "${dst}/${f}" ]] || HAVE_PDFS=0
  done
  if [[ "${HAVE_PDFS}" != "1" ]]; then
    warn "Omnis PDFs not found: the database stays empty. Re-run with OMNIS_PDF_DIR=/path/with/${PDF_NAMES[*]}"
  fi
}

# Fingerprint of everything the data depends on: repo commit, PDFs, doc pack (names, sizes, mtimes), model.
data_fingerprint() {
  {
    git -C "${SRC_DIR}" rev-parse HEAD
    (cd "${SRC_DIR}/Omnis PDF" && sha256sum "${PDF_NAMES[@]}")
    if [[ -n "${OMNISDOC_PACK}" ]]; then
      find "${OMNISDOC_PACK}" -type f -printf '%P %s %T@\n' | LC_ALL=C sort
    fi
    printf '%s\n' "${EMBED_MODEL}"
  } | sha256sum | cut -d' ' -f1
}

# extract -> chunk -> validate -> embed (incremental) -> import (upsert, full-sync of stale docs).
build_data() {
  [[ "${HAVE_PDFS}" == "1" ]] || return 0
  if [[ -n "${OMNISDOC_PACK}" && ! -d "${OMNISDOC_PACK}" ]]; then
    die "OMNISDOC_PACK is not a directory: ${OMNISDOC_PACK}"
  fi
  local marker="${STAMP_DIR}/data_build.sha256" want args
  want="$(data_fingerprint)"
  if [[ "${FORCE_BUILD:-0}" != "1" && -f "${marker}" && "$(cat "${marker}")" == "${want}" ]]; then
    log "data: already built for these inputs (FORCE_BUILD=1 to repeat)"
    return 0
  fi
  install -d -o "${APP_USER}" -g "${APP_USER}" "${SRC_DIR}/output"
  chown -R "${APP_USER}:${APP_USER}" "${SRC_DIR}/output"
  args=(build --from extract --to import --target local)
  if [[ -n "${OMNISDOC_PACK}" ]]; then args+=(--omnisdoc "${OMNISDOC_PACK}"); fi
  if [[ -n "${EMBED_THREADS}" ]]; then args+=(--threads "${EMBED_THREADS}"); fi
  log "data: building (embedding on CPU takes hours; interrupted runs resume incrementally)"
  # Environment variables reach import_to_postgres.py through pipeline.py (no .env file is needed or written).
  as_app env \
    RAG_DB_HOST="${DB_HOST}" RAG_DB_PORT="${DB_PORT}" RAG_DB_NAME="${DB_NAME}" \
    RAG_DB_USER=rag_app RAG_DB_PASS="${RAG_DB_PASS}" EMBED_MODEL="${EMBED_MODEL}" \
    HF_HOME="${HF_HOME_DIR}" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    "${VENV_PIPE}/bin/python" "${SRC_DIR}/scripts/pipeline.py" "${args[@]}"
  printf '%s' "${want}" > "${marker}"
}

prefetch_model() {
  local stamp="${STAMP_DIR}/model_$(printf '%s' "${EMBED_MODEL}" | tr '/' '_')"
  [[ "${SKIP_MODEL_DOWNLOAD:-0}" == "1" ]] && { warn "model prefetch skipped: the first service start will download it"; return 0; }
  [[ -f "${stamp}" ]] && { log "model ${EMBED_MODEL}: already cached"; return 0; }
  log "model ${EMBED_MODEL}: downloading (~2.2 GB, one time)"
  as_app env HF_HOME="${HF_HOME_DIR}" PYTHONDONTWRITEBYTECODE=1 EMBED_MODEL="${EMBED_MODEL}" \
    "${VENV_RAG}/bin/python" -c 'import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ["EMBED_MODEL"])'
  touch "${stamp}"
}

write_units() {
  local rag_unit mcp_unit
  rag_unit="[Unit]
Description=OmnisDocRAG rag-server (FastAPI retrieval)
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${SRC_DIR}/docker_mcp-rag/rag-server
EnvironmentFile=${RAG_ENV_FILE}
ExecStart=${VENV_RAG}/bin/uvicorn ragserver:app --host 127.0.0.1 --port ${RAG_PORT}
Restart=on-failure
RestartSec=5
TimeoutStartSec=${HEALTH_TIMEOUT_S}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${STATE_DIR}

[Install]
WantedBy=multi-user.target"
  mcp_unit="[Unit]
Description=OmnisDocRAG mcp-server (FastMCP, Streamable HTTP)
After=network-online.target omnisdocrag-rag.service
Wants=omnisdocrag-rag.service

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${SRC_DIR}/docker_mcp-rag/mcp-server
EnvironmentFile=${MCP_ENV_FILE}
ExecStart=${VENV_MCP}/bin/python server.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target"
  write_if_changed "${UNIT_DIR}/omnisdocrag-rag.service" "${rag_unit}" 644 root:root && CHANGED_RAG=1 || true
  write_if_changed "${UNIT_DIR}/omnisdocrag-mcp.service" "${mcp_unit}" 644 root:root && CHANGED_MCP=1 || true
  systemctl daemon-reload
}

restart_or_start() {
  local unit="$1" changed="$2"
  if systemctl is-active --quiet "${unit}"; then
    if [[ "${changed}" == "1" ]]; then log "restarting ${unit}"; systemctl restart "${unit}"; fi
  else
    log "starting ${unit}"; systemctl start "${unit}"
  fi
}

start_services() {
  systemctl enable omnisdocrag-rag.service omnisdocrag-mcp.service >/dev/null 2>&1
  restart_or_start omnisdocrag-rag.service "${CHANGED_RAG}"
  restart_or_start omnisdocrag-mcp.service "${CHANGED_MCP}"
}

verify() {
  local i out
  log "verify: waiting for rag-server /health (up to ${HEALTH_TIMEOUT_S}s)"
  for ((i = 0; i < HEALTH_TIMEOUT_S; i += 3)); do
    out="$(curl -fsS "http://127.0.0.1:${RAG_PORT}/health" 2>/dev/null || true)"
    [[ -n "${out}" ]] && break
    sleep 3
  done
  [[ -n "${out}" ]] || { journalctl -u omnisdocrag-rag -n 30 --no-pager >&2 || true; die "rag-server did not become healthy"; }
  log "verify: /health -> ${out}"

  if [[ "${HAVE_PDFS}" == "1" ]]; then
    out="$(curl -fsS -X POST "http://127.0.0.1:${RAG_PORT}/search" -H 'Content-Type: application/json' \
            -d '{"query":"Set current list","top_k":1,"format":"json"}')" || die "search request failed"
    printf '%s' "${out}" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["results"] else 1)' \
      || die "search returned no result: ${out:0:300}"
    log "verify: /search OK"
  else
    warn "verify: /search skipped, no data built"
  fi

  for ((i = 0; i < 30; i++)); do
    # Streamable HTTP endpoint: any HTTP status (even 4xx for a bare GET) proves the listener is up.
    curl -s -o /dev/null "http://127.0.0.1:${MCP_PORT}/mcp" && break
    sleep 1
  done
  curl -s -o /dev/null "http://127.0.0.1:${MCP_PORT}/mcp" || die "mcp-server not listening on :${MCP_PORT}"
  log "verify: mcp-server listening on ${MCP_BIND_HOST}:${MCP_PORT}"
}

# Non-loopback IPv4 addresses (one per line); everything except 127.x.x.x.
list_host_ips() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | grep -v '^127\.' || true
}

print_summary() {
  local ip ips=()
  mapfile -t ips < <(list_host_ips)
  cat <<EOF

Installed. Services: omnisdocrag-rag (127.0.0.1:${RAG_PORT}), omnisdocrag-mcp (${MCP_BIND_HOST}:${MCP_PORT}).
  Logs:     journalctl -u omnisdocrag-rag -u omnisdocrag-mcp -f
  Config:   ${CONF_DIR}/   (DB passwords in secrets.env, root only)

VS Code .vscode/mcp.json, one entry per host interface:
EOF
  if [[ "${HAVE_PDFS}" != "1" ]]; then
    warn "database is EMPTY: run  OMNIS_PDF_DIR=/path/to/pdfs bash install_omnisdocrag.sh  to build the data"
  fi
  if [[ "${MCP_BIND_HOST}" == 127.* ]]; then
    warn "MCP bound to ${MCP_BIND_HOST}: reachable only from this host, other interfaces are not served"
    printf '  { "servers": { "omnis-rag": { "type": "http", "url": "http://127.0.0.1:%s/mcp" } } }\n' "${MCP_PORT}"
  elif ((${#ips[@]} == 0)); then
    warn "no non-loopback IPv4 address found"
  else
    for ip in "${ips[@]}"; do
      printf '\n  # interface %s\n  { "servers": { "omnis-rag": { "type": "http", "url": "http://%s:%s/mcp" } } }\n' "${ip}" "${ip}" "${MCP_PORT}"
    done
  fi
}

main() {
  check_prerequisites
  install_apt_packages
  ensure_user_and_dirs
  sync_repo
  ensure_venv "${VENV_RAG}" "${RAG_REQ_FILE}" "${TORCH_INDEX}" rag 1 && CHANGED_RAG=1 || true
  ensure_venv "${VENV_MCP}" "${MCP_REQ_FILE}" "" mcp 0 && CHANGED_MCP=1 || true
  ensure_venv "${VENV_PIPE}" "${PIPE_REQ_FILE}" "${TORCH_INDEX}" pipeline 1 || true
  ensure_secrets
  setup_database
  write_configs
  prefetch_model
  stage_pdfs
  build_data
  write_units
  start_services
  verify
  print_summary
}

main "$@"
