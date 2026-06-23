#!/usr/bin/env python3
"""A dual-purpose llmlab tool — the keystone pattern.

  * Run it   (Enter on `llm.tools.weather`, or `python weather.py [city]`):
    the __main__ block fires and prints a quick result.
  * Import it (when `llm` loads it as a plugin, or via `llm --functions`):
    the register_tools hookimpl exposes weather() to the model as a tool.

One file, two faces, decided by __name__.
"""
import sys


def weather(city: str = "Istanbul") -> str:
    "Return a one-line weather report for a city."
    # Placeholder — wire this to a real API when you like.
    return f"{city}: partly cloudy, 21°C, wind 12 km/h"


# When `llm` imports this module as a plugin, register weather() as a tool.
# Guarded so the file still runs standalone if `llm` isn't importable.
try:
    import llm

    @llm.hookimpl
    def register_tools(register):
        register(weather)
except ImportError:
    pass


if __name__ == "__main__":
    print(weather(sys.argv[1] if len(sys.argv) > 1 else "Istanbul"))
