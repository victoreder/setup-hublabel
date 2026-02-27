#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/hublabel"
ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este script precisa rodar como root. Use: sudo ./setup.sh"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_base_packages() {
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release jq openssl
}

install_docker_if_needed() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    echo "Docker e Docker Compose já estão instalados."
    return
  fi

  echo "Instalando Docker e Docker Compose..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local arch codename distro
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release; echo "$VERSION_CODENAME")"
  distro="$(. /etc/os-release; echo "$ID")"

  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
}

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_email() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_network_name() {
  local value="$1"
  [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]]
}

ask_non_empty() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt" value
    if [[ -n "$value" ]]; then
      echo "$value"
      return
    fi
    echo "Valor obrigatório. Tente novamente."
  done
}

ask_password() {
  local prompt="$1"
  local value
  while true; do
    read -r -s -p "$prompt" value
    echo
    if [[ -n "$value" ]]; then
      echo "$value"
      return
    fi
    echo "Senha obrigatória. Tente novamente."
  done
}

ask_domain() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt" value
    if validate_domain "$value"; then
      echo "$value"
      return
    fi
    echo "Domínio inválido. Tente novamente."
  done
}

ask_email() {
  local value
  while true; do
    read -r -p "E-mail válido para SSL (Let's Encrypt): " value
    if validate_email "$value"; then
      echo "$value"
      return
    fi
    echo "E-mail inválido. Tente novamente."
  done
}

ask_network_name() {
  local value
  while true; do
    read -r -p "Nome da rede Docker [traefik-public]: " value
    value="${value:-traefik-public}"
    if validate_network_name "$value"; then
      echo "$value"
      return
    fi
    echo "Nome de rede inválido. Use letras, números, ., _ ou -."
  done
}

generate_secrets() {
  EVOLUTION_API_KEY="$(openssl rand -hex 16)"
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
}

prompt_inputs() {
  echo "=============================================="
  echo " Setup automático (estilo Orion)"
  echo " Etapa 1: Traefik + Portainer"
  echo "=============================================="
  echo

  PORTAINER_DOMAIN="$(ask_domain "Domínio do Portainer (ex: portainer.seudominio.com): ")"
  ADMIN_USER="$(ask_non_empty "Usuário admin padrão: ")"
  ADMIN_PASSWORD="$(ask_password "Senha admin padrão: ")"
  SERVER_NAME="$(ask_non_empty "Nome do servidor (ex: VPS-01): ")"
  DOCKER_NETWORK="$(ask_network_name)"
  ACME_EMAIL="$(ask_email)"

  echo
  echo "=============================================="
  echo " Etapa 2: Evolution API"
  echo "=============================================="
  echo

  EVOLUTION_DOMAIN="$(ask_domain "Domínio da Evolution API (ex: wpp.seudominio.com): ")"
}

write_env_file() {
  cat > "$ENV_FILE" <<ENVVARS
PORTAINER_DOMAIN=${PORTAINER_DOMAIN}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SERVER_NAME=${SERVER_NAME}
DOCKER_NETWORK=${DOCKER_NETWORK}
ACME_EMAIL=${ACME_EMAIL}
EVOLUTION_DOMAIN=${EVOLUTION_DOMAIN}
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
ENVVARS
}

