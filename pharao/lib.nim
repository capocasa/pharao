## Pharao dynamic library.
#
# This is compiled to a dynamic library by the pharao server
# when a source file is updated. It provides the library
# interface to receive the request from the server and send the
# response, and some variables and utilities as an interface for the source file.
#

import
  std/[macros,macrocache],
  ./common,
  mummy

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

var
  respondProc: RespondProc  # call web server responder
  log: LogProc  # write to log

## logging tools

# these are duplicated from pharao.nim so we only have to
# receive the log proc on intialization

proc debug(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(DebugLevel, message)
proc info(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(InfoLevel, message)
proc error(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(ErrorLevel, message)

## user code preprocessing macros

macro filterImportsOnly(source: typed): untyped =
  result = newStmtList()
  template filter(n: NimNode) =
    if n.kind == nnkImportStmt or n.kind == nnkImportExceptStmt or n.kind == nnkFromStmt:
      result.add(n)
  if source[1].kind == nnkStmtList:
    for n in source[1]:
      filter(n)
  else:
    filter(source[1])

macro filterNoImports(source: typed): untyped =
  result = newStmtList()
  template filter(n: NimNode) =
    if n.kind == nnkImportStmt or n.kind == nnkImportExceptStmt or n.kind == nnkFromStmt:
      discard
    else:
      result.add(n)
  if source[1].kind == nnkStmtList:
    for n in source[1]:
      filter(n)
  else:
    filter(source[1])

macro includePharaoSource(): untyped =
  newNimNode(nnkIncludeStmt).add(newIdentNode(pharaoSourcePath))

## Write imports from user-supplied code (but nothing else)
var
  # dummy vars
  # just so the import macro can include sourcePath
  # in this scope to extract and insert the import statements
  # (those are not allowed in a proc)
  code: int
  headers: HttpHeaders
  body: string
  request: Request

filterImportsOnly(includePharaoSource)

## dynlib interface


# main request proc
proc pharaoRequest*(request: Request) {.exportc,dynlib.} =
  
  ## Interface is the request param and these local vars
  var
    code = 200
    headers = @{"Content-Type":"text/html"}.HttpHeaders
    body = ""

  # interface func to respond
  # manually to continue execution
  # after completed request
  proc respond() =
    respondProc(request, code, headers, body)

  ## Write user supplied code, minus imports
  filterNoImports(includePharaoSource())

  # autorespond if not responded yet
  if not request.responded:
    respond()

# Initialization hook, called by pharao on loading library to
# provide callables. Data could be provided too.
proc pharaoInit(respondProcArg: RespondProc, logProc: LogProc) {.exportc,dynlib.} =
  respondProc = respondProcArg
  log = logProc
  assert not respondProc.isNil, "Empty responder received"
  assert not logProc.isNil, "Empty logger received"


