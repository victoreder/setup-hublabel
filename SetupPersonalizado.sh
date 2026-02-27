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

collect_inputs() {
  print_header
  echo -e "${YELLOW}Etapa 1/5 - Coleta de informações (tudo no início)${RESET}"
  echo

  ask "Nome do servidor (ex: vps-producao): " SERVER_NAME
  ask "Timezone (ex: America/Sao_Paulo): " TZ_VALUE
  ask "E-mail para Let's Encrypt (Traefik): " LETSENCRYPT_EMAIL

  echo
  echo "Domínios públicos apontando para esta VPS:"
  ask "- Portainer (ex: portainer.seudominio.com): " PORTAINER_DOMAIN
  ask "- Evolution API (ex: evolution.seudominio.com): " EVOLUTION_DOMAIN
  ask "- MinIO Console (ex: minio.seudominio.com): " MINIO_DOMAIN
  ask "- n8n (ex: n8n.seudominio.com): " N8N_DOMAIN

  echo
  echo "Credenciais:"
  ask "- Usuário admin básico (HTTP Auth para Traefik/Portainer): " ADMIN_USER
  ask_secret "- Senha admin básico: " ADMIN_PASSWORD
  ask "- E-mail admin do n8n: " N8N_ADMIN_EMAIL
  ask_secret "- Senha admin do n8n: " N8N_ADMIN_PASSWORD
  ask_secret "- Chave de criptografia do n8n (N8N_ENCRYPTION_KEY): " N8N_ENCRYPTION_KEY

  ask "- MinIO Root User: " MINIO_ROOT_USER
  ask_secret "- MinIO Root Password: " MINIO_ROOT_PASSWORD

  ask "- Evolution API AUTHENTICATION_API_KEY: " EVOLUTION_API_KEY
  ask_secret "- Senha PostgreSQL (Evolution): " EVOLUTION_DB_PASSWORD
  ask_secret "- Senha Redis (Evolution): " EVOLUTION_REDIS_PASSWORD

  echo
  echo -e "${BLUE}Resumo rápido:${RESET}"
  cat <<SUMMARY
Servidor: ${SERVER_NAME}
Timezone: ${TZ_VALUE}
Email LE: ${LETSENCRYPT_EMAIL}
Portainer: ${PORTAINER_DOMAIN}
Evolution: ${EVOLUTION_DOMAIN}
MinIO: ${MINIO_DOMAIN}
n8n: ${N8N_DOMAIN}
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
MINIO_DOMAIN=${MINIO_DOMAIN}
N8N_DOMAIN=${N8N_DOMAIN}

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
      DATABASE_ENABLED: "true"
      DATABASE_CONNECTION_URI: postgresql://evolution:${EVOLUTION_DB_PASSWORD}@postgres-evolution:5432/evolution
      REDIS_ENABLED: "true"
      REDIS_URI: redis://:${EVOLUTION_REDIS_PASSWORD}@redis-evolution:6379
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
      TZ: ${TZ}
    volumes:
      - ./minio:/data
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.http.routers.minio.rule=Host(`${MINIO_DOMAIN}`)
      - traefik.http.routers.minio.entrypoints=websecure
      - traefik.http.routers.minio.tls.certresolver=le
      - traefik.http.services.minio.loadbalancer.server.port=9001

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_EDITOR_BASE_URL: https://${N8N_DOMAIN}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
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
      - traefik.http.routers.n8n.rule=Host(`${N8N_DOMAIN}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=le
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

  for url in "https://${PORTAINER_DOMAIN}" "https://${EVOLUTION_DOMAIN}" "https://${MINIO_DOMAIN}" "https://${N8N_DOMAIN}"; do
    if curl -kfsS --max-time 20 "${url}" >/dev/null; then
      ok "URL respondeu: ${url}"
    else
      warn "URL ainda não respondeu (DNS/SSL propagação?): ${url}"
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
- MinIO Console: https://${MINIO_DOMAIN}
- n8n: https://${N8N_DOMAIN}

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
