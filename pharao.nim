
when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

import
  std/[os, osproc, parseopt,envvars,strutils,paths,tables,dynlib,times,strscans,locks,strformat],
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

  let port = getEnv("PHARAO_PORT", "2347").parseInt.Port
  let host = getEnv("PHARAO_HOST", "localhost")
  let wwwRoot = getEnv("PHARAO_WWW_ROOT", "/var/www")
  let dynlibRoot = getEnv("PHARAO_DYNLIB_PATH", "lib")
  let nimCmd = getEnv("PHARAO_NIM_PATH", "nim")
  let nimCachePath = getEnv("PHARAO_NIM_CACHE", "cache")
  let outputErrors = getEnv("PHARAO_OUTPUT_ERRORS", "true").parseBool
  let logErrors = getEnv("PHARAO_LOG_ERRORS", "true").parseBool
  let logFile = getEnv("PHARAO_LOG_FILE", "-")
  let (logInfo, logDebug) = case getEnv("PHARAO_LOG_LEVEL", "DEBUG"):
    of "DEBUG":
      (true, true)
    of "INFO":
      (true, false)
    of "ERROR":
      (false, false)
    else:
      echo "Invalid PHARAO_LOG_LEVEL, must be DEBUG, INFO or ERROR"
      quit(2)

  let logDateTimePattern = getEnv("PHARAO_LOG_DATETIME_PATTERN", "yyyy-MM-dd'T'HH:mm:sszzz")
  let logPattern = getEnv("PHARAO_LOG_PATTERN", "[$1 $2] $3") & "\n"
  let logger = newFileLogger(if logFile == "-": stdout else: logFile.open(fmAppend))

  proc usage() =
    echo "Invalid option or argument, run with optoin --help for more information"
    quit(1)

  for kind, key, val in getopt():
    case kind
    of cmdEnd:
      break
    of cmdShortOption:
      usage()
    of cmdLongOption:
      case key:
        of "help":
          if val != "":
            usage()
          echo """
Usage: pharao

Starts a web server that will compile and execute Nim files in a web
root directory and serve the result.

Configuration by environment variable:

Variable              Default value

PHARAO_PORT             2347
PHARAO_HOST             localhost
PHARAO_WWW_ROOT         /var/www
PHARAO_DYNLIB_ROOT      [working directory]/lib
PHARAO_NIM_PATH         nim
PHARAO_NIM_CACHE        [working directory]/cache
PHARAO_OUTPUT_ERRORS    true
PHARAO_LOG_ERRORS       true

"""
          quit(0)

    of cmdArgument:
      usage()
  
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

  proc error(message: string) =
    log(ErrorLevel, message)
  proc info(message: string) =
    log(InfoLevel, message)
  proc debug(message: string) =
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
    initProc(respond, log)
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
        route.initLibrary(dynlibPath)
      except LibraryError as e:
        if logErrors:
          log(ErrorLevel, e.msg)
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
        let (dir, name, ext) = request.path.splitFile
        
        let dynlibPath = dynlibRoot / request.path.parentDir / DynlibFormat % request.path.lastPathPart
        createDir(dynlibPath.parentDir)

        # compile the source.
        #

        if not route.libHandle.isNil:
          route.libHandle.unloadLib
          route.libHandle = nil
        let cmd = "$1 c --nimcache:$2 --app:lib --d:useMalloc --noMain --d:pharao.sourcePath=$3 -o:$4 -" % [nimCmd, nimCachePath, sourcePath, dynlibPath]
        let (output, exitCode) = execCmdEx(cmd, input="include pharao/wrap")
        if exitCode == 0:
          log(DebugLevel, output)
        else:
          route.lock.release
          request.respond(500, defaultHeaders, if outputErrors: output else: "internal server error")
          if logErrors:
            log(ErrorLevel, output)
          return
        try:
          route.initLibrary(dynlibPath)
        except LibraryError as e:
          route.lock.release
          request.respond(500, defaultHeaders, if outputErrors: e.msg else: "internal server error")
          if logErrors:
            log(ErrorLevel, e.msg)
          return
      route.lock.release
      route.requestProc(request)
      if not request.responded:
        request.respond(503, defaultHeaders, "unavailable")
    else:
      request.respond(404, defaultHeaders, "not found")

  let server = newServer(handler)
  server.serve(port, host)

when isMainModule and appType == "console":
  initPharaoServer()

