#!/usr/bin/env python3
"""Whether two answers (status from <file>.head, body from <file>) are the same: status and every field (key order,
1 vs 1.0 aside; an error's wording too). diff.py <rust answer> <ts answer>"""
import json, sys

def load(p):
    try:
        head = json.loads(open(p + ".head").read().strip().splitlines()[-1])
    except Exception as e:
        head = {"unreadable": str(e)}
    try:
        body = json.load(open(p))
    except Exception as e:
        body = "unreadable: %s" % e
    return head.get("status"), body

(sa, a), (sb, b) = load(sys.argv[1]), load(sys.argv[2])
out = []
# An answer that is not there is no answer to compare: the asking failed.
for name, status in (("rust", sa), ("ts", sb)):
    if not isinstance(status, int):
        out.append("no answer from %s" % name)
if sa != sb:
    out.append("status %s vs %s" % (sa, sb))

def walk(x, y, p):
    if len(out) > 5:
        return
    if isinstance(x, dict) and isinstance(y, dict):
        for k in sorted(set(x) | set(y)):
            if k not in x or k not in y:
                out.append("%s.%s missing in %s" % (p, k, "rust" if k not in x else "ts"))
            else:
                walk(x[k], y[k], p + "." + k)
    elif isinstance(x, list) and isinstance(y, list):
        if len(x) != len(y):
            out.append("%s: %d items vs %d" % (p, len(x), len(y)))
        for i, (u, v) in enumerate(zip(x, y)):
            walk(u, v, "%s[%d]" % (p, i))
    elif x != y or (type(x) is bool) != (type(y) is bool):
        out.append("%s: %s vs %s" % (p, json.dumps(x, ensure_ascii=False)[:70], json.dumps(y, ensure_ascii=False)[:70]))

walk(a, b, "")
print("\n".join(out))
sys.exit(1 if out else 0)
