"""Notifications: at the end of a dispatcher cycle, tell the owner what waits for them (a spec to review, a card to
ship, a blocked run), once per wait with one reminder, and when the factory is stuck. What was told is in
<home>/notify.json; the settings are `notify` in <home>/config.yml.
  cycle --home H [--now <ISO time on this machine's clock>]"""
import argparse, base64, http.client, json, os, subprocess, sys, urllib.error, urllib.request
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ in the installed scripts
sys.path.insert(0, str(HERE))
import shipfloor_config
from dashboard import Factory, bash, gh_json, read_yaml

TIMEOUT_S = 20  # per channel
TITLE_MAX = 80
DIGEST_LINES = 4
IDLE_AFTER = timedelta(hours=1)
BLOCKED = "blocked in "  # the state of a blocked card, then the stage it stopped in
WAITS = {"Spec Review": "spec to review", "Staged": "ready to ship"}  # where the owner decides, and what the dashboard says there
STAGE_OF = {"Ready for Refinement": "refine", "Technical Refinement": "refine", "Ready for Dev": "develop", "Coding": "develop",
            "Validation": "validate", "Ready for Prod": "deploy", "Staged": "deploy"}  # the stage a card in this column is in
CAUSES = {"usage_limit": ("Shipfloor · the factory is stuck", "The Claude usage limit was hit. New runs wait for it to reset.", "usage limit hit"),
          "skipped": ("{project} · the factory is stuck", "The dispatcher skips this project. The dashboard says why.", "project skipped"),
          "idle": ("{project} · the factory is stuck", "No card moved for an hour and nothing is paused.", "no card moved for an hour")}
# the text is data: the script reads it from the environment and never has it in its source
TOAST = r"""$ErrorActionPreference = 'Stop'
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text></text><text></text></binding></visual></toast>')
$text = $xml.GetElementsByTagName('text')
$text.Item(0).InnerText = $env:SHIPFLOOR_TOAST_TITLE
$text.Item(1).InnerText = $env:SHIPFLOOR_TOAST_BODY
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
"""
TOAST_ARG = base64.b64encode(TOAST.encode("utf-16-le")).decode()


def log(message):
    print(f"{datetime.now().astimezone().isoformat(timespec='seconds')} shipfloor: notify: {message}", file=sys.stderr)


def send(channel, title, body, topic):
    """None when the channel delivered, else why not, in words of our own: an exception can carry the ntfy URL."""
    try:
        if os.environ.get("SHIPFLOOR_NOTIFY_SEND"):
            run = [bash(), os.environ["SHIPFLOOR_NOTIFY_SEND"], channel, title, body]
            return None if subprocess.run(run, capture_output=True, timeout=TIMEOUT_S).returncode == 0 else "the sender failed"
        if channel == "toast":
            env = dict(os.environ, SHIPFLOOR_TOAST_TITLE=title, SHIPFLOOR_TOAST_BODY=body)
            run = ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", TOAST_ARG]
            r = subprocess.run(run, env=env, capture_output=True, timeout=TIMEOUT_S, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            return None if r.returncode == 0 else "powershell failed"
        title_header = "=?UTF-8?B?" + base64.b64encode(title.encode("utf-8")).decode() + "?="  # headers are latin-1; ntfy reads RFC 2047
        request = urllib.request.Request(f"https://ntfy.sh/{topic}", data=body.encode("utf-8"), headers={"Title": title_header}, method="POST")
        with urllib.request.urlopen(request, timeout=TIMEOUT_S):
            return None
    except subprocess.TimeoutExpired:
        return "timed out"
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}"
    except (OSError, ValueError, http.client.HTTPException) as e:
        return type(e).__name__


def in_quiet(quiet, now):
    if not quiet:
        return False
    start, end, at = quiet[:5], quiet[6:], now.strftime("%H:%M")
    return start <= at < end if start < end else at >= start or at < end


def blocked_cards(last, p):
    return set(((last.get("projects") or {}).get(p) or {}).get("blocked_cards") or [])


def board(home, p):
    try:
        lines = (Path(home) / "projects" / p / "board.tsv").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    return {int(c[0]): c[1] for c in (line.split("\t") for line in lines) if len(c) > 1 and c[0].isdigit()}


def last_health(home):
    logs = sorted((Path(home) / "logs").glob("health-*.jsonl"))
    for line in reversed(logs[-1].read_text(encoding="utf-8").splitlines() if logs else []):
        try:
            return json.loads(line)
        except ValueError:  # a line cut short by a cycle that died while writing it
            continue
    return {}


