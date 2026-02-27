# setup-hublabel

Setup automático no estilo Orion com fluxo:

1. **Traefik + Portainer** (primeiro)
2. **Evolution API** (depois, pedindo somente o domínio da Evolution)

Durante a instalação da Evolution, o script também sobe **Postgres** e **Redis** automaticamente.

## Uso

```bash
chmod +x setup.sh
sudo ./setup.sh
```

## O que o setup solicita

### Etapa 1 (Traefik + Portainer)
- Domínio do Portainer
- Usuário
- Senha
- Nome do servidor
- Nome da rede Docker
- E-mail válido (Let's Encrypt)

### Etapa 2 (Evolution API)
- Domínio da Evolution API

## Geração automática na Evolution

O setup gera e aplica automaticamente:
- `SERVER_URL` com o domínio informado
- `AUTHENTICATION_API_KEY` aleatória
- senha aleatória do Postgres usada na `DATABASE_CONNECTION_URI`
- label do Traefik com `Host(<domínio-da-evolution>)`

## Arquivos gerados

Em `/opt/hublabel`:
- `.env`
- `docker-compose.yml`

## Requisitos

- Ubuntu/Debian com `sudo`/`root`
- DNS dos domínios apontando para o IP do servidor
- Portas `80` e `443` liberadas
