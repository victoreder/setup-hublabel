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
##   - Versão antiga (v1.8: N8N no app.* + Disparador) ... oferece trocar pela nova:
##     remove o Disparador (e o N8N, ou mantém o N8N só em app.*/webhook/... com os
##     fluxos [SAAS] HUBLABEL desativados), mantém a Evolution e o MinIO e usa os dados deles
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
## Senha inicial do administrador criado pelo setup
ADMIN_SENHA_PADRAO="Padrao123456"
## SQL de criação das tabelas (arquivo único, neste repositório)
SQL_URL="https://raw.githubusercontent.com/victoreder/setup-hublabel/main/sql/criar-tabelas.sql"
## Tabelas conferidas depois do SQL (FollowupExecucao fica no fim do arquivo)
TABELAS_SQL=(SAAS_Contas SAAS_Usuarios FollowupExecucao SAAS_Personalizacao)

amarelo="\e[33m"
verde="\e[92m"
branco="\e[97m"
vermelho="\e[91m"
## Paleta única em amarelo (verde e vermelho só para ✔ e ✘)
ciano="\e[93m"
azul="\e[33m"
roxo="\e[33m"
cinza="\e[90m"
negrito="\e[1m"
reset="\e[0m"

## Lê do terminal mesmo quando o script vem por "curl | bash"
TTY=/dev/tty
{ : </dev/tty; } 2>/dev/null || TTY=/dev/stdin

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; printf "\e[?25h"' EXIT

## ============================================================================
## VISUAL (cores, caixas, efeitos)
## ============================================================================