def waiting(boards, last):
    """The cards that wait for the owner: in Spec Review or Staged, or blocked (then in the stage they stopped in)."""
    out = []
    for p, cards in boards.items():
        for n, column in sorted(cards.items()):
            if n in blocked_cards(last, p) and column in STAGE_OF:
                out.append({"project": p, "n": n, "state": BLOCKED + STAGE_OF[column]})
            elif column in WAITS:
                out.append({"project": p, "n": n, "state": column})
    return [dict(w, key=f"{w['project']}#{w['n']}") for w in out]


def stuck(f, boards, last, moved_at, now):
    """The causes that hold now: the usage limit, a skipped project, a project where nothing moved for an hour."""
    out = [{"cause": "usage_limit", "project": ""}] if last.get("usage_limited") else []
    for p, cards in boards.items():
        if f.skipped(p):
            out.append({"cause": "skipped", "project": p})
        working = [n for n, column in cards.items() if column in STAGE_OF and column != "Staged" and n not in blocked_cards(last, p)]
        paused = (f.home / "PAUSE").exists() or (f.pdir(p) / "PAUSE").exists()
        if working and not paused and now - datetime.fromisoformat(moved_at[p]) >= IDLE_AFTER:
            out.append({"cause": "idle", "project": p})
    return [dict(c, key=f"{c['cause']}:{c['project']}") for c in out]


def catalog(language):
    try:
        return json.loads((HERE / "lang" / f"notify.{language}.json").read_text(encoding="utf-8")).get("exact", {})
    except (OSError, ValueError):
        return {}


