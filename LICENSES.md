# Licences of what these builds contain

The build scripts in this repository are MIT-licensed (see `LICENSE`). The files attached to releases are builds of other projects, which keep their own licences.

## PHP

PHP is under the PHP License 3.01, built with static-php-cli (MIT). Each release has one static program each for the CLI and php-fpm. Besides PHP's bundled extensions, they contain these extensions:

| Extension | Licence |
|---|---|
| apcu, event, ev, imagick, memcached, pcov, redis | PHP License 3.01 |
| excimer, grpc, mongodb (with libmongoc and libbson), opentelemetry, swoole | Apache-2.0 |
| igbinary, msgpack | BSD-3-Clause |
| sqlsrv, pdo_sqlsrv | MIT |

They link these libraries statically. GMP, GNU gettext, GNU libiconv, libde265, libheif and unixODBC's driver manager are under the LGPL. Each project publishes its source, and `scripts/php.sh` rebuilds PHP against a changed copy of any of them with static-php-cli.

| Library | Used by | Licence |
|---|---|---|
| brotli | swoole, image formats | MIT |
| bzip2 | bz2, imagick | bzip2-1.0.6 |
| c-ares | grpc, swoole | MIT |
| curl | curl | curl |
| FastLZ | memcached | MIT |
| FreeType | imagick | FreeType License (FTL), chosen from FTL or GPL-2.0 |
| GMP | gmp, ldap | LGPL-3.0-or-later, chosen from LGPL-3.0 or GPL-2.0 |
| GNU gettext (libintl) | gettext | LGPL-2.1-or-later |
| GNU libiconv | iconv, gettext, libxml2, unixODBC | LGPL-2.1-or-later |
| gRPC core (with abseil, re2, upb) | grpc | Apache-2.0 (abseil Apache-2.0; re2 and upb BSD-3-Clause) |
| ICU | intl | Unicode-3.0 |
| ImageMagick | imagick | ImageMagick License |
| libaom | imagick and gd (AVIF) | BSD-2-Clause, with the AOMedia patent licence |
| libavif | gd (AVIF) | BSD-2-Clause |
| libde265 | imagick (HEIF) | LGPL-3.0-or-later |
| libedit | readline, pgsql | BSD-3-Clause |
| libevent | event | BSD-3-Clause |
| libheif | imagick (HEIF) | LGPL-3.0-or-later |
| libjpeg-turbo | imagick | IJG, BSD-3-Clause and Zlib |
| libjxl | imagick (JPEG XL) | BSD-3-Clause |
| libmemcached (with libhashkit) | memcached | BSD-3-Clause |
| libpng | gd, imagick | libpng-2.0 |
| libsodium | sodium, ldap | ISC |
| libtiff | imagick | libtiff |
| libwebp | imagick | BSD-3-Clause |
| libxml2 | dom, xml, simplexml, xmlreader, xmlwriter, soap | MIT |
| libxslt | xsl | MIT |
| libzip | zip | BSD-3-Clause |
| ncurses | libedit | X11 (MIT-style) |
| nghttp2 | swoole | MIT |
| Oniguruma | mbregex (mb_split, mb_ereg) | BSD-2-Clause |
| OpenLDAP (libldap) | ldap | OLDAP-2.8 |
| OpenSSL | openssl, curl, grpc, ldap, pgsql | Apache-2.0 |
| PostgreSQL (libpq) | pgsql, pdo_pgsql | PostgreSQL License |
| SQLite | sqlite3, pdo_sqlite | Public domain |
| UW IMAP c-client | imap | Apache-2.0 |
| unixODBC | sqlsrv, pdo_sqlsrv | LGPL-2.1-or-later |
| zlib | zlib and most of the above | Zlib |

## PHP extensions for Windows

Built against windows.php.net's devel pack for each PHP version, or repackaged unchanged from the DLLs an extension's own project publishes, and load-tested in that version's official PHP.

