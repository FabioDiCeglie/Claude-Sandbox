FROM python:3.11-slim

# Declare early so every RUN below (apt-get, uv sync) routes through Squid
# when --build-arg HTTP_PROXY=http://sandbox-proxy:3128 is passed
ARG HTTP_PROXY
ARG HTTPS_PROXY

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /workspace

COPY pyproject.toml uv.lock README.md ./
COPY src ./src
COPY tests ./tests

RUN uv sync --frozen --group dev || uv sync --group dev

CMD ["bash"]
