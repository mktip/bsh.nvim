#!/usr/bin/env python3
"""Reverse text — a second tool, to show one folder holding many."""
import sys


def reverse(text: str) -> str:
    "Reverse a string."
    return text[::-1]


try:
    import llm

    @llm.hookimpl
    def register_tools(register):
        register(reverse)
except ImportError:
    pass


if __name__ == "__main__":
    print(reverse(" ".join(sys.argv[1:]) or "hello, llmlab"))