| Extension | Licence | Source |
|---|---|---|
| apcu | PHP License 3.01 | [krakjoe/apcu](https://github.com/krakjoe/apcu) |
| igbinary | BSD-3-Clause | [igbinary/igbinary](https://github.com/igbinary/igbinary) |
| msgpack | BSD-3-Clause | [msgpack/msgpack-php](https://github.com/msgpack/msgpack-php) |
| pcov | PHP License 3.01 | [krakjoe/pcov](https://github.com/krakjoe/pcov) |
| redis | PHP License 3.01 | [phpredis/phpredis](https://github.com/phpredis/phpredis) |
| opentelemetry | Apache-2.0 | [open-telemetry/opentelemetry-php-instrumentation](https://github.com/open-telemetry/opentelemetry-php-instrumentation) |
| grpc | Apache-2.0 | [PECL's grpc tarball](https://pecl.php.net/package/grpc) |
| mongodb | Apache-2.0 | [mongodb/mongo-php-driver](https://github.com/mongodb/mongo-php-driver)'s own Windows DLLs, unchanged |
| sqlsrv | MIT | [microsoft/msphpsql](https://github.com/microsoft/msphpsql)'s DLLs, signed by Microsoft, unchanged |
| pdo_sqlsrv | MIT | [microsoft/msphpsql](https://github.com/microsoft/msphpsql)'s DLLs, signed by Microsoft, unchanged |

grpc's DLL compiles in gRPC core and the copies of these libraries that its PECL tarball carries in `third_party/`. It doesn't use c-ares on Windows. Each zip's `licenses/php_grpc/` holds grpc's `LICENSE` and `NOTICE.txt` and each library's licence, taken from grpc's v1.84.0 tag and the commits it pins for its submodules.

| Library | Licence |
|---|---|
| gRPC core, with code generated from the envoy, xds, udpa, cel-spec, googleapis, grpc-proto and protoc-gen-validate protos | Apache-2.0 |
| abseil-cpp | Apache-2.0 |
| BoringSSL, with its fiat-crypto parts | Apache-2.0 |
| re2 | BSD-3-Clause |
| upb and code generated from protobuf's own types (protobuf) | BSD-3-Clause |
| address_sorting | BSD-3-Clause |
| utf8_range | MIT |
| xxHash | BSD-2-Clause |
| zlib | Zlib |

mongodb's DLL compiles in libbson and libmongoc (from mongo-c-driver) and libmongocrypt, with the code they carry; it uses the OpenSSL in PHP's own folder. Each zip's `licenses/php_mongodb/` holds the driver's `LICENSE` and `THIRD_PARTY_NOTICES` and these libraries' licences and notices, taken from the driver's tag and the commits it pins for its submodules.

| Library | Licence |
|---|---|
| libbson, libmongoc and their common code (mongo-c-driver) | Apache-2.0 (its base64 code ISC, its MD5 code Zlib) |
| libmongocrypt, with kms-message | Apache-2.0 (kms-message's base64 code ISC) |
| jsonsl | MIT |
| utf8proc | MIT |
| uthash | BSD-1-Clause |
| php_array_api.h | PHP License 3.01 |

sqlsrv's and pdo_sqlsrv's zips hold msphpsql's `LICENSE` from the tag of their version. Both use Windows' own ODBC (`odbc32.dll`); connecting to SQL Server also needs Microsoft's ODBC Driver for SQL Server, which isn't included.

## Ruby

| Component | Licence |
|---|---|
| Ruby (macOS builds, from ruby-lang.org source) | Ruby License or BSD-2-Clause |
| OpenSSL, linked statically | Apache-2.0 |
| libyaml, linked statically | MIT |
| RubyInstaller (repackaged for Windows) | BSD-3-Clause; Ruby and its bundled libraries keep their own licences |

## pgvector

| Component | Licence |
|---|---|
| pgvector | PostgreSQL License |

## memcached

| Component | Licence |
|---|---|
| memcached | BSD-3-Clause (Danga Interactive) |
| libevent, linked statically | BSD-3-Clause, with ISC-licensed parts (arc4random) |

## MariaDB

MariaDB Server and its client programs for macOS. The server uses its bundled wolfSSL; the client library, MariaDB Connector/C, uses GnuTLS with Nettle, built static (Connector/C has no wolfSSL support). The client's line editing is macOS's own libedit, linked from the system, so no GNU readline is in the build. Each archive carries MariaDB's `COPYING` and `THIRDPARTY` notices in `share/doc/`, and the licences of Connector/C, wolfSSL (with its exception for MariaDB), GnuTLS, Nettle, fmt and PCRE2 in `share/doc/connector-c/`, `wolfssl/`, `gnutls/`, `nettle/`, `fmt/` and `pcre2/`. Each `mariadb-<version>` release also has `mariadb-<version>-sources.tar.gz`: MariaDB's source tarball, the fmt and PCRE2 zips its build compiles in, the GnuTLS and Nettle tarballs, and the scripts that build them (`scripts/lib.sh`, `scripts/mariadb.sh`, `scripts/mariadb.env`). A build is never released without it.

| Component | Licence |
|---|---|
| MariaDB Server and client programs | GPL-2.0-only |
| MariaDB Connector/C (the client library the programs link) | LGPL-2.1-or-later |
| wolfSSL, bundled | GPL-3.0-or-later, with wolfSSL's exception that lets MariaDB Server use it under GPL-2.0 |
| zlib, bundled | Zlib |
| PCRE2, bundled | BSD-3-Clause (with the PCRE2 exception) |
| fmt, bundled | MIT |
| GnuTLS, linked statically into Connector/C, with its included libtasn1 | LGPL-2.1-or-later |
| libunistring, GnuTLS's included copy (Unicode normalisation and character classes), linked statically into Connector/C | LGPL-2.1-or-later for some files; LGPL-3.0-or-later or GPL-2.0-or-later for others, used under GPL-2.0-or-later |
| Nettle and its mini-gmp, linked statically into Connector/C | LGPL-3.0-or-later or GPL-2.0-or-later, used under GPL-2.0-or-later |

## PostGIS

PostGIS for macOS and Windows x64, built without raster support (no GDAL), for each Postgres version DevKit installs. On macOS, libxml2, SQLite and libc++ are macOS's own, linked from the system. On Windows, built with MSYS2's GCC, libxml2 and SQLite are built from source and linked in too, with GCC's C++ runtime, winpthreads and the mingw-w64 runtime, so the modules import nothing but `postgres.exe` and Windows' own DLLs. Each archive carries PostGIS's `COPYING` and `LICENSE.TXT` and the licences of everything linked into it in `doc/`; Windows archives also list the MSYS2 packages of the runtime in `doc/toolchain.txt`.

| Component | Licence |
|---|---|
| PostGIS | GPL-2.0-or-later |
| GEOS | LGPL-2.1-or-later |
| PROJ | MIT |
| proj.db | PROJ's data, including the EPSG dataset under the EPSG terms of use |
| json-c | MIT |
| protobuf-c | BSD-2-Clause |
| PostgreSQL's headers' inline code (and on Windows libpgport and libpgcommon) | PostgreSQL License |
| libxml2 (Windows) | MIT |
| SQLite (Windows) | Public domain |
| GCC's runtime, libgcc and libstdc++ (Windows) | GPL-3.0-or-later with the GCC Runtime Library Exception |
| winpthreads (Windows) | MIT, with parts under BSD-3-Clause |
| mingw-w64 runtime (Windows start-up code and libmingwex) | ZPL-2.1-style mingw-w64 licence, with parts under other permissive licences listed in its `COPYING.MinGW-w64-runtime.txt` |

GEOS, PROJ, json-c and protobuf-c (and on Windows libxml2 and SQLite) are linked statically into the PostGIS modules. Each `postgis-<version>` release also has `postgis-<version>-sources.tar.gz`: the PostGIS, GEOS, PROJ, json-c, protobuf-c, libxml2 and SQLite tarballs and the scripts that build them (`scripts/lib.sh`, `scripts/postgis.sh`, `scripts/postgis-windows.sh`, `scripts/postgis.env`), which rebuild against changed copies. A build is never released without it, nor with a sources file that lacks the script that made it (or, for Windows, the libxml2 and SQLite tarballs). Each archive's `doc/postgresql/COPYRIGHT` is PostgreSQL's licence. GCC's runtime, winpthreads and the mingw-w64 runtime are the compiler's own libraries (the GPL's System Libraries); their sources are MSYS2's, at the versions in `doc/toolchain.txt`.

## libwebrtc

Google's WebRTC (BSD-3-Clause) from LiveKit's fork (`webrtc-sdk/webrtc`), built with the recipe and patches of LiveKit's `webrtc-sys` crate (Apache-2.0). Each archive includes the full licence texts generated by WebRTC's build (`LICENSE.md`). It's built **without H.264**: no FFmpeg and no OpenH264 are compiled in, and the build fails if their code or licences appear.

| Component | Licence |
|---|---|
| WebRTC | BSD-3-Clause |
| abseil-cpp, BoringSSL, fiat-crypto, Perfetto, libc++ | Apache-2.0 (libc++ with the LLVM exception) |
| dav1d, libaom | BSD-2-Clause |
| libvpx, libyuv, libsrtp, Opus, protobuf, rnnoise, pffft | BSD-style |
| PortAudio | MIT |
| zlib | zlib |
| libjpeg-turbo | IJG and BSD-3-Clause |
| g711, g722 | public domain |
| fft (Mark Olesen), Ooura FFT, spl_sqrt_floor | permissive notices |

## Voice engines

Two engines, each with its own copy of ggml. Each archive includes the engines' licence files in `LICENSES/`.

| Component | Licence |
|---|---|
| transcribe.cpp (handy-computer) | MIT |
| ggml (in transcribe.cpp and in llama.cpp), with llamafile's tinyBLAS kernels | MIT |
| llama.cpp and its `common` library | MIT |
| nlohmann/json, cpp-httplib (in llama.cpp's `common`) | MIT |
| miniz, Silero VAD's runtime code (in transcribe.cpp) | MIT |
| dr_wav (only in the smoke test, not in the archives) | Public domain or MIT-0 |

The Windows build uses the Vulkan SDK (LunarG) to compile shaders and link against `vulkan-1.dll`; the SDK isn't in the archives, and DevKit loads the Vulkan loader the system provides.

## Models

The models keep their creators' licences. Each model in a `models-<date>` release has a `NOTICE.txt` with its creators, source and commit, licence, what changed, a disclaimer and the full licence text, from [`models/licenses/`](models/licenses). The catalogue allows only these licences:

| Model | Creator | Licence | In the release |
|---|---|---|---|
| Parakeet Ultra | Moondream, post-trained from NVIDIA's Parakeet TDT 0.6B v3 | CC-BY-4.0 | converted and quantized by DevKit |
| Parakeet TDT 0.6B v3 | NVIDIA | CC-BY-4.0 | converted and quantized by DevKit |
| Nemotron 3.5 ASR 0.6B | NVIDIA | OpenMDW-1.1 | converted and quantized by DevKit |
| Qwen3-ASR 0.6B | Qwen team, Alibaba Cloud | Apache-2.0 | converted and quantized by DevKit |
| Granite Speech 4.1 2B | IBM | Apache-2.0 | converted and quantized by DevKit |
| Whisper large-v3-turbo | OpenAI | MIT | converted and quantized by DevKit |
| Whisper small | OpenAI | Apache-2.0 | converted and quantized by DevKit |
| Silero VAD v6.2 | Silero Team | MIT | converted by DevKit |
| Qwen3.5 4B and 9B, Qwen3.6 35B-A3B | Qwen team, Alibaba Cloud; quantized to GGUF by Unsloth | Apache-2.0 | pinned on Hugging Face, unmodified |

CC-BY-4.0 asks that changes be indicated: quantizing changes a model's weights, so the speech models' notices say they're modified. OpenMDW-1.1 ends the rights of anyone who sues claiming the model infringes a patent or copyright, unless they were sued first.

The speech test clips in [`models/fixtures/`](models/fixtures) come from Google's [FLEURS](https://huggingface.co/datasets/google/fleurs) test split (CC-BY-4.0), by way of transcribe.cpp's samples; [`models/fixtures/fixtures.json`](models/fixtures/fixtures.json) names each clip's FLEURS utterance and reference text. The chat templates in [`models/templates/`](models/templates) are Qwen's (Apache-2.0), unmodified.
