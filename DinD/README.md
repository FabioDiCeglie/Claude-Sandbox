# DinD — step 1

Minimal FastAPI app with unit tests and Docker Compose.

## Local run

```bash
uv sync --group dev
uv run dind-app
```

Try http://localhost:8080/greet/world

## Unit tests

```bash
uv run pytest
```

## Docker

```bash
docker compose -f docker/docker-compose.yaml up --build
```

## Project layout

```
src/
  main.py
tests/
  unit/
    test_greet.py
docker/
  Dockerfile
  docker-compose.yaml
```
