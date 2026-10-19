# devkit-runtimes

Build scripts for the runtimes [DevKit](https://getdevkit.app) installs, built on GitHub Actions and attached to this repository's releases:

- **PHP 8.2 to 8.5** for macOS (Apple silicon and Intel): static CLI and php-fpm programs built with [static-php-cli](https://github.com/crazywhalecc/static-php-cli), with the extensions in [`scripts/php-extensions.txt`](scripts/php-extensions.txt).
- **PHP extensions for Windows** (8.0 to 8.5): apcu, igbinary, msgpack, pcov, redis, opentelemetry and grpc for windows.php.net's official PHP (non-thread-safe, x64), built against each version's devel pack as one DLL per PHP version (igbinary up to 8.4 and opentelemetry from 8.1 for now), and mongodb, sqlsrv and pdo_sqlsrv, repackaged unchanged from the DLLs their own projects publish. Connecting to SQL Server with sqlsrv or pdo_sqlsrv also needs Microsoft's ODBC Driver for SQL Server, which isn't included.
- **Ruby 3.2 to 4.0**: relocatable builds for macOS with OpenSSL and libyaml linked in, and RubyInstaller's Ruby repackaged as a zip for Windows.
- **pgvector** for every PostgreSQL version DevKit installs, on macOS and Windows.
- **memcached** for macOS, with libevent linked in.
- **MariaDB 11.8 and 10.11** for macOS: relocatable server and client programs with wolfSSL, zlib, PCRE2 and fmt built in, and GnuTLS with Nettle for the client library.
- **PostGIS 3.6** for every PostgreSQL version DevKit installs, on macOS: the `postgis` and `postgis_topology` modules with GEOS, PROJ, json-c and protobuf-c linked in, the `postgis_tiger_geocoder` extension, PROJ's `proj.db`, and the licences of all of them. Built without raster support (no GDAL).
- **libwebrtc** for macOS and Windows (both architectures each), built without H.264.
- **The voice engines** for DevKit's local dictation, meeting notes and chat: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for speech and [llama.cpp](https://github.com/ggml-org/llama.cpp) with its `common` library, each with its own ggml. Static libraries for macOS (Metal on Apple silicon, the CPU on Intel) and DLLs for Windows x64 (CPU variants picked at run time, plus Vulkan).
- **The models** DevKit offers for them, in [`models/catalogue.json`](models/catalogue.json): speech models converted and quantized here, and chat models checked here (see [Models](#models)).

Each release holds one version for every platform (`php-8.4.26`, `php-ext-redis-6.3.0`, `ruby-3.4.7`, `pgvector-0.8.7`, `memcached-1.6.45`, `mariadb-11.8.9`, `postgis-3.6.4`, `libwebrtc-0.3.49`, `voice-engines-0.4.0-0.1.160`), except model releases (`models-2026-10-17`), which hold one catalogue. MariaDB and PostGIS releases also hold the complete sources they were built from, with the scripts that build them (`mariadb-11.8.9-sources.tar.gz`, `postgis-3.6.4-sources.tar.gz`), as the GPL asks. Every file has a build attestation, so you can check it came from this repository's workflow:

```sh
gh attestation verify php-8.4.26-cli-macos-aarch64.tar.gz --repo frankperez87/devkit-runtimes
```

DevKit doesn't download runtimes from here directly. Its publishing step checks each file's digest and attestation, then serves it from DevKit's own server with a signed list of SHA-256 sums. libwebrtc and the voice engines are only used to build DevKit: DevKit's build checks each archive's digest and attestation before it links it.

## How it builds

The [Build workflow](.github/workflows/build.yml) runs daily and builds each PHP patch release php.net has published that isn't released here yet. Run it by hand (Actions › Build › Run workflow) to build Ruby, pgvector, memcached, MariaDB or PostGIS, or to rebuild everything. libwebrtc builds only when chosen by name (`what: libwebrtc`); it takes an hour or two per target. The voice engines build only when chosen by name too (`what: voice-engines`), after their pins change. So do the PHP extensions for Windows (`what: php-ext-windows`), building just the files not released yet; to rebuild a released file, delete that asset from its release, then run again. Only runs on `main` attach files to releases.

Whenever a run builds MariaDB or PostGIS, one Linux job per project collects its sources with [`scripts/sources.sh`](scripts/sources.sh), fetching and checking each input as the build does. The release step attaches a MariaDB or PostGIS build only when its `<name>-<version>-sources.tar.gz` came from the same run; otherwise it attaches the rest and fails.

Every input is checked: GitHub release digests for static-php-cli, OpenSSL, Postgres and RubyInstaller; ruby-lang.org's SHA-256; a pinned SHA-256 for libyaml; a pinned commit for pgvector's tag; windows.php.net's SHA-256 for each PHP and devel pack, and pinned commits for the PHP SDK and each Windows extension's tag, a pinned SHA-256 for grpc's PECL tarball (patched for Visual C++ from `scripts/php-ext-patches`) and for each licence notice its zips carry, and GitHub digests, or a pinned SHA-256 for releases older than GitHub's digests, for the DLLs mongo-php-driver and Microsoft publish, with Microsoft's Authenticode signature on sqlsrv and pdo_sqlsrv; a pinned SHA-256 plus memcached.org's SHA-1 for memcached, and libevent's GitHub digest; archive.mariadb.org's SHA-256 plus a pinned one for MariaDB, GitHub digests for the fmt and pcre2 its CMake would otherwise fetch with an MD5, and pinned SHA-256s for GnuTLS and Nettle (checked against upstream's signatures when pinned); a pinned SHA-256 plus download.osgeo.org's MD5 for PostGIS, GitHub digests for GEOS, PROJ and json-c, and a pinned SHA-256 for protobuf-c; crates.io's SHA-256 for the `webrtc-sys` recipe, and pinned commits for WebRTC and depot_tools; pinned commits for transcribe.cpp and llama.cpp, each checked against the crate DevKit links it through (crates.io's SHA-256), and the Vulkan SDK's pinned SHA-256, which must also be the one LunarG publishes. Each script fails unless its result works: PHP loads every listed extension, Ruby runs from another folder with nothing linked outside the system, pgvector loads into Postgres and answers a query, each Windows PHP extension loads into the official PHP of its version (`php -m` lists it), memcached links only macOS's own libraries and answers a set and a get, MariaDB runs from a folder with a space in its path, answers a query over TCP on 127.0.0.1 only, dumps and restores a database, logs a user in with a password and links nothing outside the system, PostGIS runs from a folder with a space in its path in each Postgres version, creates its extensions, measures a distance, transforms with the shipped `proj.db`, encodes a vector tile and links nothing outside the system, libwebrtc has no FFmpeg or OpenH264 code or licences, and the voice engines link from their manifests alone, transcribe a FLEURS clip on the CPU, and render and parse a tool call with llama.cpp's chat code. Windows engine DLLs must use the dynamic C runtime; each build records its MSVC version in `BUILDINFO.json`, and DevKit installs at least that Visual C++ Redistributable. Everything targets macOS 13 or later.

Run a script on a Mac:

```sh
scripts/php.sh 8.4 out/
scripts/ruby.sh 3.4 out/
scripts/pgvector.sh 18.6.0 out/
scripts/memcached.sh out/
scripts/mariadb.sh 11.8 out/
scripts/postgis.sh 18.6.0 out/     # needs protoc-c: brew install protobuf-c
scripts/sources.sh mariadb out/    # or postgis; also runs on Linux
scripts/libwebrtc.sh aarch64 out/   # about 30 GB of disk
scripts/voice-engines.sh aarch64 out/
scripts/models.sh whisper-small out/    # one model; scripts/models.sh all out/ for every one
```

PostGIS's tarball ships no code generated from its `.proto` files, so its build runs protoc-c from Homebrew's `protobuf-c` to write that C source. It's a build tool only: the runtime library linked in is protobuf-c's own release, pinned in [`scripts/postgis.env`](scripts/postgis.env), and the script fails if anything links a Homebrew library. DevKit runs PostGIS with `PROJ_DATA` pointing at the shipped `proj.db`.

On Windows, from a Visual Studio 2022 developer prompt: `pwsh scripts/voice-engines-windows.ps1 x86_64 out`, or `pwsh scripts/php-ext-windows.ps1 -Minor 8.4 -Exts "redis" -Out out` (for PHP 8.0 to 8.3, a prompt with the 14.29 toolset: `vcvars64.bat -vcvars_ver=14.29`).

## Voice engines

Each `voice-engines-<transcribe-cpp-sys>-<llama-cpp-sys-2>` release is named after the two crates DevKit links the engines through, and its archives hold:

- `transcribe/`: transcribe.cpp's `cmake --install` prefix, which `transcribe-cpp-sys` reads from `TRANSCRIBE_DIR`. `lib/transcribe-link.json` says how to link it.
- `llama/`: llama.cpp's install prefix plus its `common` library and headers (what a chat shim over `common_chat_templates_apply` and `common_chat_parse` needs), with `lib/llama-link.json` in the same shape. Apple builds list CoreGraphics, which Metal needs to give a process its GPU.
- `LICENSES/` and `BUILDINFO.json`: the pins, compiler, CMake options and smoke test results.

llama.cpp is built without curl, OpenSSL or subprocesses. The pins live in [`scripts/voice-engines.env`](scripts/voice-engines.env).

## Models

[`models/catalogue.json`](models/catalogue.json) lists every model DevKit offers for speech and chat, each pinned to an upstream commit and SHA-256. The [Models workflow](.github/workflows/models.yml) runs when it changes on `main` (or by hand, for named models) and releases `models-<date>`:

- **Speech models** (Parakeet Ultra, Parakeet v3, Nemotron 3.5 ASR, Qwen3-ASR, Granite Speech 4.1 2B, Whisper large-v3-turbo and small, Silero VAD) are converted from their upstream files with transcribe.cpp's converter at the engine commit, in its locked Python environments, then quantized and attached to the release. Each is under 2 GiB.
- **Chat models** (Qwen3.5 4B and 9B, Qwen3.6 35B-A3B) are Unsloth's GGUFs, left exactly as published and pinned on Hugging Face by commit, SHA-256 and size. DevKit applies its own copy of each model's chat template, from Qwen's repository ([`models/templates/`](models/templates)), rather than the one the GGUF carries.
- **Licences** must be MIT, Apache-2.0, CC-BY-4.0 or OpenMDW-1.1, as the Hugging Face API reports them at the pinned commit (`license_name` when the tag is `other`). Each model gets a `NOTICE.txt` naming who made it, the source and commit, its licence, what DevKit changed, a disclaimer and the licence's full text ([`models/licenses/`](models/licenses)).
- **Tests** run on the CPU: speech models transcribe [FLEURS clips](models/fixtures) within an error rate, chat models answer in JSON and make a tool call with thinking off, and the 35B, which needs more memory than a hosted runner has, gets a header check and a load. `catalogue.json` in the release records each model's test level and results.

The release attests the converted files, the notices and `catalogue.json`. DevKit's publishing verifies them with `--signer-workflow frankperez87/devkit-runtimes/.github/workflows/models.yml --source-ref refs/heads/main --deny-self-hosted-runners`, then mirrors every file to its own server.

Once a week, [Model updates](.github/workflows/model-updates.yml) checks the Hugging Face API for newer commits of each model and GitHub for new llama.cpp security advisories. It downloads only files that changed, runs the same checks and tests, and opens a pull request with the old and new SHA-256, the licence, the test results and the Hub's scan status; text from upstream is shown as code. Merging it starts a new release. It needs **Allow GitHub Actions to create and approve pull requests** turned on in this repository's Actions settings, and an optional read-only `HF_TOKEN` secret raises the Hub's rate limit.

## Licences

The scripts are MIT-licensed ([`LICENSE`](LICENSE)). The builds contain other projects under their own licences, including LGPL libraries in PHP, and every model keeps its own licence; see [`LICENSES.md`](LICENSES.md).
