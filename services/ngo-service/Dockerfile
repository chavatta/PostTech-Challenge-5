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
# gunicorn com 2 workers x 4 threads: suficiente para o CRUD leve; access log no stdout (12-factor)
CMD ["gunicorn", "--bind", "0.0.0.0:8081", "--workers", "2", "--threads", "4", "--access-logfile", "-", "app:app"]
