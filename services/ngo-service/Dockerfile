# syntax=docker/dockerfile:1
# ------------------------------------------------------------------------------
# ngo-service — imagem otimizada (multi-stage)
# Estágio 1 (builder): instala as dependências Python em um prefixo isolado.
# Estágio 2 (runtime): copia só o necessário, roda como usuário não-root.
# Resultado: imagem pequena, sem compilador/pip cache, superfície de ataque menor.
# ------------------------------------------------------------------------------
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8081
# Patches de segurança do Debian: a tag "slim" é reconstruída com atraso e o Trivy bloqueia
# CVEs com fix disponível (perl, pcre2, sqlite...). Upgrade + limpeza na mesma camada.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*
# Usuário sem privilégios: boa prática de segurança em containers (CIS Docker Benchmark 4.1)
RUN addgroup --system app && adduser --system --ingroup app --no-create-home app
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .
USER app
EXPOSE 8081
# Healthcheck local: útil no docker-compose; no Kubernetes usamos liveness/readiness probes.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8081/health',timeout=2).status==200 else 1)"
# 1 worker x 8 threads: métricas Prometheus consistentes por pod; escala horizontal é papel do HPA.
# newrelic-admin envolve o gunicorn para APM/tracing; sem licença ele apenas não reporta.
CMD ["newrelic-admin", "run-program", "gunicorn", "--bind", "0.0.0.0:8081", "--workers", "1", "--threads", "8", "--access-logfile", "-", "app:app"]
