# syntax=docker/dockerfile:1
# ------------------------------------------------------------------------------
# volunteer-service — imagem otimizada (multi-stage), mesma estratégia do ngo-service.
# ------------------------------------------------------------------------------
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8083
# Patches de segurança do Debian: a tag "slim" é reconstruída com atraso e o Trivy bloqueia
# CVEs com fix disponível (perl, pcre2, sqlite...). Upgrade + limpeza na mesma camada.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*
RUN addgroup --system app && adduser --system --ingroup app --no-create-home app
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .
USER app
EXPOSE 8083
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8083/health',timeout=2).status==200 else 1)"
CMD ["gunicorn", "--bind", "0.0.0.0:8083", "--workers", "2", "--threads", "4", "--access-logfile", "-", "app:app"]
