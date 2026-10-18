#!/usr/bin/env python3
"""Finds newer versions of the catalogue's models and new llama.cpp security
advisories, using only the Hugging Face and GitHub APIs.

Usage: python3 scripts/model_updates.py check <report.json>
       python3 scripts/model_updates.py pr <report.json> <results dir>

For each model it resolves the upstream repository's newest commit. A speech
model changes when the files the converter reads (its include globs) change;
a Hugging Face GGUF
changes when the pinned file's LFS oid changes. Only changed files are
downloaded (small ones, to hash them; LFS files are taken by their oid and
checked when models.sh downloads them). Licences go through the same
allowlist. check rewrites models/catalogue.json with the new pins, appends
new advisories to models/llama-advisories.json and writes a report; pr turns
the report and the test results models.sh wrote into a pull request body.

Nothing from the APIs is trusted as Markdown: every upstream string in the
report is escaped with code().
"""

import json
import pathlib
import re
import sys
import urllib.parse

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import models  # noqa: E402

CATALOGUE = models.MODELS / "catalogue.json"
ADVISORIES = models.MODELS / "llama-advisories.json"


def code(text, limit: int = 160) -> str:
    """Upstream text, safe in a pull request body: one line of inline code,
    so no Markdown, HTML, links or @mentions take effect.

    >>> code("hi `there` @team <b>x</b>\\n[a](b)")
    "`hi 'there' @team <b>x</b> [a](b)`"
    >>> code(None)
    '`-`'
    >>> code("x" * 10, limit=4)
    '`xxxx…`'
    """
    if text is None:
        return "`-`"
    s = re.sub(r"[\x00-\x1f\x7f​-‏‪-‮⁠-⁤﻿]", " ", str(text))
    s = re.sub(r"[\U000e0000-\U000e007f]", "", s)
    s = re.sub(r"\s+", " ", s).strip().replace("`", "'")
    if len(s) > limit:
        s = s[:limit] + "…"
    return f"`{s or '-'}`"


def security(info: dict) -> str:
    """A one-line summary of the Hub's securityFileStatus for a file.

    >>> security({"securityFileStatus": {"status": "safe", "avScan": {"status": "safe"}, "jFrogScan": {"status": "queued"}}})
    'safe (avScan: safe, jFrogScan: queued)'
    >>> security({})
    'not reported'
    """
    status = info.get("securityFileStatus")
    if not status:
        return "not reported"
    scans = [f"{k}: {v.get('status')}" for k, v in status.items() if isinstance(v, dict) and v.get("status")]
    return f"{status.get('status')} ({', '.join(scans)})" if scans else str(status.get("status"))


def head(repo: str) -> dict:
    return models.api(f"{models.HF}/api/models/{repo}")


def speech_update(model: dict) -> dict:
    src = model["source"]
    if src.get("host") == "github":
        return None  # Silero VAD's weights come from the locked converter environment.
    info = head(src["repo"])
    new = info["sha"]
    licence = models.license_key(info.get("cardData") or {})
    if new == src["commit"]:
        return None
    old_files = {f["path"]: f for f in src["files"]}
    tree = [e for e in models.hf_tree(src["repo"], new)
            if e["type"] == "file" and models.included(e["path"], src["include"])]
    changed, files = [], []
    for e in tree:
        old = old_files.get(e["path"])
        if e.get("lfs"):
            digest = e["lfs"]["oid"]
        elif old and old["size"] == e["size"] and old.get("blob") == e["oid"]:
            digest = old["sha256"]
        else:
            # Small files: fetched to hash, since the Hub lists only their git oid.
            digest = models.pin_one(src["repo"], new, e["path"])
        entry = {"path": e["path"], "size": e["size"], "sha256": digest, "blob": e["oid"]}
        files.append(entry)
        if not old or old["sha256"] != digest:
            changed.append(entry)
    removed = sorted(set(old_files) - {f["path"] for f in files})
    if not changed and not removed and licence == model["license"]:
        return None
    paths = [c["path"] for c in changed]
    scans = {p["path"]: security(p) for p in models.hf_paths_info(src["repo"], new, paths)} if paths else {}
    return {"id": model["id"], "repo": src["repo"], "old": src["commit"], "new": new, "licence": licence,
            "licence_ok": licence in models.ALLOWED and licence == model["license"],
            "changed": [{**c, "security": scans.get(c["path"], "not reported")} for c in changed],
            "removed": removed, "files": files}


