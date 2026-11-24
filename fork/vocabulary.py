#!/usr/bin/env python3
"""Keeps the front of Hex's vocabulary on the terms Derek used most in the last 30 days.

Transcription reads only the front of the vocabulary (src/dictation/vocabulary.rs): Parakeet with
Labs › Vocabulary biasing on biases toward the first 64 terms, and Whisper and Qwen3-ASR read the
first terms that fit 500 and 1,000 characters joined by ", ". The rest still serves rewriting and
search. Each night the automation lists the new dictations, picks up to 5 new terms, and runs
apply, which adds them and ranks the vocabulary:

  1. pinned terms (state/vocab/pinned.json, in that order);
  2. then by uses in the last 30 days of History's final text, most first; equal counts go
     terms this script added in the last 30 days (up to 200 characters of the front), then
     Derek's own terms, then imported terms and older ones this script added, each group
     keeping its current order.

The front takes ranked terms while they fit (64 terms, or the characters left; a term too long
for what is left is passed over for shorter ones), so the model reads exactly those terms.

Only the running Hex edits the vocabulary. "hex vocabulary add" appends, so apply moves the fewest
terms to the end (remove, then add with the same spellings) that leave the planned front first.
It writes only when the front changes or a term is added or removed, backs up settings.json
first, and checks afterwards that every term and spelling is still there and the front matches the
plan. Terms Derek added or imported are never removed and get no new spellings; a term this script
added is removed after 90 days unused. No dictation text is stored.

  fork/vocabulary.py init --import-log LOG          record the imported terms (once)
  fork/vocabulary.py dictations                     dictations since the last apply, to stdout
  fork/vocabulary.py plan [--add FILE] [--exclude-app APP]   tonight's changes; writes nothing
  fork/vocabulary.py apply [--add FILE] [--exclude-app APP]  back up, change, verify, record

FILE: {"add": [{"term": "…", "sounds_like": ["…"]}]}
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import date, datetime, timedelta

HOME = os.path.expanduser(os.environ.get("HEX_FORK_HOME", "~/.hex-fork"))
STATE = os.path.join(HOME, "state", "vocab")
OWN = os.path.join(STATE, "own.json")
PINNED = os.path.join(STATE, "pinned.json")
IMPORTED = os.path.join(STATE, "imported.json")
LAST_PLAN = os.path.join(STATE, "last-plan.json")
BACKUPS = os.path.join(HOME, "backup", "vocab")
HEX = os.environ.get("HEX_FORK_HEX", "/Applications/Hex.app/Contents/MacOS/hex")
SETTINGS = os.path.join(
    os.path.expanduser(os.environ.get("HEX_APPLICATION_SUPPORT_DIR", "~/Library/Application Support/hex")),
    "settings.json",
)

PARAKEET_TERMS = 64
MAX_ADDS = 5
MAX_CHARS = 64
USAGE_DAYS = 30
FIRST_WINDOW_DAYS = 7
GRACE_DAYS = 30
GRACE_CHARS = 200
UNUSED_DAYS = 90
DAY_MS = 86_400_000


class HexError(Exception):
    pass


def run_hex(*args):
    proc = subprocess.run([HEX, *args, "--json"], capture_output=True, text=True)
    if proc.returncode != 0:
        detail = " ".join((proc.stdout.strip() or proc.stderr.strip()).split())
        raise HexError(f"hex {' '.join(args)} exited {proc.returncode}: {detail[:300]}")
    return json.loads(proc.stdout)


def load(path, default):
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError:
        return default


def save(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    temporary = path + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
        file.write("\n")
    os.replace(temporary, path)


def day(ms):
    return datetime.fromtimestamp(ms / 1000).date().isoformat()


def mention(term):
    """The term in any case; a Latin letter or digit at either end must not touch another."""
    pattern = re.escape(term)
    if term[:1].isascii() and term[:1].isalnum():
        pattern = r"(?<![A-Za-z0-9])" + pattern
    if term[-1:].isascii() and term[-1:].isalnum():
        pattern += r"(?![A-Za-z0-9])"
    return re.compile(pattern, re.IGNORECASE)


def front_rule(model, biasing):
    """How much of the list the selected model reads; None when transcription reads none of it."""
    if model["vocabulary"] == "prompt":
        qwen3 = "qwen3" in f"{model['id']} {model['name']}".lower()
        return {"unit": "characters", "limit": 1_000 if qwen3 else 500}
    if model["vocabulary"] == "bias" and biasing:
        return {"unit": "terms", "limit": PARAKEET_TERMS}
    return None


def terms_read(rule, terms):
    if rule is None:
        return 0
    if rule["unit"] == "terms":
        return min(len(terms), rule["limit"])
    chars = 0
    for index, term in enumerate(terms):
        chars += (2 if index else 0) + len(term)
        if chars > rule["limit"]:
            return index
    return len(terms)


def entries_now():
    return [
        {"term": entry["term"], "sounds_like": list(entry.get("sounds_like", []))}
        for entry in run_hex("vocabulary", "list")["entries"]
    ]


def build(additions_path, exclude_app):
    """Tonight's changes, computed from the running Hex and History; changes nothing."""
    vocabulary = entries_now()
    selected = run_hex("status")["model"]
    kind = next(
        (model.get("vocabulary", "none") for model in run_hex("model", "list")["models"] if model["id"] == selected["id"]),
        "none",
    )
    model = {"id": selected["id"], "name": selected["name"], "vocabulary": kind}
    biasing = run_hex("settings", "get", "labs.vocabulary_biasing")["settings"][0]["value"]
    history = run_hex("history", "--since", f"{USAGE_DAYS}d", "--limit", "10000")["entries"]
    if exclude_app:
        history = [entry for entry in history if (entry.get("application") or "").casefold() != exclude_app.casefold()]

    own = {term.casefold(): (term, info) for term, info in load(OWN, {}).get("terms", {}).items()}
    pinned = [term.casefold() for term in load(PINNED, [])]
    imported = {term.casefold() for term in load(IMPORTED, [])}
    today = date.today()
    listed = {entry["term"].casefold(): entry for entry in vocabulary}

    adds, spellings, skipped = [], [], []
    additions = load(additions_path, {}).get("add", []) if additions_path else []
    for index, item in enumerate(additions):
        term = item["term"].strip()
        key = term.casefold()
        heard = [spelling.strip() for spelling in item.get("sounds_like", []) if spelling.strip()]
        if index >= MAX_ADDS:
            skipped.append({"term": term, "reason": f"over the limit of {MAX_ADDS} per night"})
            continue
        if len(term) > MAX_CHARS or any(len(spelling) > MAX_CHARS or "," in spelling for spelling in heard):
            skipped.append({"term": term, "reason": f"a term or spelling is over {MAX_CHARS} characters or has a comma"})
            continue
        if key in listed:
            if key not in own:
                skipped.append({"term": term, "reason": "added by hand or imported; left as it is"})
                continue
            known = {spelling.casefold() for spelling in listed[key]["sounds_like"]}
            heard = [spelling for spelling in heard if spelling.casefold() not in known]
            if not heard:
                skipped.append({"term": term, "reason": "already listed with these spellings"})
                continue
            spellings.append({"term": listed[key]["term"], "sounds_like": heard})
            continue
        adds.append({"term": term, "sounds_like": heard})
        listed[key] = adds[-1]

    terms = [entry["term"] for entry in vocabulary] + [entry["term"] for entry in adds]
    counts, latest = {}, {}
    for term in terms:
        pattern = mention(term)
        key = term.casefold()
        counts[key] = 0
        for entry in history:
            found = len(pattern.findall(entry.get("final_text") or ""))
            if found:
                counts[key] += found
                latest[key] = max(latest.get(key, 0), entry["timestamp_ms"])

    seen = {}
    removes = []
    for key, (term, info) in own.items():
        last = max(filter(None, [info.get("last_seen"), day(latest[key]) if key in latest else None]), default=None)
        seen[key] = last
        since = date.fromisoformat(last or info["added"])
        if key in listed and key not in pinned and today - since > timedelta(days=UNUSED_DAYS):
            removes.append(listed[key]["term"])

    removed = {term.casefold() for term in removes}
    after = [entry for entry in vocabulary if entry["term"].casefold() not in removed] + adds
    for change in spellings:
        target = next(entry for entry in after if entry["term"].casefold() == change["term"].casefold())
        target["sounds_like"] = target["sounds_like"] + change["sounds_like"]

    added_today = {entry["term"].casefold() for entry in adds}
    grace_chars = 0
    groups = {}
    for entry in after:
        key = entry["term"].casefold()
        added = today if key in added_today else (date.fromisoformat(own[key][1]["added"]) if key in own else None)
        if added and today - added < timedelta(days=GRACE_DAYS) and grace_chars + len(entry["term"]) + 2 <= GRACE_CHARS:
            grace_chars += len(entry["term"]) + 2
            groups[key] = "new"
        elif key in own or key in added_today or key in imported:
            groups[key] = "imported" if key in imported else "added"
        else:
            groups[key] = "derek"
    order = {"new": 0, "derek": 1, "imported": 2, "added": 2}
    position = {entry["term"].casefold(): index for index, entry in enumerate(after)}
    by_key = {entry["term"].casefold(): entry for entry in after}
    ranked = [by_key[key] for key in pinned if key in by_key] + sorted(
        (entry for entry in after if entry["term"].casefold() not in pinned),
        key=lambda entry: (-counts[entry["term"].casefold()], order[groups[entry["term"].casefold()]], position[entry["term"].casefold()]),
    )

    rule = front_rule(model, biasing)
    current = [entry["term"] for entry in vocabulary][: terms_read(rule, [entry["term"] for entry in vocabulary])]
    front = set()
    if rule and rule["unit"] == "terms":
        front = {entry["term"].casefold() for entry in ranked[: rule["limit"]]}
    elif rule:
        chars = 0
        for entry in ranked:
            cost = (2 if front else 0) + len(entry["term"])
            if chars + cost <= rule["limit"]:
                chars += cost
                front.add(entry["term"].casefold())
    last_front = max((position[key] for key in front), default=-1)
    moves = [entry for entry in after if entry["term"].casefold() not in front and position[entry["term"].casefold()] < last_front]
    moved = {entry["term"].casefold() for entry in moves}
    final = [entry for entry in after if entry["term"].casefold() not in moved] + moves
    planned = [entry["term"] for entry in final][: terms_read(rule, [entry["term"] for entry in final])]
    reorder = {term.casefold() for term in planned} != {term.casefold() for term in current}
    if not reorder:
        moves, final, planned = [], after, [entry["term"] for entry in after][: terms_read(rule, [entry["term"] for entry in after])]

    def row(term):
        key = term.casefold()
        return {"term": term, "uses": counts.get(key, 0), "group": "pinned" if key in pinned else groups.get(key)}

    return {
        "model": model,
        "biasing": biasing,
        "front_rule": rule,
        "usage": {"since_days": USAGE_DAYS, "dictations": len(history), "excluded_app": exclude_app},
        "count": {"before": len(vocabulary), "after": len(final)},
        "groups": {name: sum(1 for value in groups.values() if value == name) for name in ("new", "derek", "imported", "added")},
        "front_now": [row(term) for term in current],
        "front_planned": [row(term) for term in planned],
        "entering": [row(term) for term in planned if term.casefold() not in {t.casefold() for t in current}],
        "leaving": [row(term) for term in current if term.casefold() not in {t.casefold() for t in planned}],
        "moves": [entry["term"] for entry in moves],
        "adds": adds,
        "spellings": spellings,
        "removes": removes,
        "skipped": skipped,
        "write": bool(moves or adds or spellings or removes),
        "_final": final,
        "_seen": seen,
        "_latest": {key: day(value) for key, value in latest.items()},
    }


