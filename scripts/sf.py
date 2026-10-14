"""Entry point of the factory's Python commands: sf.py <command> [args]. Run it through a wrapper (lib/py.sh)."""
import sys

sys.dont_write_bytecode = True  # before any import: the installed copy never gets a __pycache__

import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", newline="\n")
    except (AttributeError, ValueError):
        pass


def cmd_version(args):
    import shipfloor_core
    print(shipfloor_core.__version__)
    return 0


def cmd_gate(args):
    from shipfloor_core import gate
    return gate.main(args)


COMMANDS = {"version": cmd_version, "gate": cmd_gate}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print("usage: sf.py <%s>" % "|".join(sorted(COMMANDS)), file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
