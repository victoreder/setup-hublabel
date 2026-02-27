#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Setup Personalizado VPS
# Instala: Traefik, Portainer, Evolution API, MinIO e n8n
# ==================================================

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
RESET="\e[0m"

BASE_DIR="/opt/setup-personalizado"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
TRAEFIK_DIR="${BASE_DIR}/traefik"
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DIR}/dynamic"
ENV_FILE="${BASE_DIR}/.env"
LOG_FILE="${BASE_DIR}/setup.log"

print_header() {
  clear || true
  echo -e "${BLUE}==============================================================${RESET}"
  echo -e "${BLUE}           SETUP PERSONALIZADO - VPS AUTOMATIZADO             ${RESET}"
  echo -e "${BLUE}==============================================================${RESET}"
  echo
}

log() {
  mkdir -p "${BASE_DIR}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

ok() {
  echo -e "${GREEN}✔ $*${RESET}"
  log "OK: $*"
}

warn() {
  echo -e "${YELLOW}⚠ $*${RESET}"
  log "WARN: $*"
}

die() {
  echo -e "${RED}✖ $*${RESET}"
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Execute como root: sudo bash SetupPersonalizado.sh"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"
}

ask() {
  local prompt="$1"
  local var_name="$2"
  local value
  while true; do
    read -r -p "$prompt" value
    if [[ -n "${value}" ]]; then
      printf -v "$var_name" '%s' "$value"
      break
    fi
    echo "Valor obrigatório. Tente novamente."
  done
}

ask_secret() {
  local prompt="$1"
  local var_name="$2"
  local value
  while true; do
    read -r -s -p "$prompt" value
    echo
    if [[ -n "${value}" ]]; then
      printf -v "$var_name" '%s' "$value"
      break
    fi
    echo "Valor obrigatório. Tente novamente."
  done
}

ask_default() {
  local prompt="$1"
  local var_name="$2"
  local default_value="$3"
  local value
  read -r -p "${prompt} [${default_value}]: " value
  value="${value:-${default_value}}"
  printf -v "$var_name" '%s' "$value"
}

normalize_domain() {
  local input="$1"
  input="$(echo -n "${input}" | xargs)"
  input="${input#http://}"
  input="${input#https://}"
  input="${input%%/*}"
  input="${input,,}"
  printf '%s' "${input}"
}

generate_secret() {
  openssl rand -base64 36 | tr -dc 'A-Za-z0-9@#%+=._-' | head -c 28
}

collect_inputs() {
  print_header
  echo -e "${YELLOW}Etapa 1/5 - Coleta de informações (tudo no início)${RESET}"
  echo -e "${BLUE}Informe domínios e senhas principais. Segredos internos serão gerados automaticamente.${RESET}"
  echo

  SERVER_NAME="$(hostname)"
  TZ_VALUE="America/Sao_Paulo"
  ask "E-mail para Let's Encrypt (Traefik): " LETSENCRYPT_EMAIL

  echo
  echo "Domínios públicos apontando para esta VPS:"
  ask "- Portainer (ex: portainer.seudominio.com): " PORTAINER_DOMAIN
  ask "- Evolution API (ex: evolution.seudominio.com): " EVOLUTION_DOMAIN
  ask "- MinIO Console (ex: minio.seudominio.com): " MINIO_CONSOLE_DOMAIN
  ask "- MinIO S3/API (ex: s3.seudominio.com): " MINIO_S3_DOMAIN
  ask "- n8n Editor (ex: n8n.seudominio.com): " N8N_EDITOR_DOMAIN
  ask "- n8n Webhook (ex: hook.seudominio.com): " N8N_WEBHOOK_DOMAIN

  PORTAINER_DOMAIN="$(normalize_domain "${PORTAINER_DOMAIN}")"
  EVOLUTION_DOMAIN="$(normalize_domain "${EVOLUTION_DOMAIN}")"
  MINIO_CONSOLE_DOMAIN="$(normalize_domain "${MINIO_CONSOLE_DOMAIN}")"
  MINIO_S3_DOMAIN="$(normalize_domain "${MINIO_S3_DOMAIN}")"
  N8N_EDITOR_DOMAIN="$(normalize_domain "${N8N_EDITOR_DOMAIN}")"
  N8N_WEBHOOK_DOMAIN="$(normalize_domain "${N8N_WEBHOOK_DOMAIN}")"

  echo
  echo "Acessos principais (você define):"
  ask_default "- Usuário admin para Basic Auth (Traefik/Portainer)" ADMIN_USER "admin"
  ask_secret "- Senha admin do Basic Auth: " ADMIN_PASSWORD
  ask_default "- E-mail login do n8n (Basic Auth)" N8N_ADMIN_EMAIL "admin@${N8N_EDITOR_DOMAIN}"
  ask_secret "- Senha login do n8n (Basic Auth): " N8N_ADMIN_PASSWORD
  ask_default "- MinIO Root User" MINIO_ROOT_USER "minioadmin"
  ask_secret "- MinIO Root Password: " MINIO_ROOT_PASSWORD

  # Segredos internos gerados automaticamente
  N8N_ENCRYPTION_KEY="$(generate_secret)$(generate_secret)"
  EVOLUTION_API_KEY="$(generate_secret)$(generate_secret)"
  EVOLUTION_DB_PASSWORD="$(generate_secret)"
  EVOLUTION_REDIS_PASSWORD="$(generate_secret)"

  echo
  echo -e "${BLUE}Resumo rápido:${RESET}"
  cat <<SUMMARY
Servidor: ${SERVER_NAME}
Timezone: ${TZ_VALUE}
Email LE: ${LETSENCRYPT_EMAIL}
Portainer: ${PORTAINER_DOMAIN}
Evolution: ${EVOLUTION_DOMAIN}
MinIO Console: ${MINIO_CONSOLE_DOMAIN}
MinIO S3/API: ${MINIO_S3_DOMAIN}
n8n Editor: ${N8N_EDITOR_DOMAIN}
n8n Webhook: ${N8N_WEBHOOK_DOMAIN}
Usuário Basic Auth: ${ADMIN_USER}
Usuário MinIO: ${MINIO_ROOT_USER}
SUMMARY
  echo
  read -r -p "Confirmar e seguir instalação? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || die "Instalação cancelada pelo usuário."
}


install_dependencies() {
  echo
  echo -e "${YELLOW}Etapa 2/5 - Instalando dependências do sistema${RESET}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl wget git jq unzip openssl ca-certificates gnupg lsb-release \
    ufw apache2-utils software-properties-common

  timedatectl set-timezone "${TZ_VALUE}" || warn "Não foi possível ajustar timezone via timedatectl"

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
    ok "Docker instalado"
  else
    ok "Docker já estava instalado"
  fi

  systemctl enable docker
  systemctl start docker

  if ! command -v docker-compose >/dev/null 2>&1; then
    local compose_plugin_path="/usr/local/lib/docker/cli-plugins"
    mkdir -p "${compose_plugin_path}"
    curl -SL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64" -o "${compose_plugin_path}/docker-compose"
    chmod +x "${compose_plugin_path}/docker-compose"
    ln -sf "${compose_plugin_path}/docker-compose" /usr/local/bin/docker-compose
  fi

  require_cmd docker
  require_cmd docker-compose
  require_cmd htpasswd
  ok "Dependências prontas"
}

prepare_files() {
  echo
  echo -e "${YELLOW}Etapa 3/5 - Gerando arquivos de configuração${RESET}"

  mkdir -p "${TRAEFIK_DYNAMIC_DIR}" "${BASE_DIR}/data" "${BASE_DIR}/certs" \
    "${BASE_DIR}/portainer" "${BASE_DIR}/minio" "${BASE_DIR}/n8n" \
    "${BASE_DIR}/evolution/postgres" "${BASE_DIR}/evolution/redis"

  touch "${TRAEFIK_DIR}/acme.json"
  chmod 600 "${TRAEFIK_DIR}/acme.json"

  BASIC_AUTH_HASH=$(htpasswd -nbB "${ADMIN_USER}" "${ADMIN_PASSWORD}" | sed -e 's/\$/\$\$/g')

  cat > "${ENV_FILE}" <<ENV
SERVER_NAME=${SERVER_NAME}
TZ=${TZ_VALUE}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}

PORTAINER_DOMAIN=${PORTAINER_DOMAIN}
EVOLUTION_DOMAIN=${EVOLUTION_DOMAIN}
MINIO_CONSOLE_DOMAIN=${MINIO_CONSOLE_DOMAIN}
MINIO_S3_DOMAIN=${MINIO_S3_DOMAIN}
N8N_EDITOR_DOMAIN=${N8N_EDITOR_DOMAIN}
N8N_WEBHOOK_DOMAIN=${N8N_WEBHOOK_DOMAIN}

ADMIN_USER=${ADMIN_USER}
BASIC_AUTH_HASH=${BASIC_AUTH_HASH}

N8N_ADMIN_EMAIL=${N8N_ADMIN_EMAIL}
N8N_ADMIN_PASSWORD=${N8N_ADMIN_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
EVOLUTION_DB_PASSWORD=${EVOLUTION_DB_PASSWORD}
EVOLUTION_REDIS_PASSWORD=${EVOLUTION_REDIS_PASSWORD}
ENV

  cat > "${COMPOSE_FILE}" <<'YAML'
services:
  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    command:
      - --api.dashboard=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.file.directory=/etc/traefik/dynamic
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.le.acme.tlschallenge=true
      - --certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --log.level=INFO
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/acme.json:/letsencrypt/acme.json
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
    networks:
      - proxy

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer:/data
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(`${PORTAINER_DOMAIN}`)
      - traefik.http.routers.portainer.entrypoints=websecure
      - traefik.http.routers.portainer.tls.certresolver=le
      - traefik.http.routers.portainer.middlewares=auth@file
      - traefik.http.services.portainer.loadbalancer.server.port=9000

  postgres-evolution:
    image: postgres:16-alpine
    container_name: postgres-evolution
    restart: unless-stopped
    environment:
      POSTGRES_DB: evolution
      POSTGRES_USER: evolution
      POSTGRES_PASSWORD: ${EVOLUTION_DB_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./evolution/postgres:/var/lib/postgresql/data
    networks:
      - proxy

  redis-evolution:
    image: redis:7-alpine
    container_name: redis-evolution
    restart: unless-stopped
    command: redis-server --appendonly yes --requirepass ${EVOLUTION_REDIS_PASSWORD}
    volumes:
      - ./evolution/redis:/data
    networks:
      - proxy

  evolution:
    image: atendai/evolution-api:latest
    container_name: evolution
    restart: unless-stopped
    environment:
      SERVER_URL: https://${EVOLUTION_DOMAIN}
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES: "true"
      LANGUAGE: pt-BR
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://evolution:${EVOLUTION_DB_PASSWORD}@postgres-evolution:5432/evolution
      DATABASE_CONNECTION_CLIENT_NAME: evolution
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://:${EVOLUTION_REDIS_PASSWORD}@redis-evolution:6379/1
      CACHE_REDIS_PREFIX_KEY: evolution
      CACHE_LOCAL_ENABLED: "false"
      N8N_ENABLED: "true"
      TZ: ${TZ}
    depends_on:
      - postgres-evolution
      - redis-evolution
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(`${EVOLUTION_DOMAIN}`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.tls.certresolver=le
      - traefik.http.services.evolution.loadbalancer.server.port=8080

  minio:
    image: minio/minio:latest
    container_name: minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      MINIO_BROWSER_REDIRECT_URL: https://${MINIO_CONSOLE_DOMAIN}
      MINIO_SERVER_URL: https://${MINIO_S3_DOMAIN}
      TZ: ${TZ}
    volumes:
      - ./minio:/data
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.http.routers.minio-console.rule=Host(`${MINIO_CONSOLE_DOMAIN}`)
      - traefik.http.routers.minio-console.entrypoints=websecure
      - traefik.http.routers.minio-console.tls.certresolver=le
      - traefik.http.routers.minio-console.service=minio-console
      - traefik.http.services.minio-console.loadbalancer.server.port=9001
      - traefik.http.routers.minio-s3.rule=Host(`${MINIO_S3_DOMAIN}`)
      - traefik.http.routers.minio-s3.entrypoints=websecure
      - traefik.http.routers.minio-s3.tls.certresolver=le
      - traefik.http.routers.minio-s3.service=minio-s3
      - traefik.http.services.minio-s3.loadbalancer.server.port=9000

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      N8N_HOST: ${N8N_EDITOR_DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      N8N_PROXY_HOPS: 1
      WEBHOOK_URL: https://${N8N_WEBHOOK_DOMAIN}/
      N8N_EDITOR_BASE_URL: https://${N8N_EDITOR_DOMAIN}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_ONBOARDING_FLOW_DISABLED: "true"
      N8N_RUNNERS_ENABLED: "true"
      N8N_SECURE_COOKIE: "true"
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: ${N8N_ADMIN_EMAIL}
      N8N_BASIC_AUTH_PASSWORD: ${N8N_ADMIN_PASSWORD}
      GENERIC_TIMEZONE: ${TZ}
      TZ: ${TZ}
    volumes:
      - ./n8n:/home/node/.n8n
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n-editor.rule=Host(`${N8N_EDITOR_DOMAIN}`)
      - traefik.http.routers.n8n-editor.entrypoints=websecure
      - traefik.http.routers.n8n-editor.tls.certresolver=le
      - traefik.http.routers.n8n-editor.service=n8n
      - traefik.http.routers.n8n-webhook.rule=Host(`${N8N_WEBHOOK_DOMAIN}`)
      - traefik.http.routers.n8n-webhook.entrypoints=websecure
      - traefik.http.routers.n8n-webhook.tls.certresolver=le
      - traefik.http.routers.n8n-webhook.service=n8n
      - traefik.http.services.n8n.loadbalancer.server.port=5678

networks:
  proxy:
    name: proxy
YAML

  cat > "${TRAEFIK_DYNAMIC_DIR}/middlewares.yml" <<YAML
http:
  middlewares:
    auth:
      basicAuth:
        users:
          - "${BASIC_AUTH_HASH}"
YAML

  ok "Arquivos criados em ${BASE_DIR}"
}

run_installation() {
  echo
  echo -e "${YELLOW}Etapa 4/5 - Subindo serviços${RESET}"

  cd "${BASE_DIR}"
  docker-compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d
  ok "Containers iniciados"
}

verify_installation() {
  echo
  echo -e "${YELLOW}Etapa 5/5 - Verificações automáticas${RESET}"

  local failed=0
  local services=(traefik portainer postgres-evolution redis-evolution evolution minio n8n)

  for service in "${services[@]}"; do
    if docker ps --format '{{.Names}}' | grep -qx "${service}"; then
      ok "Container ${service} está em execução"
    else
      warn "Container ${service} não está em execução"
      failed=1
    fi
  done

  sleep 8

  for url in \
    "https://${PORTAINER_DOMAIN}" \
    "https://${EVOLUTION_DOMAIN}" \
    "https://${MINIO_CONSOLE_DOMAIN}" \
    "https://${MINIO_S3_DOMAIN}" \
    "https://${N8N_EDITOR_DOMAIN}" \
    "https://${N8N_WEBHOOK_DOMAIN}"; do
    local status
    status="$(curl -kIsS --max-time 20 -o /dev/null -w '%{http_code}' "${url}" || true)"

    if [[ "${status}" =~ ^(200|301|302|307|308|401|403)$ ]]; then
      ok "URL respondeu (${status}): ${url}"
    elif [[ "${status}" == "404" ]]; then
      warn "URL respondeu com 404 (roteamento/domínio incorreto): ${url}"
      failed=1
    else
      warn "URL não acessível ou inesperada (HTTP ${status:-erro}): ${url}"
      failed=1
    fi
  done

  echo
  echo -e "${BLUE}======================== RESULTADO ========================${RESET}"
  if [[ ${failed} -eq 0 ]]; then
    echo -e "${GREEN}Instalação concluída com sucesso.${RESET}"
  else
    echo -e "${YELLOW}Instalação concluída com alertas. Verifique logs:${RESET} ${LOG_FILE}"
    echo "Use: docker logs <container> --tail 100"
  fi

  cat <<ACCESS

Acessos:
- Portainer: https://${PORTAINER_DOMAIN}
- Evolution: https://${EVOLUTION_DOMAIN}
- MinIO Console: https://${MINIO_CONSOLE_DOMAIN}
- MinIO S3/API: https://${MINIO_S3_DOMAIN}
- n8n Editor: https://${N8N_EDITOR_DOMAIN}
- n8n Webhook: https://${N8N_WEBHOOK_DOMAIN}

Credenciais definidas por você:
- BASIC AUTH (Traefik/Portainer): ${ADMIN_USER} / ${ADMIN_PASSWORD}
- n8n BASIC AUTH: ${N8N_ADMIN_EMAIL} / ${N8N_ADMIN_PASSWORD}
- MinIO: ${MINIO_ROOT_USER} / ${MINIO_ROOT_PASSWORD}

Segredos gerados automaticamente:
- Evolution API KEY: ${EVOLUTION_API_KEY}
- Evolution PostgreSQL PASSWORD: ${EVOLUTION_DB_PASSWORD}
- Evolution Redis PASSWORD: ${EVOLUTION_REDIS_PASSWORD}
- n8n ENCRYPTION KEY: ${N8N_ENCRYPTION_KEY}

Arquivos:
- Compose: ${COMPOSE_FILE}
- Ambiente: ${ENV_FILE}
- Logs setup: ${LOG_FILE}
ACCESS
}

main() {
  require_root
  collect_inputs
  install_dependencies
  prepare_files
  run_installation
  verify_installation
}

main "$@"
