#!/bin/bash

## ============================================================================
## SETUP PERSONALIZADO HUBLABEL v1.1
## Instala: Traefik, Portainer, Evolution API, MinIO, N8N e dependências
## Baseado exatamente no SetupOrion - sem Basic Auth
##
## COMANDO PARA INICIAR A INSTALAÇÃO:
##   sudo bash setuppersonalizado-hublabel.sh
##
## Ou torne executável e rode:
##   chmod +x setuppersonalizado-hublabel.sh
##   sudo ./setuppersonalizado-hublabel.sh
## ============================================================================

amarelo="\e[33m"
verde="\e[32m"
branco="\e[97m"
vermelho="\e[91m"
reset="\e[0m"

home_directory="$HOME"
dados_vps="${home_directory}/dados_vps/dados_vps"

dados() {
    nome_servidor=$(grep "Nome do Servidor:" "$dados_vps" 2>/dev/null | awk -F': ' '{print $2}')
    nome_rede_interna=$(grep "Rede interna:" "$dados_vps" 2>/dev/null | awk -F': ' '{print $2}')
}

validar_senha() {
    senha=$1
    tamanho_minimo=$2
    tem_erro=0
    mensagem_erro=""

    if [ ${#senha} -lt $tamanho_minimo ]; then
        mensagem_erro+="\n- Senha precisa ter no mínimo $tamanho_minimo caracteres"
        tem_erro=1
    fi
    if ! [[ $senha =~ [A-Z] ]]; then
        mensagem_erro+="\n- Falta pelo menos uma letra maiúscula"
        tem_erro=1
    fi
    if ! [[ $senha =~ [a-z] ]]; then
        mensagem_erro+="\n- Falta pelo menos uma letra minúscula"
        tem_erro=1
    fi
    if ! [[ $senha =~ [0-9] ]]; then
        mensagem_erro+="\n- Falta pelo menos um número"
        tem_erro=1
    fi
    if ! [[ $senha =~ [@_] ]]; then
        mensagem_erro+="\n- Falta pelo menos um caractere especial (@ ou _)"
        tem_erro=1
    fi
    if [[ $senha =~ [^A-Za-z0-9@_] ]]; then
        mensagem_erro+="\n- Contém caracteres especiais não permitidos (use apenas @ ou _)"
        tem_erro=1
    fi

    if [ $tem_erro -eq 1 ]; then
        echo -e "Senha inválida! Corrija os seguintes problemas:$mensagem_erro"
        return 1
    fi
    return 0
}

wait_stack() {
    echo "Este processo pode demorar um pouco. Se levar mais de 10 minutos, cancele."
    for service in "$@"; do
        while ! docker service ls --filter "name=$service" 2>/dev/null | grep -q "1/1"; do
            sleep 10
        done
        echo -e "🟢 O serviço ${verde}$service${reset} está online."
    done
}

wait_30_sec() { sleep 30; }

pull() {
    for image in "$@"; do
        while ! docker pull "$image" >/dev/null 2>&1; do
            echo "Erro ao baixar $image. Tentando novamente..."
            sleep 5
        done
    done
}

verificar_container_postgres() {
    docker ps -q --filter "name=postgres_postgres" 2>/dev/null | grep -q . && return 0 || return 1
}

pegar_senha_postgres() {
    while :; do
        if [ -f /root/postgres.yaml ]; then
            senha_postgres=$(grep "POSTGRES_PASSWORD" /root/postgres.yaml | sed 's/.*: *//' | tr -d ' ')
            [ -n "$senha_postgres" ] && break
        fi
        sleep 2
    done
}

criar_banco_postgres_da_stack() {
    local db_name="$1"
    while :; do
        if docker ps -q --filter "name=^postgres_postgres" 2>/dev/null | grep -q .; then
            CONTAINER_ID=$(docker ps -q --filter "name=^postgres_postgres" | head -1)
            if docker exec "$CONTAINER_ID" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$db_name"; then
                break
            fi
            docker exec "$CONTAINER_ID" psql -U postgres -c "CREATE DATABASE $db_name;" 2>/dev/null
            if docker exec "$CONTAINER_ID" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$db_name"; then
                break
            fi
        fi
        sleep 3
    done
}

recursos() {
    vcpu_requerido=$1
    ram_requerido=$2
    if command -v neofetch >/dev/null 2>&1; then
        vcpu_disponivel=$(neofetch --stdout 2>/dev/null | grep "CPU" | grep -oP '\(\d+\)' | tr -d '()')
        ram_disponivel=$(neofetch --stdout 2>/dev/null | grep "Memory" | awk '{print $4}' | tr -d 'MiB' | awk '{print int($1/1024 + 0.5)}')
    else
        vcpu_disponivel=$(nproc 2>/dev/null || echo 2)
        ram_disponivel=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    vcpu_disponivel=${vcpu_disponivel:-2}
    ram_disponivel=${ram_disponivel:-2}
    if [[ $vcpu_disponivel -ge $vcpu_requerido && $ram_disponivel -ge $ram_requerido ]]; then
        return 0
    else
        echo -e "${vermelho}Recursos insuficientes. Requer: ${vcpu_requerido}vCPU e ${ram_requerido}GB RAM${reset}"
        return 1
    fi
}

stack_editavel() {
    sudo apt install -y jq >/dev/null 2>&1
    arquivo="/root/dados_vps/dados_portainer"
    if [ ! -f "$arquivo" ]; then
        echo "Erro: dados_portainer não encontrado. Execute primeiro Traefik+Portainer."
        return 1
    fi

    ## Extrair variáveis ANTES de modificar o arquivo (igual SetupOrion)
    PORTAINER_URL=$(grep "Dominio do portainer:" "$arquivo" 2>/dev/null | sed 's/.*Dominio do portainer: *//' | sed 's|https://||' | tr -d ' \r\n')
    USUARIO=$(grep "Usuario:" "$arquivo" 2>/dev/null | sed 's/.*Usuario: *//' | tr -d '\r\n')
    SENHA=$(grep "Senha:" "$arquivo" 2>/dev/null | sed 's/.*Senha: *//' | tr -d '\r\n')

    ## Remove https:// do arquivo (igual SetupOrion) - preserva o restante
    sed -i 's|Dominio do portainer: https://|Dominio do portainer: |' "$arquivo" 2>/dev/null

    [ -z "$PORTAINER_URL" ] && { echo "Erro: Dominio do Portainer vazio em dados_portainer"; return 1; }
    [ -z "$USUARIO" ] && { echo "Erro: Usuario vazio em dados_portainer"; return 1; }
    [ -z "$SENHA" ] && { echo "Erro: Senha vazia em dados_portainer"; return 1; }

    TOKEN=""
    for i in $(seq 1 6); do
        ## Tenta via 127.0.0.1 (evita hairpin NAT) e via URL direta (igual SetupOrion)
        TOKEN=$(curl -k -s -m 15 -X POST -H "Content-Type: application/json" -H "Host: $PORTAINER_URL" \
            -d "{\"username\":\"$USUARIO\",\"password\":\"$SENHA\"}" \
            "https://127.0.0.1/api/auth" | jq -r .jwt 2>/dev/null)
        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
            TOKEN=$(curl -k -s -m 15 -X POST -H "Content-Type: application/json" \
                -d "{\"username\":\"$USUARIO\",\"password\":\"$SENHA\"}" \
                "https://$PORTAINER_URL/api/auth" | jq -r .jwt 2>/dev/null)
        fi
        [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && break
        echo "Tentativa $i/6 - Aguardando Portainer..."
        sleep 5
    done

    ## Fallback: se não obteve token, pede credenciais manualmente (igual SetupOrion)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo ""
        echo -e "${amarelo}Não foi possível obter o token automaticamente. Informe as credenciais do Portainer:${reset}"
        echo ""
        read -p "URL do Portainer (ex: painel.$dominio_base) [$PORTAINER_URL]: " input_url
        PORTAINER_URL="${input_url:-$PORTAINER_URL}"
        PORTAINER_URL="${PORTAINER_URL#https://}"
        PORTAINER_URL="${PORTAINER_URL%%/*}"
        read -p "Usuário do Portainer [$USUARIO]: " input_user
        USUARIO="${input_user:-$USUARIO}"
        echo -e "${amarelo}Senha não aparecerá ao digitar${reset}"
        read -s -p "Senha do Portainer: " SENHA
        echo ""
        echo -e "[ PORTAINER ]\nDominio do portainer: https://$PORTAINER_URL\nUsuario: $USUARIO\nSenha: $SENHA\nToken: " > "$arquivo"
        for i in 1 2 3; do
            TOKEN=$(curl -k -s -m 15 -X POST -H "Content-Type: application/json" -H "Host: $PORTAINER_URL" \
                -d "{\"username\":\"$USUARIO\",\"password\":\"$SENHA\"}" \
                "https://127.0.0.1/api/auth" | jq -r .jwt 2>/dev/null)
            [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && TOKEN=$(curl -k -s -m 15 -X POST -H "Content-Type: application/json" \
                -d "{\"username\":\"$USUARIO\",\"password\":\"$SENHA\"}" \
                "https://$PORTAINER_URL/api/auth" | jq -r .jwt 2>/dev/null)
            [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && break
            echo "Tentativa $i/3 com novas credenciais..."
            sleep 3
        done
        [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && { echo "Erro ao obter token Portainer. Verifique as credenciais."; return 1; }
        echo "Token obtido com sucesso!"
    fi

    echo -e "[ PORTAINER ]\nDominio do portainer: https://$PORTAINER_URL\nUsuario: $USUARIO\nSenha: $SENHA\nToken: $TOKEN" > "$arquivo"

    ENDPOINT_ID=$(curl -k -s -m 15 -H "Authorization: Bearer $TOKEN" -H "Host: $PORTAINER_URL" "https://127.0.0.1/api/endpoints" | jq -r '.[] | select(.Name == "primary") | .Id')
    [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ] && ENDPOINT_ID=$(curl -k -s -m 15 -H "Authorization: Bearer $TOKEN" "https://$PORTAINER_URL/api/endpoints" | jq -r '.[] | select(.Name == "primary") | .Id')
    SWARM_ID=$(curl -k -s -m 15 -H "Authorization: Bearer $TOKEN" -H "Host: $PORTAINER_URL" "https://127.0.0.1/api/endpoints/$ENDPOINT_ID/docker/swarm" | jq -r .ID)
    [ -z "$SWARM_ID" ] || [ "$SWARM_ID" = "null" ] && SWARM_ID=$(curl -k -s -m 15 -H "Authorization: Bearer $TOKEN" "https://$PORTAINER_URL/api/endpoints/$ENDPOINT_ID/docker/swarm" | jq -r .ID)

    if [ ! -f "$(pwd)/${STACK_NAME}.yaml" ]; then
        echo "Erro: ${STACK_NAME}.yaml não encontrado"
        return 1
    fi

    http_code=$(curl -s -o /tmp/stack_response -w "%{http_code}" -k -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Host: $PORTAINER_URL" \
        -F "Name=$STACK_NAME" \
        -F "file=@$(pwd)/${STACK_NAME}.yaml" \
        -F "SwarmID=$SWARM_ID" \
        -F "endpointId=$ENDPOINT_ID" \
        "https://127.0.0.1/api/stacks/create/swarm/file")

    if [ "$http_code" -eq 200 ]; then
        echo -e "10/10 - [ OK ] - Deploy da stack ${verde}$STACK_NAME${reset} feito com sucesso!"
    else
        echo "10/10 - [ OFF ] - Erro ao fazer deploy. HTTP $http_code"
        return 1
    fi
}

## ============================================================================
## COLETA DE INFORMAÇÕES - TUDO NO INÍCIO
## ============================================================================

coletar_informacoes() {
    clear
    echo -e "${amarelo}====================================================================================================${reset}"
    echo -e "${amarelo}              SETUP PERSONALIZADO HUBLABEL v1.1 - Coleta de Informações (TUDO NO INÍCIO)               ${reset}"
    echo -e "${amarelo}====================================================================================================${reset}"
    echo ""
    echo -e "${branco}Informe todas as informações abaixo. Depois a instalação será feita automaticamente.${reset}"
    echo ""

    ## Email e domínio base
    read -p "Email para Let's Encrypt (ex: contato@seudominio.com): " email_ssl
    read -p "Domínio base (ex: victoreder.com.br): " dominio_base
    dominio_base="${dominio_base#https://}"
    dominio_base="${dominio_base#http://}"
    dominio_base="${dominio_base%%/*}"
    dominio_base="${dominio_base,,}"
    dominio_base="${dominio_base#www.}"
    echo ""
    echo -e "${branco}Agora informe apenas o subdomínio para cada serviço. Será usado: subdominio.$dominio_base${reset}"
    echo ""

    ## Traefik + Portainer
    echo -e "${verde}[1/4] Traefik e Portainer${reset}"
    read -p "Subdomínio do Portainer (ex: painel): " sub_portainer
    sub_portainer="${sub_portainer:-painel}"
    url_portainer="${sub_portainer}.${dominio_base}"
    user_portainer="admin"
    pass_portainer="EjGse3_0@t50OPo"
    dominio_sem_sufixo="${dominio_base%%.*}"
    nome_servidor="$dominio_sem_sufixo"
    nome_rede_interna="Rede$dominio_sem_sufixo"
    echo ""

    ## Evolution API
    echo -e "${verde}[2/4] Evolution API${reset}"
    read -p "Subdomínio da Evolution API (ex: evolution): " sub_evolution
    sub_evolution="${sub_evolution:-evolution}"
    url_evolution="${sub_evolution}.${dominio_base}"
    echo ""

    ## MinIO
    echo -e "${verde}[3/4] MinIO${reset}"
    read -p "Subdomínio do painel MinIO (ex: minio): " sub_minio
    sub_minio="${sub_minio:-minio}"
    url_minio="${sub_minio}.${dominio_base}"
    read -p "Subdomínio da API S3 (ex: s3): " sub_s3
    sub_s3="${sub_s3:-s3}"
    url_s3="${sub_s3}.${dominio_base}"
    user_minio="admin"
    senha_minio="EjGse3_0@t50OPo"
    minio_version="RELEASE.2024-01-13T07-53-03Z-cpuv1"
    echo ""

    ## N8N
    echo -e "${verde}[4/4] N8N${reset}"
    read -p "Subdomínio do N8N Editor (ex: n8n): " sub_n8n
    sub_n8n="${sub_n8n:-n8n}"
    url_editorn8n="${sub_n8n}.${dominio_base}"
    read -p "Subdomínio do Webhook N8N (ex: hook): " sub_webhook
    sub_webhook="${sub_webhook:-hook}"
    url_webhookn8n="${sub_webhook}.${dominio_base}"
    email_smtp_n8n="suporte@$dominio_base"
    usuario_smtp_n8n="suporte@$dominio_base"
    senha_smtp_n8n="123"
    host_smtp_n8n="smtp"
    porta_smtp_n8n="465"
    smtp_secure_smtp_n8n=true
    echo ""

    ## Remover barras ou caracteres extras
    url_portainer="${url_portainer%%/*}"
    url_evolution="${url_evolution%%/*}"
    url_minio="${url_minio%%/*}"
    url_s3="${url_s3%%/*}"
    url_editorn8n="${url_editorn8n%%/*}"
    url_webhookn8n="${url_webhookn8n%%/*}"

    ## Confirmação
    clear
    echo -e "${amarelo}====================================================================================================${reset}"
    echo -e "${branco}Verifique os dados:${reset}"
    echo "Portainer: https://$url_portainer | User: $user_portainer"
    echo "Evolution: https://$url_evolution"
    echo "MinIO: https://$url_minio | S3: https://$url_s3 | User: $user_minio"
    echo "N8N: https://$url_editorn8n | Webhook: https://$url_webhookn8n"
    echo -e "${amarelo}====================================================================================================${reset}"
    read -p "Confirmar e iniciar instalação? (Y/N): " conf
    [[ "${conf^^}" != "Y" ]] && { echo "Cancelado."; exit 1; }
}

## ============================================================================
## VERIFICAÇÕES INICIAIS (igual SetupOrion)
## ============================================================================

verificacoes_iniciais() {
    clear
    echo -e "${amarelo}Verificando ambiente...${reset}"

    if [ "$EUID" -ne 0 ]; then
        echo -e "${vermelho}Execute como root: sudo bash setuppersonalizado-hublabel.sh${reset}"
        exit 1
    fi

    if [ ! -f /etc/debian_version ]; then
        echo -e "${vermelho}Este instalador foi preparado para sistemas baseados em Debian/Ubuntu.${reset}"
        exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${vermelho}apt-get não encontrado.${reset}"
        exit 1
    fi

    recursos 1 1 || exit 1
    echo -e "${verde}✓ Verificações concluídas${reset}"
    echo ""
}

## ============================================================================
## INSTALAÇÃO TRAEFIK + PORTAINER
## ============================================================================

instalar_traefik_portainer() {
    echo -e "${amarelo}• Instalando Traefik e Portainer...${reset}"
    cd /root

    mkdir -p dados_vps
    cat > dados_vps/dados_vps <<EOL
[DADOS DA VPS]
Nome do Servidor: $nome_servidor
Rede interna: $nome_rede_interna
Email para SSL: $email_ssl
Link do Portainer: $url_portainer
EOL

    ## Atualizar VPS
    apt-get update -qq && apt upgrade -y -qq
    timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
    apt-get install -y -qq apt-utils apparmor-utils
    hostnamectl set-hostname "$nome_servidor" 2>/dev/null || true
    sed -i "s/127.0.0.1[[:space:]]localhost/127.0.0.1 $nome_servidor/" /etc/hosts 2>/dev/null || true

    ## Docker
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | bash
    fi
    systemctl enable docker
    systemctl start docker

    ## Swarm
    ip=$(hostname -I | awk '{print $1}')
    docker swarm init --advertise-addr "$ip" 2>/dev/null || true

    ## Rede e Volumes
    docker network create --driver=overlay "$nome_rede_interna" 2>/dev/null || true
    docker volume create volume_swarm_shared 2>/dev/null || true
    docker volume create volume_swarm_certificates 2>/dev/null || true
    docker volume create portainer_data 2>/dev/null || true

    ## Traefik (Python evita problema com backticks no heredoc)
    python3 - "$nome_rede_interna" "$email_ssl" << 'PYEOF'
import sys
rede = sys.argv[1]
email = sys.argv[2]
with open('/root/traefik.yaml', 'w') as f:
    f.write(f'''version: "3.7"
services:
  traefik:
    image: traefik:latest
    command:
      - "--api.dashboard=true"
      - "--providers.swarm=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--providers.swarm.network={rede}"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencryptresolver.acme.storage=/etc/traefik/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencryptresolver.acme.email={email}"
      - "--log.level=INFO"
    volumes:
      - vol_certificates:/etc/traefik/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [ {rede} ]
    ports:
      - target: 80
        published: 80
        mode: host
      - target: 443
        published: 443
        mode: host
    deploy:
      placement: {{ constraints: [node.role == manager] }}
      labels:
        - traefik.enable=true
        - traefik.http.middlewares.redirect-https.redirectscheme.scheme=https
        - traefik.http.middlewares.redirect-https.redirectscheme.permanent=true
        - "traefik.http.routers.http-catchall.rule=Host(`{{host:.+}}`)"
        - traefik.http.routers.http-catchall.entrypoints=web
        - traefik.http.routers.http-catchall.middlewares=redirect-https@swarm
        - traefik.http.routers.http-catchall.priority=1
volumes:
  vol_shared: {{ external: true, name: volume_swarm_shared }}
  vol_certificates: {{ external: true, name: volume_swarm_certificates }}
networks:
  {rede}: {{ external: true, attachable: true, name: {rede} }}
''')
PYEOF

    pull traefik:latest
    docker stack deploy --prune --resolve-image always -c traefik.yaml traefik
    wait_stack traefik_traefik
    wait_30_sec

    ## Portainer (Python evita problema com backticks no heredoc)
    python3 - "$url_portainer" "$nome_rede_interna" << 'PYEOF'
import sys
url = sys.argv[1]
rede = sys.argv[2]
with open('/root/portainer.yaml', 'w') as f:
    f.write(f'''version: "3.7"
services:
  agent:
    image: portainer/agent:latest
    volumes: [ /var/run/docker.sock:/var/run/docker.sock, /var/lib/docker/volumes:/var/lib/docker/volumes ]
    networks: [ {rede} ]
    deploy: {{ mode: global, placement: {{ constraints: [node.platform.os == linux] }} }}
  portainer:
    image: portainer/portainer-ce:latest
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes: [ portainer_data:/data ]
    networks: [ {rede} ]
    deploy:
      mode: replicated
      replicas: 1
      placement: {{ constraints: [node.role == manager] }}
      labels:
        - traefik.enable=true
        - traefik.http.routers.portainer.rule=Host(`{url}`)
        - traefik.http.services.portainer.loadbalancer.server.port=9000
        - traefik.http.routers.portainer.tls.certresolver=letsencryptresolver
        - traefik.http.routers.portainer.service=portainer
        - traefik.swarm.network={rede}
        - traefik.http.routers.portainer.entrypoints=websecure
        - traefik.http.routers.portainer.priority=1
volumes:
  portainer_data: {{ external: true, name: portainer_data }}
networks:
  {rede}: {{ external: true, attachable: true, name: {rede} }}
''')
PYEOF

    pull portainer/agent:latest portainer/portainer-ce:latest
    docker stack deploy --prune --resolve-image always -c portainer.yaml portainer
    wait_stack portainer_portainer
    sleep 30

    ## Criar conta Portainer (127.0.0.1 evita hairpin NAT)
    for i in 1 2 3 4 5; do
        resp=$(curl -k -s -X POST -H "Host: $url_portainer" -H "Content-Type: application/json" \
            -d "{\"Username\": \"$user_portainer\", \"Password\": \"$pass_portainer\"}" \
            "https://127.0.0.1/api/users/admin/init")
        if echo "$resp" | grep -q "\"Username\":\"$user_portainer\""; then
            break
        fi
        sleep 15
    done

    token=""
    for i in 1 2 3 4 5; do
        token=$(curl -k -s -X POST -H "Host: $url_portainer" -H "Content-Type: application/json" \
            -d "{\"username\":\"$user_portainer\",\"password\":\"$pass_portainer\"}" \
            "https://127.0.0.1/api/auth" | jq -r .jwt)
        [ -n "$token" ] && [ "$token" != "null" ] && break
        sleep 10
    done

    mkdir -p dados_vps
    echo -e "[ PORTAINER ]\nDominio do portainer: https://$url_portainer\nUsuario: $user_portainer\nSenha: $pass_portainer\nToken: $token" > dados_vps/dados_portainer

    dados
    echo -e "${verde}✓ Traefik e Portainer instalados${reset}"
}

## ============================================================================
## INSTALAÇÃO POSTGRESQL
## ============================================================================

instalar_postgres() {
    echo -e "${amarelo}• Instalando PostgreSQL...${reset}"
    cd /root
    dados

    senha_postgres=$(openssl rand -hex 16)
    docker volume create postgres_data 2>/dev/null || true

    python3 - "$nome_rede_interna" "$senha_postgres" << 'PYEOF'
import sys
rede, pgpass = sys.argv[1], sys.argv[2]
with open('/root/postgres.yaml', 'w') as f:
    f.write(f'''version: "3.7"
services:
  postgres:
    image: postgres:14
    command: postgres -c max_connections=500 -c timezone=America/Sao_Paulo
    volumes: [ postgres_data:/var/lib/postgresql/data ]
    networks: [ {rede} ]
    environment:
      POSTGRES_PASSWORD: {pgpass}
      TZ: America/Sao_Paulo
    deploy:
      mode: replicated
      replicas: 1
      placement: {{ constraints: [node.role == manager] }}
volumes:
  postgres_data: {{ external: true, name: postgres_data }}
networks:
  {rede}: {{ external: true, name: {rede} }}
''')
PYEOF

    STACK_NAME="postgres"
    stack_editavel
    wait_stack postgres_postgres
    echo "$senha_postgres" > /root/.senha_postgres_tmp
    echo -e "${verde}✓ PostgreSQL instalado${reset}"
}

## ============================================================================
## INSTALAÇÃO EVOLUTION API
## ============================================================================

instalar_evolution() {
    echo -e "${amarelo}• Instalando Evolution API...${reset}"
    cd /root
    dados

    pegar_senha_postgres
    apikeyglobal=$(openssl rand -hex 16)

    docker volume create evolution_instances 2>/dev/null || true
    docker volume create evolution_redis 2>/dev/null || true

    criar_banco_postgres_da_stack evolution

    python3 - "$nome_rede_interna" "$url_evolution" "$apikeyglobal" "$senha_postgres" << 'PYEOF'
import sys
rede, url, apikey, pgpass = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open('/root/evolution.yaml', 'w') as f:
    f.write(f'''version: "3.7"
services:
  evolution_api:
    image: evoapicloud/evolution-api:latest
    volumes: [ evolution_instances:/evolution/instances ]
    networks: [ {rede} ]
    environment:
      SERVER_URL: https://{url}
      AUTHENTICATION_API_KEY: {apikey}
      AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES: "true"
      LANGUAGE: pt-BR
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://postgres:{pgpass}@postgres:5432/evolution
      DATABASE_CONNECTION_CLIENT_NAME: evolution
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://evolution_redis:6379/1
      CACHE_LOCAL_ENABLED: "false"
      N8N_ENABLED: "true"
      TZ: America/Sao_Paulo
    deploy:
      mode: replicated
      replicas: 1
      placement: {{ constraints: [node.role == manager] }}
      labels:
        - traefik.enable=true
        - traefik.http.routers.evolution.rule=Host(`{url}`)
        - traefik.http.routers.evolution.entrypoints=websecure
        - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
        - traefik.http.services.evolution.loadbalancer.server.port=8080
  evolution_redis:
    image: redis:latest
    command: [ "redis-server", "--appendonly", "yes", "--port", "6379" ]
    volumes: [ evolution_redis:/data ]
    networks: [ {rede} ]
    deploy: {{ placement: {{ constraints: [node.role == manager] }} }}
volumes:
  evolution_instances: {{ external: true, name: evolution_instances }}
  evolution_redis: {{ external: true, name: evolution_redis }}
networks:
  {rede}: {{ external: true, name: {rede} }}
''')
PYEOF

    STACK_NAME="evolution"
    stack_editavel
    echo -e "${verde}✓ Evolution API instalada | API Key: $apikeyglobal${reset}"
}

## ============================================================================
## INSTALAÇÃO MINIO
## ============================================================================

instalar_minio() {
    echo -e "${amarelo}• Instalando MinIO...${reset}"
    cd /root
    dados

    docker volume create minio_data 2>/dev/null || true

    python3 - "$nome_rede_interna" "$minio_version" "$user_minio" "$senha_minio" "$url_minio" "$url_s3" << 'PYEOF'
import sys
rede, ver, user, pwd, url_minio, url_s3 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
with open('/root/minio.yaml', 'w') as f:
    f.write(f'''version: "3.7"
services:
  minio:
    image: quay.io/minio/minio:{ver}
    command: server /data --console-address ":9001"
    volumes: [ minio_data:/data ]
    networks: [ {rede} ]
    environment:
      MINIO_ROOT_USER: {user}
      MINIO_ROOT_PASSWORD: {pwd}
      MINIO_BROWSER_REDIRECT_URL: https://{url_minio}
      MINIO_SERVER_URL: https://{url_s3}
      MINIO_REGION_NAME: eu-south
    deploy:
      mode: replicated
      replicas: 1
      placement: {{ constraints: [node.role == manager] }}
      labels:
        - traefik.enable=true
        - traefik.http.routers.minio_public.rule=Host(`{url_s3}`)
        - traefik.http.routers.minio_public.entrypoints=websecure
        - traefik.http.routers.minio_public.tls.certresolver=letsencryptresolver
        - traefik.http.services.minio_public.loadbalancer.server.port=9000
        - traefik.http.routers.minio_console.rule=Host(`{url_minio}`)
        - traefik.http.routers.minio_console.entrypoints=websecure
        - traefik.http.routers.minio_console.tls.certresolver=letsencryptresolver
        - traefik.http.services.minio_console.loadbalancer.server.port=9001
volumes:
  minio_data: {{ external: true, name: minio_data }}
networks:
  {rede}: {{ external: true, name: {rede} }}
''')
PYEOF

    STACK_NAME="minio"
    stack_editavel
    echo -e "${verde}✓ MinIO instalado${reset}"
}

## ============================================================================
## INSTALAÇÃO N8N
## ============================================================================

instalar_n8n() {
    echo -e "${amarelo}• Instalando N8N...${reset}"
    cd /root
    dados

    pegar_senha_postgres
    encryption_key=$(openssl rand -hex 16)
    criar_banco_postgres_da_stack n8n_queue

    docker volume create n8n_redis 2>/dev/null || true

    python3 - "$nome_rede_interna" "$senha_postgres" "$encryption_key" "$url_editorn8n" "$url_webhookn8n" \
        "$email_smtp_n8n" "$usuario_smtp_n8n" "$senha_smtp_n8n" "$host_smtp_n8n" "$porta_smtp_n8n" "$smtp_secure_smtp_n8n" << 'PYEOF'
import sys
a = sys.argv
rede, pgpass, enc, url_ed, url_wh = a[1], a[2], a[3], a[4], a[5]
smtp_sender, smtp_user, smtp_pass, smtp_host, smtp_port, smtp_ssl = a[6], a[7], a[8], a[9], a[10], a[11]
with open('/root/n8n.yaml', 'w') as f:
    f.write(f'''version: "3.7"
services:
  n8n_editor:
    image: n8nio/n8n:latest
    command: start
    networks: [ {rede} ]
    environment:
      N8N_FIX_MIGRATIONS: "true"
      DB_TYPE: postgresdb
      DB_POSTGRESDB_DATABASE: n8n_queue
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD: {pgpass}
      N8N_ENCRYPTION_KEY: {enc}
      N8N_HOST: {url_ed}
      N8N_EDITOR_BASE_URL: https://{url_ed}/
      WEBHOOK_URL: https://{url_wh}/
      N8N_PROTOCOL: https
      N8N_PROXY_HOPS: 1
      N8N_ONBOARDING_FLOW_DISABLED: "true"
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: n8n_redis
      QUEUE_BULL_REDIS_PORT: 6379
      N8N_SMTP_SENDER: {smtp_sender}
      N8N_SMTP_USER: {smtp_user}
      N8N_SMTP_PASS: {smtp_pass}
      N8N_SMTP_HOST: {smtp_host}
      N8N_SMTP_PORT: {smtp_port}
      N8N_SMTP_SSL: {smtp_ssl}
      TZ: America/Sao_Paulo
    deploy:
      mode: replicated
      replicas: 1
      placement: {{ constraints: [node.role == manager] }}
      labels:
        - traefik.enable=true
        - traefik.http.routers.n8n_editor.rule=Host(`{url_ed}`)
        - traefik.http.routers.n8n_editor.entrypoints=websecure
        - traefik.http.routers.n8n_editor.tls.certresolver=letsencryptresolver
        - traefik.http.services.n8n_editor.loadbalancer.server.port=5678
  n8n_webhook:
    image: n8nio/n8n:latest
    command: webhook
    networks: [ {rede} ]
    environment:
      N8N_FIX_MIGRATIONS: "true"
      DB_TYPE: postgresdb
      DB_POSTGRESDB_DATABASE: n8n_queue
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD: {pgpass}
      N8N_ENCRYPTION_KEY: {enc}
      N8N_HOST: {url_ed}
      WEBHOOK_URL: https://{url_wh}/
      N8N_PROTOCOL: https
      QUEUE_BULL_REDIS_HOST: n8n_redis
      N8N_SMTP_SENDER: {smtp_sender}
      N8N_SMTP_USER: {smtp_user}
      N8N_SMTP_PASS: {smtp_pass}
      N8N_SMTP_HOST: {smtp_host}
      N8N_SMTP_PORT: {smtp_port}
      N8N_SMTP_SSL: {smtp_ssl}
      TZ: America/Sao_Paulo
    deploy:
      mode: replicated
      replicas: 1
      placement: {{ constraints: [node.role == manager] }}
      labels:
        - traefik.enable=true
        - traefik.http.routers.n8n_webhook.rule=Host(`{url_wh}`)
        - traefik.http.routers.n8n_webhook.entrypoints=websecure
        - traefik.http.routers.n8n_webhook.tls.certresolver=letsencryptresolver
        - traefik.http.services.n8n_webhook.loadbalancer.server.port=5678
  n8n_worker:
    image: n8nio/n8n:latest
    command: worker --concurrency=10
    networks: [ {rede} ]
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_DATABASE: n8n_queue
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PASSWORD: {pgpass}
      N8N_ENCRYPTION_KEY: {enc}
      QUEUE_BULL_REDIS_HOST: n8n_redis
      TZ: America/Sao_Paulo
    deploy: {{ mode: replicated, replicas: 1, placement: {{ constraints: [node.role == manager] }} }}
  n8n_redis:
    image: redis:latest
    command: [ "redis-server", "--appendonly", "yes", "--port", "6379" ]
    volumes: [ n8n_redis:/data ]
    networks: [ {rede} ]
    deploy: {{ placement: {{ constraints: [node.role == manager] }} }}
volumes:
  n8n_redis: {{ external: true, name: n8n_redis }}
networks:
  {rede}: {{ external: true, name: {rede} }}
''')
PYEOF

    STACK_NAME="n8n"
    stack_editavel
    echo -e "${verde}✓ N8N instalado${reset}"
}

## ============================================================================
## RESUMO FINAL
## ============================================================================

resumo_final() {
    clear
    echo -e "${verde}====================================================================================================${reset}"
    echo -e "${verde}                    INSTALAÇÃO CONCLUÍDA COM SUCESSO!                                                ${reset}"
    echo -e "${verde}====================================================================================================${reset}"
    echo ""
    echo "Acessos:"
    echo "  • Portainer:    https://$url_portainer  (User: $user_portainer)"
    echo "  • Evolution:    https://$url_evolution"
    echo "  • MinIO:        https://$url_minio  |  S3: https://$url_s3  (User: $user_minio)"
    echo "  • N8N Editor:   https://$url_editorn8n"
    echo "  • N8N Webhook:  https://$url_webhookn8n"
    echo ""
    echo "Arquivos de configuração em /root/"
    echo "Dados da VPS em /root/dados_vps/"
    echo ""
}

## ============================================================================
## MAIN
## ============================================================================

main() {
    coletar_informacoes
    verificacoes_iniciais
    instalar_traefik_portainer
    instalar_postgres
    instalar_evolution
    instalar_minio
    instalar_n8n
    resumo_final
}

main "$@"
