
when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

import
  std/[os, osproc, parseopt,envvars,strutils,tables,dynlib,times,strscans,locks,strtabs,streams,parsecfg],
  mummy, mummy/fileloggers,
  pharao/common

type
  PharaoRouteObj = object
    path: string
    libHandle: LibHandle
    libModificationTime: Time
    requestProc: RequestProc
    lock: Lock
  PharaoRoute = ref PharaoRouteObj

# pharao server
# handle requests, compile .nim file in web root to dynlib and load

proc initPharaoServer() =

  proc usage() =
    stderr.write "Invalid option or argument, run with option --help for more information\n"
    quit(1)

  proc help() =
    echo """
Usage: pharao [options]

Starts a web server that will compile and execute Nim files in a web
root directory and serve the result.

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

  let logDateTimePattern = byEnv("PHARAO_LOG_DATETIME_PATTERN", "yyyy-MM-dd'T'HH:mm:sszzz")
  let logPattern = byEnv("PHARAO_LOG_PATTERN", "[$1 $2] $3") & "\n"

  let logger = newFileLogger(if logFile == "-": stdout else: logFile.open(fmAppend))
 
  ## server utility procs

  proc newPharaoRoute(path: string): PharaoRoute =
    new(result)
    result.path = path
    result.lock.initLock

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
      formattedMessage.add logPattern % [now().format(logDateTimePattern), $level, line]
    logger.log(level, formattedMessage[0..^2])

  proc error(message: string) {.hint[XDeclaredButNotUsed]: off.} =
    log(ErrorLevel, message)
  proc info(message: string) {.hint[XDeclaredButNotUsed]: off.} =
    log(InfoLevel, message)
  proc debug(message: string) {.hint[XDeclaredButNotUsed]: off.} =
    log(DebugLevel, message)

  proc initLibrary(route: var PharaoRoute, dynlibPath: string) =
    route.libHandle = loadLib(dynlibPath)
    if route.libHandle.isNil:
      raise newException(LibraryError, "dynamic library $1 could not be loaded for path" % [dynlibPath, route.path])
    route.requestProc = cast[RequestProc](route.libHandle.symAddr("pharaoRequest"))
    if route.requestProc.isNil:
      raise newException(LibraryError, "dynamic library $1 has no pharaoRequest, not loading route for path $2" % [dynlibPath, route.path])

    let initProc = cast[InitProc](route.libHandle.symAddr("pharaoInit"))
    if initProc.isNil:
      raise newException(LibraryError, "dynamic library $1 has no pharaoInit, not loading route for path $2" % [dynlibPath, route.path])
    initProc(respond, log, stdout, stderr, stdin)
    route.libModificationTime = dynlibPath.getLastModificationTime

  var routes: Table[string, PharaoRoute]

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
        error(e.msg)
      routes[path] = route

  proc handler(request: Request) =
    let sourcePath = wwwRoot / request.path
    let defaultHeaders = @{"Content-Type": "text/plain"}.HttpHeaders
    if fileExists(sourcePath):

      var route = routes.mgetOrPut(request.path, newPharaoRoute(request.path))

      # lock route (but now other routes) during entire compilation. could possibly be optimized
      # in several ways but unsure whether any of them are good idea
      route.lock.acquire
      if route.libModificationTime < sourcePath.getLastModificationTime:
        let dynlibPath = dynlibRoot / request.path.parentDir / DynlibFormat % request.path.lastPathPart
        createDir(dynlibPath.parentDir)

        # compile the source.
        #

        # unload previous program
        if not route.libHandle.isNil:
          let deinitProc = cast[DeinitProc](route.libHandle.symAddr("pharaoDeinit"))
          if deinitProc.isNil:
            error("dynamic library $1 has no pharaoDeinit, unloading without cleanup for path $2" % [dynlibPath, route.path])
          else:
            deinitProc()
          route.libHandle.unloadLib
          route.libHandle = nil
        let cmd = "$1 c $2 --nimcache:$3 --app:lib --d:useMalloc --d:pharao.sourcePath=$4 -o:$5 -" % [nimCmd, nimArgs, nimCachePath, sourcePath, dynlibPath]
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
          request.respond(500, defaultHeaders, if outputErrors: output else: "internal server error\n")
          error(output)
          return
        try:
          debug("Loading $1" % dynlibPath)
          route.initLibrary(dynlibPath)
        except LibraryError as e:
          route.lock.release
          request.respond(500, defaultHeaders, if outputErrors: e.msg else: "internal server error\n")
          error(e.msg)
          return
      route.lock.release
      route.requestProc(request)
      if not request.responded:
        error("Internal error, no request response from $1" % request.path)
        request.respond(503, defaultHeaders, "unavailable\n")

    else:
      request.respond(404, defaultHeaders, "not found\n")
    info($request)

  let server = newServer(handler)
  info("Pharao $1 wrapped to $2:$3" % [wwwRoot, host, $port.int])
  server.serve(port, host)

when isMainModule and appType == "console":
  initPharaoServer()

