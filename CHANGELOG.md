# Changelog

## 0.3.0 - 2026-09-21

- Custom error pages: error.nim takes over 404, 500 and 503 responses, cascading up to the web root, with code and body prefilled (fixes #2)
- PHARAO_ERROR_PAGE configures the error page: a filename cascades, a path starting with / is fixed at the web root
- Builtin error pages are now proper plain text status pages with the pharao version
- Route exceptions are reported to the server via an error callback so PHARAO_OUTPUT_ERRORS now also applies to them
- Fix segfault on second request to a route: restore --d:useMalloc for compiled routes (Nim issue #24816 regression)
- Pass the directory above the pharao binary on the nim path when it contains pharao/lib.nim, so checkout builds compile routes against their own sources

## 0.2.1 - 2026-07-04

- Fix per-request route leak that crashed pharao under load
- Clear compiled library cache on pharao upgrade
- Support `body.len` for Content-Length header