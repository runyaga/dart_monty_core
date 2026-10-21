# Package versioning

`dart_monty_core` does not use semantic versioning. The version identifies
the pinned upstream Monty release and this package's fixes for that pin.
Upstream 1.1.0 maps to package version 0.110.x. The script
`tool/check_version_pin.sh` checks the mapping.

Any release can contain a breaking change. Applications should pin a package
version and read the [changelog](../../CHANGELOG.md) before upgrading.

Prospective users can open an issue to describe a required use case.
