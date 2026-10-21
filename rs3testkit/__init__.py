"""Offline test kit for RuneScape 3 Lua plugins.

    rs3test check <plugin>          validate plugin.json and files
    rs3test run <plugin> [specs]    run Lua spec files against the mock API

See README.md for the spec API (kit, test, expect).
"""

from .manifest import Finding, Report, validate

__version__ = "0.1.0"
__all__ = ["validate", "Report", "Finding", "Session", "__version__"]


def __getattr__(name):
    # Session needs lupa; import it lazily so `check` works without it.
    if name == "Session":
        from .host import Session
        return Session
    raise AttributeError(name)
