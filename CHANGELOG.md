# Changelog

## 1.3.0

- `convertToModelMessages` keeps empty-text reasoning that carries provider metadata, converts assistant reasoning-file parts and inlines non-image `data:` URL files instead of throwing.
  Compatibility: Source-compatible; changes are additive. Request bodies, results, warnings and errors change to match the reviewed upstream package.
