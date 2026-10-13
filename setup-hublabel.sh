#!/usr/bin/env bash

## ============================================================================
## SETUP HUBLABEL v2.0
## Instala: HubLabel Disparador (tudo em um) + Redis, Evolution API (+ Postgres
## e Redis) e MinIO (S3). Sem N8N e sem Portainer.
##
## Funciona em VPS zerada e em VPS que já tem outro sistema:
##   - VPS zerada ............... Docker + Caddy (HTTPS automático)
##   - Traefik (Portainer, EasyPanel, Coolify, Dokploy...) ... usa o Traefik que já existe
##   - Outro proxy (nginx...) ... sobe sem proxy e mostra o que apontar
##
## COMANDO (como root):
##   bash <(curl -sSL https://raw.githubusercontent.com/victoreder/setup-hublabel/main/setup-hublabel.sh)
##
## Rodar de novo atualiza a instalação (as configurações ficam em /opt/hublabel).
## ============================================================================

set -uo pipefail

VERSAO="2.0"
DIR="/opt/hublabel"
ENV_FILE="$DIR/.env"
PROJETO="hublabel"
LICENCA_URL="https://licencas.hublabel.com.br"

IMG_APP="ghcr.io/victoreder/hublabel-disparador:latest"
IMG_REDIS="redis:7-alpine"
IMG_EVOLUTION="evoapicloud/evolution-api:latest"
IMG_POSTGRES="postgres:14"
IMG_MINIO="ghcr.io/victoreder/minio:RELEASE.2024-01-13T07-53-03Z"
IMG_CADDY="caddy:2-alpine"

S3_BUCKET="n8n"
SENHA_PADRAO_INTEGRACAO="Padrao123456"
## Tabelas conferidas depois do SQL (FollowupExecucao fica no fim do arquivo)
TABELAS_SQL=(SAAS_Contas SAAS_Usuarios FollowupExecucao)

amarelo="\e[33m"
verde="\e[32m"
branco="\e[97m"
vermelho="\e[91m"
ciano="\e[36m"
cinza="\e[90m"
reset="\e[0m"

## Lê do terminal mesmo quando o script vem por "curl | bash"
TTY=/dev/tty
{ : </dev/tty; } 2>/dev/null || TTY=/dev/stdin

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

## ============================================================================
## UTILITÁRIOS
## ============================================================================

info()  { echo -e "${amarelo}• $*${reset}"; }
ok()    { echo -e "${verde}✔ $*${reset}"; }
aviso() { echo -e "${amarelo}! $*${reset}"; }
falha() { echo -e "${vermelho}✘ $*${reset}"; }
erro()  { falha "$*"; exit 1; }

banner() {
    clear
    echo ""
    echo -e "${branco}  ██╗  ██╗██╗   ██╗██████╗ ██╗      █████╗ ██████╗ ███████╗██╗     ${reset}"
    echo -e "${branco}  ██║  ██║██║   ██║██╔══██╗██║     ██╔══██╗██╔══██╗██╔════╝██║     ${reset}"
    echo -e "${branco}  ███████║██║   ██║██████╔╝██║     ███████║██████╔╝█████╗  ██║     ${reset}"
    echo -e "${branco}  ██╔══██║██║   ██║██╔══██╗██║     ██╔══██║██╔══██╗██╔══╝  ██║     ${reset}"
    echo -e "${branco}  ██║  ██║╚██████╔╝██████╔╝███████╗██║  ██║██████╔╝███████╗███████╗${reset}"
    echo -e "${branco}  ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚══════╝${reset}"
    echo ""
    echo -e "${amarelo}====================================================================================${reset}"
    echo -e "${amarelo}                          INSTALADOR HUBLABEL V${VERSAO}${reset}"
    echo -e "${amarelo}====================================================================================${reset}"
    echo ""
}

## cabecalho_passo N TOTAL "Título"
cabecalho_passo() {
    banner
    echo -e "${ciano}Passo $1 de $2 — $3${reset}"
    echo -e "${cinza}(digite 0 e aperte Enter para voltar à etapa anterior)${reset}"
    echo ""
}

## Remove \r, espaços nas pontas e aspas em volta (comum ao copiar e colar)
limpar() {
    local v="$1"
    v="${v//$'\r'/}"
    v="$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    printf '%s' "$v"
}

## perguntar VAR "texto" [padrão] → retorna 1 se a pessoa digitou 0 (voltar)
perguntar() {
    local __var="$1" __texto="$2" __padrao="${3:-}" __v
    while :; do
        if [ -n "$__padrao" ]; then
            printf '%b' "${branco}${__texto}${reset} [${__padrao}]: "
        else
            printf '%b' "${branco}${__texto}${reset}: "
        fi
        ler __v
        __v="$(limpar "$__v")"
        [ "$__v" = "0" ] && return 1
        __v="${__v:-$__padrao}"
        [ -n "$__v" ] && break
        aviso "Este campo é obrigatório."
    done
    printf -v "$__var" '%s' "$__v"
}

## sim_nao "pergunta" S|N → 0 = sim, 1 = não, 2 = voltar (0)
sim_nao() {
    local resp padrao="${2:-S}"
    while :; do
        printf '%b' "${branco}$1${reset} ($([ "$padrao" = S ] && echo 'S/n' || echo 's/N')): "
        ler resp
        resp="$(limpar "$resp")"
        [ "$resp" = "0" ] && return 2
        resp="${resp:-$padrao}"
        case "$resp" in
            [sSyY]*) return 0 ;;
            [nN]*) return 1 ;;
        esac
        aviso "Responda S ou N."
    done
}

enter() {
    printf '%b' "${cinza}${1:-Aperte Enter para continuar...}${reset}"
    local _r; ler _r
}

## Lê uma linha do terminal; se o terminal fechar, encerra em vez de ficar em loop
ler() {
    IFS= read -r "$1" <"$TTY" || { echo; erro "Entrada encerrada. Rode o setup de novo."; }
}

aleatorio() { head -c "${1:-16}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

porta_em_uso() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
    else
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
    fi
}

porta_livre_a_partir_de() {
    local p="$1"
    while porta_em_uso "$p"; do p=$((p + 1)); done
    echo "$p"
}

ip_da_vps() {
    local ip=""
    for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip="$(curl -fsS4 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
    hostname -I 2>/dev/null | awk '{print $1}'
}

ip_do_dominio() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

