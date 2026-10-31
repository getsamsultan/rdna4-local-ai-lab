#!/usr/bin/env python3
"""Round 2 mechanical checks: run what can be run, compute what can be computed. No judge involved.

Usage: python3 execcheck.py [--pg "host=... port=... user=..."] [--promtool PATH] answers-*.jsonl
Writes exec-results.csv: n, prompt_id, config, check, score_0_2, detail.

Executed prompts (score 0-2, these replace the judges' score for that prompt):
  12 modbus-parser  the answer's code is imported and run against hidden tests, plus its own pytest tests
  13 meter-rollover the answer's SQL runs against a real PostgreSQL with test data (rollovers incl. at midnight,
                    a gap, three meters) and is compared to the computed daily totals
  14 promql-alert   promtool checks the rule file, then promtool unit tests check that the rule's expression
                    fires for the card above 300 W only, and that query (a) returns one 5-minute average per card
Computed prompts (cross-check only, not a score): 1 2 3 4 7 8 are searched for the key numbers from RUBRIC.md.
  "found 3/4" means 3 of the 4 key values appear somewhere in the answer. It doesn't prove the working is right.

The answers' code runs as a subprocess with a timeout. It's model-written code: run this inside a throwaway
container if you don't trust it (e.g. docker run --rm --network none ...).
Run it AFTER the human blind pass: the output names configs.
"""
import argparse, csv, json, pathlib, re, shutil, subprocess, sys, tempfile, textwrap
from decimal import Decimal
from datetime import datetime, timedelta, timezone

here = pathlib.Path(__file__).parent
ap = argparse.ArgumentParser()
ap.add_argument("files", nargs="+")
ap.add_argument("--pg", default="host=/tmp port=5432 user=postgres", help="libpq connection string for a scratch PostgreSQL")
ap.add_argument("--promtool", default="promtool")
ap.add_argument("--out", default="exec-results.csv")
a = ap.parse_args()

BLOCK = re.compile(r"```[ \t]*([\w+-]*)[^\n]*\n(.*?)```", re.S)
def blocks(text, langs=None):
    out = []
    for lang, body in BLOCK.findall(text or ""):
        if langs is None or lang.lower() in langs: out.append((lang.lower(), body))
    return out

# ---------------------------------------------------------------- 12 modbus-parser
HIDDEN = textwrap.dedent('''
    import sys, json
    from solution import parse_mbap
    def data_ok(d, want):
        if isinstance(d, (bytes, bytearray)): return bytes(d) == want
        if isinstance(d, (list, tuple)): return list(d) == list(want)
        if isinstance(d, str): return d.replace(" ", "").lower() in (want.hex(), "0x" + want.hex())
        return False
    res = {}
    def check(name, fn):
        try: res[name] = bool(fn())
        except Exception as e: res[name] = False
    def raises(frame):
        try: parse_mbap(frame)
        except Exception: return True
        return False
    f1 = bytes.fromhex("000100000006110300 6B0003".replace(" ", ""))
    def valid1():
        r = parse_mbap(f1)
        return (r["transaction_id"], r["protocol_id"], r["length"], r["unit_id"], r["function_code"]) == (1, 0, 6, 17, 3) and data_ok(r["data"], bytes.fromhex("006B0003"))
    f2 = bytes.fromhex("0002 0000 000B 01 10 0001 0002 04 000A 0102".replace(" ", ""))
    def valid2():
        r = parse_mbap(f2)
        return (r["transaction_id"], r["length"], r["unit_id"], r["function_code"]) == (2, 11, 1, 16) and data_ok(r["data"], bytes.fromhex("0001000204000A0102"))
    check("valid_read_holding", valid1)
    check("valid_write_multiple", valid2)
    check("rejects_short_7_bytes", lambda: raises(f1[:7]))
    check("rejects_protocol_id_1", lambda: raises(f1[:2] + b"\\x00\\x01" + f1[4:]))
    check("rejects_length_too_big", lambda: raises(f1[:4] + b"\\x00\\x07" + f1[6:]))
    check("rejects_length_too_small", lambda: raises(f1[:4] + b"\\x00\\x05" + f1[6:]))
    check("rejects_trailing_byte", lambda: raises(f1 + b"\\x00"))
    print(json.dumps(res))
''')