def public(plan):
    return {key: value for key, value in plan.items() if not key.startswith("_")}


def snapshot(entries):
    return {(entry["term"], frozenset(entry.get("sounds_like", []))) for entry in entries}


def apply(args):
    plan = build(args.add, args.exclude_app)
    own_state = load(OWN, {"terms": {}})
    backup = None
    if plan["write"]:
        os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
        backup = os.path.join(BACKUPS, f"settings-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json")
        shutil.copyfile(SETTINGS, backup)
        os.chmod(backup, 0o600)
        try:
            for term in plan["removes"]:
                run_hex("vocabulary", "remove", term)
            for entry in plan["adds"] + plan["spellings"]:
                run_hex("vocabulary", "add", entry["term"], *(["--sounds-like", ",".join(entry["sounds_like"])] if entry["sounds_like"] else []))
            for term in plan["moves"]:
                entry = next(item for item in plan["_final"] if item["term"] == term)
                run_hex("vocabulary", "remove", term)
                run_hex("vocabulary", "add", term, *(["--sounds-like", ",".join(entry["sounds_like"])] if entry["sounds_like"] else []))
        except HexError as error:
            sys.exit(f"stopped: {error}; settings.json before tonight's changes is at {backup}")
        after = entries_now()
        rule = plan["front_rule"]
        read = {entry["term"].casefold() for entry in after[: terms_read(rule, [entry["term"] for entry in after])]}
        expected = {row["term"].casefold() for row in plan["front_planned"]}
        problems = []
        if snapshot(after) != snapshot(plan["_final"]):
            problems.append("the terms or spellings differ from the plan")
        if read != expected:
            problems.append("the front differs from the plan")
        if problems:
            sys.exit(f"stopped: {'; '.join(problems)}; settings.json before tonight's changes is at {backup}")

    terms = own_state.setdefault("terms", {})
    for term in plan["removes"]:
        terms.pop(next(name for name in terms if name.casefold() == term.casefold()), None)
    for entry in plan["adds"]:
        terms[entry["term"]] = {"added": date.today().isoformat(), "last_seen": None}
    for name, info in terms.items():
        info["last_seen"] = max(filter(None, [info.get("last_seen"), plan["_latest"].get(name.casefold())]), default=None)
    listed_until = own_state.pop("listed_until_ms", None)
    if listed_until:
        own_state["analyzed_until_ms"] = listed_until
    save(OWN, own_state)
    if not os.path.exists(PINNED):
        save(PINNED, [])
    result = {**public(plan), "backup": backup}
    save(LAST_PLAN, {**result, "applied_at": datetime.now().isoformat(timespec="seconds")})
    print(json.dumps(result, ensure_ascii=False, indent=2))


