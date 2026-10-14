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


def cmd_board(args):
    from shipfloor_core import board
    return board.main(args)


def cmd_setup_board(args):
    from shipfloor_core import setup
    return setup.main(args)


def cmd_report(args):
    from shipfloor_core import report
    return report.main(args)


def cmd_metrics(args):
    from shipfloor_core import metrics
    return metrics.main(args)


def cmd_review_page(args):
    from shipfloor_core import review_page
    return review_page.main(args)


def cmd_brief(args):
    from shipfloor_core import brief
    return brief.main(args)


def cmd_cli(args):
    from shipfloor_core import cli
    return cli.main(args)


def cmd_deploy(args):
    from shipfloor_core import deploy
    return deploy.main(args)


def cmd_dispatch(args):
    from shipfloor_core import dispatch
    return dispatch.main(args)


def cmd_cycle(args):
    from shipfloor_core import cycle
    return cycle.main(args)


def cmd_cycle_project(args):
    from shipfloor_core import cycle
    return cycle.main_project(args)


def cmd_stack(args):
    from shipfloor_core import stack
    return stack.main(args)


COMMANDS = {"version": cmd_version, "board": cmd_board, "setup-board": cmd_setup_board, "report": cmd_report,
            "metrics": cmd_metrics, "review-page": cmd_review_page, "cli": cmd_cli, "deploy": cmd_deploy,
            "dispatch": cmd_dispatch, "cycle": cmd_cycle, "cycle-project": cmd_cycle_project, "stack": cmd_stack,
            "brief": cmd_brief}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print("usage: sf.py <%s>" % "|".join(sorted(COMMANDS)), file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
