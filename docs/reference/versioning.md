# Package versioning

`dart_monty_core` does not use semantic versioning. The version identifies
the pinned upstream Monty release and this package's fixes for that pin.
Upstream 1.3.0 maps to package version 0.130.x. The script
`tool/check_version_pin.sh` checks the mapping.

Any release can contain a breaking change. Applications should pin a package
version and read the [changelog](../../CHANGELOG.md) before upgrading.

Prospective users can open an issue to describe a required use case.

## The dump limit

A dump is the session snapshot the package writes and reads back. It is
upstream's format, and what a dump may hold follows the upstream release
that wrote it.

Upstream 1.3.0 kept the dump version of 1.2.0: both carry the same
DUMP_VERSION 13, so the version a dump declares is no guide to the release
that wrote it. The payloads are.

- A dump written by 1.2.0 restores on 1.3.0.
- A dump written by 1.3.0 that holds a `functools.lru_cache` wrapper fails to
  load on 1.2.0: 1.2.0's payload decoder does not know that heap payload, so
  the load ends in a payload decode error (finding 38).

So the limit is a payload, not the dump version: on a downgrade to 1.2.0, a
1.3.0 dump that holds a `functools.lru_cache` wrapper does not restore, and
the load ends in a payload decode error, under the same DUMP_VERSION 13.
