#!/usr/bin/env python3
"""Vets, converts and tests the models in models/catalogue.json.

Usage:
  python3 scripts/models.py ids [speech|chat]
  python3 scripts/models.py speech <id> --tools <dir> --transcribe <src> --work <dir> --out <dir>
  python3 scripts/models.py chat <id> --tools <dir> --work <dir> --out <dir>
  python3 scripts/models.py catalogue --results <dir> --out <dir> --tag <release tag>
  python3 scripts/models.py pin <repo> <commit> <include glob>...

speech converts one speech model from its pinned upstream files with
transcribe.cpp's converter, quantizes it, transcribes the fixtures on the CPU
and writes <file>.gguf, <id>.NOTICE.txt and <id>.result.json to --out. chat
checks one Hugging Face GGUF against its pinned SHA-256 and size, never
changing it, runs the chat tests (or loads it, for the largest) and writes
the NOTICE and result. catalogue merges the results into the catalogue.json
DevKit's publishing reads. pin lists the files of a repository at a commit
that match the include globs (the files the converter reads), with their
SHA-256, for writing a catalogue entry.

Every model's licence must be on the allowlist, read from the Hugging Face
API at the pinned commit (license_name when the tag is "other").

Only the Python standard library; downloads use curl.
"""

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import pathlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
MODELS = REPO / "models"
sys.path.insert(0, str(HERE))
from speech_check import error_rate  # noqa: E402

HF = "https://huggingface.co"
GITHUB = "https://api.github.com"
# GitHub release assets must be smaller than 2 GiB.
MAX_ASSET = 2 * 1024**3
ALLOWED = {"mit", "apache-2.0", "cc-by-4.0", "openmdw-1.1"}
LICENSE_TEXT = {"mit": "MIT.txt", "apache-2.0": "Apache-2.0.txt", "cc-by-4.0": "CC-BY-4.0.txt",
                "openmdw-1.1": "OpenMDW-1.1.txt"}
LICENSE_NAME = {"mit": "MIT License", "apache-2.0": "Apache License 2.0",
                "cc-by-4.0": "Creative Commons Attribution 4.0 International (CC BY 4.0)",
                "openmdw-1.1": "OpenMDW License Agreement 1.1 (OpenMDW-1.1)"}


def load_catalogue() -> dict:
    return json.loads((MODELS / "catalogue.json").read_text())


def find(catalogue: dict, model_id: str) -> dict:
    for model in catalogue["speech"] + catalogue["chat"]:
        if model["id"] == model_id:
            return model
    sys.exit(f"{model_id} isn't in models/catalogue.json")


# --- Hugging Face and GitHub APIs -----------------------------------------

def retry_after(headers) -> int:
    """Seconds to wait from a 429's RateLimit header ("api";r=0;t=163).

    >>> retry_after({"RateLimit": '"api";r=0;t=163'})
    164
    >>> retry_after({})
    60
    """
    m = re.search(r"t=(\d+)", headers.get("RateLimit", "") or "")
    return int(m[1]) + 1 if m else 60


