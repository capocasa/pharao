
## Pharao dynamic library.
#
# This is compiled to a dynamic library by the pharao server
# when a source file is updated. It provides the library
# interface to receive the request from the server and send the
# response, and some variables and utilities as an interface for the source file.
#

import
  std/[strutils,dynlib,times,macros],
  mummy,
  ./common

when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

when appType != "lib":
  {.error: "Pharaoh dynamic library must be compiled with params '--app:lib'"}

# set the include file passed from server at dynamic lib compile time
const sourcePath {.strdefine: "pharaoh.sourcePath".} = ""
when sourcePath == "":
  {.error: "Pharaoh dynamic library requires a source path, please let pharoh server compile it".}



# this is an include with a string for the file name
proc noImports(stmts: NimNode): NimNode =
  result = newStmtList()
  for stmt in stmts:
    if stmt.kind != nnkImportStmt:
      result.add(stmt)

proc importsOnly(stmts: NimNode): NimNode =
  result = newStmtList()
  for stmt in stmts:
    if stmt.kind == nnkImportStmt:
      result.add(stmt)

macro entomb(): untyped =
  noImports(parseStmt(readFile(sourcePath), sourcePath))

macro preEntomb(): untyped =
  importsOnly(parseStmt(readFile(sourcePath), sourcePath))

#macro dynamicInclude(): untyped =
#  newNimNode(nnkIncludeStmt).add(newIdentNode(sourcePath))

# dynlib interface
proc NimMain() {.cdecl, importc.}
proc library_init() {.exportc, dynlib, cdecl.} =
  NimMain()
proc library_deinit() {.exportc, dynlib, cdecl.} =
  GC_FullCollect()

preEntomb()

proc request*(request: Request, respondProc: RespondProc) {.exportc, dynlib.} =
  var
    code = 200
    headers = @{"Content-Type":"text/html"}.HttpHeaders
    body = "" 

  # local interface
  proc respond() =
    respondProc(request, code, headers, body)
  
  template echo(x: varargs[string, `$`]) =
    body &= x.join

  entomb()

  if not request.responded:
    respond()


