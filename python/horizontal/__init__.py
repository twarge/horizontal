"""Python bindings for Horizontal.

The engine is Horizontal's own Swift model, exposed through one JSON-RPC
dispatch call. By default it is loaded into this process from
``libHorizontalPy.dylib``; pass ``isolated=True`` to run it in a
``horizontal serve`` subprocess instead (a crash there cannot take the
interpreter down).

    import horizontal
    project = horizontal.open("Sherlock Horizon/Sherlock.hprj")
    for net in project.nets():
        print(net["name"], net["pin_count"])
"""

from ._native import HorizontalError, find_cli, find_dylib
from .client import Project, Session, new_project, open

__all__ = ["HorizontalError", "Project", "Session", "find_cli", "find_dylib", "new_project", "open"]
