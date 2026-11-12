#!/usr/bin/env python3
"""Home Assistant from the command line, for agents. Python 3 standard library only.

Reads the URL and token file from ~/.config/comma-ha/connection.json
({"url": ..., "token_file": ...}); never prints the token.

  ha entities [TEXT] [--domain D] [--all]   list entities (id, state, name); unavailable ones only with --all
  ha state ENTITY                           one entity's state and attributes
  ha services [DOMAIN]                      services you can call, with their fields
  ha call DOMAIN.SERVICE [ENTITY ...] [key=value ...]
                                            call a service; prints each entity's state and attributes after
                                            the call, and under "differs" the asked values it does not show
  ha check                                  HA version and API status
  ha catalog [--all]                        every live entity by area, with its services: the device list
                                            for an agent's skill (unavailable ones only with --all)

Values in key=value are read as JSON when they parse (brightness_pct=40, rgb_color=[255,0,0]),
otherwise as text. Exit status: 0 ok, 1 HA refused or failed, 2 usage error.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CONFIG = Path(os.environ.get("COMMA_HA_CONFIG", Path.home() / ".config/comma-ha/connection.json"))
DOWN = ("unavailable", "unknown")


def fail(message, code=1):
    print(json.dumps({"error": message}, ensure_ascii=False))
    sys.exit(code)


def load():
    try:
        conn = json.loads(CONFIG.read_text())
        token = Path(conn["token_file"]).read_text().strip()
        return conn["url"].rstrip("/"), token
    except Exception as e:  # config missing or malformed
        fail(f"cannot read HA connection from {CONFIG}: {type(e).__name__}")


URL, TOKEN = None, None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the request carries the token, and the new address may be another host."""

    def redirect_request(self, *_args):
        return None  # urllib then raises the 3xx as an HTTPError


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def api(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(URL + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            fail(f"HA at {URL} redirected {method} {path} to {e.headers.get('Location')}; the token is not sent "
                 "there. Set url in the connection file to the address HA itself serves.")
        detail = e.read().decode(errors="replace")[:300]
        fail(f"HA answered {e.code} for {method} {path}: {detail}")
    except (urllib.error.URLError, OSError) as e:
        fail(f"cannot reach HA at {URL}: {e}")


def name(s):
    return s.get("attributes", {}).get("friendly_name", "")


def entities(args):
    text, domain, show_all = [], None, False
    it = iter(args)
    for a in it:
        if a == "--domain":
            domain = next(it, None)
        elif a == "--all":
            show_all = True
        else:
            text.append(a.lower())
    rows = []
    for s in api("GET", "/api/states"):
        eid = s["entity_id"]
        if domain and not eid.startswith(domain + "."):
            continue
        if not show_all and s["state"] in DOWN:
            continue
        hay = (eid + " " + name(s)).lower()
        if all(t in hay for t in text):
            rows.append((eid, s["state"], name(s)))
    for eid, state, fn in sorted(rows):
        print(json.dumps({"entity_id": eid, "state": state, "name": fn}, ensure_ascii=False))
    if not rows:
        print(json.dumps({"matches": 0}))


def state(args):
    if len(args) != 1:
        fail("usage: ha state ENTITY", 2)
    print(json.dumps(api("GET", "/api/states/" + args[0]), ensure_ascii=False, indent=1))


def services(args):
    for d in api("GET", "/api/services"):
        if args and d["domain"] != args[0]:
            continue
        for svc, spec in sorted(d["services"].items()):
            fields = sorted((spec.get("fields") or {}).keys())
            print(json.dumps({"service": f"{d['domain']}.{svc}", "fields": fields}, ensure_ascii=False))


def parse_value(v):
    try:
        return json.loads(v)
    except ValueError:
        return v


def call(args):
    if not args or "." not in args[0]:
        fail("usage: ha call DOMAIN.SERVICE [ENTITY ...] [key=value ...]", 2)
    domain, service = args[0].split(".", 1)
    ids, data = [], {}
    for a in args[1:]:
        if "=" in a:
            k, v = a.split("=", 1)
            data[k] = parse_value(v)
        else:
            ids.append(a)
    if ids:
        data["entity_id"] = ids if len(ids) > 1 else ids[0]
    api("POST", f"/api/services/{domain}/{service}", data)
    time.sleep(1)  # let HA apply the change before reading it back
    # HA accepting the call does not mean the device reached the asked values: read them back and compare.
    print(json.dumps({"called": args[0], "data": data, "accepted": True}, ensure_ascii=False))
    for eid in ids:
        s = api("GET", "/api/states/" + eid)
        attrs = s.get("attributes", {})
        row = {"entity_id": eid, "state": s["state"], "name": name(s), "attributes": attrs}
        differs = differences(data, attrs)
        if differs:
            row["differs"] = differs
        print(json.dumps(row, ensure_ascii=False))


def differences(asked, attrs):
    """Asked values the entity's attributes do not show. brightness_pct is compared with brightness (0-255)."""
    out = {}
    for key, want in asked.items():
        if key == "entity_id":
            continue
        if key == "brightness_pct" and isinstance(want, (int, float)) and "brightness" in attrs:
            have = attrs["brightness"]
            if not isinstance(have, (int, float)) or abs(have * 100 / 255 - want) > 1:
                out[key] = {"asked": want, "now": None if have is None else round(have * 100 / 255)}
        elif key in attrs and attrs[key] != want:
            out[key] = {"asked": want, "now": attrs[key]}
    return out


AREA_TEMPLATE = "{% for s in states %}{{ s.entity_id }}|{{ area_name(s.entity_id) or '' }}\n{% endfor %}"
READ_ONLY = {"sensor", "binary_sensor", "sun", "weather", "zone", "person", "device_tracker", "update", "event"}
ATTRS = ("unit_of_measurement", "device_class", "supported_features", "supported_color_modes", "color_mode",
         "brightness", "current_temperature",
         "temperature", "hvac_modes", "preset_modes", "source_list", "options")


def catalog(args):
    show_all = "--all" in args
    req = urllib.request.Request(URL + "/api/template", method="POST",
                                 data=json.dumps({"template": AREA_TEMPLATE}).encode(),
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=60) as r:
            areas = dict(line.split("|", 1) for line in r.read().decode().splitlines() if "|" in line)
    except Exception as e:  # template API refused: list without areas
        print(json.dumps({"warning": f"areas unavailable: {e}"}))
        areas = {}
    services = {d["domain"]: sorted(d["services"]) for d in api("GET", "/api/services")}
    rows = []
    for s in api("GET", "/api/states"):
        if not show_all and s["state"] in DOWN:
            continue
        eid = s["entity_id"]
        domain = eid.split(".", 1)[0]
        attrs = {k: s["attributes"][k] for k in ATTRS if k in s["attributes"]}
        rows.append({"area": areas.get(eid, ""), "entity_id": eid, "name": name(s), "state": s["state"],
                     "services": [] if domain in READ_ONLY else services.get(domain, []), **attrs})
    for row in sorted(rows, key=lambda r: (r["area"] == "", r["area"], r["entity_id"])):
        print(json.dumps(row, ensure_ascii=False))


def check(_args):
    cfg = api("GET", "/api/config")
    print(json.dumps({"api": api("GET", "/api/")["message"], "version": cfg.get("version"),
                      "state": cfg.get("state")}, ensure_ascii=False))


COMMANDS = {"entities": entities, "state": state, "services": services, "call": call, "check": check, "catalog": catalog}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(2)
    URL, TOKEN = load()
    COMMANDS[sys.argv[1]](sys.argv[2:])