def load_state(home):
    try:
        s = json.loads((Path(home) / "notify.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        s = None
    s = s if isinstance(s, dict) else {}
    return {"cards": s.get("cards", {}), "stuck": s.get("stuck", {}), "columns": s.get("columns", {}),
            "moved_at": s.get("moved_at", {}), "held": bool(s.get("held"))}


def save_state(home, state):
    tmp = Path(home) / "notify.json.tmp"
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, Path(home) / "notify.json")


def titles_of(f):
    """title(p, n): the card's title, from one read of the project's issues; "" when it cannot be read."""
    known = {}

    def title(p, n):
        if p not in known:
            issues, err = gh_json("issue", "list", "--repo", str(shipfloor_config.dotted(f.config(p), "project.repo")),
                                  "--state", "all", "--limit", "300", "--json", "number,title")
            if err:
                log(f"titles of {p} not read: {(err.splitlines() or [''])[0][:200]}")
            known[p] = {i["number"]: i.get("title") for i in issues if isinstance(i, dict) and "number" in i} if isinstance(issues, list) else {}
        name = " ".join(str(known[p].get(n) or "").split())
        return name if len(name) <= TITLE_MAX else name[:TITLE_MAX - 1] + "…"
    return title


def wait_message(t, w, name, reminder=False):
    p, n, state = w["project"], w["n"], w["state"]
    if state.startswith(BLOCKED):
        head, line = "{project} · #{n} is blocked", t("Stopped in {stage}", stage=t(state[len(BLOCKED):]))
    else:
        head, line = "{project} · #{n} waits for you", f"{t(state)} · {t(WAITS[state])}"
    if reminder:
        head = "{project} · #{n} still waits for you"
    return t(head, project=p, n=n), "\n".join(x for x in (name, line) if x)


def digest_message(t, waits, causes, title):
    lines = []
    for w in waits:
        state = t(BLOCKED + "{stage}", stage=t(w["state"][len(BLOCKED):])) if w["state"].startswith(BLOCKED) else t(w["state"])
        name = title(w["project"], w["n"])
        lines.append(f"{w['project']} #{w['n']}{' ' + name if name else ''} · {state}")
    lines += [f"{c['project'] or 'Shipfloor'} · {t(CAUSES[c['cause']][2])}" for c in causes]
    if len(lines) > DIGEST_LINES:
        lines[DIGEST_LINES:] = [t("and {n} more", n=len(lines) - DIGEST_LINES)]
    head = t("Shipfloor · 1 card needs you") if len(waits) == 1 else t("Shipfloor · {n} cards need you", n=len(waits)) if waits else t("Shipfloor · the factory is stuck")
    return head, "\n".join(lines)


def deliver(messages, channels, topic):
    """Each message goes to every channel; a message counts as told (its marks are set) when one channel delivered.
    A channel that failed is not tried again in this cycle, and its failure is one log line."""
    failed = {}
    for title, body, marks in messages:
        delivered = False
        for channel in channels:
            if channel in failed:
                continue
            err = send(channel, title, body, topic)
            if err:
                failed[channel] = err
            else:
                delivered = True
        if delivered:
            for target, key, value in marks:
                target[key] = value
    for channel, err in failed.items():
        log(f"{channel} failed: {err}")


def cycle(home, now):
    f = Factory(home, "")
    raw = read_yaml(f.home / "config.yml")
    errs = shipfloor_config.machine_problems(raw)
    if errs:
        log("config.yml is invalid, nothing is sent: " + "; ".join(errs))
        return
    cfg = shipfloor_config.merged(raw, shipfloor_config.MACHINE_DEFAULTS)
    nf, cat = cfg["notify"], catalog(cfg["language"])
    on = nf["events"]
    t =lambda text, **kw: cat.get(text, text).format(**kw)
    state, stamp = load_state(home), now.isoformat(timespec="seconds")
    boards = {p: board(home, p) for p in f.projects()}
    last = last_health(home)
    title = titles_of(f)

    columns = {p: {str(n): c for n, c in cards.items()} for p, cards in boards.items()}
    moved_at = {p: stamp if columns[p] != state["columns"].get(p) else state["moved_at"].get(p, stamp) for p in boards}
    done = [(p, n) for p, cards in boards.items() for n, c in sorted(cards.items())
            if c == "Done" and state["columns"].get(p, {}).get(str(n), "Done") != "Done"]  # a card never seen before is not announced

    waits, causes = waiting(boards, last), stuck(f, boards, last, moved_at, now)
    cards = {}
    for w in waits:  # a card that left its state and came back waits anew
        old = state["cards"].get(w["key"])
        cards[w["key"]] = old if old and old["state"] == w["state"] else {"state": w["state"], "since": stamp, "told": None, "reminded": None}
    stucks = {c["key"]: state["stuck"].get(c["key"]) or {"since": stamp, "told": None} for c in causes}
    waits.sort(key=lambda w: (cards[w["key"]]["since"], w["project"], w["n"]))

    waited = lambda w: now - datetime.fromisoformat(cards[w["key"]]["since"]) >= timedelta(minutes=nf["reminder_min"])
    wanted = lambda w: on["blocked" if w["state"].startswith(BLOCKED) else "waiting"]
    fresh = [w for w in waits if wanted(w) and cards[w["key"]]["told"] is None]
    fresh_causes = [c for c in causes if on["stuck"] and stucks[c["key"]]["told"] is None]
    messages = []
    if in_quiet(nf["quiet"], now):
        state["held"] = state["held"] or bool(fresh or fresh_causes)
    elif state["held"]:
        listed, why = [w for w in waits if wanted(w)], [c for c in causes if on["stuck"]]
        if listed or why:
            marks = [(cards[w["key"]], "told", stamp) for w in listed] + [(stucks[c["key"]], "told", stamp) for c in why]
            marks += [(cards[w["key"]], "reminded", stamp) for w in listed if waited(w)] + [(state, "held", False)]  # the digest is their reminder
            messages.append((*digest_message(t, listed, why, title), marks))
        else:
            state["held"] = False
    else:
        messages += [(*wait_message(t, w, title(w["project"], w["n"])), [(cards[w["key"]], "told", stamp)]) for w in fresh]
        if on["reminder"]:
            messages += [(*wait_message(t, w, title(w["project"], w["n"]), True), [(cards[w["key"]], "reminded", stamp)]) for w in waits
                         if cards[w["key"]]["told"] and cards[w["key"]]["reminded"] is None and waited(w)]
        for c in fresh_causes:
            head, body, _ = CAUSES[c["cause"]]
            messages.append((t(head, project=c["project"]), t(body), [(stucks[c["key"]], "told", stamp)]))
        if on["done"]:
            messages += [(t("{project} · #{n} reached production", project=p, n=n), title(p, n), []) for p, n in done]

    channels = [ch for ch in ("toast", "ntfy") if nf["channels"][ch] and (nf["ntfy_topic"] if ch == "ntfy" else
                os.name == "nt" or os.environ.get("SHIPFLOOR_NOTIFY_SEND"))]
    deliver(messages, channels, nf["ntfy_topic"])
    state.update(cards=cards, stuck=stucks, columns=columns, moved_at=moved_at)
    save_state(home, state)


def main():
    a = argparse.ArgumentParser(prog="shipfloor_notify")
    a.add_argument("command", choices=("cycle",))
    a.add_argument("--home", required=True)
    a.add_argument("--now", type=datetime.fromisoformat, default=None)
    args = a.parse_args()
    sys.stderr.reconfigure(errors="replace")  # a title in the log must not be what fails
    cycle(args.home, args.now or datetime.now())


if __name__ == "__main__":
    main()
