#!/usr/bin/env python3
"""Checks the Build workflow's release wiring.

Usage: python3 scripts/check_workflow.py [--require-yaml] [<workflow file>]

Every build job (each job but plan and release) must be in release.needs and
in the release's if:, and every needs.plan.outputs.X a job reads must be one
of the plan job's outputs, read from the plan step's output of the same name.
A merge that breaks one of these fails silently: a job missing from needs
lets the release download artifacts before that job finishes, a job missing
from the if: means a run of only that job releases nothing, and an undeclared
output reads as an empty string. The plan job runs this, so such a merge
turns the run red instead.

It reads the workflow (.github/workflows/build.yml by default) with PyYAML.
Without PyYAML it says so and skips the check, unless --require-yaml (CI)
makes that an error.
"""

import pathlib
import re
import sys

NOT_BUILDS = ("plan", "release")
PLAN_OUTPUT = re.compile(r"needs\.plan\.outputs\.([A-Za-z0-9_-]+)")
STEP_OUTPUT = re.compile(r"^\$\{\{\s*steps\.plan\.outputs\.([A-Za-z0-9_-]+)\s*\}\}$")


def strings(value):
    """Every string in a parsed YAML value.

    >>> list(strings({"a": ["x", {"b": "y"}], "c": 3}))
    ['x', 'y']
    """
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def counts_job(condition: str, job: str) -> bool:
    """Whether a release if: releases a run in which only this job ran. A
    heuristic: it looks for needs.<job>.result != 'skipped' anywhere in the
    expression, which fits its one OR of such clauses.

    >>> counts_job("needs.php.result != 'skipped' || needs['voice-engines'].result != 'skipped'", "voice-engines")
    True
    >>> counts_job("needs.php.result != 'skipped'", "ruby"), counts_job("needs.php.result == 'success'", "php")
    (False, False)
    """
    name = re.escape(job)
    return re.search(rf"needs(?:\.{name}|\[\s*['\"]{name}['\"]\s*\])\.result\s*!=\s*'skipped'", condition) is not None


def problems(workflow: dict) -> list:
    """What's wrong with a parsed workflow's release wiring.

    >>> wf = {"jobs": {
    ...     "plan": {"outputs": {"php": "${{ steps.plan.outputs.php }}"}},
    ...     "php": {"needs": "plan", "if": "needs.plan.outputs.php != '[]'"},
    ...     "voice-engines": {"needs": "plan",
    ...         "strategy": {"matrix": {"include": "${{ fromJSON(needs.plan.outputs.voice_engines) }}"}}},
    ...     "release": {"needs": ["plan", "php", "voice-engines"],
    ...         "if": "${{ !cancelled() && (needs.php.result != 'skipped' || needs['voice-engines'].result != 'skipped') }}"}}}
    >>> problems(wf)
    ["voice-engines reads needs.plan.outputs.voice_engines, which the plan job doesn't declare"]
    >>> wf["jobs"]["plan"]["outputs"]["voice_engines"] = "${{ steps.plan.outputs.voice_engines }}"
    >>> problems(wf)
    []
    >>> wf["jobs"]["release"]["needs"].remove("php")
    >>> wf["jobs"]["release"]["if"] = "${{ needs['voice-engines'].result != 'skipped' }}"
    >>> problems(wf)
    ['release.needs is missing php', "release's if: doesn't release a run of only php"]
    >>> wf["jobs"]["release"]["needs"].append("php")
    >>> wf["jobs"]["release"]["if"] = "${{ needs.php.result != 'skipped' || needs['voice-engines'].result != 'skipped' }}"
    >>> wf["jobs"]["plan"]["outputs"]["php"] = "${{ steps.plan.outputs.php_minors }}"
    >>> problems(wf)
    ["the plan job's output php reads ${{ steps.plan.outputs.php_minors }}, not steps.plan.outputs.php"]
    """
    jobs = workflow.get("jobs") or {}
    release = jobs.get("release") or {}
    needs = release.get("needs") or []
    needs = [needs] if isinstance(needs, str) else list(needs)
    condition = str(release.get("if") or "")
    declared = (jobs.get("plan") or {}).get("outputs") or {}
    out = []
    builds = [job for job in jobs if job not in NOT_BUILDS]
    out += [f"release.needs is missing {job}" for job in builds if job not in needs]
    out += [f"release's if: doesn't release a run of only {job}" for job in builds if not counts_job(condition, job)]
    for job, body in jobs.items():
        read = sorted({m for s in strings(body) for m in PLAN_OUTPUT.findall(s)})
        out += [f"{job} reads needs.plan.outputs.{key}, which the plan job doesn't declare"
                for key in read if key not in declared]
    for key, value in declared.items():
        m = STEP_OUTPUT.match(str(value).strip())
        if not m or m[1] != key:
            out.append(f"the plan job's output {key} reads {value}, not steps.plan.outputs.{key}")
    return out


def main(argv: list) -> None:
    require = "--require-yaml" in argv
    args = [a for a in argv if a != "--require-yaml"]
    path = pathlib.Path(args[0]) if args else pathlib.Path(__file__).resolve().parent.parent / ".github/workflows/build.yml"
    try:
        import yaml
    except ImportError:
        if require:
            sys.exit("PyYAML isn't installed, and the workflow check needs it")
        print("PyYAML isn't installed, so the workflow check is skipped (the plan job runs it)", file=sys.stderr)
        return
    found = problems(yaml.safe_load(path.read_text(encoding="utf-8")))
    for problem in found:
        print(f"{path}: {problem}", file=sys.stderr)
    if found:
        sys.exit(1)
    print(f"{path}: the release waits for and counts every build job, and every plan output read is declared")


if __name__ == "__main__":
    main(sys.argv[1:])
