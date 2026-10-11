# devkit-runtimes

Build scripts for the runtimes [DevKit](https://getdevkit.app) installs, built on GitHub Actions and attached to this repository's releases:

- **PHP 8.2 to 8.5** for macOS (Apple silicon and Intel): static CLI and php-fpm programs built with [static-php-cli](https://github.com/crazywhalecc/static-php-cli), with the extensions in [`scripts/php-extensions.txt`](scripts/php-extensions.txt).
- **Ruby 3.2 to 4.0**: relocatable builds for macOS with OpenSSL and libyaml linked in, and RubyInstaller's Ruby repackaged as a zip for Windows.
- **pgvector** for every PostgreSQL version DevKit installs, on macOS and Windows.
- **memcached** for macOS, with libevent linked in.

Each release holds one version for every platform (`php-8.4.26`, `ruby-3.4.7`, `pgvector-0.8.7`, `memcached-1.6.45`). Every file has a build attestation, so you can check it came from this repository's workflow:

```sh
gh attestation verify php-8.4.26-cli-macos-aarch64.tar.gz --repo frankperez87/devkit-runtimes
```

DevKit doesn't download from here directly. Its publishing step checks each file's digest and attestation, then serves it from DevKit's own server with a signed list of SHA-256 sums.

## How it builds

The [Build workflow](.github/workflows/build.yml) runs daily and builds each PHP patch release php.net has published that isn't released here yet. Run it by hand (Actions › Build › Run workflow) to build Ruby, pgvector or memcached, or to rebuild everything. Only runs on `main` attach files to releases.

Every input is checked: GitHub release digests for static-php-cli, OpenSSL, Postgres and RubyInstaller; ruby-lang.org's SHA-256; a pinned SHA-256 for libyaml; a pinned commit for pgvector's tag; a pinned SHA-256 plus memcached.org's SHA-1 for memcached, and libevent's GitHub digest. Each script fails unless its result works: PHP loads every listed extension, Ruby runs from another folder with nothing linked outside the system, pgvector loads into Postgres and answers a query, and memcached links only macOS's own libraries and answers a set and a get. Everything targets macOS 13 or later.

Run a script on a Mac:

```sh
scripts/php.sh 8.4 out/
scripts/ruby.sh 3.4 out/
scripts/pgvector.sh 18.6.0 out/
scripts/memcached.sh out/
```

## Licences

The scripts are MIT-licensed ([`LICENSE`](LICENSE)). The builds contain other projects under their own licences, including LGPL libraries in PHP; see [`LICENSES.md`](LICENSES.md).