write_compose_file() {
  cat > "$COMPOSE_FILE" <<'COMPOSE'
services:
  traefik:
    image: traefik:v3.1
    container_name: traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${DOCKER_NETWORK}
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencryptresolver.acme.tlschallenge=true
      - --certificatesresolvers.letsencryptresolver.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.letsencryptresolver.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks:
      - ${DOCKER_NETWORK}

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - ${DOCKER_NETWORK}
    ports:
      - "127.0.0.1:9000:9000"
    labels:
      - traefik.enable=true
      - traefik.docker.network=${DOCKER_NETWORK}
      - traefik.http.routers.portainer.rule=Host(`${PORTAINER_DOMAIN}`)
      - traefik.http.routers.portainer.entrypoints=websecure
      - traefik.http.routers.portainer.tls=true
      - traefik.http.routers.portainer.tls.certresolver=letsencryptresolver
      - traefik.http.services.portainer.loadbalancer.server.port=9000

  postgres:
    image: postgres:15
    container_name: evolution_postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=evolution
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - evolution_postgres_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}

  evolution_redis:
    image: redis:latest
    container_name: evolution_redis
    restart: unless-stopped
    command: redis-server --appendonly yes --port 6379
    volumes:
      - evolution_redis:/data
    networks:
      - ${DOCKER_NETWORK}

  evolution_api:
    image: evoapicloud/evolution-api:latest
    container_name: evolution_api
    restart: unless-stopped
    volumes:
      - evolution_instances:/evolution/instances
    networks:
      - ${DOCKER_NETWORK}
    environment:
      - SERVER_URL=https://${EVOLUTION_DOMAIN}
      - AUTHENTICATION_API_KEY=${EVOLUTION_API_KEY}
      - AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
      - DEL_INSTANCE=false
      - QRCODE_LIMIT=1902
      - LANGUAGE=pt-BR
      - CONFIG_SESSION_PHONE_CLIENT=SetupOrion
      - CONFIG_SESSION_PHONE_NAME=Chrome
      - DATABASE_ENABLED=true
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/evolution
      - DATABASE_CONNECTION_CLIENT_NAME=evolution
      - DATABASE_SAVE_DATA_INSTANCE=true
      - DATABASE_SAVE_DATA_NEW_MESSAGE=true
      - DATABASE_SAVE_MESSAGE_UPDATE=true
      - DATABASE_SAVE_DATA_CONTACTS=true
      - DATABASE_SAVE_DATA_CHATS=true
      - DATABASE_SAVE_DATA_LABELS=true
      - DATABASE_SAVE_DATA_HISTORIC=true
      - N8N_ENABLED=true
      - EVOAI_ENABLED=true
      - OPENAI_ENABLED=true
      - DIFY_ENABLED=true
      - TYPEBOT_ENABLED=true
      - TYPEBOT_API_VERSION=latest
      - CHATWOOT_ENABLED=true
      - CHATWOOT_MESSAGE_READ=true
      - CHATWOOT_MESSAGE_DELETE=true
      - CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/chatwoot?sslmode=disable
      - CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=false
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://evolution_redis:6379/1
      - CACHE_REDIS_PREFIX_KEY=evolution
      - CACHE_REDIS_SAVE_INSTANCES=false
      - CACHE_LOCAL_ENABLED=false
      - S3_ENABLED=false
      - S3_ACCESS_KEY=
      - S3_SECRET_KEY=
      - S3_BUCKET=evolution
      - S3_PORT=443
      - S3_ENDPOINT=
      - S3_USE_SSL=true
      - WA_BUSINESS_TOKEN_WEBHOOK=evolution
      - WA_BUSINESS_URL=https://graph.facebook.com
      - WA_BUSINESS_VERSION=v23.0
      - WA_BUSINESS_LANGUAGE=pt_BR
      - TELEMETRY=false
      - TELEMETRY_URL=
      - WEBSOCKET_ENABLED=false
      - WEBSOCKET_GLOBAL_EVENTS=false
      - SQS_ENABLED=false
      - SQS_ACCESS_KEY_ID=
      - SQS_SECRET_ACCESS_KEY=
      - SQS_ACCOUNT_ID=
      - SQS_REGION=
      - RABBITMQ_ENABLED=false
      - RABBITMQ_FRAME_MAX=8192
      - RABBITMQ_URI=amqp://USER:PASS@rabbitmq:5672/evolution
      - RABBITMQ_EXCHANGE_NAME=evolution
      - RABBITMQ_GLOBAL_ENABLED=false
      - RABBITMQ_EVENTS_APPLICATION_STARTUP=false
      - RABBITMQ_EVENTS_INSTANCE_CREATE=false
      - RABBITMQ_EVENTS_INSTANCE_DELETE=false
      - RABBITMQ_EVENTS_QRCODE_UPDATED=false
      - RABBITMQ_EVENTS_SEND_MESSAGE_UPDATE=false
      - RABBITMQ_EVENTS_MESSAGES_SET=false
      - RABBITMQ_EVENTS_MESSAGES_UPSERT=true
      - RABBITMQ_EVENTS_MESSAGES_EDITED=false
      - RABBITMQ_EVENTS_MESSAGES_UPDATE=false
      - RABBITMQ_EVENTS_MESSAGES_DELETE=false
      - RABBITMQ_EVENTS_SEND_MESSAGE=false
      - RABBITMQ_EVENTS_CONTACTS_SET=false
      - RABBITMQ_EVENTS_CONTACTS_UPSERT=false
      - RABBITMQ_EVENTS_CONTACTS_UPDATE=false
      - RABBITMQ_EVENTS_PRESENCE_UPDATE=false
      - RABBITMQ_EVENTS_CHATS_SET=false
      - RABBITMQ_EVENTS_CHATS_UPSERT=false
      - RABBITMQ_EVENTS_CHATS_UPDATE=false
      - RABBITMQ_EVENTS_CHATS_DELETE=false
      - RABBITMQ_EVENTS_GROUPS_UPSERT=false
      - RABBITMQ_EVENTS_GROUP_UPDATE=false
      - RABBITMQ_EVENTS_GROUP_PARTICIPANTS_UPDATE=false
      - RABBITMQ_EVENTS_CONNECTION_UPDATE=true
      - RABBITMQ_EVENTS_CALL=false
      - RABBITMQ_EVENTS_TYPEBOT_START=false
      - RABBITMQ_EVENTS_TYPEBOT_CHANGE_STATUS=false
      - WEBHOOK_GLOBAL_ENABLED=false
      - WEBHOOK_GLOBAL_URL=
      - WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS=false
      - WEBHOOK_EVENTS_APPLICATION_STARTUP=false
      - WEBHOOK_EVENTS_QRCODE_UPDATED=false
      - WEBHOOK_EVENTS_MESSAGES_SET=false
      - WEBHOOK_EVENTS_SEND_MESSAGE_UPDATE=false
      - WEBHOOK_EVENTS_MESSAGES_UPSERT=false
      - WEBHOOK_EVENTS_MESSAGES_EDITED=false
      - WEBHOOK_EVENTS_MESSAGES_UPDATE=false
      - WEBHOOK_EVENTS_MESSAGES_DELETE=false
      - WEBHOOK_EVENTS_SEND_MESSAGE=false
      - WEBHOOK_EVENTS_CONTACTS_SET=false
      - WEBHOOK_EVENTS_CONTACTS_UPSERT=false
      - WEBHOOK_EVENTS_CONTACTS_UPDATE=false
      - WEBHOOK_EVENTS_PRESENCE_UPDATE=false
      - WEBHOOK_EVENTS_CHATS_SET=false
      - WEBHOOK_EVENTS_CHATS_UPSERT=false
      - WEBHOOK_EVENTS_CHATS_UPDATE=false
      - WEBHOOK_EVENTS_CHATS_DELETE=false
      - WEBHOOK_EVENTS_GROUPS_UPSERT=false
      - WEBHOOK_EVENTS_GROUPS_UPDATE=false
      - WEBHOOK_EVENTS_GROUP_PARTICIPANTS_UPDATE=false
      - WEBHOOK_EVENTS_CONNECTION_UPDATE=false
      - WEBHOOK_EVENTS_LABELS_EDIT=false
      - WEBHOOK_EVENTS_LABELS_ASSOCIATION=false
      - WEBHOOK_EVENTS_CALL=false
      - WEBHOOK_EVENTS_TYPEBOT_START=false
      - WEBHOOK_EVENTS_TYPEBOT_CHANGE_STATUS=false
      - WEBHOOK_EVENTS_ERRORS=false
      - WEBHOOK_EVENTS_ERRORS_WEBHOOK=
      - WEBHOOK_REQUEST_TIMEOUT_MS=60000
      - WEBHOOK_RETRY_MAX_ATTEMPTS=10
      - WEBHOOK_RETRY_INITIAL_DELAY_SECONDS=5
      - WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF=true
      - WEBHOOK_RETRY_MAX_DELAY_SECONDS=300
      - WEBHOOK_RETRY_JITTER_FACTOR=0.2
      - WEBHOOK_RETRY_NON_RETRYABLE_STATUS_CODES=400,401,403,404,422
      - PROVIDER_ENABLED=false
      - PROVIDER_HOST=127.0.0.1
      - PROVIDER_PORT=5656
      - PROVIDER_PREFIX=evolution
    labels:
      - traefik.enable=true
      - traefik.docker.network=${DOCKER_NETWORK}
      - traefik.http.routers.evolution.rule=Host(`${EVOLUTION_DOMAIN}`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.priority=1
      - traefik.http.routers.evolution.tls=true
      - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
      - traefik.http.routers.evolution.service=evolution
      - traefik.http.services.evolution.loadbalancer.server.port=8080
      - traefik.http.services.evolution.loadbalancer.passHostHeader=true

volumes:
  traefik_letsencrypt:
  portainer_data:
  evolution_postgres_data:
  evolution_instances:
  evolution_redis:

networks:
  ${DOCKER_NETWORK}:
    name: ${DOCKER_NETWORK}
COMPOSE
}