def api(url: str, body: dict = None, tries: int = 6):
    """GET (or POST body) a JSON API, retrying 429s and server errors. The
    token goes only to the API host, never along a redirect."""
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(tries):
        req = urllib.request.Request(url, data=data, headers={"User-Agent": "devkit-runtimes models"})
        if data is not None:
            req.add_header("Content-Type", "application/json")
        token = os.environ.get("HF_TOKEN") if url.startswith(HF) else os.environ.get("GITHUB_TOKEN")
        if token:
            req.add_unredirected_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                wait = retry_after(e.headers) if e.code == 429 else 10 * (attempt + 1)
                print(f"{url}: HTTP {e.code}, retrying in {wait} s", file=sys.stderr)
                time.sleep(wait)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, socket.timeout) as e:
            print(f"{url}: {e}, retrying", file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    sys.exit(f"{url}: gave up after {tries} tries")


def hf_model(repo: str, rev: str) -> dict:
    return api(f"{HF}/api/models/{repo}/revision/{urllib.parse.quote(rev, safe='')}")


def hf_tree(repo: str, rev: str) -> list:
    return api(f"{HF}/api/models/{repo}/tree/{rev}?recursive=true")


def hf_paths_info(repo: str, rev: str, paths: list) -> list:
    return api(f"{HF}/api/models/{repo}/paths-info/{rev}", {"paths": paths, "expand": True})


def license_key(card: dict) -> str:
    """The licence a model card declares, as the allowlist names it.

    >>> license_key({"license": "cc-by-4.0"})
    'cc-by-4.0'
    >>> license_key({"license": "other", "license_name": "openmdw-1.1"})
    'openmdw-1.1'
    >>> license_key({"license": ["Apache-2.0"]})
    'apache-2.0'
    >>> license_key({"license": "other"})
    'other'
    """
    tag = card.get("license")
    if isinstance(tag, list):
        tag = tag[0] if len(tag) == 1 else ",".join(tag)
    tag = (tag or "").lower()
    if tag == "other":
        return (card.get("license_name") or "other").lower()
    return tag


def check_license(where: str, found: str, declared: str) -> None:
    """Fails unless a repository's licence is allowed and is the catalogue's.

    >>> check_license("a/b", "mit", "mit")
    >>> check_license("a/b", "other", "mit")
    Traceback (most recent call last):
    ...
    SystemExit: a/b: licence 'other' isn't on the allowlist (apache-2.0, cc-by-4.0, mit, openmdw-1.1)
    """
    if found not in ALLOWED:
        sys.exit(f"{where}: licence '{found}' isn't on the allowlist ({', '.join(sorted(ALLOWED))})")
    if found != declared:
        sys.exit(f"{where}: licence is '{found}', but the catalogue says '{declared}'")


def vet_source(source: dict, declared: str) -> dict:
    """Checks the pinned commit exists, isn't gated and has an allowed licence."""
    if source.get("host") == "github":
        info = api(f"{GITHUB}/repos/{source['repo']}/license?ref={source['commit']}")
        found = (info.get("license") or {}).get("spdx_id", "").lower()
        check_license(source["repo"], found, declared)
        return {"license": found}
    info = hf_model(source["repo"], source["commit"])
    if info.get("sha") != source["commit"]:
        sys.exit(f"{source['repo']}: {source['commit']} resolves to {info.get('sha')}")
    if info.get("gated"):
        sys.exit(f"{source['repo']} is gated")
    found = license_key(info.get("cardData") or {})
    check_license(source["repo"], found, declared)
    return {"license": found, "license_tag": (info.get("cardData") or {}).get("license")}


# --- Files ----------------------------------------------------------------

def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(repo: str, commit: str, path: str, want: str, dest: pathlib.Path) -> None:
    """Downloads one file at a commit and checks its SHA-256."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file() and sha256(dest) == want:
        return
    url = f"{HF}/{repo}/resolve/{commit}/{urllib.parse.quote(path)}"
    cmd = ["curl", "-fL", "--proto-redir", "=https", "--retry", "5", "--retry-delay", "10", "--retry-all-errors",
           "-C", "-", "-sS", "-o", str(dest), url]
    if os.environ.get("HF_TOKEN"):
        # curl sends a custom Authorization header to the first host only.
        cmd[1:1] = ["-H", f"Authorization: Bearer {os.environ['HF_TOKEN']}"]
    subprocess.run(cmd, check=True)
    got = sha256(dest)
    if got != want:
        dest.unlink()
        sys.exit(f"{repo}@{commit}/{path}: SHA-256 {got} doesn't match {want}")


def free_space_for(path: pathlib.Path, need: int) -> None:
    """Fails early when a download wouldn't fit with 2 GB to spare."""
    path.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(path).free
    if free < need + 2 * 1000**3:
        sys.exit(f"{path}: {free / 1e9:.1f} GB free, {need / 1e9:.1f} GB needed")


def pin_one(repo: str, commit: str, path: str) -> str:
    """The SHA-256 of a small (non-LFS) file at a commit, by downloading it:
    the Hub lists only its git oid."""
    with tempfile.TemporaryDirectory() as tmp:
        dest = pathlib.Path(tmp) / "f"
        url = f"{HF}/{repo}/resolve/{commit}/{urllib.parse.quote(path)}"
        subprocess.run(["curl", "-fsSL", "--retry", "5", "-o", str(dest), url], check=True)
        return sha256(dest)


def included(path: str, include: list) -> bool:
    """
    >>> included("model.safetensors", ["*.json", "model.safetensors"]), included("README.md", ["*.json"])
    (True, False)
    """
    return any(fnmatch.fnmatch(path, g) for g in include)


def pin(repo: str, commit: str, include: list) -> list:
    """The files of a repository at a commit that match the include globs,
    with their SHA-256 (the LFS oid for large files) and git oid."""
    files = []
    for entry in hf_tree(repo, commit):
        if entry["type"] != "file" or not included(entry["path"], include):
            continue
        digest = entry["lfs"]["oid"] if entry.get("lfs") else pin_one(repo, commit, entry["path"])
        files.append({"path": entry["path"], "size": entry["size"], "sha256": digest, "blob": entry["oid"]})
    return files


# --- GGUF headers ---------------------------------------------------------

GGUF_SCALARS = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}