def check_parser(ans):
    py = [b for l, b in blocks(ans) if l in ("python", "py", "")]
    impl = [b for b in py if "def parse_mbap" in b]
    tests = [b for b in py if "def test_" in b and b not in impl]
    if not impl:
        return 0, "no parse_mbap implementation found"
    d = pathlib.Path(tempfile.mkdtemp(prefix="mbap-"))
    src = impl[-1]
    # tests may sit in the same block as the implementation; split them off so the module imports cleanly
    (d / "solution.py").write_text(src)
    mods = set(re.findall(r"from\s+([\w.]+)\s+import\s+[^\n]*parse_mbap", "\n".join(tests + [src])))
    for m in mods:
        if m != "solution" and "." not in m: shutil.copy(d / "solution.py", d / f"{m}.py")
    t = "\n\n".join(tests)
    if not tests and "def test_" in src:
        t = src  # tests live with the implementation
    if t:
        has_import = re.search(r"^\s*(from\s+\S+\s+import\s+[^\n]*parse_mbap|def parse_mbap)", t, re.M)
        (d / "test_answer.py").write_text(t if has_import else "from solution import *\n" + t)
    try:
        h = subprocess.run([sys.executable, "-c", HIDDEN], cwd=d, capture_output=True, text=True, timeout=30)
        hidden = json.loads(h.stdout.strip().splitlines()[-1]) if h.returncode == 0 and h.stdout.strip() else None
    except Exception:
        hidden = None
    if hidden is None:
        return 0, "implementation doesn't import or crashes on the hidden tests"
    own = "no own tests"
    own_ok = False
    if t:
        p = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "test_answer.py"],
                           cwd=d, capture_output=True, text=True, timeout=60)
        last = (p.stdout.strip().splitlines() or ["?"])[-1]
        own_ok = p.returncode == 0 and "passed" in last
        own = f"own tests: {last}"
    passed = sum(hidden.values()); failed = [k for k, v in hidden.items() if not v]
    detail = f"hidden {passed}/{len(hidden)}" + (f" (failed: {', '.join(failed)})" if failed else "") + f"; {own}"
    if passed == len(hidden) and own_ok: return 2, detail
    if passed >= len(hidden) - 1 or (passed >= 4 and own_ok): return 1, detail
    return 0, detail

# ---------------------------------------------------------------- 13 meter-rollover
def series():
    """Test data: three meters, 15-minute readings over two UTC days.
    101: 2.5 kWh per interval, rolls over mid-morning on day 1.
    202: 1.0 kWh per interval, no rollover, readings missing 10:00-11:45 on day 2 (gap).
    303: 4.0 kWh per interval, rolls over exactly between 23:45 on day 1 and 00:00 on day 2."""
    t0 = datetime(2026, 10, 1, tzinfo=timezone.utc); rows = []
    for meter, start, step in ((101, Decimal("999900"), Decimal("2.5")), (202, Decimal("5000"), Decimal("1.0")),
                               (303, Decimal("999620"), Decimal("4.0"))):
        v = start
        for i in range(2 * 96):
            ts = t0 + timedelta(minutes=15 * i)
            if not (meter == 202 and ts.day == 2 and 10 <= ts.hour < 12):
                rows.append((ts, meter, v % 1000000))
            v += step
    return rows

def expected(rows, variant):
    out, prev = {}, {}
    for ts, m, v in sorted(rows, key=lambda r: (r[1], r[0])):
        if m in prev:
            pts, pv = prev[m]
            d = v - pv
            if d < 0: d += 1000000
            day = ts.date()
            if variant == "prev_day": day = pts.date()
            if variant == "within_day" and pts.date() != ts.date(): d = None
            if variant == "skip_gaps" and ts - pts > timedelta(minutes=15): d = None
            if d is not None:
                out[(m, day)] = out.get((m, day), Decimal(0)) + d
        prev[m] = (ts, v)
    return out

VARIANTS = ("later_day", "prev_day", "within_day", "skip_gaps")

def psql(sql, db):
    return subprocess.run(["psql", f"{a.pg} dbname={db}", "-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1",
                           "-c", "SET TIME ZONE 'UTC'; SET statement_timeout = '15s';", "-c", sql],
                          capture_output=True, text=True, timeout=60)

