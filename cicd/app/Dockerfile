# Multi-stage: a imagem final nao carrega toolchain de build.
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
# Usuario nao-root: exigencia basica de seguranca em cluster
RUN useradd -u 10001 -m appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY main.py .
USER 10001
EXPOSE 8000
# APP_VERSION e injetado no build para aparecer em /metrics e /
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
