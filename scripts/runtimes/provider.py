"""A self-hosted, OpenAI-compatible endpoint (`runtime.provider`, #151): the `-c` arguments that point `codex exec` at it
and keep it from talking to anyone else, and the doctor's checks of the endpoint. stdlib only. The value of the key
(the variable named by api_key_env) is sent to the endpoint and nowhere else: no line says it, no header, no body."""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

TIMEOUT = 5  # seconds, for each request
SWITCHES = ("analytics.enabled=false", 'otel.metrics_exporter="none"', "feedback.enabled=false",
            "check_for_update_on_startup=false", 'web_search="disabled"')


def codex_args(base_url, key_env=""):
    """The `-c` pairs of a codex run on the provider `sf`, then the switches that turn its other network traffic off."""
    env = ',env_key="%s"' % key_env if key_env else ""
    table = ('model_providers.sf={name="sf",base_url="%s"%s,wire_api="responses",requires_openai_auth=false,'
             'supports_websockets=false}' % (base_url, env))
    out = []
    for c in (table, "model_provider=sf", *SWITCHES):
        out += ["-c", c]
    return out


def _host(base_url):
    return urllib.parse.urlsplit(base_url).netloc or base_url


def _request(url, key, body=None):
    """(status, parsed JSON or None) of one request; status None when nobody answered."""
    headers = {"Accept": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=TIMEOUT) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, None
    except (OSError, ValueError):  # refused, unreachable, timed out, not a URL
        return None, None
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, None


def check(base_url, models, key_env="", wire="responses"):
    """[("ok" | "FAIL", text)]: the key's variable is set, GET <base_url>/models answers and lists every configured
    model, POST <base_url>/responses exists (404 or 405 = an endpoint with chat completions only); with wire="chat",
    POST <base_url>/chat/completions answers a one-token request instead."""
    host, base, out = _host(base_url), base_url.rstrip("/"), []
    key = os.environ.get(key_env, "") if key_env else ""
    if key_env:
        if key:
            out.append(("ok", "provider: %s is set" % key_env))
        else:
            out.append(("FAIL", "provider: %s is not set in the environment (api_key_env)" % key_env))
    status, doc = _request(base + "/models", key)
    if status is None:
        out.append(("FAIL", "provider: %s is not answering (GET /models, %d s)" % (host, TIMEOUT)))
        return out
    if status != 200:
        out.append(("FAIL", "provider: GET /models at %s answered HTTP %d" % (host, status)))
        return out
    served = {m.get("id") for m in (doc.get("data") if isinstance(doc, dict) else None) or [] if isinstance(m, dict)}
    missing = [m for m in models if m not in served]
    for m in models:
        if m in missing:
            out.append(("FAIL", "provider: model %s is not served by %s (GET /models)" % (m, host)))
        else:
            out.append(("ok", "provider: model %s is served by %s" % (m, host)))
    if not models or missing:  # a 404 for a model nobody serves is not a missing /responses
        return out
    if wire == "chat":  # the opencode runtime: chat completions, one token
        status, _ = _request(base + "/chat/completions", key,
                             {"model": models[0], "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1})
        if status in (404, 405):
            out.append(("FAIL", "provider: %s has no /chat/completions (HTTP %d): the opencode runtime needs it" % (host, status)))
        elif status is None or status >= 500:
            out.append(("FAIL", "provider: POST /chat/completions at %s %s" % (host, "did not answer" if status is None else "answered HTTP %d" % status)))
        else:
            out.append(("ok", "provider: %s answers /chat/completions" % host))
        return out
    status, _ = _request(base + "/responses", key, {"model": models[0], "input": "ping", "max_output_tokens": 1})
    if status in (404, 405):
        out.append(("FAIL", "provider: %s has no /responses (HTTP %d): the codex runtime needs the Responses API; "
                            "use the opencode runtime (#152)" % (host, status)))
    elif status is None or status >= 500:
        out.append(("FAIL", "provider: POST /responses at %s %s" % (host, "did not answer" if status is None else "answered HTTP %d" % status)))
    else:
        out.append(("ok", "provider: %s answers /responses" % host))
    return out


def main(argv):
    if argv[:1] == ["codex-args"] and 2 <= len(argv) <= 3:
        print("\0".join(codex_args(argv[1], argv[2] if len(argv) > 2 else "")), end="\0")
        return 0
    if argv[:1] == ["check"] and 2 <= len(argv) <= 4:
        models = [m for m in (argv[2].split("\0") if len(argv) > 2 else []) if m]
        rows = check(argv[1], models, argv[3] if len(argv) > 3 else "")
        for kind, text in rows:
            print("%s %s" % (kind, text))
        return 1 if any(k == "FAIL" for k, _ in rows) else 0
    print("usage: provider.py codex-args <base_url> [<key_env>] | check <base_url> [<models, NUL-separated> [<key_env>]]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