def chat_update(model: dict) -> dict:
    src, f = model["source"], model["source"]["file"]
    info = head(src["repo"])
    new = info["sha"]
    licence = models.license_key(info.get("cardData") or {})
    notes = []
    base = head(model["base"]["repo"])
    if base["sha"] != model["base"]["commit"]:
        [tpl] = models.hf_paths_info(model["base"]["repo"], base["sha"], ["chat_template.jinja"]) or [{}]
        old = models.hf_paths_info(model["base"]["repo"], model["base"]["commit"], ["chat_template.jinja"]) or [{}]
        if tpl.get("oid") != old[0].get("oid"):
            notes.append(f"{model['base']['repo']}'s chat template changed at {new_short(base['sha'])}: "
                         "DevKit's template stays until someone reviews the new one.")
    if new == src["commit"] and licence == model["license"]:
        return {"id": model["id"], "notes": notes} if notes else None
    [p] = models.hf_paths_info(src["repo"], new, [f["path"]]) or [None]
    if p is None:
        return {"id": model["id"], "repo": src["repo"], "old": src["commit"], "new": new, "licence": licence,
                "licence_ok": False, "missing": f["path"], "notes": notes}
    lfs = p.get("lfs") or {}
    if lfs.get("oid") == f["sha256"] and licence == model["license"]:
        return {"id": model["id"], "notes": notes} if notes else None
    return {"id": model["id"], "repo": src["repo"], "old": src["commit"], "new": new, "licence": licence,
            "licence_ok": licence in models.ALLOWED and licence == model["license"],
            "file": {"path": f["path"], "sha256": lfs.get("oid"), "size": p.get("size")},
            "old_file": f, "security": security(p), "notes": notes}


def new_short(sha: str) -> str:
    return sha[:12]


def fix_refs(patched: list) -> list:
    """The build tags and commits an advisory's patched versions name.

    >>> fix_refs([">= b8146", "26a48ad", "none"])
    ['b8146', '26a48ad']
    """
    return [m for p in patched for m in re.findall(r"\b(b\d+|[0-9a-f]{7,40})\b", p)]


def advisories(pinned: str) -> list:
    """New llama.cpp security advisories, and whether the pinned commit has
    each fix (when the advisory names the build tag or commit that fixed it)."""
    known = set(json.loads(ADVISORIES.read_text(encoding="utf-8"))["known"]) if ADVISORIES.is_file() else set()
    found = []
    for adv in models.api(f"{models.GITHUB}/repos/ggml-org/llama.cpp/security-advisories?per_page=100"):
        if adv["ghsa_id"] in known:
            continue
        patched = sorted({v.get("patched_versions") or "" for v in adv.get("vulnerabilities") or []} - {""})
        fixed = None
        for ref in fix_refs(patched):
            cmp = models.api(f"{models.GITHUB}/repos/ggml-org/llama.cpp/compare/{ref}...{pinned}")
            fixed = cmp.get("status") in ("ahead", "identical")
        found.append({"ghsa": adv["ghsa_id"], "severity": adv.get("severity"), "summary": adv.get("summary"),
                      "published": adv.get("published_at"), "patched": patched, "pinned_has_fix": fixed,
                      "url": f"https://github.com/ggml-org/llama.cpp/security/advisories/{adv['ghsa_id']}"})
    return found


def check(report_path: str) -> None:
    catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    report = {"speech": [], "chat": [], "advisories": [], "notes": []}
    for model in catalogue["speech"]:
        u = speech_update(model)
        if u:
            report["speech"].append(u)
            if u["licence_ok"] and not u["removed"]:
                model["source"]["commit"] = u["new"]
                model["source"]["files"] = u["files"]
    for model in catalogue["chat"]:
        u = chat_update(model)
        if not u:
            continue
        report["notes"] += [f"{model['id']}: {n}" for n in u.get("notes", [])]
        if "new" in u:
            report["chat"].append(u)
            if u["licence_ok"] and u.get("file"):
                model["source"]["commit"] = u["new"]
                model["source"]["file"] = u["file"]
    pins = models.engine_pins()
    report["advisories"] = advisories(pins["llama_commit"])
    CATALOGUE.write_text(json.dumps(catalogue, indent=2, ensure_ascii=False) + "\n")
    if report["advisories"]:
        known = json.loads(ADVISORIES.read_text(encoding="utf-8"))["known"] if ADVISORIES.is_file() else []
        ADVISORIES.write_text(json.dumps({"known": sorted(set(known) | {a["ghsa"] for a in report["advisories"]})},
                                         indent=2) + "\n")
    report["changed_ids"] = [u["id"] for u in report["speech"] + report["chat"] if u.get("licence_ok")]
    pathlib.Path(report_path).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"changed": report["changed_ids"], "advisories": [a["ghsa"] for a in report["advisories"]],
                      "notes": len(report["notes"])}))


