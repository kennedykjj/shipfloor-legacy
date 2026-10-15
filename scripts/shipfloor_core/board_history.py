"""The board history (#184): one line per change of the board in <home>/logs/board-<YYYY-MM>.jsonl.

A line is {"t": ISO time, "cards": {"<number>": "<column>"}}: the whole board, keys sorted. The dispatcher
records after each board read; the day view replays the lines of one date. Never raises: history is a
convenience and must not stop a cycle."""
import datetime
import glob
import json
import os
import re

_FILE = re.compile(r"board-\d{4}-\d\d\.jsonl")


def _files(home):
    return sorted(p for p in glob.glob(os.path.join(home, "logs", "board-*.jsonl")) if _FILE.fullmatch(os.path.basename(p)))


def _last_cards(home):
    """the cards of the last valid line of the newest file, or None"""
    for path in reversed(_files(home)):
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            return None
        for line in reversed(lines):
            try:
                cards = json.loads(line).get("cards")
            except (ValueError, AttributeError):
                continue
            if isinstance(cards, dict):
                return cards
        return None
    return None


def record(home, rows, now=None):
    """Append the board when it differs from the last line. rows: (number, column) pairs. An empty read
    writes nothing. Returns True when a line was written, False when logs/ could not be written."""
    cards = {str(n): c for n, c in sorted((str(n), c) for n, c in rows if str(n))}
    if not cards:
        return None
    if cards == _last_cards(home):
        return None
    now = now or datetime.datetime.now().astimezone()
    line = json.dumps({"t": now.isoformat(timespec="seconds"), "cards": cards}, ensure_ascii=False)
    try:
        with open(os.path.join(home, "logs", "board-%s.jsonl" % now.strftime("%Y-%m")), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        return False
    return True


def day(home, date):
    """the lines of one local date, in file order; lines that are not JSON are skipped"""
    out = []
    for path in _files(home):
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for line in lines:
            try:
                row = json.loads(line)
                t = datetime.datetime.fromisoformat(row["t"])
            except (ValueError, KeyError, TypeError):
                continue
            if isinstance(row, dict) and t.astimezone().date() == date:
                out.append(row)
    return out


def entered(home):
    """{"<number>": ISO time} of when each card of the newest line came into the column it has there: the time of the
    first line of its current stay. A card that has the same column in every line has no entry (when it came there is
    not on record). Lines that are not JSON are skipped."""
    newest, out, cur = None, {}, None
    for path in reversed(_files(home)):
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for line in reversed(lines):
            try:
                row = json.loads(line)
                cards, t = row.get("cards"), row["t"]
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            if not isinstance(cards, dict) or not isinstance(t, str):
                continue
            if newest is None:
                newest, cur = cards, {n: t for n in cards}
                continue
            for n in [n for n in cur if cards.get(n) != newest[n]]:
                out[n] = cur.pop(n)  # the line after this one is where its stay began
            for n in cur:
                cur[n] = t
            if not cur:
                return out
    return out
