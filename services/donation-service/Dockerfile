# syntax=docker/dockerfile:1
# ------------------------------------------------------------------------------
# donation-service (Go) — HOT PATH da plataforma.
# Estágio 1: compila binário estático (CGO_ENABLED=0), sem símbolos de debug (-s -w).
# Estágio 2: distroless "static" = sem shell, sem package manager, ~2 MB de base.
#            É a menor superfície de ataque possível para um binário Go.
# ------------------------------------------------------------------------------
FROM golang:1.23-alpine AS builder
WORKDIR /src
# Copia primeiro os arquivos de módulo para aproveitar o cache de camadas do Docker
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/donation-service .

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
ENV PORT=8082
COPY --from=builder /out/donation-service /donation-service
USER nonroot:nonroot
EXPOSE 8082
ENTRYPOINT ["/donation-service"]