## Campo de um JWT (sem validar assinatura): jwt_campo TOKEN campo
jwt_campo() {
    local p
    p="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
    case $((${#p} % 4)) in 2) p="$p==" ;; 3) p="$p=" ;; esac
    printf '%s' "$p" | base64 -d 2>/dev/null | sed -n "s/.*\"$2\" *: *\"\([^\"]*\)\".*/\1/p"
}

## Cabeçalhos de autenticação do Supabase (chave nova sb_... vai só no apikey)
supabase_curl() { # supabase_curl CHAVE URL → código HTTP (corpo em $TMP/resp)
    local chave="$1" url="$2"
    if [[ "$chave" == sb_* ]]; then
        curl -s -o "$TMP/resp" -w '%{http_code}' --max-time 20 -H "apikey: $chave" "$url"
    else
        curl -s -o "$TMP/resp" -w '%{http_code}' --max-time 20 -H "apikey: $chave" -H "Authorization: Bearer $chave" "$url"
    fi
}

## ============================================================================
## DETECÇÃO DO AMBIENTE DA VPS
## ============================================================================
## Define:
##   MODO_DEPLOY = compose | stack     (docker compose ou docker stack deploy)
##   MODO_ROTA   = caddy | labels | file | manual
##   PAINEL      = nome amigável do que foi encontrado

## Lê a configuração de um Traefik (serviço do Swarm ou container) e imprime
## variáveis TRAEFIK_* para o shell.
analisar_traefik() { # analisar_traefik service|container NOME
    docker "$([ "$1" = service ] && echo service || echo container)" inspect "$2" >"$TMP/traefik.json" 2>/dev/null || return 1
    python3 - "$1" "$TMP/traefik.json" <<'PYEOF'
import json, re, subprocess, sys, os

tipo, arq = sys.argv[1], sys.argv[2]
d = json.load(open(arq))[0]

if tipo == "service":
    cs = d["Spec"]["TaskTemplate"]["ContainerSpec"]
    args = (cs.get("Command") or []) + (cs.get("Args") or [])
    mounts = [(m.get("Source"), m.get("Target")) for m in (cs.get("Mounts") or []) if m.get("Type") == "bind"]
    redes = []
    for n in d["Spec"]["TaskTemplate"].get("Networks") or []:
        try:
            nome = subprocess.run(["docker", "network", "inspect", "-f", "{{.Name}}", n["Target"]],
                                  capture_output=True, text=True).stdout.strip()
        except Exception:
            nome = ""
        if nome:
            redes.append(nome)
else:
    args = [d.get("Path", "")] + (d.get("Args") or [])
    mounts = [(m.get("Source"), m.get("Destination")) for m in (d.get("Mounts") or []) if m.get("Type") == "bind"]
    redes = list((d.get("NetworkSettings") or {}).get("Networks", {}).keys())

def no_host(caminho):
    """Converte um caminho de dentro do container para o caminho na VPS."""
    melhor = None
    for src, dst in mounts:
        if dst and (caminho == dst or caminho.startswith(dst.rstrip("/") + "/")):
            if melhor is None or len(dst) > len(melhor[1]):
                melhor = (src, dst)
    if not melhor:
        return ""
    return melhor[0] + caminho[len(melhor[1].rstrip("/")):]

a = "\n".join(args)
al = a.lower()

## Arquivo de configuração estática (traefik.yml / .toml)
texto = ""
cfg = re.search(r"--configfile[= ](\S+)", a, re.I)
candidatos = [cfg.group(1)] if cfg else ["/etc/traefik/traefik.yml", "/etc/traefik/traefik.yaml", "/etc/traefik/traefik.toml",
                                         "/traefik.yml", "/traefik.yaml", "/traefik.toml"]
for c in candidatos:
    h = no_host(c)
    if h and os.path.isfile(h):
        texto = open(h, errors="ignore").read()
        break
if not texto and os.path.isdir("/etc/easypanel/traefik"):
    for raiz, _, arquivos in os.walk("/etc/easypanel/traefik"):
        for f in arquivos:
            if f in ("traefik.yml", "traefik.yaml", "traefik.toml", "static.yaml", "static.yml"):
                texto += open(os.path.join(raiz, f), errors="ignore").read() + "\n"
tl = texto.lower()

def primeiro(padroes, s, flags=re.M):
    for p in padroes:
        m = re.search(p, s, flags)
        if m:
            return m.group(1)
    return ""

resolver = primeiro([r"--certificatesresolvers\.([^.=\s]+)\."], a, re.I) or \
    primeiro([r"^\s*certificatesresolvers:\s*\n\s+([A-Za-z0-9_-]+):", r"\[certificatesresolvers\.([A-Za-z0-9_-]+)"], texto, re.M | re.I)

entrada = primeiro([r"--entrypoints\.([^.=\s]+)\.address=[^\s]*:443\b"], a, re.I) or \
    primeiro([r"^\s*([A-Za-z0-9_-]+):\s*\n\s+address:\s*[\"']?[^\"'\n]*:443[\"']?",
              r"\[entrypoints\.([A-Za-z0-9_-]+)\]\s*\n\s*address\s*=\s*\"[^\"]*:443\""], texto, re.M | re.I)

swarm = "--providers.swarm" in al or re.search(r"^\s*swarm:\s*$", tl, re.M) is not None or "[providers.swarm]" in tl
docker = "--providers.docker" in al or re.search(r"^\s*docker:\s*$", tl, re.M) is not None or "[providers.docker]" in tl
rede = primeiro([r"--providers\.(?:swarm|docker)\.network=(\S+)"], a, re.I) or \
    primeiro([r"^\s*network:\s*[\"']?([A-Za-z0-9_.-]+)", r"^\s*network\s*=\s*\"([A-Za-z0-9_.-]+)\""], texto, re.M)
pasta = primeiro([r"--providers\.file\.directory=(\S+)"], a, re.I) or \
    primeiro([r"^\s*directory:\s*[\"']?([^\"'\s]+)", r"^\s*directory\s*=\s*\"([^\"]+)\""], texto, re.M)

if not rede:
    for r in redes:
        if r not in ("ingress", "bridge", "host", "none", "docker_gwbridge"):
            rede = r
            break

if swarm:
    rota, label = "labels", "traefik.swarm.network"
elif docker:
    rota, label = "labels", "traefik.docker.network"
elif pasta:
    rota, label = "file", ""
else:
    ## Sem nada declarado: o padrão do Traefik em Swarm (v3) ou container
    rota = "labels"
    label = "traefik.swarm.network" if tipo == "service" else "traefik.docker.network"

pasta_host = no_host(pasta) if pasta else ""

def seguro(v):
    return re.sub(r"[^A-Za-z0-9_.:/@-]", "", v or "")

print(f"TRAEFIK_RESOLVER='{seguro(resolver)}'")
print(f"TRAEFIK_ENTRYPOINT='{seguro(entrada) or 'websecure'}'")
print(f"TRAEFIK_REDE='{seguro(rede)}'")
print(f"TRAEFIK_LABEL_REDE='{seguro(label)}'")
print(f"TRAEFIK_PASTA_ARQUIVOS='{seguro(pasta_host)}'")
print(f"TRAEFIK_ROTA='{rota}'")
PYEOF
}

detectar_ambiente() {
    MODO_DEPLOY="compose"
    MODO_ROTA="caddy"
    PAINEL="VPS zerada"
    TRAEFIK_RESOLVER=""; TRAEFIK_ENTRYPOINT=""; TRAEFIK_REDE=""; TRAEFIK_LABEL_REDE=""
    TRAEFIK_PASTA_ARQUIVOS=""; TRAEFIK_ROTA=""
    HUBLABEL_V18=0

    local tem_docker=0 alvo="" tipo=""
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && tem_docker=1

    if [ "$tem_docker" = 1 ]; then
        ## Instalação antiga do HubLabel (v1.8 com N8N)
        docker service ls --format '{{.Name}}' 2>/dev/null | grep -Eq '^(disparador_disparador-inbound|n8n_n8n_editor)$' && HUBLABEL_V18=1

        ## Traefik rodando como serviço do Swarm?
        alvo="$(docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /traefik/ {print $1; exit}')"
        if [ -n "$alvo" ]; then
            tipo="service"
        else
            alvo="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /traefik/ && $1 !~ /^hublabel/ {print $1; exit}')"
            [ -n "$alvo" ] && tipo="container"
        fi
    fi

    ## Nome do painel (só para mostrar)
    local nome=""
    if [ -d /etc/easypanel ] || { [ "$tem_docker" = 1 ] && docker service ls --format '{{.Name}}' 2>/dev/null | grep -qi easypanel; }; then
        nome="EasyPanel"
    elif [ -d /data/coolify ]; then
        nome="Coolify"
    elif [ -d /etc/dokploy ]; then
        nome="Dokploy"
    elif [ "$tem_docker" = 1 ] && docker ps --format '{{.Image}}' 2>/dev/null | grep -qi portainer; then
        nome="Portainer"
    fi

    if [ -n "$tipo" ]; then
        local saida
        if saida="$(analisar_traefik "$tipo" "$alvo")"; then
            eval "$saida"
        fi
        if [ -z "$TRAEFIK_REDE" ] || { [ "$TRAEFIK_ROTA" = file ] && [ -z "$TRAEFIK_PASTA_ARQUIVOS" ]; }; then
            MODO_ROTA="manual"
        else
            MODO_ROTA="$TRAEFIK_ROTA"
        fi
        [ "$tipo" = service ] && MODO_DEPLOY="stack" || MODO_DEPLOY="compose"
        ## Container comum não entra em rede overlay que não é "attachable": usa stack nesse caso
        if [ "$MODO_DEPLOY" = compose ] && [ -n "$TRAEFIK_REDE" ] \
            && [ "$(docker network inspect -f '{{.Driver}} {{.Attachable}}' "$TRAEFIK_REDE" 2>/dev/null)" = "overlay false" ]; then
            MODO_DEPLOY="stack"
        fi
        PAINEL="${nome:+$nome + }Traefik"
        return
    fi

    if porta_em_uso 80 || porta_em_uso 443; then
        MODO_ROTA="manual"
        MODO_DEPLOY="compose"
        local quem=""
        quem="$(ss -ltnpH 2>/dev/null | grep -E '[:.](80|443) ' | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
        PAINEL="${nome:-${quem:-outro sistema}} (portas 80/443 já em uso)"
        return
    fi

    [ -n "$nome" ] && PAINEL="$nome (sem proxy nas portas 80/443)"
}

descrever_ambiente() {
    echo -e "${branco}Ambiente detectado:${reset} ${verde}$PAINEL${reset}"
    case "$MODO_ROTA" in
        caddy)  echo "  O sistema será instalado com Docker e HTTPS automático (Caddy). Sem Portainer." ;;
        labels) echo "  Vou usar o Traefik que já existe nesta VPS (rede: $TRAEFIK_REDE${TRAEFIK_RESOLVER:+, certificado: $TRAEFIK_RESOLVER})." ;;
        file)   echo "  Vou cadastrar os domínios no Traefik que já existe nesta VPS (rede: $TRAEFIK_REDE)." ;;
        manual) echo "  Esta VPS já tem um proxy nas portas 80/443 que eu não consigo configurar sozinho."
                echo "  Vou instalar tudo e, no final, mostrar para qual porta apontar cada domínio no seu painel." ;;
    esac
    if [ "$HUBLABEL_V18" = 1 ]; then
        echo ""
        aviso "Esta VPS já tem o HubLabel antigo (v1.8 com N8N)."
        aviso "Esta instalação é separada: use subdomínios diferentes e um Supabase diferente do atual."
    fi
}

