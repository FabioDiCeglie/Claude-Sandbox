from __future__ import annotations

import uvicorn
from fastapi import FastAPI

app = FastAPI(title="claude-sandbox-dood")


def greet_message(name: str) -> str:
    cleaned = name.strip()
    if not cleaned:
        raise ValueError("name must not be empty")
    return f"Hello, {cleaned}!"


@app.get("/greet/{name}")
async def greet(name: str) -> dict[str, str]:
    return {"message": greet_message(name)}


def main() -> None:
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=False)


if __name__ == "__main__":
    main()
