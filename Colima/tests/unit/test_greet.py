import pytest

from main import greet_message


def test_greet_message() -> None:
    assert greet_message("world") == "Hello, world!"


def test_greet_message_strips_whitespace() -> None:
    assert greet_message("  world  ") == "Hello, world!"


def test_greet_message_empty_raises() -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        greet_message("   ")