## ============================================================================
## ASSISTENTE (PERGUNTAS)
## ============================================================================

TOTAL_PASSOS=5

passo_dominios() {
    cabecalho_passo 1 $TOTAL_PASSOS "Domínios"
    echo "Informe o domínio principal da sua empresa (sem https://)."
    echo -e "${cinza}Exemplo: suaempresa.com.br${reset}"
    echo ""
    perguntar DOMINIO_BASE "Domínio principal" "${DOMINIO_BASE:-}" || return 1
    DOMINIO_BASE="${DOMINIO_BASE,,}"
    DOMINIO_BASE="${DOMINIO_BASE#http://}"; DOMINIO_BASE="${DOMINIO_BASE#https://}"
    DOMINIO_BASE="${DOMINIO_BASE%%/*}"; DOMINIO_BASE="${DOMINIO_BASE#www.}"
    if ! [[ "$DOMINIO_BASE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        falha "Domínio inválido: $DOMINIO_BASE"
        enter
        passo_dominios; return
    fi

    echo ""
    echo "Endereços que serão usados:"
    echo -e "  Sistema (aplicativo): ${verde}${SUB_APP:-app}.$DOMINIO_BASE${reset}"
    echo -e "  WhatsApp (Evolution): ${verde}${SUB_EVO:-wpp}.$DOMINIO_BASE${reset}"
    echo -e "  Arquivos (S3):        ${verde}${SUB_S3:-s3}.$DOMINIO_BASE${reset}"
    echo ""
    sim_nao "Usar esses endereços?" S
    case $? in
        2) return 1 ;;
        0) SUB_APP="${SUB_APP:-app}"; SUB_EVO="${SUB_EVO:-wpp}"; SUB_S3="${SUB_S3:-s3}" ;;
        1)
            echo ""
            echo "Digite só a primeira parte (ex.: app)."
            perguntar SUB_APP "Subdomínio do sistema" "${SUB_APP:-app}" || return 1
            perguntar SUB_EVO "Subdomínio da Evolution" "${SUB_EVO:-wpp}" || return 1
            perguntar SUB_S3 "Subdomínio do S3" "${SUB_S3:-s3}" || return 1
            SUB_APP="${SUB_APP%%.*}"; SUB_EVO="${SUB_EVO%%.*}"; SUB_S3="${SUB_S3%%.*}"
            SUB_APP="${SUB_APP,,}"; SUB_EVO="${SUB_EVO,,}"; SUB_S3="${SUB_S3,,}"
            ;;
    esac
    APP_HOST="$SUB_APP.$DOMINIO_BASE"
    EVO_HOST="$SUB_EVO.$DOMINIO_BASE"
    S3_HOST="$SUB_S3.$DOMINIO_BASE"
    if [ "$APP_HOST" = "$EVO_HOST" ] || [ "$APP_HOST" = "$S3_HOST" ] || [ "$EVO_HOST" = "$S3_HOST" ]; then
        falha "Os três subdomínios precisam ser diferentes."
        enter
        passo_dominios; return
    fi
    verificar_dns
}

verificar_dns() {
    local ip_vps tudo_ok resp h ip
    ip_vps="$(ip_da_vps)"
    while :; do
        echo ""
        echo -e "${branco}Conferindo o DNS (registros tipo A apontando para ${ip_vps:-esta VPS})...${reset}"
        tudo_ok=1
        for h in "$APP_HOST" "$EVO_HOST" "$S3_HOST"; do
            ip="$(ip_do_dominio "$h")"
            if [ -n "$ip" ] && { [ -z "$ip_vps" ] || [ "$ip" = "$ip_vps" ]; }; then
                echo -e "  ${verde}✔${reset} $h → $ip"
            else
                echo -e "  ${vermelho}✘${reset} $h → ${ip:-não encontrado}"
                tudo_ok=0
            fi
        done
        [ "$tudo_ok" = 1 ] && { echo ""; ok "DNS certo."; sleep 1; return 0; }
        echo ""
        echo "No painel do seu domínio (Registro.br, Cloudflare, Hostinger...), crie um registro"
        echo -e "tipo ${branco}A${reset} para cada endereço com ✘, apontando para ${branco}${ip_vps:-o IP desta VPS}${reset}."
        echo -e "${cinza}Usa Cloudflare? Deixe a nuvem cinza (\"somente DNS\").${reset}"
        echo -e "${cinza}A mudança pode levar alguns minutos para valer.${reset}"
        echo ""
        printf '%b' "${branco}Enter${reset} = conferir de novo  |  ${branco}C${reset} = continuar mesmo assim  |  ${branco}0${reset} = voltar e corrigir: "
        ler resp
        resp="$(limpar "$resp")"
        case "$resp" in
            0) passo_dominios; return ;;
            [cC]*) aviso "Sem o DNS certo o HTTPS não funciona. Corrija assim que puder."; sleep 2; return 0 ;;
        esac
    done
}