LARGURA=62
NOMES_PASSOS=("Domínios" "Supabase" "Tabelas" "Licença" "Seu sistema")
TOTAL_PASSOS=${#NOMES_PASSOS[@]}
QUADROS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

info()  { echo -e "  ${ciano}›${reset} $*"; }
ok()    { echo -e "  ${verde}✔${reset} $*"; }
aviso() { echo -e "  ${amarelo}!${reset} ${amarelo}$*${reset}"; }
falha() { echo -e "  ${vermelho}✘ $*${reset}"; }
erro()  { falha "$*"; exit 1; }
dica()  { echo -e "  ${cinza}$*${reset}"; }
texto() { echo -e "  $*"; }

## linha [largura] [caractere]
linha() { local n="${1:-$LARGURA}" c="${2:-─}"; [ "$n" -gt 0 ] && printf "%.0s$c" $(seq 1 "$n"); }

## Efeito de máquina de escrever (desligado fora do terminal ou com SEM_EFEITO=1)
digitar() { # digitar "texto" [cor]
    local t="$1" cor="${2:-}" i
    printf '%b' "$cor"
    if [ -t 1 ] && [ -z "${SEM_EFEITO:-}" ]; then
        for ((i = 0; i < ${#t}; i++)); do
            printf '%s' "${t:i:1}"
            sleep 0.012
        done
    else
        printf '%s' "$t"
    fi
    printf '%b\n' "$reset"
}

banner() {
    clear
    echo ""
    echo -e "\e[93m  ██╗  ██╗██╗   ██╗██████╗ ██╗      █████╗ ██████╗ ███████╗██╗     ${reset}"
    echo -e "\e[93m  ██║  ██║██║   ██║██╔══██╗██║     ██╔══██╗██╔══██╗██╔════╝██║     ${reset}"
    echo -e "\e[93m  ███████║██║   ██║██████╔╝██║     ███████║██████╔╝█████╗  ██║     ${reset}"
    echo -e "\e[93m  ██╔══██║██║   ██║██╔══██╗██║     ██╔══██║██╔══██╗██╔══╝  ██║     ${reset}"
    echo -e "\e[93m  ██║  ██║╚██████╔╝██████╔╝███████╗██║  ██║██████╔╝███████╗███████╗${reset}"
    echo -e "\e[93m  ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚══════╝${reset}"
    echo -e "  ${cinza}$(linha 66 ━)${reset}"
    echo -e "  ${negrito}${branco}Instalador oficial${reset}  ${cinza}•  versão $VERSAO${reset}"
    echo ""
}

## Trilha com os passos: ✔ feitos, ● atual, ○ próximos
trilha() {
    local atual="$1" i n s=""
    for i in "${!NOMES_PASSOS[@]}"; do
        n=$((i + 1))
        if [ "$n" -lt "$atual" ]; then
            s+="${verde}✔ ${NOMES_PASSOS[$i]}${reset}"
        elif [ "$n" -eq "$atual" ]; then
            s+="${negrito}${ciano}● ${NOMES_PASSOS[$i]}${reset}"
        else
            s+="${cinza}○ ${NOMES_PASSOS[$i]}${reset}"
        fi
        [ "$n" -lt "$TOTAL_PASSOS" ] && s+="${cinza} ─ ${reset}"
    done
    echo -e "  $s"
}

## Título em caixa: titulo_caixa "TEXTO" [cor]
titulo_caixa() {
    local cor="${2:-$ciano}"
    echo -e "  ${cor}╭$(linha "$LARGURA")${reset}"
    printf '  %b│%b  ' "$cor" "$reset"
    digitar "$1" "${negrito}${branco}"
    echo -e "  ${cor}╰$(linha "$LARGURA")${reset}"
}

## cabecalho_passo N "Título"
cabecalho_passo() {
    banner
    trilha "$1"
    echo ""
    titulo_caixa "PASSO $1 DE $TOTAL_PASSOS  ·  $2"
    dica "Digite 0 e aperte Enter para voltar ao passo anterior."
    echo ""
}

## Bloco de informações: abrir_bloco "TÍTULO" [cor] / item "Rótulo" "valor" / fechar_bloco
## Quantidade de caracteres (não de bytes), em qualquer idioma do terminal
tamanho() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c; }

## Texto completado com espaços até N caracteres
completar() { local n; n=$(tamanho "$1"); printf '%s%*s' "$1" $(($2 > n ? $2 - n : 0)) ''; }

abrir_bloco() {
    BLOCO_COR="${2:-$roxo}"
    echo -e "  ${BLOCO_COR}┌─ ${negrito}${branco}$1${reset} ${BLOCO_COR}$(linha $((LARGURA - $(tamanho "$1") - 3)))${reset}"
}
item() { printf '  %b│%b  %b%s%b %s\n' "$BLOCO_COR" "$reset" "$cinza" "$(completar "$1" 14)" "$reset" "$2"; }
fechar_bloco() { echo -e "  ${BLOCO_COR}└$(linha "$LARGURA")${reset}"; echo ""; }

## Item já respondido dentro de um passo
feito() { printf '  %b✔%b %b%s%b %s\n' "$verde" "$reset" "$cinza" "$(completar "$1" 18)" "$reset" "$2"; }

## Numeração das instruções: instrucao N "texto"
instrucao() { echo -e "  ${ciano}${negrito}$1${reset}  $2"; }

## girar "mensagem" comando... → roda com animação; saída em $TMP/ultimo.log
girar() {
    local msg="$1" pid rc i=0
    shift
    "$@" >"$TMP/ultimo.log" 2>&1 &
    pid=$!
    printf '\e[?25l'
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %b%s%b %s' "$ciano" "${QUADROS[i % 10]}" "$reset" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid"
    rc=$?
    printf '\e[?25h'
    if [ "$rc" = 0 ]; then
        printf '\r  %b✔%b %s\e[K\n' "$verde" "$reset" "$msg"
    else
        printf '\r  %b✘%b %s\e[K\n' "$vermelho" "$reset" "$msg"
    fi
    return "$rc"
}

## esperar "mensagem" SEGUNDOS comando... → repete o comando até dar certo (com animação)
esperar() {
    local msg="$1" limite="$2" inicio i=0
    shift 2
    inicio=$SECONDS
    printf '\e[?25l'
    while :; do
        if "$@" >/dev/null 2>&1; then
            printf '\e[?25h\r  %b✔%b %s\e[K\n' "$verde" "$reset" "$msg"
            return 0
        fi
        if [ $((SECONDS - inicio)) -ge "$limite" ]; then
            printf '\e[?25h\r  %b✘%b %s\e[K\n' "$vermelho" "$reset" "$msg"
            return 1
        fi
        local f
        for f in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            printf '\r  %b%s%b %s' "$ciano" "${QUADROS[i % 10]}" "$reset" "$msg"
            i=$((i + 1))
            sleep 0.1
        done
    done
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
            printf '%b' "  ${ciano}➜${reset} ${branco}${__texto}${reset} ${cinza}[${__padrao}]${reset}: "
        else
            printf '%b' "  ${ciano}➜${reset} ${branco}${__texto}${reset}: "
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
        printf '%b' "  ${ciano}➜${reset} ${branco}$1${reset} ${cinza}($([ "$padrao" = S ] && echo 'S/n' || echo 's/N'))${reset}: "
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
    printf '%b' "  ${cinza}${1:-Aperte Enter para continuar...}${reset}"
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

## IPs de um domínio, um por linha. Pergunta primeiro ao servidor DNS oficial do
## domínio e depois ao Google/Cloudflare, para não pegar resposta velha do cache da VPS.
ips_do_dominio() {
    {
        python3 -I - "$1" 2>/dev/null <<'PYEOF'
import json, random, socket, struct, sys, urllib.request

host = sys.argv[1].strip(".").lower()

def doh(nome, tipo):
    """Consulta DNS por HTTPS (Google e Cloudflare). Retorna os dados das respostas do tipo pedido."""
    codigo = {"A": 1, "NS": 2}[tipo]
    saida = []
    for base in ("https://dns.google/resolve", "https://cloudflare-dns.com/dns-query"):
        try:
            req = urllib.request.Request(f"{base}?name={nome}&type={tipo}", headers={"accept": "application/dns-json"})
            dados = json.load(urllib.request.urlopen(req, timeout=5))
        except Exception:
            continue
        for r in dados.get("Answer") or []:
            if r.get("type") == codigo:
                v = r.get("data", "").rstrip(".")
                if v and v not in saida:
                    saida.append(v)
    return saida

def pular_nome(dados, i):
    while True:
        tam = dados[i]
        if tam == 0:
            return i + 1
        if tam & 0xC0 == 0xC0:
            return i + 2
        i += tam + 1

def consulta_direta(ip_ns, nome):
    """Pergunta direto ao servidor DNS oficial do domínio (sem cache no caminho)."""
    tid = random.randint(0, 65535)
    pacote = struct.pack(">HHHHHH", tid, 0, 1, 0, 0, 0)
    for parte in nome.split("."):
        pacote += bytes([len(parte)]) + parte.encode()
    pacote += b"\0" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(pacote, (ip_ns, 53))
        dados, _ = s.recvfrom(4096)
    finally:
        s.close()
    if struct.unpack(">H", dados[:2])[0] != tid:
        return []
    respostas = struct.unpack(">H", dados[6:8])[0]
    i = pular_nome(dados, 12) + 4
    ips = []
    for _ in range(respostas):
        i = pular_nome(dados, i)
        tipo, _cls, _ttl, tam = struct.unpack(">HHIH", dados[i:i + 10])
        i += 10
        if tipo == 1 and tam == 4:
            ips.append(socket.inet_ntoa(dados[i:i + 4]))
        i += tam
    return ips

ips = []
## 1) Servidor oficial do domínio: acha a zona subindo pelos níveis (app.x.com.br → x.com.br)
partes = host.split(".")
for n in range(len(partes) - 1):
    zona = ".".join(partes[n:])
    servidores = doh(zona, "NS")
    if not servidores:
        continue
    for ns in servidores[:3]:
        for ip_ns in doh(ns, "A")[:1]:
            try:
                ips = consulta_direta(ip_ns, host)
            except Exception:
                ips = []
            if ips:
                break
        if ips:
            break
    break
## 2) DNS públicos (Google e Cloudflare)
for ip in doh(host, "A"):
    if ip not in ips:
        ips.append(ip)
print("\n".join(ips))
PYEOF
        getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}'
    } | awk 'NF && !visto[$0]++'
}

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
    imagem = cs.get("Image") or ""
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
    imagem = (d.get("Config") or {}).get("Image") or ""
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

def versao_traefik():
    """Versão principal do Traefik: pela tag da imagem ou perguntando ao próprio Traefik."""
    m = re.search(r":v?(\d+)(?:\.|$|@|-)", imagem.split("/")[-1])
    if m:
        return int(m.group(1))
    try:
        if tipo == "service":
            cid = subprocess.run(["docker", "ps", "-q", "-f", f"label=com.docker.swarm.service.name={d['Spec']['Name']}"],
                                 capture_output=True, text=True, timeout=10).stdout.split()
        else:
            cid = [d.get("Id", "")]
        if cid and cid[0]:
            saida = subprocess.run(["docker", "exec", cid[0], "traefik", "version"],
                                   capture_output=True, text=True, timeout=15).stdout
            m = re.search(r"Version:\s*v?(\d+)\.", saida)
            if m:
                return int(m.group(1))
    except Exception:
        pass
    return 0

## Traefik v2 não tem o provedor "swarm" (Swarm é o docker com swarmMode): com a label
## traefik.swarm.network ele recusa as labels e ignora o serviço inteiro (404)
if versao_traefik() == 2:
    swarm = False

if swarm:
    rota, label = "labels", "traefik.swarm.network"
elif docker:
    rota, label = "labels", "traefik.docker.network"
elif pasta:
    rota, label = "file", ""
else:
    ## Sem nada declarado: o padrão do Traefik em Swarm (v3) ou container
    rota = "labels"
    label = "traefik.swarm.network" if tipo == "service" and versao_traefik() != 2 else "traefik.docker.network"

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
        ## Instalação antiga do HubLabel (v1.8: N8N no app.* e Disparador)
        detectar_versao_antiga && HUBLABEL_V18=1

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
        PAINEL="${nome:-Traefik}"
        return
    fi

    if porta_em_uso 80 || porta_em_uso 443; then
        MODO_ROTA="manual"
        MODO_DEPLOY="compose"
        local quem=""
        quem="$(ss -ltnpH 2>/dev/null | grep -E '[:.](80|443) ' | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
        [ "$quem" = "docker-proxy" ] && quem=""
        PAINEL="${nome:-${quem:-outro painel}}"
        return
    fi

    [ -n "$nome" ] && PAINEL="$nome"
}

descrever_ambiente() {
    ok "Ambiente detectado: ${negrito}$PAINEL${reset}"
}

## ============================================================================
## VERSÃO ANTIGA (v1.8: N8N + Disparador, com Evolution e MinIO em stacks)
## ============================================================================
## A migração remove o N8N (que atende o app.*) e o Disparador antigo e instala
## o sistema novo no lugar. A Evolution e o MinIO antigos continuam rodando e o
## sistema novo passa a usar os dois (WhatsApps conectados e arquivos ficam).

MIGRACAO=0
APP_HOST_ANTIGO=""; EVO_HOST_ANTIGO=""; S3_HOST_ANTIGO=""
ANTIGO_N8N=(); ANTIGO_DISPARADOR=(); ANTIGO_CONTAINERS=()
REMOVER_STACKS=(); REMOVER_SERVICOS=()
EVO_EXTERNA=0; S3_EXTERNO=0; EVO_SERVICO_EXT=""; MINIO_SERVICO_EXT=""
## Manter o N8N: ele sai do app.* (fica só em app.*/webhook/...) e os fluxos [SAAS] HUBLABEL são desativados
MANTER_N8N=0; N8N_TRAEFIK_WEBHOOK=""; N8N_TRAEFIK_EDITOR=""
N8N_SERVICO_WEBHOOK=""; N8N_SERVICO_EDITOR=""; N8N_ROUTER_WEBHOOK=""; N8N_TEM_MIDDLEWARE=0
## Prefixo dos fluxos do HubLabel antigo no N8N: "[SAAS] HUBLABEL - <versão>"
PREFIXO_FLUXOS_SAAS="[SAAS] HUBLABEL"

## Variável de ambiente de um serviço do Swarm ou container: env_de service|container NOME VAR
env_de() {
    local f
    if [ "$1" = service ]; then
        f='{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}'
    else
        f='{{range .Config.Env}}{{println .}}{{end}}'
    fi
    docker "$1" inspect -f "$f" "$2" 2>/dev/null </dev/null | sed -n "s/^$3=//p" | head -1 | tr -d '\r'
}

## Só o host de uma URL: "https://App.x.com.br/webhook" → "app.x.com.br"
host_de_url() {
    local h="${1#*://}"
    h="${h%%/*}"; h="${h%%:*}"
    printf '%s' "${h,,}"
}

## Stack (namespace) de um serviço do Swarm
ns_de() { docker service inspect -f '{{index .Spec.Labels "com.docker.stack.namespace"}}' "$1" 2>/dev/null </dev/null; }

## Hosts que um serviço atende: regras Host(`...`) do Traefik e URLs do N8N
hosts_do_servico() {
    local v
    {
        docker service inspect -f '{{range $k, $v := .Spec.Labels}}{{println $v}}{{end}}' "$1" 2>/dev/null </dev/null \
            | grep -o 'Host(`[^`]*`)' | sed 's/^Host(`//; s/`)$//'
        for v in WEBHOOK_URL N8N_HOST N8N_EDITOR_BASE_URL; do
            v="$(env_de service "$1" "$v")"
            [ -n "$v" ] && echo "$(host_de_url "$v")"
        done
    } | tr 'A-Z' 'a-z' | awk 'NF && !visto[$0]++'
}

## Labels de um serviço do Swarm, uma por linha: chave=valor
labels_de() { docker service inspect -f '{{range $k, $v := .Spec.Labels}}{{$k}}={{$v}}{{println}}{{end}}' "$1" 2>/dev/null </dev/null; }

## Preenche VAR com o valor (só se VAR ainda estiver vazia)
preencher() { [ -z "${!1:-}" ] && [ -n "$2" ] && printf -v "$1" '%s' "$2"; return 0; }

## Procura o N8N do app.* e o Disparador antigo e lê o que der da instalação.
## Retorna 0 se encontrou a versão antiga.
detectar_versao_antiga() {
    ANTIGO_N8N=(); ANTIGO_DISPARADOR=(); ANTIGO_CONTAINERS=()
    EVO_SERVICO_EXT=""; MINIO_SERVICO_EXT=""
    local nome img ns h v app="" candidatos_n8n=() proj svc tipo

    docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null >"$TMP/servicos"
    while read -r nome img; do
        [ -n "$nome" ] || continue
        ns="$(ns_de "$nome")"
        [ "$ns" = "$PROJETO" ] && continue
        case "${img,,}" in
            *hublabel-disparador*) ANTIGO_DISPARADOR+=("$nome") ;;
            *evolution-api*) [ -z "$EVO_SERVICO_EXT" ] && EVO_SERVICO_EXT="$nome" ;;
            *minio*) [ -z "$MINIO_SERVICO_EXT" ] && MINIO_SERVICO_EXT="$nome" ;;
            *n8n*) candidatos_n8n+=("$nome") ;;
        esac
    done <"$TMP/servicos"

    ## Disparador rodando como container comum (fora do Swarm)
    docker ps -a --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.swarm.service.name"}}' \
        2>/dev/null >"$TMP/containers"
    while IFS='|' read -r nome img proj svc; do
        [ -n "$nome" ] && [ -z "$svc" ] && [ "$proj" != "$PROJETO" ] || continue
        [[ "${img,,}" == *hublabel-disparador* ]] && ANTIGO_CONTAINERS+=("$nome")
    done <"$TMP/containers"

    ## Dados do Disparador antigo (Supabase, endereços e chaves)
    for nome in "${ANTIGO_DISPARADOR[@]}" "${ANTIGO_CONTAINERS[@]}"; do
        [[ " ${ANTIGO_DISPARADOR[*]} " == *" $nome "* ]] && tipo=service || tipo=container
        v="$(env_de "$tipo" "$nome" BACK_URL)"
        [ -n "$v" ] && [ -z "$app" ] && app="$(host_de_url "$v")"
        preencher SUPABASE_URL "$(env_de "$tipo" "$nome" SUPABASE_URL)"
        preencher SUPABASE_SERVICE_ROLE_KEY "$(env_de "$tipo" "$nome" SUPABASE_SERVICE_ROLE_KEY)"
        preencher SUPABASE_ANON_KEY "$(env_de "$tipo" "$nome" SUPABASE_ANON_KEY)"
        preencher LICENCA_EMAIL "$(env_de "$tipo" "$nome" LICENCA_EMAIL)"
        v="$(env_de "$tipo" "$nome" EVOLUTION_BASE_URL)"; preencher EVO_HOST_ANTIGO "${v:+$(host_de_url "$v")}"
        preencher EVOLUTION_API_KEY "$(env_de "$tipo" "$nome" EVOLUTION_API_KEY)"
        v="$(env_de "$tipo" "$nome" S3_PUBLIC_BASE_URL)"; preencher S3_HOST_ANTIGO "${v:+$(host_de_url "$v")}"
        preencher S3_ACCESS_KEY "$(env_de "$tipo" "$nome" S3_ACCESS_KEY_ID)"
        preencher S3_SECRET_KEY "$(env_de "$tipo" "$nome" S3_SECRET_ACCESS_KEY)"
    done

    ## N8N que atende o endereço do sistema (app.*). Outro N8N do cliente fica intocado.
    for nome in "${candidatos_n8n[@]}"; do
        while read -r h; do
            if { [ -n "$app" ] && [ "$h" = "$app" ]; } || { [ -z "$app" ] && [[ "$h" == app.* ]]; }; then
                ANTIGO_N8N+=("$nome")
                [ -z "$app" ] && app="$h"
                break
            fi
        done < <(hosts_do_servico "$nome")
    done

    [ ${#ANTIGO_N8N[@]} -gt 0 ] || [ ${#ANTIGO_DISPARADOR[@]} -gt 0 ] || [ ${#ANTIGO_CONTAINERS[@]} -gt 0 ] || return 1

    ## Nomes do N8N no Traefik: o serviço com o roteador do app.* é o de webhook; o outro é o editor
    local r t
    for nome in "${ANTIGO_N8N[@]}"; do
        labels_de "$nome" >"$TMP/labels"
        t="$(sed -n 's/^traefik\.http\.services\.\([^.]*\)\.loadbalancer\.server\.port=.*/\1/p' "$TMP/labels" | head -1)"
        [ -n "$t" ] || continue
        r="$(awk -v h="Host(\`$app\`)" 'index($0, "traefik.http.routers.") == 1 && $0 ~ /^[^=]*\.rule=/ && index($0, h) {
                split($0, p, "."); print p[4]; exit }' "$TMP/labels")"
        if [ -n "$r" ] && [ -z "$N8N_TRAEFIK_WEBHOOK" ]; then
            N8N_TRAEFIK_WEBHOOK="$t"; N8N_SERVICO_WEBHOOK="$nome"; N8N_ROUTER_WEBHOOK="$r"
            grep -q "^traefik\.http\.routers\.$r\.middlewares=" "$TMP/labels" && N8N_TEM_MIDDLEWARE=1
        elif [ -z "$r" ] && [ -z "$N8N_TRAEFIK_EDITOR" ]; then
            N8N_TRAEFIK_EDITOR="$t"; N8N_SERVICO_EDITOR="$nome"
        fi
    done

    APP_HOST_ANTIGO="$app"
    SUPABASE_URL="${SUPABASE_URL:+$(normalizar_supabase_url "$SUPABASE_URL")}"

    ## Evolution antiga: continua rodando e o sistema novo usa ela
    if [ -n "$EVO_SERVICO_EXT" ]; then
        v="$(env_de service "$EVO_SERVICO_EXT" SERVER_URL)"
        [ -n "$v" ] && EVO_HOST_ANTIGO="$(host_de_url "$v")"
        v="$(env_de service "$EVO_SERVICO_EXT" AUTHENTICATION_API_KEY)"
        [ -n "$v" ] && EVOLUTION_API_KEY="$v"
        [ -n "${EVO_HOST_ANTIGO:-}" ] && EVO_EXTERNA=1
    fi

    ## MinIO antigo: continua rodando (mesmo bucket, links das mídias continuam valendo)
    if [ -n "$MINIO_SERVICO_EXT" ]; then
        v="$(env_de service "$MINIO_SERVICO_EXT" MINIO_SERVER_URL)"
        [ -n "$v" ] && S3_HOST_ANTIGO="$(host_de_url "$v")"
        MINIO_ROOT_USER="$(env_de service "$MINIO_SERVICO_EXT" MINIO_ROOT_USER)"
        MINIO_ROOT_PASSWORD="$(env_de service "$MINIO_SERVICO_EXT" MINIO_ROOT_PASSWORD)"
        if [ -f /root/dados_vps/dados_minio ]; then
            preencher S3_ACCESS_KEY "$(sed -n 's/^Access Key: *//p' /root/dados_vps/dados_minio | head -1 | tr -d '\r')"
            preencher S3_SECRET_KEY "$(sed -n 's/^Secret Key: *//p' /root/dados_vps/dados_minio | head -1 | tr -d '\r')"
        fi
        [ -n "${S3_HOST_ANTIGO:-}" ] && S3_EXTERNO=1
    fi
    ## Chave pela metade não serve: o setup cria uma nova no MinIO
    if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then S3_ACCESS_KEY=""; S3_SECRET_KEY=""; fi

    ## Endereços já conhecidos viram as respostas padrão do passo 1
    if [ -n "$app" ]; then
        APP_HOST="$app"
        DOMINIO_BASE="${app#*.}"
        SUB_APP="${app%%.*}"
        EVO_HOST="${EVO_HOST_ANTIGO:-wpp.$DOMINIO_BASE}"
        S3_HOST="${S3_HOST_ANTIGO:-s3.$DOMINIO_BASE}"
        SUB_EVO="${EVO_HOST%%.*}"
        SUB_S3="${S3_HOST%%.*}"
    fi
    return 0
}

## Tela de aviso: "Você tem a versão antiga do sistema. Deseja instalar a nova?"
oferecer_migracao() {
    banner
    titulo_caixa "VOCÊ TEM A VERSÃO ANTIGA DO SISTEMA" "$amarelo"
    echo ""
    abrir_bloco "ENCONTREI NESTA VPS" "$amarelo"
    [ ${#ANTIGO_N8N[@]} -gt 0 ] && item "N8N" "${APP_HOST_ANTIGO:-?}  (${ANTIGO_N8N[*]})"
    [ ${#ANTIGO_DISPARADOR[@]} -gt 0 ] && item "Disparador" "${ANTIGO_DISPARADOR[*]}"
    [ ${#ANTIGO_CONTAINERS[@]} -gt 0 ] && item "Disparador" "${ANTIGO_CONTAINERS[*]}"
    [ "$EVO_EXTERNA" = 1 ] && item "WhatsApp" "$EVO_HOST_ANTIGO  (Evolution)"
    [ "$S3_EXTERNO" = 1 ] && item "Arquivos" "$S3_HOST_ANTIGO  (MinIO)"
    fechar_bloco
    abrir_bloco "O QUE A NOVA VERSÃO FAZ" "$azul"
    item "Remove" "o Disparador antigo"
    item "Instala" "o novo HubLabel em ${APP_HOST_ANTIGO:-app.seudominio}"
    local mantem=""
    [ "$EVO_EXTERNA" = 1 ] && mantem+="Evolution (WhatsApps conectados), "
    [ "$S3_EXTERNO" = 1 ] && mantem+="MinIO (arquivos), "
    item "Mantém" "${mantem}Portainer e o seu Supabase"
    fechar_bloco
    sim_nao "Deseja instalar a nova versão?" S
    if [ $? != 0 ]; then
        echo ""
        info "Tudo bem, nada foi alterado na VPS."
        exit 0
    fi
    MIGRACAO=1
    if [ ${#ANTIGO_N8N[@]} -gt 0 ]; then
        echo ""
        texto "E o ${branco}N8N${reset}? Ele é usado para outros fluxos, além do HubLabel?"
        if [ -n "$N8N_TRAEFIK_WEBHOOK" ] && [ "$MODO_ROTA" = labels ]; then
            dica "S = manter: os fluxos \"$PREFIXO_FLUXOS_SAAS - ...\" são desativados e os outros continuam,"
            dica "    com o link de webhook em https://$APP_HOST_ANTIGO/webhook/..."
            dica "N = remover o N8N (os fluxos deixam de existir; exporte antes o que quiser guardar)"
            echo ""
            sim_nao "Manter o N8N?" S
            [ $? != 1 ] && MANTER_N8N=1
        else
            aviso "Não consegui separar o N8N do novo sistema nesta VPS: ele será removido."
            aviso "Os fluxos do N8N deixam de existir. Exporte antes o que quiser guardar."
            enter "Aperte Enter para continuar (ou Ctrl+C para cancelar)..."
        fi
    fi
    if [ "$EVO_EXTERNA" = 1 ] && [ -z "${EVOLUTION_API_KEY:-}" ]; then
        echo ""
        texto "Não encontrei a API Key global da Evolution atual."
        perguntar EVOLUTION_API_KEY "API Key da Evolution" || exit 0
    fi
}

## Monta a lista do que remover: a stack inteira só quando ela tem apenas N8N, Redis e Disparador
planejar_remocao() {
    REMOVER_STACKS=(); REMOVER_SERVICOS=()
    local s ns outros alvos=("${ANTIGO_DISPARADOR[@]}")
    [ "$MANTER_N8N" = 1 ] || alvos+=("${ANTIGO_N8N[@]}")
    for s in "${alvos[@]}"; do
        ns="$(ns_de "$s")"
        if [ -n "$ns" ]; then
            outros="$(docker service ls --filter "label=com.docker.stack.namespace=$ns" --format '{{.Image}}' 2>/dev/null \
                | grep -viE 'n8n|redis|hublabel-disparador')"
            if [ -z "$outros" ]; then
                [[ " ${REMOVER_STACKS[*]} " == *" $ns "* ]] || REMOVER_STACKS+=("$ns")
                continue
            fi
        fi
        REMOVER_SERVICOS+=("$s")
    done
}

## Apaga as stacks também no Portainer (senão elas ficam lá e podem ser publicadas de novo)
remover_stacks_portainer() {
    [ -f /root/dados_vps/dados_portainer ] || return 0
    python3 -I - "$@" <<'PYEOF'
import json, re, ssl, sys, urllib.request

txt = open("/root/dados_vps/dados_portainer", errors="ignore").read()

def campo(nome):
    m = re.search(rf"^{nome}:[ \t]*(.*)$", txt, re.M)
    return m.group(1).strip() if m else ""

host = re.sub(r"^https?://", "", campo("Dominio do portainer")).split("/")[0]
usuario, senha = campo("Usuario"), campo("Senha")
if not (host and usuario and senha):
    sys.exit(0)
ctx = ssl._create_unverified_context()

def chamar(base, host_hdr, metodo, caminho, corpo=None, token=None):
    h = {"Content-Type": "application/json"}
    if host_hdr:
        h["Host"] = host_hdr
    if token:
        h["Authorization"] = "Bearer " + token
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(base + caminho, data=dados, method=metodo, headers=h)
    with urllib.request.urlopen(req, timeout=10, context=ctx) as r:
        return json.loads(r.read().decode() or "null")

for base, host_hdr in (("https://127.0.0.1", host), ("https://" + host, None)):
    try:
        token = chamar(base, host_hdr, "POST", "/api/auth", {"username": usuario, "password": senha})["jwt"]
        pilhas = chamar(base, host_hdr, "GET", "/api/stacks", token=token) or []
    except Exception:
        continue
    for p in pilhas:
        if p.get("Name") in sys.argv[1:]:
            try:
                chamar(base, host_hdr, "DELETE", f"/api/stacks/{p['Id']}?endpointId={p.get('EndpointId')}", token=token)
            except Exception:
                pass
    break
PYEOF
}

antigos_removidos() {
    local ns s
    for ns in "${REMOVER_STACKS[@]}"; do
        [ -z "$(docker service ls -q --filter "label=com.docker.stack.namespace=$ns" 2>/dev/null)" ] || return 1
        [ -z "$(docker ps -q --filter "label=com.docker.stack.namespace=$ns" 2>/dev/null)" ] || return 1
    done
    for s in "${REMOVER_SERVICOS[@]}"; do
        docker service inspect "$s" >/dev/null 2>&1 && return 1
    done
    return 0
}

remover_versao_antiga() {
    local ns s
    planejar_remocao
    [ ${#REMOVER_STACKS[@]} -gt 0 ] && remover_stacks_portainer "${REMOVER_STACKS[@]}" >/dev/null 2>&1
    for ns in "${REMOVER_STACKS[@]}"; do docker stack rm "$ns" >/dev/null 2>&1; done
    for s in "${REMOVER_SERVICOS[@]}"; do docker service rm "$s" >/dev/null 2>&1; done
    for s in "${ANTIGO_CONTAINERS[@]}"; do docker rm -f "$s" >/dev/null 2>&1; done
    esperar "Removendo $([ "$MANTER_N8N" = 1 ] || echo "o N8N e ")o Disparador antigo" 180 antigos_removidos \
        || aviso "Ainda tem partes da versão antiga saindo. Se o sistema não abrir, confira no Portainer."
}

## ---------------------------------------------------------------- Manter o N8N
## Comando do N8N dentro do container dele (usa o banco configurado no próprio container)
n8n_cli() { docker exec "$N8N_CID" n8n "$@" </dev/null; }

## Fluxos ativos do HubLabel antigo, um por linha: id|nome
fluxos_saas_ativos() {
    n8n_cli list:workflow --active=true 2>/dev/null \
        | awk -v pre="$PREFIXO_FLUXOS_SAAS" -F'|' 'NF >= 2 && $1 ~ /^[A-Za-z0-9]+$/ && index(toupper(substr($0, length($1) + 2)), toupper(pre)) == 1'
}

## n8n 2.x usa unpublish; versões anteriores, update --active=false
desativar_fluxos() {
    local id
    for id in "$@"; do
        n8n_cli unpublish:workflow --id="$id" >/dev/null 2>&1 \
            || n8n_cli update:workflow --id="$id" --active=false >/dev/null 2>&1
    done
    return 0
}

## Reinicia o N8N para valer a mudança dos fluxos; no serviço de webhook tira também o
## middleware que acrescentava /webhook (o link volta a ser o padrão: app.*/webhook/...)
reiniciar_n8n() {
    local ns s img extra
    ns="$(ns_de "$N8N_SERVICO_WEBHOOK")"
    if [ -n "$ns" ]; then
        docker service ls --filter "label=com.docker.stack.namespace=$ns" --format '{{.Name}} {{.Image}}' >"$TMP/n8n_servicos"
    else
        printf '%s n8n\n' "${ANTIGO_N8N[@]}" >"$TMP/n8n_servicos"
    fi
    while read -r s img; do
        [[ "${img,,}" == *n8n* ]] || continue
        extra=()
        [ "$s" = "$N8N_SERVICO_WEBHOOK" ] && [ "$N8N_TEM_MIDDLEWARE" = 1 ] \
            && extra=(--label-rm "traefik.http.routers.$N8N_ROUTER_WEBHOOK.middlewares")
        docker service update --detach --force "${extra[@]}" "$s" >/dev/null 2>&1 </dev/null || return 1
    done <"$TMP/n8n_servicos"
}

ajustar_n8n_mantido() {
    local svc ids=() lista restantes
    svc="${N8N_SERVICO_EDITOR:-$N8N_SERVICO_WEBHOOK}"
    N8N_CID="$(docker ps -q -f "label=com.docker.swarm.service.name=$svc" | head -1)"
    if [ -z "$N8N_CID" ]; then
        aviso "O N8N não está rodando: desative à mão os fluxos \"$PREFIXO_FLUXOS_SAAS - ...\"."
    else
        girar "Procurando os fluxos \"$PREFIXO_FLUXOS_SAAS\" no N8N" fluxos_saas_ativos
        lista="$(cat "$TMP/ultimo.log")"
        if [ -n "$lista" ]; then
            mapfile -t ids < <(printf '%s\n' "$lista" | cut -d'|' -f1)
            girar "Desativando ${#ids[@]} fluxo(s) do HubLabel antigo" desativar_fluxos "${ids[@]}"
            restantes="$(fluxos_saas_ativos)"
            if [ -n "$restantes" ]; then
                aviso "Não consegui desativar estes fluxos. Desative no editor do N8N:"
                printf '%s\n' "$restantes" | cut -d'|' -f2- | sed 's/^/      - /'
            fi
        else
            ok "Nenhum fluxo \"$PREFIXO_FLUXOS_SAAS\" ativo"
        fi
    fi
    girar "Reiniciando o N8N" reiniciar_n8n || aviso "Não consegui reiniciar o N8N. Reinicie a stack dele no Portainer."
}

## O N8N responde a webhook que não existe com "The requested webhook ... is not registered"
n8n_no_ar() {
    curl -sk --max-time 10 --resolve "$APP_HOST:443:127.0.0.1" "https://$APP_HOST/webhook/hublabel-teste-de-rota" \
        | grep -qi 'is not registered\|requested webhook'
}

verificar_rota_n8n() {
    esperar "Conferindo os webhooks do N8N em https://$APP_HOST/webhook/" 120 n8n_no_ar && return 0
    aviso "O N8N ainda não respondeu em https://$APP_HOST/webhook/. Confira a stack dele no Portainer."
}

## ============================================================================
## ASSISTENTE (PERGUNTAS)
## ============================================================================

## ---------------------------------------------------------------- Passo 1: domínios
## Deixa só o domínio: tira http(s)://, www., caminho, porta, espaços e ponto no fim
## Ex.: "HTTPS://www.SuaEmpresa.com.br/login" → "suaempresa.com.br"
normalizar_dominio() {
    local d
    d="$(limpar "$1")"
    d="${d,,}"
    d="${d// /}"
    d="$(printf '%s' "$d" | sed -E 's#^[a-z]+:/*##; s#^[^@/]*@##; s#[/?\#].*$##; s#:[0-9]*$##; s#\.+$##; s#^(www\.)+##')"
    printf '%s' "$d"
}

## Subdomínio: só a primeira parte (ex.: "https://app.suaempresa.com.br" → "app")
normalizar_sub() {
    local d
    d="$(normalizar_dominio "$1")"
    printf '%s' "${d%%.*}"
}

## Migração: os endereços já vêm da instalação antiga. WhatsApp e arquivos ficam
## presos aos da Evolution e do MinIO antigos, que continuam rodando.
passo_dominios_migracao() {
    local h
    while :; do
        cabecalho_passo 1 "DOMÍNIOS"
        texto "Estes são os endereços da sua instalação atual:"
        echo ""
        abrir_bloco "ENDEREÇOS DO SEU SISTEMA" "$azul"
        item "Sistema" "$APP_HOST"
        item "WhatsApp" "$EVO_HOST"
        item "Arquivos" "$S3_HOST"
        fechar_bloco
        dica "O novo sistema entra no lugar do N8N. WhatsApp e arquivos continuam onde já estão."
        echo ""
        sim_nao "Usar esses endereços?" S
        case $? in
            2) continue ;;
            1)
                echo ""
                dica "Digite o endereço completo (ex.: app.suaempresa.com.br)."
                perguntar h "Sistema" "$APP_HOST" || continue
                APP_HOST="$(normalizar_dominio "$h")"
                if [ "$EVO_EXTERNA" != 1 ]; then
                    perguntar h "WhatsApp" "$EVO_HOST" || continue
                    EVO_HOST="$(normalizar_dominio "$h")"
                fi
                if [ "$S3_EXTERNO" != 1 ]; then
                    perguntar h "Arquivos" "$S3_HOST" || continue
                    S3_HOST="$(normalizar_dominio "$h")"
                fi
                ;;
        esac
        if [ "$APP_HOST" = "$EVO_HOST" ] || [ "$APP_HOST" = "$S3_HOST" ] || [ "$EVO_HOST" = "$S3_HOST" ]; then
            falha "Os três endereços precisam ser diferentes."
            enter
            continue
        fi
        DOMINIO_BASE="${APP_HOST#*.}"
        SUB_APP="${APP_HOST%%.*}"; SUB_EVO="${EVO_HOST%%.*}"; SUB_S3="${S3_HOST%%.*}"
        verificar_dns && return 0
    done
}

passo_dominios() {
    if [ "$MIGRACAO" = 1 ] && [ -n "${APP_HOST:-}" ]; then
        passo_dominios_migracao
        return
    fi
    while :; do
        cabecalho_passo 1 "DOMÍNIOS"
        texto "Qual é o domínio da sua empresa?"
        dica "Exemplo: suaempresa.com.br  (sem https:// e sem www)"
        echo ""
        local d
        perguntar d "Domínio" "${DOMINIO_BASE:-}" || return 1
        DOMINIO_BASE="$(normalizar_dominio "$d")"
        [ "$DOMINIO_BASE" != "$(limpar "$d")" ] && dica "  Ajustei para: $DOMINIO_BASE"
        if ! [[ "$DOMINIO_BASE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            falha "Domínio inválido: $DOMINIO_BASE"
            enter
            continue
        fi

        echo ""
        abrir_bloco "ENDEREÇOS DO SEU SISTEMA" "$azul"
        item "Sistema" "${SUB_APP:-app}.$DOMINIO_BASE"
        item "WhatsApp" "${SUB_EVO:-wpp}.$DOMINIO_BASE"
        item "Arquivos" "${SUB_S3:-s3}.$DOMINIO_BASE"
        fechar_bloco
        sim_nao "Usar esses endereços?" S
        case $? in
            2) continue ;;
            0) SUB_APP="${SUB_APP:-app}"; SUB_EVO="${SUB_EVO:-wpp}"; SUB_S3="${SUB_S3:-s3}" ;;
            1)
                echo ""
                dica "Digite só a primeira parte do endereço (ex.: app)."
                perguntar SUB_APP "Sistema" "${SUB_APP:-app}" || continue
                perguntar SUB_EVO "WhatsApp" "${SUB_EVO:-wpp}" || continue
                perguntar SUB_S3 "Arquivos" "${SUB_S3:-s3}" || continue
                SUB_APP="$(normalizar_sub "$SUB_APP")"; SUB_EVO="$(normalizar_sub "$SUB_EVO")"; SUB_S3="$(normalizar_sub "$SUB_S3")"
                ;;
        esac
        APP_HOST="$SUB_APP.$DOMINIO_BASE"
        EVO_HOST="$SUB_EVO.$DOMINIO_BASE"
        S3_HOST="$SUB_S3.$DOMINIO_BASE"
        ## Evolution e MinIO antigos continuam nos endereços deles
        [ "$EVO_EXTERNA" = 1 ] && EVO_HOST="$EVO_HOST_ANTIGO"
        [ "$S3_EXTERNO" = 1 ] && S3_HOST="$S3_HOST_ANTIGO"
        if [ "$APP_HOST" = "$EVO_HOST" ] || [ "$APP_HOST" = "$S3_HOST" ] || [ "$EVO_HOST" = "$S3_HOST" ]; then
            falha "Os três endereços precisam ser diferentes."
            enter
            continue
        fi
        verificar_dns && return 0
    done
}

## Retorna 0 = DNS ok (ou seguir mesmo assim), 1 = voltar e corrigir os domínios
verificar_dns() {
    local ip_vps tudo_ok resp h ip ips
    ip_vps="$(ip_da_vps)"
    while :; do
        echo ""
        info "Conferindo se os endereços já apontam para esta VPS ${cinza}(${ip_vps:-IP desconhecido})${reset}..."
        tudo_ok=1
        for h in "$APP_HOST" "$EVO_HOST" "$S3_HOST"; do
            ips="$(ips_do_dominio "$h")"
            if [ -n "$ips" ] && { [ -z "$ip_vps" ] || printf '%s\n' "$ips" | grep -qxF "$ip_vps"; }; then
                echo -e "    ${verde}✔${reset} $h"
            else
                ip="$(printf '%s\n' "$ips" | head -1)"
                echo -e "    ${vermelho}✘${reset} $h ${cinza}→ ${ip:-não encontrado}${reset}"
                tudo_ok=0
            fi
        done
        [ "$tudo_ok" = 1 ] && { echo ""; ok "Tudo certo com os endereços!"; sleep 1; return 0; }
        echo ""
        abrir_bloco "COMO APONTAR" "$amarelo"
        item "Onde" "no painel do seu domínio (Registro.br, Cloudflare, Hostinger...)"
        item "Tipo" "A"
        item "Nome" "a primeira parte de cada endereço com ✘ (ex.: $SUB_APP)"
        item "Valor" "${ip_vps:-o IP desta VPS}"
        fechar_bloco
        dica "Usa Cloudflare? Deixe a nuvem cinza (\"somente DNS\"). Pode levar alguns minutos para valer."
        echo ""
        printf '%b' "  ${branco}Enter${reset} conferir de novo  ${cinza}•${reset}  ${branco}C${reset} continuar assim  ${cinza}•${reset}  ${branco}0${reset} corrigir os endereços: "
        ler resp
        resp="$(limpar "$resp")"
        case "$resp" in
            0) return 1 ;;
            [cC]*) aviso "Sem o apontamento certo o sistema não abre. Corrija assim que puder."; sleep 2; return 0 ;;
        esac
    done
}

## ---------------------------------------------------------------- Passo 2: Supabase
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

## Esconde o meio de uma chave: eyJhbGci…x1Yz
resumir_chave() { local k="$1"; [ "${#k}" -gt 16 ] && printf '%s…%s' "${k:0:8}" "${k: -4}" || printf '%s' "$k"; }

supabase_pedir_url() {
    instrucao "1." "Copie a ${branco}Project URL${reset} ${cinza}(parece com https://abcdefgh.supabase.co)${reset}"
    echo ""
    local u codigo
    while :; do
        perguntar u "Project URL" "${SUPABASE_URL:-}" || return 1
        SUPABASE_URL="$(normalizar_supabase_url "$u")"
        [ "$SUPABASE_URL" != "$(limpar "$u")" ] && dica "  Ajustei para: $SUPABASE_URL"
        codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SUPABASE_URL/auth/v1/health")"
        if [ "$codigo" = "000" ]; then
            falha "Não consegui acessar $SUPABASE_URL. Confira se copiou a URL certa."
            continue
        fi
        return 0
    done
}

supabase_pedir_anon() {
    instrucao "2." "Copie a chave ${branco}anon public${reset} ${cinza}(começa com eyJ... ou sb_publishable_...)${reset}"
    echo ""
    local k papel ref codigo
    while :; do
        perguntar k "Chave anon public" "${SUPABASE_ANON_KEY:-}" || return 1
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
            falha "O Supabase recusou essa chave. Copie de novo, inteira."
            continue
        fi
        SUPABASE_ANON_KEY="$k"
        return 0
    done
}

supabase_pedir_service() {
    instrucao "3." "Copie a chave ${branco}service_role${reset} ${cinza}(clique em Reveal; começa com eyJ... ou sb_secret_...)${reset}"
    echo ""
    local k ref codigo
    while :; do
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
            falha "O Supabase recusou essa chave. Copie de novo, inteira."
            continue
        fi
        SUPABASE_SERVICE_ROLE_KEY="$k"
        return 0
    done
}

passo_supabase() {
    local sub=0 aproveitar="$MIGRACAO"
    ## Migração: a URL e a service_role vêm do Disparador antigo; a anon public precisa ser informada
    if [ "$MIGRACAO" = 1 ] && [ -n "${SUPABASE_URL:-}" ] \
        && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SUPABASE_URL/auth/v1/health")" != 000 ]; then
        sub=1
    fi
    while :; do
        cabecalho_passo 2 "SUPABASE"
        texto "Abra o seu projeto no ${branco}Supabase${reset} e vá em ${branco}Project Settings → API${reset}."
        dica "(ou clique no botão Connect, no topo da tela do projeto)"
        [ "$MIGRACAO" = 1 ] && dica "Os dados que já estavam na instalação antiga aparecem preenchidos: só aperte Enter."
        echo ""
        [ "$sub" -gt 0 ] && feito "Project URL" "$SUPABASE_URL"
        [ "$sub" -gt 1 ] && feito "Chave anon public" "$(resumir_chave "$SUPABASE_ANON_KEY")"
        [ "$sub" -gt 0 ] && echo ""
        case "$sub" in
            0) supabase_pedir_url || return 1; sub=1 ;;
            1) if supabase_pedir_anon; then sub=2; else sub=0; fi ;;
            2)
                if [ "$aproveitar" = 1 ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] \
                    && [ "$(supabase_curl "$SUPABASE_SERVICE_ROLE_KEY" "$SUPABASE_URL/auth/v1/admin/users?page=1&per_page=1")" = 200 ]; then
                    aproveitar=0
                    feito "Chave service_role" "$(resumir_chave "$SUPABASE_SERVICE_ROLE_KEY")"
                    echo ""
                    ok "Supabase conectado!"
                    sleep 1
                    return 0
                fi
                aproveitar=0
                if supabase_pedir_service; then
                    feito "Chave service_role" "$(resumir_chave "$SUPABASE_SERVICE_ROLE_KEY")"
                    echo ""
                    ok "Supabase conectado!"
                    sleep 1
                    return 0
                fi
                sub=1
                ;;
        esac
    done
}

## ---------------------------------------------------------------- Passo 3: tabelas
tabelas_faltando() {
    local t codigo faltando=()
    for t in "${TABELAS_SQL[@]}"; do
        codigo="$(supabase_curl "$SUPABASE_SERVICE_ROLE_KEY" "$SUPABASE_URL/rest/v1/$t?select=*&limit=1")"
        [ "$codigo" = "200" ] || faltando+=("$t")
    done
    printf '%s ' "${faltando[@]}"
}

passo_sql() {
    cabecalho_passo 3 "TABELAS"
    local falta resp
    info "Conferindo as tabelas no seu Supabase..."
    falta="$(tabelas_faltando)"
    if [ "$MIGRACAO" = 1 ] && [ "${SQL_MIGRACAO_OK:-0}" = 0 ]; then
        echo ""
        aviso "Seu Supabase é da versão antiga: rode o SQL novo para atualizar as tabelas."
        dica "Pode rodar sem medo: ele só cria o que falta e atualiza as funções. Seus dados ficam."
        echo ""
    elif [ -z "${falta// /}" ]; then
        ok "Tabelas do sistema encontradas!"
        sleep 1
        return 0
    else
        echo ""
        falha "As tabelas do sistema ainda não existem no seu Supabase."
        echo ""
    fi
    texto "Siga o ${branco}vídeo de instalação${reset} para criar as tabelas:"
    echo ""
    instrucao "1." "Copie o ${branco}SQL${reset} que está na ${branco}descrição do vídeo${reset} ou neste link:"
    echo -e "      ${verde}$SQL_URL${reset}"
    instrucao "2." "Abra o ${branco}SQL Editor${reset} do seu Supabase e cole o SQL"
    instrucao "3." "Clique em ${branco}Run${reset} e espere aparecer ${branco}Success${reset}"
    echo ""
    while :; do
        printf '%b' "  ${ciano}➜${reset} Aperte ${branco}Enter${reset} depois de rodar o SQL ${cinza}(0 = voltar)${reset}: "
        ler resp
        [ "$(limpar "$resp")" = "0" ] && return 1
        info "Conferindo..."
        falta="$(tabelas_faltando)"
        if [ -z "${falta// /}" ]; then
            SQL_MIGRACAO_OK=1
            ok "Tabelas criadas!"
            sleep 1
            return 0
        fi
        falha "As tabelas ainda não foram encontradas."
        dica "Confira se rodou o SQL no projeto certo ($SUPABASE_URL) e se terminou com Success."
        echo ""
    done
}

## ---------------------------------------------------------------- Passo 4: licença
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
    cabecalho_passo 4 "LICENÇA"
    texto "Informe o e-mail usado na compra do HubLabel."
    echo -e "  ${amarelo}⚠  Cada licença vale para uma instalação.${reset}"
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
        LICENCA_MOTIVO=""
        info "Verificando a licença..."
        consultar_licenca
        case $? in
            0)
                ok "Licença liberada!"
                sleep 1
                return 0
                ;;
            1)
                falha "Licença não liberada: ${LICENCA_MOTIVO:-recusada}"
                case "$LICENCA_MOTIVO" in
                    *"sem licença"*) dica "Confira se é exatamente o e-mail da compra. Se estiver certo, fale com o suporte." ;;
                    *) dica "Fale com o suporte do HubLabel." ;;
                esac
                echo ""
                ;;
            2)
                falha "Não consegui falar com o servidor de licenças agora."
                printf '%b' "  ${branco}Enter${reset} tentar de novo  ${cinza}•${reset}  ${branco}C${reset} continuar sem verificar  ${cinza}•${reset}  ${branco}0${reset} voltar: "
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

## ---------------------------------------------------------------- Passo 5: seu sistema
## Busca um usuário do sistema pelo e-mail → imprime o id (vazio se não existe)
usuario_por_email() {
    local q
    q="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"
    supabase_curl "$SUPABASE_SERVICE_ROLE_KEY" "$SUPABASE_URL/rest/v1/SAAS_Usuarios?select=id&Email=eq.$q&limit=1" >/dev/null
    sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$TMP/resp"
}

passo_acesso() {
    local sub=0
    while :; do
        cabecalho_passo 5 "SEU SISTEMA"
        if [ "$sub" = 0 ]; then
            texto "Qual nome você quer dar ao seu sistema?"
            dica "Ele aparece nas telas e na aba do navegador. Dá para mudar depois no painel."
            echo ""
            perguntar NOME_SISTEMA "Nome do sistema" "${NOME_SISTEMA:-}" || return 1
            NOME_SISTEMA="$(printf '%s' "$NOME_SISTEMA" | tr -d "\"'\\\\<>\`\$")"
            sub=1
            continue
        fi
        feito "Nome do sistema" "$NOME_SISTEMA"
        echo ""
        texto "Qual e-mail vai ser o ${branco}super administrador${reset} (o dono do sistema)?"
        dica "A senha inicial será $ADMIN_SENHA_PADRAO. Troque depois de entrar."
        echo ""
        local e
        while :; do
            perguntar e "E-mail do administrador" "${ADMIN_EMAIL:-$LICENCA_EMAIL}" || { sub=0; continue 2; }
            e="${e,,}"
            if ! [[ "$e" =~ ^[^@[:space:]\"\']+@[^@[:space:]\"\']+\.[^@[:space:]\"\']+$ ]]; then
                falha "E-mail inválido."
                continue
            fi
            ADMIN_EMAIL="$e"
            break
        done
        if [ -n "$(usuario_por_email "$ADMIN_EMAIL")" ]; then
            ok "Esse e-mail já tem conta no sistema. A senha dele continua a mesma."
            sleep 2
        fi
        return 0
    done
}

## ---------------------------------------------------------------- Confirmação
assistente() {
    local passos=(passo_dominios passo_supabase passo_sql passo_licenca passo_acesso)
    local i r
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
        trilha $((TOTAL_PASSOS + 1))
        echo ""
        titulo_caixa "CONFIRA OS DADOS"
        echo ""
        abrir_bloco "ENDEREÇOS" "$azul"
        item "Sistema" "https://$APP_HOST"
        item "WhatsApp" "https://$EVO_HOST"
        item "Arquivos" "https://$S3_HOST"
        fechar_bloco
        abrir_bloco "SEU SISTEMA" "$roxo"
        item "Nome" "$NOME_SISTEMA"
        item "Administrador" "$ADMIN_EMAIL"
        item "Licença" "$LICENCA_EMAIL"
        item "Supabase" "$SUPABASE_URL"
        fechar_bloco
        if [ "$MIGRACAO" = 1 ]; then
            abrir_bloco "VERSÃO ANTIGA" "$amarelo"
            if [ "$MANTER_N8N" = 1 ]; then
                item "Remover" "Disparador antigo"
                item "Manter" "N8N em https://$APP_HOST/webhook/... (fluxos $PREFIXO_FLUXOS_SAAS desativados)"
            else
                item "Remover" "N8N e Disparador antigo"
            fi
            [ "$EVO_EXTERNA" = 1 ] && item "Manter" "Evolution em $EVO_HOST (WhatsApps conectados)"
            [ "$S3_EXTERNO" = 1 ] && item "Manter" "MinIO em $S3_HOST (arquivos)"
            fechar_bloco
        fi
        sim_nao "Está tudo certo? S = instalar  •  N = corrigir" S
        r=$?
        [ $r = 0 ] && return 0
        dica "Vamos refazer. Aperte Enter nas respostas que já estão certas."
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
        apt-get update -qq && apt-get install -y -qq python3 >/dev/null
    fi
    local ram
    ram="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
    if [ -n "$ram" ] && [ "$ram" -lt 1800 ]; then
        aviso "Esta VPS tem ${ram}MB de memória. O recomendado é 2GB ou mais."
        sleep 2
    fi
}

instalar_docker_agora() {
    apt-get update -qq || return 1
    timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
    curl -fsSL https://get.docker.com | sh
}

instalar_compose_agora() {
    apt-get update -qq || return 1
    apt-get install -y -qq docker-compose-plugin || apt-get install -y -qq docker-compose-v2
}

instalar_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || erro "Não encontrei o apt-get. Instale o Docker e rode de novo."
        girar "Preparando a VPS (pode levar alguns minutos)" instalar_docker_agora || erro "Não consegui preparar a VPS (instalação do Docker)."
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    if [ "$MODO_DEPLOY" = compose ] && ! docker compose version >/dev/null 2>&1; then
        girar "Instalando componentes" instalar_compose_agora || erro "Não consegui instalar o Docker Compose."
    fi
    docker info >/dev/null 2>&1 || erro "O Docker não está rodando."
}

## ============================================================================
## CONFIGURAÇÃO SALVA (/opt/hublabel/.env)
## ============================================================================

VARS_SALVAS=(MODO_DEPLOY MODO_ROTA PAINEL TRAEFIK_RESOLVER TRAEFIK_ENTRYPOINT TRAEFIK_REDE TRAEFIK_LABEL_REDE
    TRAEFIK_PASTA_ARQUIVOS REDE_INTERNA PORTA_APP PORTA_EVO PORTA_S3
    DOMINIO_BASE SUB_APP SUB_EVO SUB_S3 APP_HOST EVO_HOST S3_HOST
    SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY LICENCA_EMAIL BACK_PATH NOME_SISTEMA ADMIN_EMAIL
    EVOLUTION_API_KEY POSTGRES_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY
    EVO_EXTERNA S3_EXTERNO MINIO_SERVICO_EXT MANTER_N8N N8N_TRAEFIK_WEBHOOK N8N_TRAEFIK_EDITOR)

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
    ## Instalações antigas usavam /webhook no endereço: mantém para não quebrar os webhooks já cadastrados
    BACK_PATH="${BACK_PATH-/webhook}"
}

gerar_segredos() {
    EVOLUTION_API_KEY="${EVOLUTION_API_KEY:-$(aleatorio 16)}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(aleatorio 16)}"
    ## MinIO antigo: as credenciais de administrador são as dele (não inventa outras)
    if [ "${S3_EXTERNO:-0}" != 1 ]; then
        MINIO_ROOT_USER="${MINIO_ROOT_USER:-hublabel}"
        MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(aleatorio 16)}"
    fi
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
        [ "${EVO_EXTERNA:-0}" != 1 ] && PORTA_EVO="${PORTA_EVO:-$(porta_livre_a_partir_de 8080)}"
        [ "${S3_EXTERNO:-0}" != 1 ] && PORTA_S3="${PORTA_S3:-$(porta_livre_a_partir_de 9000)}"
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
    if [ "$n" = hublabel_app ] && [ "${MANTER_N8N:-0}" = 1 ]; then
        ## N8N mantido: o app.* é do sistema (acima do roteador antigo do N8N) e só /webhook... vai para o N8N
        printf '%s- traefik.http.routers.%s.priority=100\n' "$ind" "$n"
        rota_n8n hublabel_n8n 'PathPrefix(`/webhook/`) || PathPrefix(`/webhook-waiting/`)' "$N8N_TRAEFIK_WEBHOOK" "$h" "$ind"
        ## URL de teste fica no editor (processo principal do N8N)
        rota_n8n hublabel_n8n_teste 'PathPrefix(`/webhook-test/`)' "${N8N_TRAEFIK_EDITOR:-$N8N_TRAEFIK_WEBHOOK}" "$h" "$ind"
    fi
}

## Roteador do sistema que aponta para um serviço do N8N (definido na stack dele)
rota_n8n() { # rota_n8n ROUTER CAMINHOS SERVICO HOST INDENT
    local n="$1" caminhos="$2" s="$3" h="$4" ind="$5"
    printf '%s- traefik.http.routers.%s.rule=Host(`%s`) && (%s)\n' "$ind" "$n" "$h" "$caminhos"
    printf '%s- traefik.http.routers.%s.entrypoints=%s\n' "$ind" "$n" "$TRAEFIK_ENTRYPOINT"
    printf '%s- traefik.http.routers.%s.priority=1000\n' "$ind" "$n"
    printf '%s- traefik.http.routers.%s.tls=true\n' "$ind" "$n"
    [ -n "$TRAEFIK_RESOLVER" ] && printf '%s- traefik.http.routers.%s.tls.certresolver=%s\n' "$ind" "$n" "$TRAEFIK_RESOLVER"
    printf '%s- traefik.http.routers.%s.service=%s\n' "$ind" "$n" "$s"
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
    local evo_ext="${EVO_EXTERNA:-0}" s3_ext="${S3_EXTERNO:-0}"
    ## MinIO antigo fica em outra stack: o sistema fala com ele pelo endereço público (como o Disparador antigo)
    local s3_endpoint="http://hublabel-minio:9000"
    [ "$s3_ext" = 1 ] && s3_endpoint="https://$S3_HOST"
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
      BACK_URL: "https://$APP_HOST${BACK_PATH:-}"
      EVOLUTION_BASE_URL: "https://$EVO_HOST"
      EVOLUTION_API_KEY: "$EVOLUTION_API_KEY"
      S3_ENDPOINT: "$s3_endpoint"
      S3_ACCESS_KEY_ID: "$S3_ACCESS_KEY"
      S3_SECRET_ACCESS_KEY: "$S3_SECRET_KEY"
      S3_BUCKET: "$S3_BUCKET"
      S3_REGION: "eu-south"
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
        if [ "$MODO_DEPLOY" = compose ]; then
            [ "$s3_ext" = 1 ] && echo "    depends_on: [hublabel-redis]" || echo "    depends_on: [hublabel-redis, hublabel-minio]"
        fi
        extras hublabel-app 1 hublabel_app "$APP_HOST" 3090 "${PORTA_APP:-}" 1024M

        cat <<EOF

  hublabel-redis:
    image: $IMG_REDIS
    command: ["redis-server", "--appendonly", "yes", "--maxmemory", "200mb", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - hublabel_redis:/data
EOF
        extras hublabel-redis 0 "" "" "" "" 256M

        if [ "$evo_ext" != 1 ]; then
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
        fi

        if [ "$s3_ext" != 1 ]; then
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
        fi

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
        if [ "$evo_ext" != 1 ]; then
            echo "  evolution_instances:"
            echo "  evolution_postgres:"
            echo "  evolution_redis:"
        fi
        [ "$s3_ext" != 1 ] && echo "  minio_data:"
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
        {
            printf '%s {\n    encode gzip\n    reverse_proxy hublabel-app:3090\n}\n' "$APP_HOST"
            [ "$evo_ext" != 1 ] && printf '\n%s {\n    reverse_proxy hublabel-evolution:8080\n}\n' "$EVO_HOST"
            [ "$s3_ext" != 1 ] && printf '\n%s {\n    reverse_proxy hublabel-minio:9000\n}\n' "$S3_HOST"
        } >"$DIR/Caddyfile"
    fi

    if [ "$MODO_ROTA" = file ]; then
        local app evo s3 rotas=()
        app="$(nome_dns hublabel-app)"; evo="$(nome_dns hublabel-evolution)"; s3="$(nome_dns hublabel-minio)"
        rotas=("hublabel_app $APP_HOST")
        [ "$evo_ext" != 1 ] && rotas+=("hublabel_evolution $EVO_HOST")
        [ "$s3_ext" != 1 ] && rotas+=("hublabel_s3 $S3_HOST")
        {
            echo "## Gerado pelo setup HubLabel v$VERSAO"
            echo "http:"
            echo "  routers:"
            for r in "${rotas[@]}"; do
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
            if [ "$evo_ext" != 1 ]; then
                echo "    hublabel_evolution:"
                echo "      loadBalancer:"
                echo "        servers: [{ url: \"http://$evo:8080\" }]"
            fi
            if [ "$s3_ext" != 1 ]; then
                echo "    hublabel_s3:"
                echo "      loadBalancer:"
                echo "        servers: [{ url: \"http://$s3:9000\" }]"
            fi
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

baixar_imagens_stack() {
    local img imgs=("$IMG_APP" "$IMG_REDIS")
    [ "${EVO_EXTERNA:-0}" != 1 ] && imgs+=("$IMG_EVOLUTION" "$IMG_POSTGRES")
    [ "${S3_EXTERNO:-0}" != 1 ] && imgs+=("$IMG_MINIO")
    for img in "${imgs[@]}"; do
        docker pull -q "$img" || true
    done
}

subir() {
    cd "$DIR" || erro "Pasta $DIR não encontrada."
    if [ "$MODO_DEPLOY" = stack ]; then
        girar "Baixando o sistema (pode levar alguns minutos)" baixar_imagens_stack
        girar "Iniciando os serviços" docker stack deploy --prune --resolve-image always -c "$PROJETO.yml" "$PROJETO" \
            || { tail -5 "$TMP/ultimo.log"; erro "Falha ao iniciar. Arquivo: $DIR/$PROJETO.yml"; }
    else
        girar "Baixando o sistema (pode levar alguns minutos)" docker compose -f "$PROJETO.yml" pull -q \
            || { tail -5 "$TMP/ultimo.log"; erro "Não consegui baixar o sistema. Confira a internet da VPS."; }
        girar "Iniciando os serviços" docker compose -f "$PROJETO.yml" up -d --remove-orphans \
            || { tail -5 "$TMP/ultimo.log"; erro "Falha ao iniciar. Arquivo: $DIR/$PROJETO.yml"; }
    fi
}

## Container do MinIO: o nosso ou o antigo (outra stack) que continua rodando
minio_container() {
    if [ "${S3_EXTERNO:-0}" = 1 ]; then
        docker ps -q -f "label=com.docker.swarm.service.name=$MINIO_SERVICO_EXT" | head -1
    else
        container_de hublabel-minio
    fi
}

minio_pronto() {
    local cid
    cid="$(minio_container)"
    [ -n "$cid" ] && docker exec "$cid" mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
}

configurar_minio() {
    local externo="${S3_EXTERNO:-0}" criado=0
    if [ "$externo" = 1 ] && [ -z "${MINIO_ROOT_USER:-}" ]; then
        ## Sem a senha de administrador do MinIO antigo: segue com a chave que o Disparador já usava
        aviso "Não encontrei a senha de administrador do MinIO atual. Mantive a chave de acesso que já existia."
        return 0
    fi
    esperar "Preparando o armazenamento de arquivos" "$([ "$externo" = 1 ] && echo 60 || echo 180)" minio_pronto \
        || { falha "O armazenamento não respondeu. As mídias não vão funcionar até isso ser resolvido."; return 1; }
    local cid
    cid="$(minio_container)"
    docker exec "$cid" mc ls "local/$S3_BUCKET" >/dev/null 2>&1 \
        || { docker exec "$cid" mc mb -p "local/$S3_BUCKET" >/dev/null 2>&1 && criado=1; }
    ## No MinIO antigo a permissão do bucket que já existe fica como está
    if [ "$externo" != 1 ] || [ "$criado" = 1 ]; then
        docker exec "$cid" mc anonymous set download "local/$S3_BUCKET" >/dev/null 2>&1 \
            || aviso "Não consegui deixar o bucket com leitura pública."
    fi
    docker exec "$cid" mc admin user add local "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 \
        || { falha "Não consegui criar a chave de acesso dos arquivos."; return 1; }
    docker exec "$cid" mc admin policy attach local readwrite --user "$S3_ACCESS_KEY" >/dev/null 2>&1 \
        || docker exec "$cid" mc admin policy set local readwrite "user=$S3_ACCESS_KEY" >/dev/null 2>&1 || true
}

sistema_respondendo() {
    local cid estado
    cid="$(container_de hublabel-app)"
    [ -n "$cid" ] || return 1
    estado="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null)"
    [ "$estado" = healthy ] || docker exec "$cid" wget -qO- http://127.0.0.1:3090/health
}

aguardar_sistema() {
    esperar "Ligando o sistema (até 5 minutos)" 300 sistema_respondendo && return 0
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

https_respondendo() {
    [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$APP_HOST:443:127.0.0.1" "https://$APP_HOST/health")" = 200 ]
}

verificar_https() {
    [ "$MODO_ROTA" = manual ] && return 0
    esperar "Liberando o acesso em https://$APP_HOST" 150 https_respondendo && return 0
    aviso "O endereço ainda não abriu. Confira o apontamento do domínio."
    aviso "O cadeado (HTTPS) pode levar alguns minutos para sair."
    return 1
}

## Cria o administrador (super admin, plano Ilimitado) e grava o nome do sistema.
configurar_sistema() {
    printf '\r  %b%s%b Criando o super administrador' "$ciano" "${QUADROS[0]}" "$reset"
    ADMIN_SENHA="$ADMIN_SENHA_PADRAO" NOME_SISTEMA="${NOME_SISTEMA:-}" ADMIN_EMAIL="${ADMIN_EMAIL:-}" \
    SB_URL="$SUPABASE_URL" SB_KEY="$SUPABASE_SERVICE_ROLE_KEY" python3 -I - >"$TMP/admin" 2>&1 <<'PYEOF'
import json, os, time, urllib.error, urllib.parse, urllib.request

url, chave = os.environ["SB_URL"], os.environ["SB_KEY"]
email, senha = os.environ["ADMIN_EMAIL"], os.environ["ADMIN_SENHA"]
nome_sistema = os.environ["NOME_SISTEMA"]
## Sem nome informado: o nome do usuário é o próprio e-mail
nome_admin = email
q = urllib.parse.quote


def chamar(metodo, caminho, corpo=None, extra=None):
    h = {"apikey": chave, "Content-Type": "application/json", "Prefer": "return=representation"}
    if not chave.startswith("sb_"):
        h["Authorization"] = "Bearer " + chave
    h.update(extra or {})
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(url + caminho, data=dados, method=metodo, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        txt = e.read().decode(errors="ignore")
        try:
            return e.code, json.loads(txt)
        except Exception:
            return e.code, txt
    except Exception as e:
        return 0, str(e)


def usuario():
    _, r = chamar("GET", f'/rest/v1/SAAS_Usuarios?select=id,auth_user_id,"contaId"&Email=eq.{q(email)}&limit=1')
    return r[0] if isinstance(r, list) and r else None


def plano_ilimitado():
    _, r = chamar("GET", "/rest/v1/SAAS_Planos?select=id&nome=eq.Ilimitado&limit=1")
    return r[0]["id"] if isinstance(r, list) and r else None


if email:
    u = usuario()
    senha_usada = False
    if not u and senha:
        senha_usada = True
        meta = {"nome": nome_admin}
        plano = plano_ilimitado()
        if plano:
            meta["planoId"] = str(plano)
        cod, r = chamar("POST", "/auth/v1/admin/users",
                        {"email": email, "password": senha, "email_confirm": True, "user_metadata": meta})
        if cod >= 300 or cod == 0:
            msg = (r.get("msg") or r.get("message") or r.get("error_description")) if isinstance(r, dict) else r
            print("ERRO_ADMIN", msg)
        for _ in range(10):
            u = usuario()
            if u:
                break
            time.sleep(1)
    if u:
        chamar("PATCH", f'/rest/v1/SAAS_Usuarios?id=eq.{u["id"]}', {"super_admin": True, "funcao": "admin"})
        if u.get("contaId"):
            corpo = {"status": True, "dataValidade": None}
            plano = plano_ilimitado()
            if plano:
                corpo["plano"] = plano
            chamar("PATCH", f'/rest/v1/SAAS_Contas?id=eq.{u["contaId"]}', corpo)
        print("OK_ADMIN", "novo" if senha_usada else "existente")
    else:
        print("ERRO_ADMIN o usuário não apareceu no sistema")

if nome_sistema:
    agora = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cod, r = chamar("POST", "/rest/v1/SAAS_Personalizacao", {"id": 1, "nome": nome_sistema, "updated_at": agora},
                    {"Prefer": "resolution=merge-duplicates,return=minimal"})
    print("OK_NOME" if 0 < cod < 300 else f"ERRO_NOME {r}")
PYEOF
    printf '\r\e[K'
    ADMIN_CRIADO="$(sed -n 's/^OK_ADMIN //p' "$TMP/admin" | head -1)"
    if [ -n "$ADMIN_CRIADO" ]; then
        ok "Super administrador criado"
    elif [ -n "${ADMIN_EMAIL:-}" ]; then
        falha "Não consegui criar o administrador: $(sed -n 's/^ERRO_ADMIN //p' "$TMP/admin" | head -1)"
        dica "Rode o setup de novo e escolha \"Refazer a configuração\" para tentar outra vez."
    fi
    if grep -q '^OK_NOME' "$TMP/admin"; then
        ok "Nome do sistema aplicado"
    elif [ -n "${NOME_SISTEMA:-}" ]; then
        aviso "Não consegui gravar o nome do sistema. Ajuste depois no painel de administrador."
    fi
}

## ============================================================================
## RESUMO FINAL
## ============================================================================

resumo_final() {
    banner
    titulo_caixa "🎉  INSTALAÇÃO CONCLUÍDA!"
    echo ""
    abrir_bloco "ACESSE SEU SISTEMA" "$azul"
    item "Endereço" "https://$APP_HOST${BACK_PATH:-}/login"
    if [ -n "${ADMIN_EMAIL:-}" ]; then
        item "E-mail" "$ADMIN_EMAIL"
        if [ "${ADMIN_CRIADO:-}" = novo ]; then
            item "Senha" "$ADMIN_SENHA_PADRAO  (troque depois de entrar)"
        else
            item "Senha" "a mesma que você já usa nesse e-mail"
        fi
        item "Perfil" "Super administrador"
    fi
    fechar_bloco
    abrir_bloco "WHATSAPP (EVOLUTION API)" "$roxo"
    item "Endereço" "https://$EVO_HOST"
    item "Manager" "https://$EVO_HOST/manager"
    item "API Key" "$EVOLUTION_API_KEY"
    fechar_bloco
    abrir_bloco "ARQUIVOS (S3)" "$roxo"
    item "Endereço" "https://$S3_HOST"
    fechar_bloco
    abrir_bloco "SUPABASE" "$azul"
    item "Projeto" "$SUPABASE_URL"
    fechar_bloco
    if [ "${MANTER_N8N:-0}" = 1 ]; then
        abrir_bloco "N8N (MANTIDO)" "$roxo"
        item "Webhooks" "https://$APP_HOST/webhook/..."
        item "Atenção" "links de webhook dos seus fluxos agora têm /webhook"
        fechar_bloco
    fi
    if [ "$MODO_ROTA" = manual ]; then
        abrir_bloco "FALTA UM PASSO: CADASTRE OS DOMÍNIOS NO SEU PAINEL (COM HTTPS)" "$amarelo"
        item "$APP_HOST" "→ http://127.0.0.1:$PORTA_APP"
        [ "${EVO_EXTERNA:-0}" != 1 ] && item "$EVO_HOST" "→ http://127.0.0.1:$PORTA_EVO"
        [ "${S3_EXTERNO:-0}" != 1 ] && item "$S3_HOST" "→ http://127.0.0.1:$PORTA_S3"
        fechar_bloco
    fi
    dica "Para atualizar: rode o mesmo comando de instalação e confirme com S."
    echo -e "  ${amarelo}Anote estes dados em um lugar seguro.${reset}"
    echo ""
}

## ============================================================================
## FLUXOS
## ============================================================================

## Título da fase de instalação
cabecalho_instalacao() {
    banner
    trilha $((TOTAL_PASSOS + 1))
    echo ""
    titulo_caixa "INSTALANDO SEU SISTEMA" "$roxo"
    dica "Pode levar alguns minutos. Não feche esta janela."
    echo ""
}

instalar() {
    gerar_segredos
    salvar_config
    gerar_arquivo_deploy
    [ "$MIGRACAO" = 1 ] && remover_versao_antiga
    [ "$MANTER_N8N" = 1 ] && ajustar_n8n_mantido
    subir
    configurar_minio
    configurar_sistema
    aguardar_sistema
    verificar_https
    [ "$MANTER_N8N" = 1 ] && verificar_rota_n8n
    resumo_final
}

menu_instalacao_existente() {
    carregar_config
    banner
    titulo_caixa "VOCÊ JÁ TEM TUDO INSTALADO NESTA VPS"
    dica "https://${APP_HOST:-?}"
    echo ""
    sim_nao "Deseja atualizar para a versão mais nova?" S || exit 0
    banner
    titulo_caixa "ATUALIZANDO SEU SISTEMA" "$roxo"
    echo ""
    gerar_arquivo_deploy
    subir
    ## O MinIO já foi configurado na instalação: a chave salva continua valendo
    aguardar_sistema
    echo ""
    ok "${negrito}Atualização concluída!${reset}"
    exit 0
}

main() {
    verificacoes_iniciais

    if [ -f "$ENV_FILE" ]; then
        menu_instalacao_existente
    fi

    banner
    titulo_caixa "BEM-VINDO! VAMOS INSTALAR O SEU SISTEMA"
    echo ""
    texto "São ${negrito}$TOTAL_PASSOS passos${reset} rápidos. Tenha em mãos o painel do seu domínio e o Supabase."
    echo ""
    info "Analisando a VPS..."
    BACK_PATH=""
    detectar_ambiente
    descrever_ambiente
    sleep 2
    ## Versão antiga (N8N + Disparador): oferece trocar pela nova
    [ "$HUBLABEL_V18" = 1 ] && oferecer_migracao

    assistente
    cabecalho_instalacao
    instalar_docker
    instalar
}

main "$@"
