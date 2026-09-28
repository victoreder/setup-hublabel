## MinIO RELEASE.2024-01-13T07-53-03Z (console completo: users, policies, access keys)
## Imagem própria para não depender do quay.io/minio (que passou a retornar 401).
## Binários baixados do arquivo oficial dl.min.io e validados por sha256.

FROM debian:bookworm-slim AS build

ARG TARGETARCH
ARG MINIO_RELEASE=RELEASE.2024-01-13T07-53-03Z
ARG MC_MONTH=2024-01

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /out

## minio server
RUN set -eux; \
    base="https://dl.min.io/server/minio/release/linux-${TARGETARCH}/archive"; \
    curl -fsSL -o minio "${base}/minio.${MINIO_RELEASE}"; \
    echo "$(curl -fsSL "${base}/minio.${MINIO_RELEASE}.sha256sum" | awk '{print $1}')  minio" | sha256sum -c -; \
    chmod +x minio

## mc (cliente, usado pelo setup via docker exec) - última release do mesmo mês
RUN set -eux; \
    base="https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive"; \
    mc_release=$(curl -fsSL "${base}/" | grep -o "mc\.RELEASE\.${MC_MONTH}-[0-9T-]*Z" | sort -u | tail -n1 | sed 's/^mc\.//'); \
    test -n "$mc_release"; \
    echo "mc: $mc_release"; \
    curl -fsSL -o mc "${base}/mc.${mc_release}"; \
    echo "$(curl -fsSL "${base}/mc.${mc_release}.sha256sum" | awk '{print $1}')  mc" | sha256sum -c -; \
    chmod +x mc

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/minio /out/mc /usr/bin/

EXPOSE 9000
VOLUME ["/data"]

ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]