## Deixa só https://host (tira /rest/v1, /auth/v1, barras, espaços...)
normalizar_supabase_url() {
    local u
    u="$(limpar "$1")"
    u="${u,,}"
    u="${u%%\?*}"; u="${u%%#*}"
    [[ "$u" =~ ^https?:// ]] || u="https://$u"
    u="$(printf '%s' "$u" | sed -E 's#^(https?://[^/]+).*#\1#')"
    case "$u" in
        https://*:443) u="${u%:443}" ;;
        http://*:80) u="${u%:80}" ;;
    esac
    printf '%s' "$u"
}

## Host como o sistema calcula para a licença (porta padrão some)
host_instalacao() {
    local h="${1#*://}"
    case "$1" in
        https://*) h="${h%:443}" ;;
        http://*)  h="${h%:80}" ;;
    esac
    printf '%s' "$h"
}

ref_supabase() {
    local h
    h="$(host_instalacao "$SUPABASE_URL")"
    [[ "$h" == *.supabase.co ]] && printf '%s' "${h%%.*}"
}

passo_supabase_url() {
    cabecalho_passo 2 $TOTAL_PASSOS "Supabase"
    echo "Abra o seu projeto no Supabase e vá em:"
    echo -e "  ${branco}Project Settings → API${reset}  (ou o botão ${branco}Connect${reset} no topo)"
    echo ""
    echo -e "Copie a ${branco}Project URL${reset}. Ela parece com: https://abcdefgh.supabase.co"
    echo ""
    local u codigo
    perguntar u "Project URL" "${SUPABASE_URL:-}" || return 1
    SUPABASE_URL="$(normalizar_supabase_url "$u")"
    [ "$SUPABASE_URL" != "$(limpar "$u")" ] && echo -e "${cinza}  Ajustei para: $SUPABASE_URL${reset}"
    info "Conferindo..."
    codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SUPABASE_URL/auth/v1/health")"
    if [ "$codigo" = "000" ]; then
        falha "Não consegui acessar $SUPABASE_URL. Confira se copiou a URL certa."
        enter
        passo_supabase_url; return
    fi
    ok "Supabase encontrado."

    echo ""
    echo -e "Agora, na mesma tela (${branco}API Keys${reset}), copie a chave ${branco}anon public${reset}."
    echo -e "${cinza}É a chave pública. Começa com eyJ... ou sb_publishable_...${reset}"
    echo ""
    while :; do
        local k papel ref
        perguntar k "Chave anon public" "${SUPABASE_ANON_KEY:-}" || { passo_supabase_url; return; }
        if [[ "$k" == sb_secret_* ]] || [ "$(jwt_campo "$k" role)" = "service_role" ]; then
            falha "Essa é a chave service_role (secreta). Aqui vai a anon public."
            continue
        fi
        if [[ "$k" != sb_publishable_* ]]; then
            papel="$(jwt_campo "$k" role)"
            if [ "$papel" != "anon" ]; then
                falha "Isso não parece a chave anon public. Copie de novo, inteira."
                continue
            fi
            ref="$(jwt_campo "$k" ref)"
            if [ -n "$ref" ] && [ -n "$(ref_supabase)" ] && [ "$ref" != "$(ref_supabase)" ]; then
                falha "Essa chave é de outro projeto do Supabase ($ref)."
                continue
            fi
        fi
        codigo="$(supabase_curl "$k" "$SUPABASE_URL/auth/v1/settings")"
        if [ "$codigo" != "200" ]; then
            falha "O Supabase recusou essa chave (HTTP $codigo). Copie de novo, inteira."
            continue
        fi
        SUPABASE_ANON_KEY="$k"
        ok "Chave anon public válida."
        break
    done
}

passo_supabase_service() {
    cabecalho_passo 3 $TOTAL_PASSOS "Supabase — chave secreta"
    echo -e "Na mesma tela do Supabase, copie a chave ${branco}service_role${reset} (clique em Reveal)."
    echo -e "${cinza}É a chave secreta. Começa com eyJ... ou sb_secret_...${reset}"
    echo ""
    while :; do
        local k ref codigo
        perguntar k "Chave service_role" "${SUPABASE_SERVICE_ROLE_KEY:-}" || return 1
        if [[ "$k" == sb_publishable_* ]] || [ "$(jwt_campo "$k" role)" = "anon" ]; then
            falha "Essa é a chave anon public. Aqui vai a service_role (secreta)."
            continue
        fi
        if [[ "$k" != sb_secret_* ]]; then
            if [ "$(jwt_campo "$k" role)" != "service_role" ]; then
                falha "Isso não parece a chave service_role. Copie de novo, inteira."
                continue
            fi
            ref="$(jwt_campo "$k" ref)"
            if [ -n "$ref" ] && [ -n "$(ref_supabase)" ] && [ "$ref" != "$(ref_supabase)" ]; then
                falha "Essa chave é de outro projeto do Supabase ($ref)."
                continue
            fi
        fi
        codigo="$(supabase_curl "$k" "$SUPABASE_URL/auth/v1/admin/users?page=1&per_page=1")"
        if [ "$codigo" != "200" ]; then
            falha "O Supabase recusou essa chave (HTTP $codigo). Copie de novo, inteira."
            continue
        fi
        SUPABASE_SERVICE_ROLE_KEY="$k"
        ok "Chave service_role válida."
        sleep 1
        break
    done
}

tabelas_faltando() {
    local t codigo faltando=()
    for t in "${TABELAS_SQL[@]}"; do
        codigo="$(supabase_curl "$SUPABASE_SERVICE_ROLE_KEY" "$SUPABASE_URL/rest/v1/$t?select=*&limit=1")"
        [ "$codigo" = "200" ] || faltando+=("$t")
    done
    printf '%s ' "${faltando[@]}"
}

passo_sql() {
    cabecalho_passo 4 $TOTAL_PASSOS "Tabelas do sistema"
    info "Conferindo as tabelas no seu Supabase..."
    local falta resp link ref
    falta="$(tabelas_faltando)"
    if [ -z "${falta// /}" ]; then
        ok "Tabelas do sistema encontradas."
        sleep 1
        return 0
    fi
    ref="$(ref_supabase)"
    link="${ref:+https://supabase.com/dashboard/project/$ref/sql/new}"
    while :; do
        echo ""
        echo "As tabelas do sistema ainda não existem no seu Supabase. Para criar:"
        echo -e "  1. Abra o ${branco}SQL Editor${reset} do Supabase${link:+: ${verde}$link${reset}}"
        echo -e "  2. Cole o conteúdo do arquivo SQL de criação das tabelas e clique em ${branco}Run${reset}"
        echo -e "  3. Espere aparecer ${branco}Success${reset} e volte aqui"
        echo ""
        printf '%b' "Aperte ${branco}Enter${reset} depois de rodar o SQL (0 = voltar): "
        ler resp
        [ "$(limpar "$resp")" = "0" ] && return 1
        info "Conferindo..."
        falta="$(tabelas_faltando)"
        if [ -z "${falta// /}" ]; then
            ok "Tabelas criadas."
            sleep 1
            return 0
        fi
        falha "Ainda faltam as tabelas: $falta"
        echo -e "${cinza}Confira se rodou o SQL no projeto certo ($SUPABASE_URL) e se terminou com Success.${reset}"
    done
}

## Consulta o servidor de licenças do mesmo jeito que o sistema faz.
## Retorna 0 = liberada, 1 = recusada (motivo em LICENCA_MOTIVO), 2 = servidor indisponível
consultar_licenca() {
    local host fingerprint corpo codigo payload json
    host="$(host_instalacao "$SUPABASE_URL")"
    fingerprint="$(printf 'hublabel:%s' "$host" | sha256sum | awk '{print $1}')"
    corpo="$(printf '{"email":"%s","fingerprint":"%s","nonce":"%s","servico":"setup","versao":"setup-%s","instalacao":"%s","hostname":"%s"}' \
        "$LICENCA_EMAIL" "$fingerprint" "$(aleatorio 16)" "$VERSAO" "$host" "$(hostname)")"
    codigo="$(curl -s -o "$TMP/licenca" -w '%{http_code}' --max-time 20 -X POST \
        -H 'content-type: application/json' -d "$corpo" "$LICENCA_URL/v1/validar")"
    [ "$codigo" = "200" ] || return 2
    payload="$(sed -n 's/.*"payload" *: *"\([^"]*\)".*/\1/p' "$TMP/licenca")"
    json="$(printf '%s' "$payload" | base64 -d 2>/dev/null)"
    [ -n "$json" ] || return 2
    if printf '%s' "$json" | grep -q '"ok" *: *true'; then
        return 0
    fi
    LICENCA_MOTIVO="$(printf '%s' "$json" | sed -n 's/.*"motivo" *: *"\([^"]*\)".*/\1/p')"
    return 1
}

passo_licenca() {
    cabecalho_passo 5 $TOTAL_PASSOS "Licença"
    echo "Informe o e-mail usado na compra do HubLabel."
    echo -e "${amarelo}Atenção: cada licença vale para uma instalação.${reset}"
    echo ""
    while :; do
        local e resp
        perguntar e "E-mail da licença" "${LICENCA_EMAIL:-}" || return 1
        e="${e,,}"
        if ! [[ "$e" =~ ^[^@[:space:]\"\']+@[^@[:space:]\"\']+\.[^@[:space:]\"\']+$ ]]; then
            falha "E-mail inválido."
            continue
        fi
        LICENCA_EMAIL="$e"
        info "Verificando a licença..."
        LICENCA_MOTIVO=""
        consultar_licenca
        case $? in
            0)
                ok "Licença liberada."
                sleep 1
                return 0
                ;;
            1)
                falha "Licença não liberada: ${LICENCA_MOTIVO:-recusada}"
                case "$LICENCA_MOTIVO" in
                    *"sem licença"*) echo -e "${cinza}Confira se é exatamente o e-mail da compra. Se estiver certo, fale com o suporte.${reset}" ;;
                    *) echo -e "${cinza}Fale com o suporte do HubLabel.${reset}" ;;
                esac
                ;;
            2)
                falha "Não consegui falar com o servidor de licenças agora."
                printf '%b' "${branco}Enter${reset} = tentar de novo  |  ${branco}C${reset} = continuar sem verificar  |  ${branco}0${reset} = voltar: "
                ler resp
                resp="$(limpar "$resp")"
                [ "$resp" = "0" ] && return 1
                if [[ "$resp" =~ ^[cC] ]]; then
                    aviso "O sistema verifica a licença sozinho quando subir."
                    sleep 1
                    return 0
                fi
                ;;
        esac
    done
}

assistente() {
    local passos=(passo_dominios passo_supabase_url passo_supabase_service passo_sql passo_licenca)
    local i
    while :; do
        i=0
        while [ $i -lt ${#passos[@]} ]; do
            if ${passos[$i]}; then
                i=$((i + 1))
            else
                [ $i -gt 0 ] && i=$((i - 1))
            fi
        done

        banner
        echo -e "${branco}Confira os dados:${reset}"
        echo ""
        echo -e "${amarelo}AMBIENTE${reset}       $PAINEL"
        echo -e "${amarelo}SISTEMA${reset}        https://$APP_HOST"
        echo -e "${amarelo}EVOLUTION${reset}      https://$EVO_HOST"
        echo -e "${amarelo}S3${reset}             https://$S3_HOST"
        echo -e "${amarelo}SUPABASE${reset}       $SUPABASE_URL"
        echo -e "${amarelo}LICENÇA${reset}        $LICENCA_EMAIL"
        echo ""
        echo -e "${amarelo}====================================================================================${reset}"
        local r
        sim_nao "Está tudo certo? S = instalar  |  N = corrigir" S
        r=$?
        [ $r = 0 ] && return 0
        echo -e "${cinza}Vamos refazer. Aperte Enter nas respostas que já estão certas.${reset}"
        sleep 2
    done
}

## ============================================================================
## PREPARAÇÃO DA VPS
## ============================================================================

verificacoes_iniciais() {
    [ "$(id -u)" -eq 0 ] || erro "Rode como root (sudo -i) e tente de novo."
    command -v curl >/dev/null 2>&1 || {
        command -v apt-get >/dev/null 2>&1 || erro "Instale o curl e rode de novo."
        apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
    }
    if ! command -v python3 >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || erro "Instale o python3 e rode de novo."
        info "Instalando dependências..."
        apt-get update -qq && apt-get install -y -qq python3 >/dev/null
    fi
    local ram
    ram="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
    if [ -n "$ram" ] && [ "$ram" -lt 1800 ]; then
        aviso "Esta VPS tem ${ram}MB de memória. O recomendado é 2GB ou mais."
        sleep 2
    fi
}

instalar_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        info "Instalando o Docker (pode levar alguns minutos)..."
        command -v apt-get >/dev/null 2>&1 || erro "Não encontrei o apt-get. Instale o Docker e rode de novo."
        apt-get update -qq
        timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || erro "Não consegui instalar o Docker."
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    if [ "$MODO_DEPLOY" = compose ] && ! docker compose version >/dev/null 2>&1; then
        info "Instalando o Docker Compose..."
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
            || erro "Não consegui instalar o Docker Compose."
    fi
    docker info >/dev/null 2>&1 || erro "O Docker não está rodando."
    ok "Docker pronto."
}

## ============================================================================
## CONFIGURAÇÃO SALVA (/opt/hublabel/.env)
## ============================================================================

VARS_SALVAS=(MODO_DEPLOY MODO_ROTA PAINEL TRAEFIK_RESOLVER TRAEFIK_ENTRYPOINT TRAEFIK_REDE TRAEFIK_LABEL_REDE
    TRAEFIK_PASTA_ARQUIVOS REDE_INTERNA PORTA_APP PORTA_EVO PORTA_S3
    DOMINIO_BASE SUB_APP SUB_EVO SUB_S3 APP_HOST EVO_HOST S3_HOST
    SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY LICENCA_EMAIL
    EVOLUTION_API_KEY POSTGRES_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY)

salvar_config() {
    mkdir -p "$DIR"
    local v
    {
        echo "## HubLabel — configuração do setup v$VERSAO ($(date '+%d/%m/%Y %H:%M'))"
        echo "## Para mudar algo, rode o setup de novo e escolha \"Refazer a configuração\"."
        for v in "${VARS_SALVAS[@]}"; do
            printf "%s='%s'\n" "$v" "${!v:-}"
        done
    } >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

carregar_config() {
    # shellcheck disable=SC1090
    . "$ENV_FILE"
}

gerar_segredos() {
    EVOLUTION_API_KEY="${EVOLUTION_API_KEY:-$(aleatorio 16)}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(aleatorio 16)}"
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-hublabel}"
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(aleatorio 16)}"
    S3_ACCESS_KEY="${S3_ACCESS_KEY:-$(head -c 200 /dev/urandom | tr -dc 'A-Z0-9' | head -c 20)}"
    S3_SECRET_KEY="${S3_SECRET_KEY:-$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 40)}"
    local cliente="${DOMINIO_BASE%%.*}"
    cliente="$(printf '%s' "$cliente" | tr -cd 'a-zA-Z0-9')"
    if [ -z "${REDE_INTERNA:-}" ]; then
        REDE_INTERNA="Rede${cliente^}"
        ## Rede com esse nome já existe e não é nossa (ex.: setup antigo) → usa outro nome
        if docker network inspect "$REDE_INTERNA" >/dev/null 2>&1 \
            && [ "$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$REDE_INTERNA" 2>/dev/null)" != "$PROJETO" ]; then
            REDE_INTERNA="hublabel_rede"
        fi
    fi
    if [ "$MODO_ROTA" = manual ]; then
        PORTA_APP="${PORTA_APP:-$(porta_livre_a_partir_de 3090)}"
        PORTA_EVO="${PORTA_EVO:-$(porta_livre_a_partir_de 8080)}"
        PORTA_S3="${PORTA_S3:-$(porta_livre_a_partir_de 9000)}"
    fi
}

## ============================================================================
## ARQUIVOS DE DEPLOY
## ============================================================================

## Nome do serviço como o proxy enxerga (stack prefixa com o nome da stack)
nome_dns() { [ "$MODO_DEPLOY" = stack ] && echo "${PROJETO}_$1" || echo "$1"; }

labels_traefik() { # labels_traefik ROUTER HOST PORTA INDENT
    local n="$1" h="$2" p="$3" ind="$4"
    printf '%s- traefik.enable=true\n' "$ind"
    printf '%s- traefik.http.routers.%s.rule=Host(`%s`)\n' "$ind" "$n" "$h"
    printf '%s- traefik.http.routers.%s.entrypoints=%s\n' "$ind" "$n" "$TRAEFIK_ENTRYPOINT"
    printf '%s- traefik.http.routers.%s.tls=true\n' "$ind" "$n"
    [ -n "$TRAEFIK_RESOLVER" ] && printf '%s- traefik.http.routers.%s.tls.certresolver=%s\n' "$ind" "$n" "$TRAEFIK_RESOLVER"
    printf '%s- traefik.http.routers.%s.service=%s\n' "$ind" "$n" "$n"
    printf '%s- traefik.http.services.%s.loadbalancer.server.port=%s\n' "$ind" "$n" "$p"
    printf '%s- traefik.http.services.%s.loadbalancer.passhostheader=true\n' "$ind" "$n"
    [ -n "$TRAEFIK_LABEL_REDE" ] && printf '%s- %s=%s\n' "$ind" "$TRAEFIK_LABEL_REDE" "$TRAEFIK_REDE"
}

## Bloco final de cada serviço: redes, portas, labels e deploy/restart.
## extras SERVICO PUBLICO(0|1) [ROUTER HOST PORTA PORTA_LOCAL] [MEMORIA]
extras() {
    local publico="$2" router="${3:-}" host="${4:-}" porta="${5:-}" porta_local="${6:-}" mem="${7:-512M}"
    echo "    networks:"
    echo "      - interna"
    if [ "$publico" = 1 ] && { [ "$MODO_ROTA" = labels ] || [ "$MODO_ROTA" = file ]; }; then
        echo "      - proxy"
    fi
    if [ "$publico" = 1 ] && [ "$MODO_ROTA" = manual ] && [ -n "$porta_local" ]; then
        echo "    ports:"
        if [ "$MODO_DEPLOY" = stack ]; then
            echo "      - { target: $porta, published: $porta_local, mode: host }"
        else
            echo "      - \"127.0.0.1:$porta_local:$porta\""
        fi
    fi
    if [ "$MODO_DEPLOY" = stack ]; then
        echo "    deploy:"
        echo "      placement:"
        echo "        constraints:"
        echo "          - node.role == manager"
        echo "      resources:"
        echo "        limits:"
        echo "          memory: $mem"
        echo "      restart_policy:"
        echo "        condition: any"
        echo "        delay: 5s"
        if [ "$publico" = 1 ] && [ "$MODO_ROTA" = labels ]; then
            echo "      labels:"
            labels_traefik "$router" "$host" "$porta" "        "
        fi
    else
        echo "    restart: unless-stopped"
        echo "    logging: *log"
        if [ "$publico" = 1 ] && [ "$MODO_ROTA" = labels ]; then
            echo "    labels:"
            labels_traefik "$router" "$host" "$porta" "      "
        fi
    fi
}

gerar_arquivo_deploy() {
    local f="$DIR/$PROJETO.yml"
    local cliente="${DOMINIO_BASE%%.*}"
    {
        if [ "$MODO_DEPLOY" = stack ]; then
            echo 'version: "3.7"'
        else
            echo "name: $PROJETO"
            echo ""
            echo "x-log: &log"
            echo "  driver: json-file"
            echo "  options: { max-size: \"20m\", max-file: \"3\" }"
        fi
        cat <<EOF

## Gerado pelo setup HubLabel v$VERSAO — para mudar, rode o setup de novo.
services:

## --------------------------- HUBLABEL (tudo em um) --------------------------- ##

  hublabel-app:
    image: $IMG_APP
    command: ["node", "src/all.js"]
    environment:
      NODE_ENV: "production"
      LICENCA_EMAIL: "$LICENCA_EMAIL"
      SUPABASE_URL: "$SUPABASE_URL"
      SUPABASE_SERVICE_ROLE_KEY: "$SUPABASE_SERVICE_ROLE_KEY"
      SUPABASE_ANON_KEY: "$SUPABASE_ANON_KEY"
      BACK_URL: "https://$APP_HOST/webhook"
      EVOLUTION_BASE_URL: "https://$EVO_HOST"
      EVOLUTION_API_KEY: "$EVOLUTION_API_KEY"
      S3_ENDPOINT: "http://hublabel-minio:9000"
      S3_ACCESS_KEY_ID: "$S3_ACCESS_KEY"
      S3_SECRET_ACCESS_KEY: "$S3_SECRET_KEY"
      S3_BUCKET: "$S3_BUCKET"
      S3_PUBLIC_BASE_URL: "https://$S3_HOST/$S3_BUCKET"
      REDIS_URL: "redis://hublabel-redis:6379"
      SENHA_PADRAO_INTEGRACAO: "$SENHA_PADRAO_INTEGRACAO"
      TZ_SISTEMA: "America/Sao_Paulo"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3090/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 40s
EOF
        [ "$MODO_DEPLOY" = compose ] && echo "    depends_on: [hublabel-redis, hublabel-minio]"
        extras hublabel-app 1 hublabel_app "$APP_HOST" 3090 "${PORTA_APP:-}" 1024M

        cat <<EOF

  hublabel-redis:
    image: $IMG_REDIS
    command: ["redis-server", "--appendonly", "yes", "--maxmemory", "200mb", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - hublabel_redis:/data
EOF
        extras hublabel-redis 0 "" "" "" "" 256M

        cat <<EOF

## --------------------------- EVOLUTION API --------------------------- ##

  hublabel-evolution:
    image: $IMG_EVOLUTION
    volumes:
      - evolution_instances:/evolution/instances
    environment:
      SERVER_URL: "https://$EVO_HOST"
      AUTHENTICATION_API_KEY: "$EVOLUTION_API_KEY"
      AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES: "true"
      DEL_INSTANCE: "false"
      QRCODE_LIMIT: "1902"
      LANGUAGE: "pt-BR"
      CONFIG_SESSION_PHONE_CLIENT: "$cliente"
      CONFIG_SESSION_PHONE_NAME: "Chrome"
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: "postgresql"
      DATABASE_CONNECTION_URI: "postgresql://postgres:$POSTGRES_PASSWORD@hublabel-evolution-db:5432/evolution"
      DATABASE_CONNECTION_CLIENT_NAME: "evolution"
      DATABASE_SAVE_DATA_INSTANCE: "true"
      DATABASE_SAVE_DATA_NEW_MESSAGE: "true"
      DATABASE_SAVE_MESSAGE_UPDATE: "false"
      DATABASE_SAVE_DATA_CONTACTS: "false"
      DATABASE_SAVE_DATA_CHATS: "false"
      DATABASE_SAVE_DATA_LABELS: "false"
      DATABASE_SAVE_DATA_HISTORIC: "false"
      N8N_ENABLED: "false"
      EVOAI_ENABLED: "true"
      OPENAI_ENABLED: "true"
      DIFY_ENABLED: "true"
      TYPEBOT_ENABLED: "true"
      TYPEBOT_API_VERSION: "latest"
      CHATWOOT_ENABLED: "true"
      CHATWOOT_MESSAGE_READ: "true"
      CHATWOOT_MESSAGE_DELETE: "true"
      CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE: "false"
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: "redis://hublabel-evolution-redis:6379/1"
      CACHE_REDIS_PREFIX_KEY: "evolution"
      CACHE_REDIS_SAVE_INSTANCES: "false"
      CACHE_LOCAL_ENABLED: "false"
      S3_ENABLED: "false"
      WA_BUSINESS_TOKEN_WEBHOOK: "evolution"
      WA_BUSINESS_URL: "https://graph.facebook.com"
      WA_BUSINESS_VERSION: "v23.0"
      WA_BUSINESS_LANGUAGE: "pt_BR"
      TELEMETRY: "false"
      WEBSOCKET_ENABLED: "false"
      RABBITMQ_ENABLED: "false"
      SQS_ENABLED: "false"
      WEBHOOK_GLOBAL_ENABLED: "false"
      WEBHOOK_REQUEST_TIMEOUT_MS: "60000"
      WEBHOOK_RETRY_MAX_ATTEMPTS: "10"
      WEBHOOK_RETRY_INITIAL_DELAY_SECONDS: "5"
      WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF: "true"
      WEBHOOK_RETRY_MAX_DELAY_SECONDS: "300"
      WEBHOOK_RETRY_JITTER_FACTOR: "0.2"
      WEBHOOK_RETRY_NON_RETRYABLE_STATUS_CODES: "400,401,403,404,422"
      PROVIDER_ENABLED: "false"
EOF
        [ "$MODO_DEPLOY" = compose ] && echo "    depends_on: [hublabel-evolution-db, hublabel-evolution-redis]"
        extras hublabel-evolution 1 hublabel_evolution "$EVO_HOST" 8080 "${PORTA_EVO:-}" 1024M

        cat <<EOF

  hublabel-evolution-db:
    image: $IMG_POSTGRES
    command: ["postgres", "-c", "max_connections=200", "-c", "shared_buffers=64MB", "-c", "timezone=America/Sao_Paulo"]
    environment:
      POSTGRES_PASSWORD: "$POSTGRES_PASSWORD"
      POSTGRES_DB: "evolution"
      TZ: "America/Sao_Paulo"
    volumes:
      - evolution_postgres:/var/lib/postgresql/data
EOF
        extras hublabel-evolution-db 0 "" "" "" "" 512M

        cat <<EOF

  hublabel-evolution-redis:
    image: $IMG_REDIS
    command: ["redis-server", "--appendonly", "yes", "--maxmemory", "200mb", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - evolution_redis:/data
EOF
        extras hublabel-evolution-redis 0 "" "" "" "" 256M

        cat <<EOF

## --------------------------- MINIO (S3) --------------------------- ##

  hublabel-minio:
    image: $IMG_MINIO
    command: ["server", "/data"]
    environment:
      MINIO_ROOT_USER: "$MINIO_ROOT_USER"
      MINIO_ROOT_PASSWORD: "$MINIO_ROOT_PASSWORD"
      MINIO_SERVER_URL: "https://$S3_HOST"
      MINIO_BROWSER: "off"
      MINIO_REGION_NAME: "eu-south"
    volumes:
      - minio_data:/data
EOF
        extras hublabel-minio 1 hublabel_s3 "$S3_HOST" 9000 "${PORTA_S3:-}" 512M

        if [ "$MODO_ROTA" = caddy ]; then
            cat <<EOF

## --------------------------- CADDY (HTTPS automático) --------------------------- ##

  caddy:
    image: $IMG_CADDY
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
EOF
            extras caddy 0 "" "" "" "" 256M
        fi

        echo ""
        echo "volumes:"
        echo "  hublabel_redis:"
        echo "  evolution_instances:"
        echo "  evolution_postgres:"
        echo "  evolution_redis:"
        echo "  minio_data:"
        if [ "$MODO_ROTA" = caddy ]; then
            echo "  caddy_data:"
            echo "  caddy_config:"
        fi
        echo ""
        echo "networks:"
        echo "  interna:"
        if [ "$MODO_DEPLOY" = stack ]; then
            echo "    driver: overlay"
        else
            echo "    name: $REDE_INTERNA"
        fi
        if [ "$MODO_ROTA" = labels ] || [ "$MODO_ROTA" = file ]; then
            echo "  proxy:"
            echo "    external: true"
            echo "    name: $TRAEFIK_REDE"
        fi
    } >"$f"
    chmod 600 "$f"

    if [ "$MODO_ROTA" = caddy ]; then
        cat >"$DIR/Caddyfile" <<EOF
$APP_HOST {
    encode gzip
    reverse_proxy hublabel-app:3090
}

$EVO_HOST {
    reverse_proxy hublabel-evolution:8080
}

$S3_HOST {
    reverse_proxy hublabel-minio:9000
}
EOF
    fi

    if [ "$MODO_ROTA" = file ]; then
        local app evo s3
        app="$(nome_dns hublabel-app)"; evo="$(nome_dns hublabel-evolution)"; s3="$(nome_dns hublabel-minio)"
        {
            echo "## Gerado pelo setup HubLabel v$VERSAO"
            echo "http:"
            echo "  routers:"
            for r in "hublabel_app $APP_HOST" "hublabel_evolution $EVO_HOST" "hublabel_s3 $S3_HOST"; do
                set -- $r
                echo "    $1:"
                echo "      rule: \"Host(\`$2\`)\""
                echo "      entryPoints: [\"$TRAEFIK_ENTRYPOINT\"]"
                echo "      service: $1"
                if [ -n "$TRAEFIK_RESOLVER" ]; then
                    echo "      tls:"
                    echo "        certResolver: $TRAEFIK_RESOLVER"
                else
                    echo "      tls: {}"
                fi
            done
            echo "  services:"
            echo "    hublabel_app:"
            echo "      loadBalancer:"
            echo "        servers: [{ url: \"http://$app:3090\" }]"
            echo "    hublabel_evolution:"
            echo "      loadBalancer:"
            echo "        servers: [{ url: \"http://$evo:8080\" }]"
            echo "    hublabel_s3:"
            echo "      loadBalancer:"
            echo "        servers: [{ url: \"http://$s3:9000\" }]"
        } >"$TRAEFIK_PASTA_ARQUIVOS/hublabel-rotas.yml"
    fi
}

## ============================================================================
## SUBIR / ATUALIZAR
## ============================================================================

## ID do container de um serviço (compose ou stack)
container_de() {
    if [ "$MODO_DEPLOY" = stack ]; then
        docker ps -q -f "label=com.docker.swarm.service.name=${PROJETO}_$1" | head -1
    else
        docker ps -q -f "label=com.docker.compose.project=$PROJETO" -f "label=com.docker.compose.service=$1" | head -1
    fi
}

subir() {
    info "Baixando as imagens (pode levar alguns minutos)..."
    cd "$DIR" || erro "Pasta $DIR não encontrada."
    if [ "$MODO_DEPLOY" = stack ]; then
        local img
        for img in "$IMG_APP" "$IMG_REDIS" "$IMG_EVOLUTION" "$IMG_POSTGRES" "$IMG_MINIO"; do
            docker pull -q "$img" >/dev/null 2>&1 || aviso "Não consegui baixar $img agora (o Docker tenta de novo sozinho)."
        done
        info "Subindo os serviços..."
        docker stack deploy --prune --resolve-image always -c "$PROJETO.yml" "$PROJETO" >/dev/null \
            || erro "Falha no docker stack deploy. Arquivo: $DIR/$PROJETO.yml"
    else
        docker compose -f "$PROJETO.yml" pull -q || erro "Não consegui baixar as imagens. Confira a internet da VPS."
        info "Subindo os serviços..."
        docker compose -f "$PROJETO.yml" up -d --remove-orphans || erro "Falha ao subir os serviços. Arquivo: $DIR/$PROJETO.yml"
    fi
    ok "Serviços enviados ao Docker."
}

configurar_minio() {
    info "Preparando o S3 (bucket \"$S3_BUCKET\" e chaves de acesso)..."
    local cid="" i
    for i in $(seq 1 60); do
        cid="$(container_de hublabel-minio)"
        if [ -n "$cid" ] && docker exec "$cid" mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
            break
        fi
        cid=""
        sleep 3
    done
    [ -n "$cid" ] || { falha "O MinIO não respondeu. As mídias não vão funcionar até isso ser resolvido."; return 1; }

    docker exec "$cid" mc mb -p "local/$S3_BUCKET" >/dev/null 2>&1
    docker exec "$cid" mc anonymous set download "local/$S3_BUCKET" >/dev/null 2>&1 \
        || aviso "Não consegui deixar o bucket com leitura pública."
    docker exec "$cid" mc admin user add local "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 \
        || { falha "Não consegui criar a chave de acesso do S3."; return 1; }
    docker exec "$cid" mc admin policy attach local readwrite --user "$S3_ACCESS_KEY" >/dev/null 2>&1 \
        || docker exec "$cid" mc admin policy set local readwrite "user=$S3_ACCESS_KEY" >/dev/null 2>&1 || true
    ok "S3 pronto."
}

aguardar_sistema() {
    info "Aguardando o sistema iniciar (até 5 minutos)..."
    local i cid estado
    for i in $(seq 1 100); do
        cid="$(container_de hublabel-app)"
        if [ -n "$cid" ]; then
            estado="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null)"
            if [ "$estado" = healthy ] || docker exec "$cid" wget -qO- http://127.0.0.1:3090/health >/dev/null 2>&1; then
                ok "Sistema no ar."
                return 0
            fi
        fi
        sleep 3
    done
    echo ""
    falha "O sistema não respondeu. Últimas linhas do log:"
    if [ "$MODO_DEPLOY" = stack ]; then
        docker service logs --tail 30 "${PROJETO}_hublabel-app" 2>&1 | tail -30
    else
        docker compose -f "$DIR/$PROJETO.yml" logs --tail 30 hublabel-app 2>&1 | tail -30
    fi
    echo ""
    aviso "Problemas comuns: licença (e-mail errado ou já usada) e chaves do Supabase."
    aviso "Depois de corrigir, rode o setup de novo e escolha \"Refazer a configuração\"."
    return 1
}

verificar_https() {
    [ "$MODO_ROTA" = manual ] && return 0
    info "Conferindo o HTTPS de https://$APP_HOST ..."
    local i codigo
    for i in $(seq 1 20); do
        codigo="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$APP_HOST:443:127.0.0.1" "https://$APP_HOST/health")"
        [ "$codigo" = "200" ] && { ok "HTTPS respondendo."; return 0; }
        sleep 6
    done
    aviso "O endereço https://$APP_HOST ainda não respondeu pelo proxy (HTTP $codigo)."
    aviso "Confira o DNS. O certificado pode levar alguns minutos para sair."
    return 1
}

## ============================================================================
## RESUMO FINAL
## ============================================================================

resumo_final() {
    banner
    echo -e "${verde}====================================================================================${reset}"
    echo -e "${verde}                        INSTALAÇÃO CONCLUÍDA!${reset}"
    echo -e "${verde}====================================================================================${reset}"
    echo ""
    echo -e "${amarelo}SISTEMA${reset}"
    echo "  Acesso:             https://$APP_HOST/webhook/login"
    echo "  Webhook Meta:       https://$APP_HOST/webhook/eventsmeta"
    echo "  Webhook Evolution:  https://$APP_HOST/webhook/agente-no-whatsapp"
    echo "  Senha padrão:       $SENHA_PADRAO_INTEGRACAO  (usuários criados por integração)"
    echo ""
    echo -e "${amarelo}EVOLUTION API${reset}"
    echo "  URL:      https://$EVO_HOST"
    echo "  Manager:  https://$EVO_HOST/manager"
    echo "  API Key:  $EVOLUTION_API_KEY"
    echo ""
    echo -e "${amarelo}S3 (MINIO)${reset}"
    echo "  URL:         https://$S3_HOST"
    echo "  Bucket:      $S3_BUCKET  (https://$S3_HOST/$S3_BUCKET)"
    echo "  Access Key:  $S3_ACCESS_KEY"
    echo "  Secret Key:  $S3_SECRET_KEY"
    echo ""
    echo -e "${amarelo}SUPABASE${reset}"
    echo "  $SUPABASE_URL"
    echo ""
    if [ "$MODO_ROTA" = manual ]; then
        echo -e "${amarelo}FALTA UM PASSO: APONTAR OS DOMÍNIOS NO SEU PAINEL/PROXY (com HTTPS)${reset}"
        echo "  https://$APP_HOST  →  http://127.0.0.1:$PORTA_APP"
        echo "  https://$EVO_HOST  →  http://127.0.0.1:$PORTA_EVO"
        echo "  https://$S3_HOST  →  http://127.0.0.1:$PORTA_S3"
        echo ""
    fi
    echo -e "${amarelo}PARA ATUALIZAR${reset}"
    echo "  Rode o mesmo comando de instalação de novo e escolha \"Atualizar\"."
    echo ""
    echo -e "${cinza}Anote estes dados em um lugar seguro.${reset}"
    echo ""
}

## ============================================================================
## FLUXOS
## ============================================================================

instalar() {
    gerar_segredos
    salvar_config
    gerar_arquivo_deploy
    subir
    configurar_minio
    aguardar_sistema
    verificar_https
    resumo_final
}

menu_instalacao_existente() {
    carregar_config
    banner
    echo -e "${branco}Já existe uma instalação do HubLabel nesta VPS${reset} (https://${APP_HOST:-?})."
    echo ""
    echo "  1) Atualizar para a versão mais nova (mantém tudo como está)"
    echo "  2) Refazer a configuração (Enter mantém cada resposta atual)"
    echo "  3) Sair"
    echo ""
    local op
    perguntar op "Escolha" "1" || op=3
    case "$op" in
        1)
            gerar_arquivo_deploy
            subir
            configurar_minio
            aguardar_sistema
            echo ""
            ok "Atualização concluída."
            exit 0
            ;;
        2)
            assistente
            instalar
            exit 0
            ;;
        *) exit 0 ;;
    esac
}

main() {
    verificacoes_iniciais

    if [ -f "$ENV_FILE" ]; then
        menu_instalacao_existente
    fi

    banner
    info "Analisando a VPS..."
    detectar_ambiente
    echo ""
    descrever_ambiente
    echo ""
    echo "Vou pedir 5 informações: domínio, Supabase (URL e 2 chaves), as tabelas e a licença."
    echo "Tenha em mãos o acesso ao painel do seu domínio e ao Supabase."
    echo ""
    enter "Aperte Enter para começar..."

    assistente
    banner
    instalar_docker
    instalar
}

main "$@"