def test_line(results: pathlib.Path, model_id: str) -> tuple:
    """(passed, Markdown) for a model's test result, from models.sh's output."""
    path = results / f"{model_id}.result.json"
    if not path.is_file():
        return False, f"**Failed its checks or tests**; see `{model_id}.log` in the run's artifacts."
    test = json.loads(path.read_text(encoding="utf-8"))["test"]
    detail = ""
    if test.get("results"):
        rates = [t["error_rate"] for r in test["results"] for t in r.get("tests", []) if "error_rate" in t]
        if rates:
            detail = f", worst error rate {max(rates):.3f}"
    return True, f"Passed: test level `{test['level']}` on `{test['platform']}` ({test['backend']}){detail}"


def pr(report_path: str, results_dir: str) -> None:
    report = json.loads(pathlib.Path(report_path).read_text(encoding="utf-8"))
    results = pathlib.Path(results_dir)
    lines, failed = [], False
    lines += ["Weekly check of the catalogue's models and of llama.cpp's security advisories, by "
              "`scripts/model-updates.sh`. Text from Hugging Face and GitHub is shown as code, never as Markdown.", ""]
    for u in report["speech"]:
        lines += [f"### {u['id']}", "",
                  f"- Repository: `{u['repo']}`",
                  f"- Commit: `{u['old']}` → `{u['new']}`",
                  f"- Licence: {code(u['licence'])}" + ("" if u["licence_ok"] else " — **not allowed, or not the catalogue's; not updated**")]
        for c in u["changed"]:
            lines += [f"- Changed: {code(c['path'])}, SHA-256 `{c['sha256']}`, {c['size']} bytes; "
                      f"securityFileStatus {code(c['security'])}"]
        for r in u["removed"]:
            lines += [f"- Removed upstream: {code(r)} — **not updated; the converter may need a change**"]
        if u["licence_ok"] and not u["removed"]:
            ok, line = test_line(results, u["id"])
            failed |= not ok
            lines += [f"- Tests: {line}"]
        lines += [""]
    for u in report["chat"]:
        lines += [f"### {u['id']}", "",
                  f"- Repository: `{u['repo']}`",
                  f"- Commit: `{u['old']}` → `{u['new']}`",
                  f"- Licence: {code(u['licence'])}" + ("" if u["licence_ok"] else " — **not allowed, or not the catalogue's; not updated**")]
        if u.get("missing"):
            lines += [f"- {code(u['missing'])} is gone at the new commit — **not updated; pick the new file by hand**"]
        if u.get("file"):
            lines += [f"- File: {code(u['file']['path'])}",
                      f"- SHA-256: `{u['old_file']['sha256']}` → `{u['file']['sha256']}`",
                      f"- Size: {u['old_file']['size']} → {u['file']['size']} bytes",
                      f"- securityFileStatus: {code(u['security'])}"]
            if u["licence_ok"]:
                ok, line = test_line(results, u["id"])
                failed |= not ok
                lines += [f"- Tests: {line}"]
        lines += [""]
    if report["notes"]:
        lines += ["### Notes", ""] + [f"- {code(n, 300)}" for n in report["notes"]] + [""]
    if report["advisories"]:
        lines += ["### llama.cpp security advisories", "",
                  "New since the last check. DevKit's engines use llama.cpp at "
                  f"`{models.engine_pins()['llama_commit']}`; bump `scripts/voice-engines.env` (and DevKit's "
                  "llama-cpp-sys-2) when it lacks a fix.", ""]
        for a in report["advisories"]:
            has = {True: "has the fix", False: "**lacks the fix**", None: "unknown (no fixed build or commit listed)"}[a["pinned_has_fix"]]
            lines += [f"- [{a['ghsa']}]({a['url']}): {code(a['summary'])}, severity {code(a['severity'])}, "
                      f"patched in {code(', '.join(a['patched']) or None)}; the pinned commit {has}"]
        lines += [""]
    if failed:
        lines = ["> [!WARNING]", "> A changed model failed its checks or tests. Don't merge until it's fixed.", ""] + lines
    lines += ["Merging runs the Models workflow, which converts, tests and releases everything again."]
    print("\n".join(lines))


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check(sys.argv[2])
    else:
        pr(sys.argv[2], sys.argv[3])