def check_sql(ans, tag):
    cands = [b for l, b in blocks(ans) if "readings" in b.lower() and re.search(r"\bselect\b", b, re.I)]
    if not cands:
        return 0, "no SQL query on readings found"
    sql = max(cands, key=len)
    db = f"eval_{tag}".lower()
    subprocess.run(["psql", f"{a.pg} dbname=postgres", "-X", "-q", "-c", f"DROP DATABASE IF EXISTS {db}", "-c", f"CREATE DATABASE {db}"],
                   capture_output=True, text=True)
    rows = series()
    load = "CREATE TABLE readings(ts timestamptz, meter_id int, kwh_cumulative numeric);\nINSERT INTO readings VALUES\n" + \
           ",\n".join(f"('{ts.isoformat()}',{m},{v})" for ts, m, v in rows) + ";"
    psql(load, db)
    r = psql(sql, db)
    subprocess.run(["psql", f"{a.pg} dbname=postgres", "-X", "-q", "-c", f"DROP DATABASE IF EXISTS {db}"], capture_output=True)
    if r.returncode != 0:
        return 0, "SQL error: " + (r.stderr.strip().splitlines() or ["?"])[-1][:150]
    got = {}
    for line in r.stdout.strip().splitlines():
        cells = line.split("\t"); day = meter = val = None
        for c in cells:
            c = c.strip()
            if day is None and re.match(r"^\d{4}-\d{2}-\d{2}", c): day = datetime.fromisoformat(c[:10]).date(); continue
            if meter is None and c in ("101", "202", "303"): meter = int(c); continue
            try: val = Decimal(c)
            except Exception: pass
        if day and meter and val is not None: got[(meter, day)] = val
    if not got:
        return 0, f"query ran but returned no usable (day, meter, kWh) rows; first line: {r.stdout.strip()[:80]!r}"
    for var in VARIANTS:
        exp = expected(rows, var)
        keys = set(exp) | set(got)
        if all(abs(got.get(k, Decimal(0)) - exp.get(k, Decimal(0))) < Decimal("0.01") for k in keys):
            return (2 if var in ("later_day", "within_day", "skip_gaps") else 1), f"matches '{var}' totals ({len(got)} rows)"
    exp = expected(rows, "later_day")
    bad = sorted(k for k in set(exp) | set(got) if abs(got.get(k, Decimal(0)) - exp.get(k, Decimal(0))) >= Decimal("0.01"))
    k = bad[0]
    return 0, f"wrong totals, e.g. meter {k[0]} on {k[1]}: got {got.get(k)} want {exp.get(k)} ({len(bad)} of {len(exp)} wrong)"

# ---------------------------------------------------------------- 14 promql-alert
def check_promql(ans, tag):
    import yaml
    rule_src = None
    for l, b in blocks(ans):
        if "alert:" in b and "expr" in b:
            rule_src = b; break
    if rule_src is None:
        return 0, "no alerting rule found"
    try:
        doc = yaml.safe_load(rule_src)
    except Exception as e:
        return 0, f"rule isn't valid YAML: {str(e).splitlines()[0][:100]}"
    if isinstance(doc, dict) and "groups" in doc: groups = doc
    elif isinstance(doc, dict) and "rules" in doc: groups = {"groups": [doc]}
    elif isinstance(doc, list): groups = {"groups": [{"name": "answer", "rules": doc}]}
    elif isinstance(doc, dict) and "alert" in doc: groups = {"groups": [{"name": "answer", "rules": [doc]}]}
    else:
        return 0, "couldn't find rules in the YAML"
    d = pathlib.Path(tempfile.mkdtemp(prefix="prom-"))
    (d / "rules.yml").write_text(yaml.safe_dump(groups))
    c = subprocess.run([a.promtool, "check", "rules", "rules.yml"], cwd=d, capture_output=True, text=True)
    loads = c.returncode == 0
    notes = ["rule valid"]
    if not loads:
        err = (c.stderr or c.stdout).strip().splitlines()[-1]
        # retry without annotations: if only an annotation template is broken, Prometheus still refuses
        # to load the file, but the expression itself can be tested (rubric: minor syntax error = 1)
        for g in groups["groups"]:
            for r in g.get("rules", []): r.pop("annotations", None)
        (d / "rules.yml").write_text(yaml.safe_dump(groups))
        c2 = subprocess.run([a.promtool, "check", "rules", "rules.yml"], cwd=d, capture_output=True, text=True)
        if c2.returncode != 0 or "template" not in err:
            return 0, "promtool check rules failed: " + err[-150:]
        notes = ["rule file would NOT load (annotation template error: " + err.split("template:")[-1].strip()[:80] + ")"]
    rules = [r for g in groups["groups"] for r in g.get("rules", []) if "alert" in r]
    rule = rules[0]
    def dur(s):
        m = re.fullmatch(r"(\d+)([smh])", str(s or "0s")); return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)] if m else 0
    window = max([dur(x) for x in re.findall(r"\[(\d+[smh])\]", rule["expr"])] or [0])
    held = dur(rule.get("for")) + (window if "_over_time" in rule["expr"] else 0)
    for_ok = dur(rule.get("for")) >= 600 or window >= 600
    notes.append(f"for={rule.get('for', 'none')}")
    summary = "summary" in (rule.get("annotations") or {}) or not loads
    if not summary: notes.append("no summary annotation")
    # functional: card 0 = 350 W, card 1 = 250 W, card 2 = 100 W, constant
    inputs = [{"series": f'amdgpu_power_watts{{card="{c}"}}', "values": f"{w}+0x120"} for c, w in (("0", 350), ("1", 250), ("2", 100))]
    def exprtest(expr, samples):
        ok = False
        for with_name in (False, True):
            exp = [{"labels": ('amdgpu_power_watts' if with_name else '') + "{" + f'card="{c}"' + "}", "value": v} for c, v in samples]
            t = {"rule_files": [], "evaluation_interval": "15s",
                 "tests": [{"interval": "15s", "input_series": inputs,
                            "promql_expr_test": [{"expr": expr, "eval_time": "20m", "exp_samples": exp}]}]}
            (d / "t.yml").write_text(yaml.safe_dump(t))
            r = subprocess.run([a.promtool, "test", "rules", "t.yml"], cwd=d, capture_output=True, text=True)
            ok = ok or r.returncode == 0
        return ok
    fires_right = exprtest(rule["expr"], [("0", 350)])
    notes.append("expr fires for card 0 only" if fires_right else "expr result wrong")
    q = None
    for l, b in blocks(ans):
        for line in b.splitlines():
            line = line.strip().strip("`")
            if "amdgpu_power_watts" in line and "expr" not in line and "alert" not in line and not line.startswith("#"):
                q = line; break
        if q: break
    q_ok = bool(q) and exprtest(q, [("0", 350), ("1", 250), ("2", 100)])
    notes.append("query (a) returns 3 card averages" if q_ok else f"query (a) {'wrong' if q else 'not found'}")
    if loads and fires_right and q_ok and for_ok and summary: return 2, "; ".join(notes)
    if fires_right or q_ok: return 1, "; ".join(notes)
    return 0, "; ".join(notes)