def gguf_header(path: pathlib.Path, keys: tuple = ("general.architecture", "general.name", "general.file_type",
                                                   "tokenizer.chat_template", "stt.variant")) -> dict:
    """Reads a GGUF file's header: version, tensor count and chosen metadata.
    Fails on a file that isn't GGUF or whose header runs past its end."""
    size = path.stat().st_size
    with open(path, "rb") as f:
        def read(n):
            b = f.read(n)
            if len(b) != n:
                raise ValueError(f"{path.name}: the GGUF header runs past the end of the file")
            return b

        def string():
            (n,) = struct.unpack("<Q", read(8))
            if n > size:
                raise ValueError(f"{path.name}: a string longer than the file")
            return read(n).decode("utf-8", "replace")

        def value(t):
            if t == 8:
                return string()
            if t == 9:
                (inner, n) = struct.unpack("<IQ", read(12))
                if inner == 8:
                    for _ in range(n):
                        string()
                elif inner in GGUF_SCALARS:
                    f.seek(struct.calcsize(GGUF_SCALARS[inner]) * n, 1)
                else:
                    raise ValueError(f"{path.name}: arrays of type {inner}")
                return f"[{n}]"
            if t not in GGUF_SCALARS:
                raise ValueError(f"{path.name}: metadata type {t}")
            return struct.unpack(GGUF_SCALARS[t], read(struct.calcsize(GGUF_SCALARS[t])))[0]

        if read(4) != b"GGUF":
            raise ValueError(f"{path.name} isn't a GGUF file")
        (version, tensors, kvs) = struct.unpack("<IQQ", read(20))
        meta = {}
        for _ in range(kvs):
            key = string()
            (t,) = struct.unpack("<I", read(4))
            v = value(t)
            if key in keys:
                meta[key] = v
        for _ in range(tensors):
            string()
            (dims,) = struct.unpack("<I", read(4))
            read(8 * dims + 4 + 8)
        if f.tell() > size:
            raise ValueError(f"{path.name}: tensor table runs past the end")
    return {"version": version, "tensors": tensors, "metadata_keys": kvs, "metadata": meta}


# --- NOTICE ---------------------------------------------------------------

def notice(model: dict, files: list, engines: dict) -> str:
    """The NOTICE.txt that travels with a model: who made it, where it came
    from, its licence, what changed, the disclaimer, then the licence text."""
    src = model["source"]
    lines = [model["name"], "=" * len(model["name"]), "",
             f"This notice covers {', '.join(files)}, as DevKit (https://getdevkit.app) distributes it.", ""]
    lines += ["Created by:"] + [f"  {c}" for c in model["creators"]] + [""]
    if src.get("host") == "github":
        lines += [f"Source: https://github.com/{src['repo']} at commit {src['commit']}"]
    else:
        lines += [f"Source: {HF}/{src['repo']} at commit {src['commit']}"]
    if src.get("package"):
        lines += [f"  (weights from {src['package']})"]
    if model.get("base"):
        lines += [f"Based on: {HF}/{model['base']['repo']} at commit {model['base']['commit']}"]
    lines += ["", f"Licence: {LICENSE_NAME[model['license']]}. The full text is at the end of this file.", ""]
    if model["kind"] == "chat":
        lines += ["Changes: none. DevKit distributes the GGUF file exactly as published above and doesn't",
                  "modify it. DevKit applies its own copy of the model's chat template when it loads the",
                  f"model, from {model['chat_template']['source']}.", ""]
    else:
        quants = [q for q in model["quants"] if q != model["converter"].get("reference")]
        tool = f"transcribe.cpp {engines['transcribe_version']} (commit {engines['transcribe_commit']})"
        if quants:
            lines += [f"Changes: converted to GGUF and quantized ({', '.join(quants)}) by DevKit, with {tool}.",
                      "Quantization changes the model's weights, so this is a modified version of the model above.", ""]
        else:
            lines += [f"Changes: converted to GGUF by DevKit, with {tool}. The weights keep their values;",
                      "only the file format changed.", ""]
    if model.get("copyright"):
        lines += [model["copyright"], ""]
    lines += ["Disclaimer: the model is provided as is, without warranties or conditions of any kind, as",
              "its licence says. Its creators don't endorse DevKit, and DevKit doesn't endorse the model's",
              "output. The licence's own disclaimer and limitation of liability below apply.", "",
              "-" * 72, ""]
    text = (MODELS / "licenses" / LICENSE_TEXT[model["license"]]).read_text()
    if model["license"] == "mit":
        text = text.replace("{copyright}", model["copyright"])
    return "\n".join(lines) + text


