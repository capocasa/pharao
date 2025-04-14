## Pharao dynamic library.
#
# This is compiled to a dynamic library by the pharao server
# when a source file is updated. It provides the library
# interface to receive the request from the server and send the
# response, and some variables and utilities as an interface for the source file.
#

import
  std/[macrocache,uri,strutils,pegs,re],
  ./common,
  mummy,
  mummy/multipart,
  webby/urls

import macros except body, error

## basic compile assertions

when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

when appType != "lib":
  {.error: "Pharaoh dynamic library must be compiled with params '--app:lib'"}

## set the include file passed from server at dynamic lib compile time
const pharaoSourcePath {.strdefine: "pharao.sourcePath".} = ""
when pharaoSourcePath == "":
  {.error: "Pharaoh dynamic library requires a --d:sourcePath, usually the pharoh server will take care of that for you".}

# sets up GC and run main module on library init
proc NimMain() {.cdecl, importc.}
proc library_init() {.exportc, dynlib, cdecl.} =
  NimMain()
proc library_deinit() {.exportc, dynlib, cdecl.} =
  GC_FullCollect()

## library specific state

import ./tools

const pharaoSourceCache = CacheTable"pharaoSource"

macro includePharaoSource() =
  newNimNode(nnkIncludeStmt).add(newIdentNode(pharaoSourcePath))

macro cachePharaoSource(source: typed) =
  var
    imports = newStmtList()
    requestBody = newStmtList()
  template filter(n: NimNode) =
    if n.kind == nnkImportStmt or n.kind == nnkImportExceptStmt or n.kind == nnkFromStmt:
      imports.add(n)
    else:
      requestBody.add(n)
  if source[1].kind == nnkStmtList:
    for n in source[1]:
      filter(n)
  else:
    filter(source[1])
  pharaoSourceCache["imports"] = imports
  pharaoSourceCache["requestBody"] = requestBody

macro pharaoSourceImports(): untyped =
  result=pharaoSourceCache["imports"]
  #echo "I\n", result.treeRepr

macro pharaoSourceRequestBody(): untyped =
  result=pharaoSourceCache["requestBody"]
  #echo "RB\n", result.treeRepr

cachePharaoSource(includePharaoSource())

#pharaoSourceImports()


## dynlib interface

# main request proc
proc pharaoRequest*(requestArg: Request) {.exportc,dynlib.} =

  # init request vars
  request = requestArg
  code = 200
  headers = @{"Content-Type":"text/html"}.HttpHeaders
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
    respondProc(request, 500, headers, if outputErrors: e.msg else: "internal server error\n")

  # autorespond if not responded yet
  if not request.responded:
    respond()

# Initialization hook, called by pharao on loading library to
# provide callables. Data could be provided too.
proc pharaoInit(respondProcArg: RespondProc, logProc: LogProc, stdoutArg, stderrArg, stdinArg: File) {.exportc,dynlib.} =
  respondProc = respondProcArg
  log = logProc
  assert not respondProc.isNil, "Empty responder received"
  assert not logProc.isNil, "Empty logger received"

  # these are only recommended to be used for debugging
  # but without having them assigned programs segfault
  # on access which is hard to debug
  stdout = stdoutArg
  stderr = stderrArg
  stdin = stdinArg


