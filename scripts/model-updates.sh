#!/usr/bin/env bash
# Looks for newer versions of the catalogue's models and new llama.cpp
# security advisories, tests what changed, and writes a pull request body.
#
#   scripts/model-updates.sh <out>
#
# Uses only the Hugging Face and GitHub APIs to find changes (HF_TOKEN, a
# read-only token, raises the Hub's rate limit; 429s are retried), then runs
# models.sh on each changed model, which downloads only that model's files
# and runs the same checks and tests as a release. Rewrites
# models/catalogue.json and models/llama-advisories.json in place and writes
# <out>/pr.md and <out>/report.json. Prints "changes=true" when there is
# something to propose. A model that fails its tests is still reported, and
# the pull request says not to merge it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$(mkdir -p "$1" && cd "$1" && pwd)"

python3 -m doctest "$here/model_updates.py"
python3 "$here/model_updates.py" check "$out/report.json"

mkdir -p "$out/results"
for id in $(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["changed_ids"]))' "$out/report.json"); do
  if "$here/models.sh" "$id" "$out/results" > "$out/results/$id.log" 2>&1; then
    echo "$id passed"
  else
    echo "$id failed; see its log"
    tail -20 "$out/results/$id.log"
  fi
done

python3 "$here/model_updates.py" pr "$out/report.json" "$out/results" > "$out/pr.md"
if git -C "$here/.." diff --quiet -- models/; then
  echo "changes=false"
else
  echo "changes=true"
fi
