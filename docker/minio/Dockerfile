## MinIO RELEASE.2024-01-13T07-53-03Z (console completo: users, policies, access keys)
## Imagem própria para não depender do quay.io/minio (401) nem do dl.min.io (410).
## Compila minio + mc a partir das tags oficiais do GitHub, com as mesmas ldflags
## do build oficial (minio --version mostra RELEASE.2024-01-13T07-53-03Z).

FROM --platform=$BUILDPLATFORM golang:1.21-bookworm AS build

ARG TARGETOS
ARG TARGETARCH
ARG MINIO_RELEASE=RELEASE.2024-01-13T07-53-03Z
ARG MC_RELEASE=RELEASE.2024-01-13T08-44-48Z

ENV CGO_ENABLED=0 GOTOOLCHAIN=local

## minio server
RUN set -eux; \
    git clone --depth 1 --branch "${MINIO_RELEASE}" https://github.com/minio/minio /src/minio; \
    cd /src/minio; \
    LDFLAGS="$(MINIO_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "${MINIO_RELEASE#RELEASE.}")"; \
    GOOS=$TARGETOS GOARCH=$TARGETARCH go build -tags kqueue -trimpath -ldflags "$LDFLAGS" -o /out/minio .

## mc (cliente, usado pelo setup via docker exec)
RUN set -eux; \
    git clone --depth 1 --branch "${MC_RELEASE}" https://github.com/minio/mc /src/mc; \
    cd /src/mc; \
    LDFLAGS="$(MC_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "${MC_RELEASE#RELEASE.}")"; \
    GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "$LDFLAGS" -o /out/mc .

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/minio /out/mc /usr/bin/

EXPOSE 9000
VOLUME ["/data"]

ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]
