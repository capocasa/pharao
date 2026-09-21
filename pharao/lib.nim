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
  webby/urls,
  scf

import macros except body, error

## version, passed from pharao server at compile time
const pharaoVersion* {.strdefine: "pharaoVersion".} = "0.0.0"

proc pharaoGetVersion*(): cstring {.exportc, dynlib.} =
  pharaoVersion

## basic compile assertions

when appType != "lib":
  {.error: "Pharaoh dynamic library must be compiled with params '--app:lib'"}

## set the include file passed from server at dynamic lib compile time
const pharaoSourcePath {.strdefine: "pharao.sourcePath".} = ""
when pharaoSourcePath == "":
  {.error: "Pharaoh dynamic library requires a --d:sourcePath, usually the pharoh server will take care of that for you".}

## web root, passed from server so import and include paths resolve the
## way nim resolves them with the web root on its search path
const pharaoWwwRoot {.strdefine: "pharaoWwwRoot".} = ""

# sets up GC and run main module on library init

## library specific state

import ./tools

const pharaoSourceCache = CacheTable"pharaoSource"
const pharaoSourceDir = pharaoSourcePath.parentDir

# Parse as untyped AST so variables are resolved in function scope,
# not module scope. This prevents user vars from becoming shared globals.
# Source code filters (#? stdtmpl) are transformed via scf package first.
# Include statements that resolve to a local file are spliced in
# recursively, so includes work relative to the source file and SCF
# files get filtered. Every file read this way, and every local module
# reachable through local imports, is recorded as a dependency for the
# server's reload check.
macro cachePharaoSource() =
  let rawSource = staticRead(pharaoSourcePath)
  # Transform SCF syntax to valid Nim if needed
  let sourceCode = if rawSource.startsWith("#?"):
                     filterStdTmplAuto(rawSource)
                   else:
                     rawSource
  let ast = parseStmt(sourceCode)
  var
    imports = newStmtList()
    requestBody = newStmtList()
    deps = @[pharaoSourcePath]

  # reconstruct the path text of an import or include argument
  proc pathOf(n: NimNode): string =
    case n.kind
    of nnkIdent, nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      n.strVal
    of nnkInfix:
      if n.len == 3: pathOf(n[1]) & "/" & pathOf(n[2]) else: ""
    of nnkPrefix:
      if n.len == 2: pathOf(n[0]) & pathOf(n[1]) else: ""
    else:
      ""

  # Resolve an import or include argument to a local file the way nim
  # does with the web root on its search path: relative to the
  # importing file first, then the web root. std/ paths never resolve
  # locally, nim treats them as standard library only
  proc findLocal(baseDir: string, n: NimNode): string =
    result = ""
    let p = pathOf(n)
    if p == "" or p == "std" or p.startsWith("std/"):
      return
    let withExt = if p.endsWith(".nim"): p else: p & ".nim"
    if withExt.isAbsolute:
      if fileExists(withExt):
        result = withExt
    else:
      for base in [baseDir, pharaoWwwRoot]:
        if base != "" and fileExists(base / withExt):
          result = base / withExt
          return

  proc readStatements(path: string): NimNode =
    let raw = staticRead(path)
    let code = if raw.startsWith("#?"): filterStdTmplAuto(raw) else: raw
    parseStmt(code)

  # record a local module as dependency and follow its own local
  # imports and includes. no rewriting here, nim compiles this module
  # on its own. unparseable modules are only recorded, nim reports the
  # error when it compiles them
  proc walkDeps(deps: var seq[string], path: string) =
    if path in deps:
      return
    deps.add path
    let moduleAst = try: readStatements(path) except CatchableError: nil
    if moduleAst.isNil:
      return
    for n in moduleAst:
      if n.kind in {nnkImportStmt, nnkIncludeStmt}:
        for i in 0..<n.len:
          let f = findLocal(path.parentDir, n[i])
          if f != "":
            walkDeps(deps, f)
      elif n.kind in {nnkFromStmt, nnkImportExceptStmt}:
        # only the first child is a module path, the rest are symbols
        let f = findLocal(path.parentDir, n[0])
        if f != "":
          walkDeps(deps, f)

  proc processStmts(imports, requestBody: var NimNode, deps: var seq[string],
                    stmts: NimNode, baseDir: string) =
    for n in stmts:
      if n.kind in {nnkImportStmt, nnkImportExceptStmt, nnkFromStmt}:
        var r = n.copyNimTree()
        # all children of an import statement are module paths, from
        # and import except statements carry the module in the first
        let indices = if n.kind == nnkImportStmt: 0..<r.len else: 0..0
        for i in indices:
          if r[i].kind in {nnkIdent, nnkStrLit, nnkInfix, nnkPrefix}:
            let f = findLocal(baseDir, r[i])
            if f != "":
              walkDeps(deps, f)
              # resolve local module to absolute path so nim finds it
              r[i] = newStrLitNode(f.changeFileExt(""))
        imports.add r
      elif n.kind == nnkIncludeStmt:
        # splice local includes in, non local ones are left for nim to
        # resolve through its search path
        var keep = newNimNode(nnkIncludeStmt)
        for i in 0..<n.len:
          let f = findLocal(baseDir, n[i])
          if f == "":
            keep.add n[i]
          elif f notin deps:
            deps.add f
            processStmts(imports, requestBody, deps, readStatements(f),
                         f.parentDir)
        if keep.len > 0:
          requestBody.add keep
      else:
        requestBody.add n

  processStmts(imports, requestBody, deps, ast, pharaoSourceDir)
  pharaoSourceCache["imports"] = imports
  pharaoSourceCache["requestBody"] = requestBody
  pharaoSourceCache["deps"] = newLit(deps.join("\n"))

