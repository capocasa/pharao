# Changelog

## 0.2.1 - 2026-07-04

- Fix per-request route leak that crashed pharao under load
- Clear compiled library cache on pharao upgrade
- Support `body.len` for Content-Length header