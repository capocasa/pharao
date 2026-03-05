## Pharao dynamic library.
#
# This is compiled to a dynamic library by the pharao server
# when a source file is updated. It provides the library
# interface to receive the request from the server and send the
# response, and some variables and utilities as an interface for the source file.
#

import
  std/[macrocache,uri,strutils,pegs,re,compilesettings,os],
  ./common,
  mummy,
  mummy/multipart,
  webby/urls

import macros except body, error

## basic compile assertions


when appType != "lib":
  {.error: "Pharaoh dynamic library must be compiled with params '--app:lib'"}

## set the include file passed from server at dynamic lib compile time
const pharaoSourcePath {.strdefine: "pharao.sourcePath".} = ""
when pharaoSourcePath == "":
  {.error: "Pharaoh dynamic library requires a --d:sourcePath, usually the pharoh server will take care of that for you".}

# sets up GC and run main module on library init

## library specific state

import ./tools

const pharaoSourceCache = CacheTable"pharaoSource"
const pharaoSourceDir = pharaoSourcePath.parentDir

# Parse as untyped AST so variables are resolved in function scope,
# not module scope. This prevents user vars from becoming shared globals.
# NOTE: Source code filters (#? stdtmpl) are not supported - they can't
# be parsed by parseStmt and are inherently not thread-safe.
macro cachePharaoSource() =
  let sourceCode = staticRead(pharaoSourcePath)
  let ast = parseStmt(sourceCode)
  var
    imports = newStmtList()
    requestBody = newStmtList()

  # Resolve relative import paths to absolute paths based on source directory
  # Only resolve if the local file actually exists; otherwise leave as-is
  # (for nimble packages, stdlib, etc.)
  proc resolveImportPath(n: NimNode): NimNode =
    if n.kind == nnkIdent:
      # Bare identifier like `import foo`
      let localPath = pharaoSourceDir / n.strVal & ".nim"
      if fileExists(localPath):
        # Local file exists - resolve to absolute path (without .nim extension)
        result = newStrLitNode(pharaoSourceDir / n.strVal)
      else:
        # Not a local file - leave as-is (nimble package or stdlib)
        result = n
    elif n.kind == nnkInfix and n[0].kind == nnkIdent and n[0].strVal == "/":
      # Path like `foo/bar` or `std/random` - resolve first component if local
      let first = n[1]
      if first.kind == nnkIdent and first.strVal != "std":
        let localPath = pharaoSourceDir / first.strVal & ".nim"
        if fileExists(localPath):
          var newN = n.copyNimTree()
          newN[1] = newStrLitNode(pharaoSourceDir / first.strVal)
          result = newN
        else:
          result = n
      else:
        result = n
    elif n.kind == nnkPrefix and n[0].kind == nnkIdent and n[0].strVal == "./":
      # Explicit relative like `import ./foo` - always resolve
      result = n.copyNimTree()
      if n[1].kind == nnkIdent:
        result[1] = newStrLitNode(pharaoSourceDir / n[1].strVal)
    else:
      result = n

  proc resolveImportStmt(n: NimNode): NimNode =
    result = n.copyNimTree()
    # Import children start at index 0 for nnkImportStmt
    for i in 0..<result.len:
      if result[i].kind in {nnkIdent, nnkInfix, nnkPrefix}:
        result[i] = resolveImportPath(result[i])

  template filter(n: NimNode) =
    if n.kind == nnkImportStmt or n.kind == nnkImportExceptStmt or n.kind == nnkFromStmt:
      imports.add(resolveImportStmt(n))
    else:
      requestBody.add(n)
  if ast.kind == nnkStmtList:
    for n in ast:
      filter(n)
  else:
    filter(ast)
  pharaoSourceCache["imports"] = imports
  pharaoSourceCache["requestBody"] = requestBody

cachePharaoSource()

macro pharaoSourceImports(): untyped =
  result=pharaoSourceCache["imports"]

macro pharaoSourceRequestBody(): untyped =
  result=pharaoSourceCache["requestBody"]

pharaoSourceImports()


## dynlib interface

# main request proc
proc pharaoRequest*(requestArg: Request) {.exportc,dynlib.} =

  # init request vars
  request = requestArg
  code = 200
  headers = @{"Content-Type":"text/html; charset=utf-8"}.HttpHeaders
  body = ""

  # interface func to respond
  # manually to continue execution
  # after completed request

  ## Write user supplied code, minus imports
  try:
    pharaoSourceRequestBody()
  except:
    let e = getCurrentException()
    const logErrors = true
    if logErrors:
      error(e.msg)
    const outputErrors = true
    code = 500
    body = if outputErrors: e.msg else: "internal server error\n"
    respond()

  # autorespond if not responded yet
  if not request.responded:
    respond()

# Initialization hook, called by pharao on loading library to
# provide callables. Data could be provided too.
proc pharaoInit(respondProcArg: RespondProc, logProcArg: LogProc, stdoutArg, stderrArg, stdinArg: File) {.exportc,dynlib.} =
  proc NimMain() {.cdecl, importc.}
  respondProc = respondProcArg
  log = logProcArg
  assert not respondProc.isNil, "Empty responder received"
  assert not logProcArg.isNil, "Empty logger received"

  # these are only recommended to be used for debugging
  # but without having them assigned programs segfault
  # on access which is hard to debug
  stdout = stdoutArg
  stderr = stderrArg
  stdin = stdinArg

  debug("initialized " & querySetting(SingleValueSetting.nimcacheDir))

proc pharaoDeinit() {.exportc,dynlib.} =
  GC_FullCollect()