cachePharaoSource()

macro pharaoSourceImports(): untyped =
  result=pharaoSourceCache["imports"]

macro pharaoSourceRequestBody(): untyped =
  result=pharaoSourceCache["requestBody"]

macro pharaoSourceDeps(): untyped =
  result=pharaoSourceCache["deps"]

pharaoSourceImports()

## dependency files of this library, newline separated absolute paths,
## the server checks them to decide when to recompile
proc pharaoGetDeps*(): cstring {.exportc, dynlib.} =
  pharaoSourceDeps()


## dynlib interface

# status page presets, armed by the server right before a request runs
# so an error.nim can render code and detail without extra ceremony
var
  presetArmed {.threadvar.}: bool
  presetCode {.threadvar.}: int
  presetBody {.threadvar.}: string

proc pharaoPreset*(codeArg: cint, bodyArg: cstring, bodyArgLen: cint) {.exportc,dynlib.} =
  presetArmed = true
  presetCode = codeArg.int
  presetBody = newString(bodyArgLen)
  if bodyArgLen > 0:
    copyMem(addr presetBody[0], bodyArg, bodyArgLen)

# main request proc
proc pharaoRequest*(requestArg: Request) {.exportc,dynlib.} =

  # requests run on web server worker threads the library never created,
  # each one needs its thread-local allocator set up before allocating
  # (no-op under useMalloc, kept so non-useMalloc compiles stay safe)
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  # init request vars, error page requests start with code and body preset
  request = requestArg
  code = if presetArmed: presetCode else: 200
  headers = @{"Content-Type":"text/html; charset=utf-8"}.HttpHeaders
  body = if presetArmed: presetBody else: ""
  presetArmed = false
  presetBody = ""
  presetCode = 0

  # interface func to respond
  # manually to continue execution
  # after completed request

  ## Write user supplied code, minus imports
  try:
    pharaoSourceRequestBody()
  except:
    let e = getCurrentException()
    error(e.msg)
    if not errorProc.isNil:
      # the server handles the response, usually with an error.nim page
      errorProc(request, 500.cint, e.msg.cstring, e.msg.len.cint)
    else:
      code = 500
      body = e.msg
      respond()

  # autorespond if not responded yet
  if not request.responded:
    respond()

# Initialization hook, called by pharao on loading library to
# provide callables. Data could be provided too.
proc pharaoInit(respondProcArg: RespondProc, logProcArg: LogProc, errorProcArg: ErrorProc, stdoutArg, stderrArg, stdinArg: File) {.exportc,dynlib.} =
  proc NimMain() {.cdecl, importc.}
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  respondProc = respondProcArg
  log = logProcArg
  errorProc = errorProcArg
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
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  GC_FullCollect()

