# Changelog

## 0.3.0 - 2026-09-21

- Hot reload changes to included and locally imported files (#4)
- Includes resolve relative to the source file and source code filter files can be included
- Custom error pages: error.nim takes over 404, 500 and 503 responses, cascading up to the web root, with code and body prefilled (#2)
- PHARAO_ERROR_PAGE configures the error page: a filename cascades, a path starting with / is fixed at the web root
- Builtin error pages are now proper plain text status pages with the pharao version
- Route exceptions are reported to the server via an error callback so PHARAO_OUTPUT_ERRORS now also applies to them
- Fix crash when a route is served from more than one web server worker thread: restore --d:useMalloc for compiled routes, lost in the parseStmt rework (Nim issue #24816), and set up foreign thread allocators in the library
- Route libraries carry their dependency list, boot loading keeps hot reload working
- Running a checkout build compiles routes against its own sources, no nimble package needed

## 0.2.1 - 2026-07-04

- Fix per-request route leak that crashed pharao under load
- Clear compiled library cache on pharao upgrade
- Support `body.len` for Content-Length header
