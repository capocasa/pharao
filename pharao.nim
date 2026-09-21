when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

import
  std/[os, osproc, parseopt,envvars,strutils,sharedtables,dynlib,times,strscans,locks,strtabs,streams,parsecfg],
  mummy, mummy/fileloggers,
  pharao/common

const NimblePkgVersion {.strdefine.} = "0.0.0"

type
  PharaoRouteObj = object
    path: string
    libHandle: LibHandle
    libModificationTime: Time
    libVersion: string
    deps: seq[string]
    requestProc: RequestProc
    presetProc: PresetProc
    lock: Lock
    refCount: int
    cond: Cond
  PharaoRoute = ptr PharaoRouteObj

# pharao server
# handle requests, compile .nim file in web root to dynlib and load

proc initPharaoServer() =

  proc usage() =
    stderr.write "Invalid option or argument, run with option --help for more information\n"
    quit(1)

  proc version() =
    echo "pharao " & NimblePkgVersion
    quit(0)

  proc help() =
    echo """
Usage: pharao [options]

Starts a web server that will compile and execute Nim files in a web
root directory and serve the result.

-v, --version           Show version
-h, --help              Show this help
-p, --port:PORT         Set port
-H, --host:HOST         Set host
-W, --www-root:WWWROOT   Set the web root
-e, --env:ENV           Set an environment file

The following environment variables are read for configuration.

Variable              Default value

PHARAO_PORT                  2347                         The port to listen on
PHARAO_HOST                  localhost                    The host to bind to
PHARAO_WWW_ROOT              /var/www                     The web root
PHARAO_DYNLIB_PATH           lib                          Compiled code path
PHARAO_NIM_COMMAND           nim                          Nim command
PHARAO_NIM_ARGS                                           Additional compiler arguments
PHARAO_NIM_CACHE             cache                        Nim cache directory
PHARAO_OUTPUT_ERRORS         true                         Add errors to response body
PHARAO_LOG_ERRORS            true                         Add errors to log file
PHARAO_LOG_FILE              -                            Log file path or - for stdout
PHARAO_LOG_LEVEL             DEBUG                        Minimum level to log, DEBUG INFO or ERROR
PHARAO_LOG_DATETIME_PATTERN  yyyy-MM-dd'T'HH:mm:sszzz     Nim datetime format pattern for log
PHARAO_LOG_PATTERN           [$1 $2] $3                   Log format with $1 date, $2 level, $3 message
PHARAO_MAX_BODY_LEN          134217728                    Maximum request body size in bytes (128 MB)
PHARAO_ERROR_PAGE            error.nim                    Error page file, a filename cascades up to the web root, a path starting with / is fixed

Option takes precedence before environment value from file before environment.

"""
    quit(0)

  proc badconf(file: string, line: int) =
    stderr.write "The syntax in environment file $1 on line $2 is invalid\n" % [file, $line]
    quit(1)

  var port = 0.Port
  var host = ""
  var wwwRoot = ""
  var envFile = ""

  for kind, key, val in getopt():
    case kind
    of cmdEnd:
      break
    of cmdShortOption:
      case key:
      of "v":
        version()
      of "h":
        if val != "":
          usage()
        help()
      of "H":
        if val == "":
          usage()
        host = val
      of "p":
        if val == "":
          usage()
        port = val.parseInt.Port
      of "W":
        if val == "":
          usage()
        wwwRoot = val
      of "e":
        if val == "":
          usage()
        envFile = val
      else:
        usage()
    of cmdLongOption:
      case key:
      of "version":
        version()
      of "help":
        if val != "":
          usage()
        help()
      of "host":
        if val == "":
          usage()
        host = val
      of "port":
        if val != "":
          usage()
        port = val.parseInt.Port
      of "www-root":
        if val == "":
          usage()
        wwwRoot = val
      of "env":
        if val == "":
          usage()
        envFile = val
      else:
        usage()
    of cmdArgument:
      usage()

 
  if envFile == "":
    envFile = ".env"
 
  proc loadEnvFile(envFile: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    if not fileExists(envFile):
      return
    # use parts of the config parser for our env file
    # just error out on unsupported config parts
    var f = newFileStream(envFile, fmRead)
    var p: CfgParser
    open(p, f, envFile)
    while true:
      var e = next(p)
      case e.kind:
      of cfgEof:
        f.close
        break
      of cfgSectionStart,cfgOption,cfgError:
        f.close
        badconf(envFile, p.getLine)
      of cfgKeyValuePair:
        result[e.key] = e.value

  let env = loadEnvFile(envFile)
 
  proc byEnv(key: string, default: string): string =
    env.getOrDefault(key, getEnv(key, default))

  if port.int == 0:
    port = byEnv("PHARAO_PORT", "2347").parseInt.Port
  if host == "":
    host = byEnv("PHARAO_HOST", "localhost")
  if wwwRoot == "":
    wwwRoot = byEnv("PHARAO_WWW_ROOT", "/var/www")
  if not wwwRoot.isAbsolute:
    wwwRoot = getCurrentDir() / wwwRoot

  let dynlibRoot = byEnv("PHARAO_DYNLIB_PATH", "lib")
  let nimCmd = byEnv("PHARAO_NIM_COMMAND", "nim")
  let nimArgs = byEnv("PHARAO_NIM_ARGS", "")
  let nimCachePath = byEnv("PHARAO_NIM_CACHE", "cache")
  let outputErrors = byEnv("PHARAO_OUTPUT_ERRORS", "true").parseBool
  let maxBodyLen = byEnv("PHARAO_MAX_BODY_LEN", "134217728").parseInt
  let logFile = byEnv("PHARAO_LOG_FILE", "-")
  let (logInfo, logDebug) = case byEnv("PHARAO_LOG_LEVEL", "DEBUG"):
    of "DEBUG":
      (true, true)
    of "INFO":
      (true, false)
    of "ERROR":
      (false, false)
    else:
      echo "Invalid PHARAO_LOG_LEVEL, must be DEBUG, INFO or ERROR"
      quit(2)

  # Default to UTC format - Nim's local() timezone uses C's localtime() which
  # is not thread-safe and causes SIGSEGV in mummy's worker threads
  let logDateTimePattern = byEnv("PHARAO_LOG_DATETIME_PATTERN", "yyyy-MM-dd'T'HH:mm:ss'Z'")
  let logPattern = byEnv("PHARAO_LOG_PATTERN", "[$1 $2] $3") & "\n"

  let logger = newFileLogger(if logFile == "-": stdout else: logFile.open(fmAppend))
 
  ## server utility procs

  proc newPharaoRoute(path: string): PharaoRoute =
    result = createShared(PharaoRouteObj)
    result.path = path
    result.lock.initLock
    result.cond.initCond
    result.refCount = 0

  proc `$`(level: LogLevel): string =
    case level
    of DebugLevel:
      "DEBUG"
    of InfoLevel:
      "INFO"
    of ErrorLevel:
      "ERROR"

  proc log(level: LogLevel, message: string) =
    case level:
    of DebugLevel:
      if not logDebug:
        return
    of InfoLevel:
      if not logInfo:
        return
    else:
      discard
    var formattedMessage = ""
    for line in message.splitLines:
      formattedMessage.add logPattern % [now().utc.format(logDateTimePattern), $level, line]
    logger.log(level, formattedMessage[0..^2])

  proc error(message: string) {.hint[XDeclaredButNotUsed]: off.} =
    log(ErrorLevel, message)
  proc info(message: string) {.hint[XDeclaredButNotUsed]: off.} =
    log(InfoLevel, message)
  proc debug(message: string) {.hint[XDeclaredButNotUsed]: off.} =
    log(DebugLevel, message)

  # C-level wrappers for cross-dynlib boundary
  # Dynlib passes C types, host copies into its own Nim strings
  proc respondWrapper(request: Request, code: cint,
                      headerPairs: ptr CHeaderPair, headerCount: cint,
                      bodyPtr: cstring, bodyLen: cint) {.nimcall,gcsafe.} =
    var nimBody = newString(bodyLen)
    if bodyLen > 0:
      copyMem(addr nimBody[0], bodyPtr, bodyLen)
    var nimHeaders: HttpHeaders
    let pairs = cast[ptr UncheckedArray[CHeaderPair]](headerPairs)
    for i in 0..<headerCount:
      var name = newString(pairs[i].nameLen)
      if pairs[i].nameLen > 0:
        copyMem(addr name[0], pairs[i].name, pairs[i].nameLen)
      var value = newString(pairs[i].valueLen)
      if pairs[i].valueLen > 0:
        copyMem(addr value[0], pairs[i].value, pairs[i].valueLen)
      nimHeaders[name] = value
    request.respond(code.int, nimHeaders, nimBody)

  proc logWrapper(level: LogLevel, message: cstring) {.gcsafe.} =
    log(level, $message)

  ## error pages

  proc statusReason(code: int): string =
    case code
    of 404: "Not Found"
    of 500: "Internal Server Error"
    of 503: "Service Unavailable"
    else: "Error"

  proc builtinPage(code: int, detail: string): string =
    result = "$1 $2\n\n" % [$code, statusReason(code)]
    if detail != "":
      result.add detail & "\n\n"
    result.add "pharao/" & NimblePkgVersion & "\n"

  let errorPageEnv = byEnv("PHARAO_ERROR_PAGE", "")

  # Resolve the error page for a request. A PHARAO_ERROR_PAGE starting
  # with / is a fixed page anchored at the web root, a bare filename
  # replaces error.nim and still cascades up to the web root.
  proc resolveErrorPage(requestPath: string): string =
    if errorPageEnv.startsWith("/"):
      if fileExists(wwwRoot / errorPageEnv):
        return errorPageEnv
      debug("Configured error page $1 not found" % errorPageEnv)
      return ""
    let filename = if errorPageEnv == "": "error.nim" else: errorPageEnv
    var dir = requestPath.parentDir
    if dir == "":
      dir = "/"
    while true:
      let candidate = dir / filename
      if fileExists(wwwRoot / candidate):
        return candidate
      if dir == "/":
        return ""
      dir = dir.parentDir

  var inErrorHandler {.threadvar.}: bool

  var routes: SharedTable[string, PharaoRoute]
  routes.init()

  proc errorResponse(request: Request, code: int, detail: string)
  proc initLibrary(route: var PharaoRoute, dynlibPath: string) {.gcsafe.}

  # a checkout build compiles routes against its own sources: when the
  # directory above the server binary contains pharao/lib.nim, put it on
  # the nim path so no nimble install of pharao is needed
  var nimPathArg = ""
  let sourceRoot = getAppFilename().absolutePath.parentDir.parentDir
  if fileExists(sourceRoot / "pharao/lib.nim"):
    nimPathArg = "--path:" & sourceRoot

  proc runRoute(request: Request, routePath: string,
                presetCode: int, presetBody: string): tuple[ran: bool, detail: string] =
    ## Run the route at routePath, compiling or reloading its dynlib first
    ## if the source changed. Returns ran=false with a detail when compiling
    ## or loading failed without responding.

    # Avoid mgetOrPut here: it evaluates newPharaoRoute eagerly on
    # every call, leaking a createShared chunk, a Lock and a Cond each
    # time the key already exists. Look up first; only allocate+insert
    # when the route is genuinely missing. A first-touch race may have two
    # threads both insert; the loser's route leaks, but this happens at
    # most once per path (vs every request before), so it is negligible.
    var route: PharaoRoute = nil
    routes.withValue(routePath, existing):
      route = existing[]
    if route.isNil:
      route = newPharaoRoute(routePath)
      routes[routePath] = route

    route.lock.acquire

    # wait for in-flight requests before recompiling
    let versionStale = not route.libHandle.isNil and route.libVersion != NimblePkgVersion
    let sourcePath = wwwRoot / routePath
    var sourceChanged = route.libModificationTime < sourcePath.getLastModificationTime
    # includes and local imports
    for dep in route.deps:
      if dep != "" and (not fileExists(dep) or
          route.libModificationTime < dep.getLastModificationTime):
        sourceChanged = true
        break
    if sourceChanged or versionStale:
      while route.refCount > 0:
        route.cond.wait(route.lock)

      let dynlibPath = dynlibRoot / routePath.parentDir / DynlibFormat % routePath.lastPathPart
      createDir(dynlibPath.parentDir)

      # unload previous program
      if not route.libHandle.isNil:
        let deinitProc = cast[DeinitProc](route.libHandle.symAddr("pharaoDeinit"))
        if deinitProc.isNil:
          error("dynamic library $1 has no pharaoDeinit, unloading without cleanup for path $2" % [dynlibPath, route.path])
        else:
          deinitProc()
        route.libHandle.unloadLib
        route.libHandle = nil
      # useMalloc in both server and libraries, per Nim issue #24816: the
      # default allocator segfaults when mummy worker threads foreign to a
      # dynlib's runtime allocate inside it. the web root is deliberately
      # NOT on the search path, its files would shadow nimble packages
      let cmd = "$1 c $2 $3 --d:useMalloc --nimcache:$4 --app:lib --d:pharao.sourcePath=$5 --d:pharaoVersion=$6 --d:pharaoWwwRoot=$7 -o:$8 -" % [nimCmd, nimArgs, nimPathArg, nimCachePath, sourcePath, NimblePkgVersion, wwwRoot, dynlibPath]
      var env = newStringTable()
      for k, v in envPairs():
        if k notin env:
          env[k] = v
      debug("Source change detected, compiling: $1" % nimCmd)
      let (output, exitCode) = execCmdEx(cmd, input="include pharao/lib")
      if exitCode == 0:
        log(DebugLevel, output)
      else:
        route.lock.release
        error(output)
        return (false, output)
      try:
        debug("Loading $1" % dynlibPath)
        route.initLibrary(dynlibPath)
      except LibraryError as e:
        if not route.libHandle.isNil:
          route.libHandle.unloadLib
          route.libHandle = nil
        route.lock.release
        error(e.msg)
        return (false, e.msg)

    # increment refcount before releasing lock and executing
    inc route.refCount
    route.lock.release

    if presetCode > 0:
      route.presetProc(presetCode.cint, presetBody.cstring, presetBody.len.cint)

    try:
      route.requestProc(request)
    finally:
      route.lock.acquire
      dec route.refCount
      route.cond.signal
      route.lock.release

    (true, "")

  proc errorResponse(request: Request, code: int, detail: string) =
    ## Respond via the configured error page with code and a builtin page
    ## prefilled into it, falling back to the builtin page itself.
    let detail = if code == 500 and not outputErrors: "" else: detail
    let page = builtinPage(code, detail)
    if inErrorHandler:
      # the error page itself failed, respond builtin instead of recursing
      request.respond(code, @{"Content-Type": "text/plain"}.HttpHeaders, page)
      return
    let errorRoutePath = resolveErrorPage(request.path)
    if errorRoutePath == "":
      request.respond(code, @{"Content-Type": "text/plain"}.HttpHeaders, page)
      return
    debug("Handling $1 with error page $2" % [$code, errorRoutePath])
    inErrorHandler = true
    try:
      let (ran, errDetail) = runRoute(request, errorRoutePath, code, page)
      if not ran and errDetail != "":
        error(errDetail)
    finally:
      inErrorHandler = false
    if not request.responded:
      request.respond(code, @{"Content-Type": "text/plain"}.HttpHeaders, page)

  # C-level wrapper for cross-dynlib boundary
  proc errorWrapper(request: Request, code: cint,
                    message: cstring, messageLen: cint) {.gcsafe.} =
    var messageStr = newString(messageLen)
    if messageLen > 0:
      copyMem(addr messageStr[0], message, messageLen)
    errorResponse(request, code.int, messageStr)

  proc initLibrary(route: var PharaoRoute, dynlibPath: string) {.gcsafe.} =
    route.libHandle = loadLib(dynlibPath)
    if route.libHandle.isNil:
      raise newException(LibraryError, "dynamic library $1 could not be loaded for path" % [dynlibPath, route.path])

    # Check version before full initialization (safe to call before NimMain,
    # returns a pointer to static string data in the .so)
    let versionProc = cast[VersionProc](route.libHandle.symAddr("pharaoGetVersion"))
    route.libVersion = if not versionProc.isNil: $versionProc() else: ""

    # Dependency files (includes, local imports) the server checks to
    # decide when to recompile. Older libraries without the symbol
    # only track the main source file
    let depsProc = cast[DepsProc](route.libHandle.symAddr("pharaoGetDeps"))
    route.deps = if not depsProc.isNil: ($depsProc()).splitLines else: @[]

    route.requestProc = cast[RequestProc](route.libHandle.symAddr("pharaoRequest"))
    if route.requestProc.isNil:
      raise newException(LibraryError, "dynamic library $1 has no pharaoRequest, not loading route for path $2" % [dynlibPath, route.path])

    route.presetProc = cast[PresetProc](route.libHandle.symAddr("pharaoPreset"))
    if route.presetProc.isNil:
      raise newException(LibraryError, "dynamic library $1 has no pharaoPreset, not loading route for path $2" % [dynlibPath, route.path])

    let initProc = cast[InitProc](route.libHandle.symAddr("pharaoInit"))
    if initProc.isNil:
      raise newException(LibraryError, "dynamic library $1 has no pharaoInit, not loading route for path $2" % [dynlibPath, route.path])
    initProc(respondWrapper, logWrapper, errorWrapper, stdout, stderr, stdin)
    route.libModificationTime = dynlibPath.getLastModificationTime

  ## load existing dynlibs into routes on startup
  createDir(dynlibRoot)
  const DynlibPattern = DynlibFormat.replace("$1", "$+")
  for dynlibPath in walkDirRec(dynlibRoot):
    let dynlibName = dynlibPath.lastPathPart
    var name: string
    if scanf(dynlibName, DynlibPattern, name):
      let path = dynlibPath.parentDir[ dynlibRoot.len .. ^1 ] & DirSep & name
      var route = newPharaoRoute(path)
      try:
        debug("Loading $1" % dynlibPath)
        route.initLibrary(dynlibPath)
      except LibraryError as e:
        # broken or old protocol library, remove so the source recompiles
        error(e.msg)
        if not route.libHandle.isNil:
          route.libHandle.unloadLib
        removeFile(dynlibPath)
        continue
      if route.libVersion != NimblePkgVersion:
        info("Removing stale library $1 (version $2, expected $3)" % [dynlibPath, route.libVersion, NimblePkgVersion])
        route.libHandle.unloadLib
        route.libHandle = nil
        removeFile(dynlibPath)
        continue
      routes[path] = route

  proc handler(request: Request) =
    if fileExists(wwwRoot / request.path):
      let (ran, detail) = runRoute(request, request.path, 0, "")
      if not ran:
        errorResponse(request, 500, detail)
      elif not request.responded:
        error("Internal error, no request response from $1" % request.path)
        errorResponse(request, 503, "")
    else:
      errorResponse(request, 404, "The requested path does not match any route in this web root.")
    info($request)

  let server = newServer(handler, maxBodyLen = maxBodyLen)
  info("Pharao $1 $2 wrapped to $3:$4" % [NimblePkgVersion, wwwRoot, host, $port.int])
  server.serve(port, host)

when isMainModule and appType == "console":
  initPharaoServer()
