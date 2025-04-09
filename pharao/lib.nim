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


when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

when appType != "lib":
  {.error: "Pharaoh dynamic library must be compiled with params '--app:lib'"}

## set the include file passed from server at dynamic lib compile time
const pharaoSourcePath {.strdefine: "pharao.sourcePath".} = ""
when pharaoSourcePath == "":
  {.error: "Pharaoh dynamic library requires a --d:sourcePath, usually the pharoh server will take care of that for you".}

const transformedSource = CacheTable"transformedSource"

# sets up GC but does not exececute main module
proc PreMain() {.cdecl, importc.}
proc PreMainInner() {.cdecl, importc.}
proc NimMain() {.cdecl, importc.}
proc NimMainInner() {.cdecl, importc.}
proc NimMainModule() {.cdecl, importc.}
proc library_init() {.exportc, dynlib, cdecl.} =
  NimMain()
proc library_deinit() {.exportc, dynlib, cdecl.} =
  GC_FullCollect()

## local interface

# using pharao is reading and setting these variables,
# and letting respond get called (or call manually)
var
  #code {.threadvar.}: int
  #headers {.threadvar.}: HttpHeaders
  #body {.threadvar.}: string
  #request {.threadvar.}:Request
  respondProc: RespondProc
  log: LogProc


## source code transformation
macro pharaoInit(): untyped =
  result = transformedSource["init"]
  #echo "TRANSFORMED SOURCE INIT"
  #echo result.treeRepr

macro pharaoRequestBody(): untyped =
  result = transformedSource["requestBody"]
  #echo "TRANSFORMED SOURCE REQUEST PROC"
  #echo result.treeRepr

## some tools

proc debug(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(DebugLevel, message)
proc info(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(InfoLevel, message)
proc error(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(ErrorLevel, message)

# dummy vars
# just so the imports macro can include sourcePath
# in this scope to process the imports
var
  code: int
  headers: HttpHeaders
  body: string
  request: Request

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

filterImportsOnly(includePharaoSource)

proc pharaoRequest*(request: Request) {.exportc,dynlib.} =
  var
    code = 200
    headers = @{"Content-Type":"text/html"}.HttpHeaders
    body = ""

  proc respond() =
    respondProc(request, code, headers, body)

  filterNoImports(includePharaoSource())

  if not request.responded:
    respond()

## init defaults

##b now include the actual code body
#[
block local:
  var
    code: int
    headers: HttpHeaders
    body: string
  code = 200
  body = ""
  headers = @{"Content-Type":"text/html"}.HttpHeaders
  template echo(x: varargs[string, `$`]) =
    for s in x:
      body.add s
    body.add "\n" 
  entomb(pharaoSourcePath)
]#

## more dynlib interface
proc pharaoInit(respondProcArg: RespondProc, logProc: LogProc) {.exportc,dynlib.} =
  respondProc = respondProcArg
  log = logProc
  assert not respondProc.isNil, "Empty responder received"
  assert not logProc.isNil, "Empty logger received"

