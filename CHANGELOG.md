# Changelog

## 1.3.1

- Validate nested citation metadata for finite JSON while preserving valid nested tool, citation and text values. Reviewed npm: @ai-sdk/react 4.0.177 to 4.0.183, ai 7.0.173 to 7.0.179. Offline validation passed: node Scripts/test-packages.mjs (56 packages, 3672 owning tests and 1760 compatibility tests), generation, tooling, isolation, and version selection. See Docs/Archive/WeeklyUpstreamAudit20261122.md for retained gaps. Paid provider calls were skipped.
  Compatibility: Source-compatible validation correction. Invalid nested metadata is reported at its first path.