init_portainer_admin() {
  echo "Inicializando admin do Portainer (se necessário)..."

  local ok="false"
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:9000/api/status" >/dev/null 2>&1; then
      ok="true"
      break
    fi
    sleep 2
  done

  if [[ "$ok" != "true" ]]; then
    echo "Aviso: Portainer não ficou pronto a tempo para inicializar admin."
    return
  fi

  local payload
  payload="$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Username:$u,Password:$p}')"

  local response
  response="$(curl -sS -o /tmp/portainer-init.out -w '%{http_code}' -H 'Content-Type: application/json' -d "$payload" http://127.0.0.1:9000/api/users/admin/init || true)"

  if [[ "$response" == "200" || "$response" == "201" || "$response" == "409" ]]; then
    echo "Portainer inicializado com sucesso (ou já estava inicializado)."
  else
    echo "Aviso: init admin do Portainer não confirmado automaticamente (HTTP ${response})."
  fi
}

deploy_stack() {
  echo "Subindo stack em ${APP_DIR}..."
  cd "$APP_DIR"
  docker compose --env-file "$ENV_FILE" up -d
}

show_summary() {
  echo
  echo "=============================================="
  echo " Instalação concluída"
  echo "=============================================="
  echo "Servidor:          ${SERVER_NAME}"
  echo "Rede Docker:       ${DOCKER_NETWORK}"
  echo "E-mail SSL:        ${ACME_EMAIL}"
  echo "Portainer:         https://${PORTAINER_DOMAIN}"
  echo "Evolution API:     https://${EVOLUTION_DOMAIN}"
  echo "Evolution API KEY: ${EVOLUTION_API_KEY}"
  echo "Postgres usuário:  postgres"
  echo "Postgres senha:    ${POSTGRES_PASSWORD}"
  echo
  echo "Usuário Portainer: ${ADMIN_USER}"
  echo "Senha Portainer:   ${ADMIN_PASSWORD}"
  echo
  echo "Pasta do projeto: ${APP_DIR}"
  echo "Logs: cd ${APP_DIR} && docker compose logs -f"
}

main() {
  require_root
  install_base_packages
  install_docker_if_needed
  mkdir -p "$APP_DIR"
  prompt_inputs
  generate_secrets
  write_env_file
  write_compose_file
  deploy_stack
  init_portainer_admin
  show_summary
}

main "$@"
