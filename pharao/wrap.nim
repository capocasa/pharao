
## Pharao dynamic library.
#
# This is compiled to a dynamic library by the pharao server
# when a source file is updated. It provides the library
# interface to receive the request from the server and send the
# response, and some variables and utilities as an interface for the source file.
#

import
  std/[macros],
  ./common

from mummy import Request, HttpHeaders, responded

import mummy/fileloggers

when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

when appType != "lib":
  {.error: "Pharaoh dynamic library must be compiled with params '--app:lib'"}

## set the include file passed from server at dynamic lib compile time
const pharaoSourcePath {.strdefine: "pharao.sourcePath".} = ""
when pharaoSourcePath == "":
  {.error: "Pharaoh dynamic library requires a --d:sourcePath, usually the pharoh server will take care of that for you".}

macro entomb(path: static[string]): untyped =
  # just generates an include statement but 'entomb' sounds cooler
  newNimNode(nnkIncludeStmt).add(newIdentNode(path))

## dynlib basic init

# sets up GC but does not exececute main module
proc PreMain() {.cdecl, importc.}
proc NimMainModule() {.cdecl, importc.}
proc library_init() {.exportc, dynlib, cdecl.} =
  PreMain() 
  discard
proc library_deinit() {.exportc, dynlib, cdecl.} =
  GC_FullCollect()
  discard

## local interface

# using pharao is reading and setting these variables,
# and letting respond get called (or call manually)
var
  code {.threadvar.}: int
  headers {.threadvar.}: HttpHeaders
  body {.threadvar.}: string
  request {.threadvar.}:Request
  respondProc: RespondProc
  logger: FileLogger

proc respond() =
  respondProc(request, code, headers, body)

## some tools

proc pharaoRequest*(requestArg: Request) {.exportc,dynlib.} =
  # set defaults
  request = requestArg
  NimMainModule()

template echo(x: varargs[string, `$`]) =
  for s in x:
    body &= s
  body &= "\n"

## init defaults

code = 200
body = ""
headers = @{"Content-Type":"text/html"}.HttpHeaders

## now include the actual code body

entomb(pharaoSourcePath)

## main dynlib interface
proc pharaoInit(respondProcArg: RespondProc, logFile: File) {.exportc,dynlib.} =
  respondProc = respondProcArg
  assert not respondProc.isNil, "Empty responder received"
  logger = newFileLogger(logFile)
  stdout = logFile
  when compiles(init()):
    init()

# and automatically send it if it wasn't already

if not request.responded:
  respond()

