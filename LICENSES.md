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