# ---------------------------------------------------------------- computed cross-checks
KEYS = {
    1: [r"\b107\b", r"\b17\b", r"\b40?0108\b", r"read holding"],
    2: [r"\b351(\.0+)?\b"],
    3: [r"\b19[.,]9\d*\s*kW|\b19[.,]95\b", r"\b22[.,]1\d*\s*kVA|\b22[.,]17\b", r"\b(two|2)\s+(\w+\s+)?racks?\b"],
    4: [r"\b1\.33\b", r"\b1[,. ]?051[,. ]?200\b", r"\b210[,. ]?240\b"],
    7: [r"\b24[,. ]?576\b|\b24\s*KiB\b", r"\b3(\.0+)?\s*GiB\b", r"\b1\.5\d*\s*GiB\b", r"n[o']t\s+fit|doesn.t fit|won.t fit|cannot fit|neither fits?"],
    8: [r"\b2[0-9]{2}\s*(t/s|tok)"],
}
def norm(t):
    """Undo number formatting that hides a value from a plain search: LaTeX {,} and \\, spacing,
    thin / no-break spaces used as thousands separators, ** bold markers."""
    t = (t or "").replace("{,}", ",").replace("**", "")
    t = re.sub(r"\\[,;:! ]", " ", t)
    t = re.sub(r"[\u00a0\u2009\u202f]", " ", t)
    t = re.sub(r"(?<=\d) (?=\d{3}\b)", ",", t)   # "1 051 200" -> "1,051,200"
    return t

def check_numbers(n, ans):
    t = norm(ans)
    found = sum(bool(re.search(p, t, re.I)) for p in KEYS[n])
    return "", f"key values found {found}/{len(KEYS[n])}"

# ---------------------------------------------------------------- run
rows = []
for f in a.files:
    for l in open(f):
        r = json.loads(l); n = r["n"]; ans = r["answer"]; cfg = r["label"]
        tag = f"{cfg}_{n}".replace("-", "_")
        if n == 12: s, why = check_parser(ans); kind = "executed"
        elif n == 13: s, why = check_sql(ans, tag); kind = "executed"
        elif n == 14: s, why = check_promql(ans, tag); kind = "executed"
        elif n in KEYS: s, why = check_numbers(n, ans); kind = "computed"
        else: continue
        rows.append({"n": n, "prompt_id": r["id"], "config": cfg, "check": kind, "score_0_2": s, "detail": why})
        print(f"{n:>2} {r['id']:<15} {cfg:<14} {kind:<9} {s!s:>1}  {why}")
with open(here / a.out, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
print(f"saved {a.out}")
