FROM python:3.11-slim

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

COPY pyproject.toml README.md ./
COPY src ./src
COPY tests ./tests

RUN uv sync --frozen --no-dev || uv sync --no-dev

EXPOSE 8080

CMD ["uv", "run", "dind-app"]
