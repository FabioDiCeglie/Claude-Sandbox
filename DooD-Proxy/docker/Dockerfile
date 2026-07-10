FROM python:3.11-slim

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