# --- Speech ---------------------------------------------------------------

def run_cli(cli: pathlib.Path, model: pathlib.Path, wav: pathlib.Path, language: str, out: pathlib.Path) -> str:
    cmd = [str(cli), "-q", "--backend", "cpu", "-m", str(model), "-o", str(out), str(wav)]
    if language:
        cmd[1:1] = ["-l", language]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    if res.returncode != 0:
        sys.stderr.write(res.stdout + res.stderr)
        sys.exit(f"transcribe-cli failed on {wav.name} with {model.name}")
    return out.read_text(encoding="utf-8").strip()


def speech(args) -> None:
    catalogue = load_catalogue()
    model = find(catalogue, args.id)
    engines = engine_pins()
    out, work = pathlib.Path(args.out), pathlib.Path(args.work) / model["id"]
    out.mkdir(parents=True, exist_ok=True)
    tools, src = pathlib.Path(args.tools), pathlib.Path(args.transcribe)
    vetted = vet_source(model["source"], model["license"])

    # The pinned upstream files, each checked by SHA-256.
    source_dir = work / "source"
    files = model["source"].get("files", [])
    free_space_for(work, sum(f["size"] for f in files) * 3)
    for f in files:
        fetch(model["source"]["repo"], model["source"]["commit"], f["path"], f["sha256"], source_dir / f["path"])

    # transcribe.cpp's converter at the engine commit, in its own locked
    # environment (uv checks every package against uv.lock's hashes).
    slug = model["converter"]["slug"]
    ref = work / slug / f"{slug}-REF.gguf"
    ref.parent.mkdir(parents=True, exist_ok=True)
    conv = model["converter"]
    cmd = ["uv", "run", "--frozen", "--project", str(src / "scripts" / "envs" / conv["env"]),
           str(src / "scripts" / conv["script"])]
    if conv.get("input") == "dir":
        cmd += [str(source_dir), str(ref), "--repo-id", model["source"]["repo"]]
    elif conv.get("input"):
        cmd += [str(source_dir / conv["input"]), str(ref), "--repo-id", model["source"]["repo"]]
    else:
        cmd += [str(ref)]
    print("convert:", " ".join(cmd), flush=True)
    env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    subprocess.run(cmd, check=True, env=env)
    shutil.rmtree(source_dir, ignore_errors=True)

    produced = []
    for quant in model["quants"]:
        name = f"{model['id']}-{quant}.gguf"
        dest = out / name
        if quant == conv.get("reference"):
            shutil.copy2(ref, dest)
        else:
            subprocess.run([str(tools / "transcribe-quantize"), str(ref), str(dest), "--quant", quant], check=True,
                           stdout=subprocess.DEVNULL)
        size = dest.stat().st_size
        if size >= MAX_ASSET:
            sys.exit(f"{name} is {size} bytes; release assets must be under 2 GiB")
        produced.append(dest)
    ref.unlink()

    # Smoke tests on the CPU, for every quantization.
    fixtures = json.loads((MODELS / "fixtures" / "fixtures.json").read_text())["audio"]
    results = []
    for dest in produced:
        header = gguf_header(dest)
        checked = {"file": dest.name, "tensors": header["tensors"], "variant": header["metadata"].get("stt.variant"),
                   "tests": []}
        results.append(checked)
        for test in model["smoke"]:
            wav = MODELS / "fixtures" / test["audio"]
            if sha256(wav) != fixtures[test["audio"]]["sha256"]:
                sys.exit(f"{wav.name} isn't the fixture fixtures.json describes")
            text = run_cli(tools / "transcribe-cli", dest, wav, test.get("language", ""), work / "out.txt")
            if model["kind"] == "vad":
                segments = [line for line in text.splitlines() if line.startswith("segment:")]
                checked["tests"].append({"audio": wav.name, "speech_segments": len(segments)})
                if not segments:
                    sys.exit(f"{dest.name} found no speech in {wav.name}")
                continue
            ref_text = fixtures[test["audio"]]["text"]
            err = error_rate(fixtures[test["audio"]]["language"], ref_text, text)
            checked["tests"].append({"audio": wav.name, "text": text, "error_rate": round(err, 3),
                                     "max_error": test["max_error"]})
            print(f"{dest.name} on {wav.name}: error rate {err:.3f} (max {test['max_error']})", flush=True)
            if err > test["max_error"]:
                sys.exit(f"{dest.name} transcribed {wav.name} too far from the reference: {text!r}")

    notice_name = f"{model['id']}.NOTICE.txt"
    (out / notice_name).write_text(notice(model, [p.name for p in produced], engines), encoding="utf-8")
    result = {
        "id": model["id"],
        "vetted": vetted,
        "files": [{"name": p.name, "quant": q, "sha256": sha256(p), "size": p.stat().st_size, "asset": True}
                  for p, q in zip(produced, model["quants"])],
        "notice": notice_name,
        "test": {"level": "vad" if model["kind"] == "vad" else "transcribe", "platform": platform_name(),
                 "backend": "cpu", "results": results},
    }
    (out / f"{model['id']}.result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                                                    encoding="utf-8")
    shutil.rmtree(work, ignore_errors=True)


# --- Chat -----------------------------------------------------------------

class Server:
    """llama-server on a free loopback port, on the CPU, with DevKit's chat
    template in place of the one the GGUF carries."""

    def __init__(self, tools: pathlib.Path, gguf: pathlib.Path, template: pathlib.Path, extra: list):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.log = tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False)
        cmd = [str(tools / "llama-server"), "-m", str(gguf), "--host", "127.0.0.1", "--port", str(self.port),
               "--jinja", "--chat-template-file", str(template), "-ngl", "0", "--no-webui"] + extra
        print("server:", " ".join(cmd), flush=True)
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)

    def wait(self, timeout: int) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                self.log.seek(0)
                sys.exit(f"llama-server exited with {self.proc.returncode}:\n{self.log.read()[-4000:]}")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=5) as r:
                    if r.status == 200:
                        return
            except (urllib.error.URLError, ConnectionError, TimeoutError, socket.timeout):
                pass
            time.sleep(2)
        sys.exit(f"llama-server didn't load the model within {timeout} s")

    def chat(self, body: dict) -> dict:
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/v1/chat/completions",
                                     data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=900) as r:
            return json.load(r)

    def stop(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(30)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def json_object(text: str):
    """The JSON object in a reply, allowing a code fence around it.

    >>> json_object('```json\\n{"port": 443}\\n```')
    {'port': 443}
    >>> json_object('nope') is None
    True
    """
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        return json.loads(m[0])
    except json.JSONDecodeError:
        return None


def chat(args) -> None:
    catalogue = load_catalogue()
    model = find(catalogue, args.id)
    engines = engine_pins()
    out, work = pathlib.Path(args.out), pathlib.Path(args.work) / model["id"]
    out.mkdir(parents=True, exist_ok=True)
    tools = pathlib.Path(args.tools)
    src, f = model["source"], model["source"]["file"]

    vetted = vet_source(src, model["license"])
    base = vet_source({"repo": model["base"]["repo"], "commit": model["base"]["commit"]}, model["license"])
    # The Hub's record of the file at the pinned commit must be the pinned
    # one, before anything is downloaded.
    [info] = hf_paths_info(src["repo"], src["commit"], [f["path"]])
    lfs = info.get("lfs") or {}
    if lfs.get("oid") != f["sha256"] or info.get("size") != f["size"]:
        sys.exit(f"{src['repo']}@{src['commit']}/{f['path']}: the Hub lists {lfs.get('oid')} ({info.get('size')} bytes), "
                 f"not {f['sha256']} ({f['size']} bytes)")
    template = MODELS / model["chat_template"]["file"]
    if sha256(template) != model["chat_template"]["sha256"]:
        sys.exit(f"{template.name} isn't the template the catalogue pins")

    free_space_for(work, f["size"])
    gguf = work / f["path"]
    fetch(src["repo"], src["commit"], f["path"], f["sha256"], gguf)
    header = gguf_header(gguf)
    embedded = header["metadata"].get("tokenizer.chat_template")
    if header["metadata"].get("general.architecture") != model["architecture"]:
        sys.exit(f"{gguf.name} is architecture {header['metadata'].get('general.architecture')}, not {model['architecture']}")
    test = {"level": model["test"], "platform": platform_name(), "backend": "cpu",
            "gguf": {"version": header["version"], "tensors": header["tensors"],
                     "architecture": header["metadata"].get("general.architecture"),
                     "embedded_template_sha256": hashlib.sha256(embedded.encode()).hexdigest() if embedded else None,
                     "embedded_template_matches": embedded == template.read_text() if embedded else False}}

    threads = str(os.cpu_count() or 4)
    if model["test"] == "load":
        # Loads without copying weights into memory: a hosted runner has less
        # memory than this model needs to run.
        server = Server(tools, gguf, template, ["-c", "512", "--no-warmup", "--no-repack", "-t", threads])
        try:
            started = time.time()
            server.wait(1800)
            test["load_seconds"] = round(time.time() - started)
        finally:
            server.stop()
    else:
        fx = json.loads((MODELS / "fixtures" / "fixtures.json").read_text())["chat"]
        server = Server(tools, gguf, template, ["-c", "8192", "-t", threads])
        try:
            server.wait(900)
            off = {"chat_template_kwargs": {"enable_thinking": False}, "temperature": 0, "seed": 1}
            j = fx["json"]
            reply = server.chat({**off, "max_tokens": 200, "messages": [
                {"role": "system", "content": j["system"]}, {"role": "user", "content": j["user"]}]})
            content = reply["choices"][0]["message"].get("content") or ""
            answer = json_object(content)
            if not answer or any(answer.get(k) != v for k, v in j["expect"].items()):
                sys.exit(f"{model['id']} didn't answer with the JSON asked for: {content!r}")
            t = fx["tool"]
            reply = server.chat({**off, "max_tokens": 300, "tools": t["tools"],
                                 "messages": [{"role": "user", "content": t["user"]}]})
            calls = reply["choices"][0]["message"].get("tool_calls") or []
            got = [(c["function"]["name"], json.loads(c["function"]["arguments"] or "{}")) for c in calls]
            if got != [(t["expect"]["name"], t["expect"]["arguments"])]:
                sys.exit(f"{model['id']} didn't make the tool call asked for: {reply['choices'][0]['message']!r}")
            test["results"] = [{"test": "json", "answer": answer, "passed": True},
                               {"test": "tool_call", "calls": [{"name": n, "arguments": a} for n, a in got],
                                "passed": True}]
            print(f"{model['id']}: JSON answer and tool call passed", flush=True)
        finally:
            server.stop()

    notice_name = f"{model['id']}.NOTICE.txt"
    (out / notice_name).write_text(notice(model, [f["path"]], engines), encoding="utf-8")
    result = {
        "id": model["id"],
        "vetted": {**vetted, "base": base, "security": info.get("securityFileStatus")},
        "files": [{"name": f["path"], "sha256": f["sha256"], "size": f["size"], "asset": False,
                   "url": f"{HF}/{src['repo']}/resolve/{src['commit']}/{urllib.parse.quote(f['path'])}"}],
        "notice": notice_name,
        "test": test,
    }
    (out / f"{model['id']}.result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                                                    encoding="utf-8")
    shutil.rmtree(work, ignore_errors=True)


# --- Catalogue ------------------------------------------------------------

def engine_pins() -> dict:
    pins = {}
    for line in (HERE / "voice-engines.env").read_text().splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            pins[m[1]] = m[2]
    return {"transcribe_version": pins["TRANSCRIBE_VERSION"], "transcribe_commit": pins["TRANSCRIBE_COMMIT"],
            "llama_commit": pins["LLAMA_COMMIT"], "llama_cpp_sys": pins["LLAMA_CPP_SYS_VERSION"]}


def platform_name() -> str:
    machine = os.uname().machine.replace("arm64", "aarch64").replace("AMD64", "x86_64")
    return f"{sys.platform.replace('darwin', 'macos')}-{machine}"


def merge(model: dict, result: dict, tag: str, repo: str) -> dict:
    """One model's entry in the released catalogue.

    >>> m = {"id": "x", "kind": "speech", "name": "X", "license": "mit", "source": {"repo": "a/b", "commit": "c"}}
    >>> r = {"files": [{"name": "x-Q8_0.gguf", "sha256": "d", "size": 1, "asset": True}], "notice": "x.NOTICE.txt",
    ...      "test": {"level": "transcribe"}, "vetted": {}}
    >>> merge(m, r, "models-2026-10-17", "o/r")["files"][0]["url"]
    'https://github.com/o/r/releases/download/models-2026-10-17/x-Q8_0.gguf'
    """
    entry = {k: v for k, v in model.items() if k not in ("converter", "smoke", "chat_template")}
    entry["files"] = []
    for f in result["files"]:
        f = dict(f)
        if f.pop("asset"):
            f["url"] = f"https://github.com/{repo}/releases/download/{tag}/{f['name']}"
        entry["files"].append(f)
    entry["notice"] = {"name": result["notice"],
                       "url": f"https://github.com/{repo}/releases/download/{tag}/{result['notice']}"}
    entry["test"] = result["test"]
    entry["vetted"] = result["vetted"]
    if model.get("chat_template"):
        text = (MODELS / model["chat_template"]["file"]).read_text()
        entry["chat_template"] = {"source": model["chat_template"]["source"],
                                  "sha256": hashlib.sha256(text.encode()).hexdigest(), "text": text}
    return entry


def catalogue_cmd(args) -> None:
    catalogue = load_catalogue()
    results_dir, out = pathlib.Path(args.results), pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    repo = os.environ.get("GITHUB_REPOSITORY", "frankperez87/devkit-runtimes")
    released = {"schema": catalogue["schema"], "release": args.tag,
                "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "engines": engine_pins(), "speech": [], "chat": []}
    for kind in ("speech", "chat"):
        for model in catalogue[kind]:
            path = results_dir / f"{model['id']}.result.json"
            if not path.is_file():
                sys.exit(f"no result for {model['id']}: every catalogue model must pass before a release")
            result = json.loads(path.read_text())
            for f in result["files"]:
                if f["asset"]:
                    local = results_dir / f["name"]
                    if sha256(local) != f["sha256"]:
                        sys.exit(f"{f['name']} changed after its tests")
                    if results_dir.resolve() != out.resolve():
                        shutil.copy2(local, out / f["name"])
            if results_dir.resolve() != out.resolve():
                shutil.copy2(results_dir / result["notice"], out / result["notice"])
            released[kind].append(merge(model, result, args.tag, repo))
    (out / "catalogue.json").write_text(json.dumps(released, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"catalogue.json: {len(released['speech'])} speech and {len(released['chat'])} chat models")


def ids_cmd(args) -> None:
    catalogue = load_catalogue()
    kinds = [args.kind] if args.kind else ["speech", "chat"]
    print(json.dumps([m["id"] for k in kinds for m in catalogue[k]]))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("ids")
    s.add_argument("kind", nargs="?", choices=["speech", "chat"])
    for name in ("speech", "chat"):
        s = sub.add_parser(name)
        s.add_argument("id")
        s.add_argument("--tools", required=True)
        s.add_argument("--work", required=True)
        s.add_argument("--out", required=True)
        if name == "speech":
            s.add_argument("--transcribe", required=True)
    s = sub.add_parser("catalogue")
    s.add_argument("--results", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--tag", required=True)
    s = sub.add_parser("pin")
    s.add_argument("repo")
    s.add_argument("commit")
    s.add_argument("include", nargs="+")
    args = p.parse_args()
    if args.cmd == "ids":
        ids_cmd(args)
    elif args.cmd == "speech":
        speech(args)
    elif args.cmd == "chat":
        chat(args)
    elif args.cmd == "catalogue":
        catalogue_cmd(args)
    else:
        print(json.dumps(pin(args.repo, args.commit, args.include), indent=2))


if __name__ == "__main__":
    main()