def dictations(_args):
    own_state = load(OWN, {"terms": {}})
    now = int(time.time() * 1000)
    since = own_state.get("analyzed_until_ms", now - FIRST_WINDOW_DAYS * DAY_MS)
    history = run_hex("history", "--since", str(since), "--until", str(now), "--raw", "--oldest-first", "--limit", "10000")
    listed = []
    for entry in history["entries"]:
        text = entry.get("final_text") or ""
        item = {"time": datetime.fromtimestamp(entry["timestamp_ms"] / 1000).strftime("%Y-%m-%d %H:%M"), "app": entry.get("application"), "text": text}
        raw = entry.get("raw_text") or ""
        if raw.strip() != text.strip():
            item["raw"] = raw
        listed.append(item)
    own_state["listed_until_ms"] = now
    save(OWN, own_state)
    print(json.dumps({"since": day(since), "until": day(now), "dictations": listed}, ensure_ascii=False, indent=1))


def init(args):
    log = load(args.import_log, None)
    if log is None:
        sys.exit(f"{args.import_log} is missing")
    imported = [item["term"] for item in log["log"] if item.get("group") == "tech" and item.get("outcome") == "added"]
    save(IMPORTED, imported)
    if not os.path.exists(PINNED):
        save(PINNED, [])
    if not os.path.exists(OWN):
        save(OWN, {"terms": {}})
    print(json.dumps({"imported": len(imported), "state": STATE}))


def main():
    parser = argparse.ArgumentParser(description="Keep the front of Hex's vocabulary on the terms used most.")
    commands = parser.add_subparsers(dest="command", required=True)
    starting = commands.add_parser("init", help="record which terms were imported")
    starting.add_argument("--import-log", required=True, help="the import's log (group tech = imported)")
    commands.add_parser("dictations", help="print the dictations since the last apply")
    for name, text in (("plan", "print tonight's changes; write nothing"), ("apply", "back up, change, verify, record")):
        command = commands.add_parser(name, help=text)
        command.add_argument("--add", help='JSON file: {"add": [{"term": "…", "sounds_like": ["…"]}]}')
        command.add_argument("--exclude-app", help="leave this app's dictations out of the counts (e.g. Hex)")
    args = parser.parse_args()
    try:
        if args.command == "plan":
            print(json.dumps(public(build(args.add, args.exclude_app)), ensure_ascii=False, indent=2))
        else:
            {"init": init, "dictations": dictations, "apply": apply}[args.command](args)
    except HexError as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
