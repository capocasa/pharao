
when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

import
  std/[os, osproc, parseopt,envvars,strutils,paths,tables,dynlib,times,strscans,locks],
  mummy, mummy/fileloggers,
  pharao/common

## shared code

## Pharao server
when isMainModule and appType == "console":
  type
    PharaoRouteObj = object
      path: string
      libHandle: LibHandle
      libModificationTime: Time
      requestProc: RequestProc
      lock: Lock
    PharaoRoute = ref PharaoRouteObj
        
  proc newPharaoRoute(path: string): PharaoRoute =
    new(result)
    result.path = path
    result.lock.initLock

  # pharao server
  # handle requests, compile .nim file in web root to dynlib and load

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
    initProc(respond, nil)
    route.libModificationTime = dynlibPath.getLastModificationTime

  proc usage() =
    echo "Invalid option or argument, run with optoin --help for more information"
    quit(1)

  proc init() =

    let port = getEnv("PHARAOH_PORT", "2347").parseInt.Port
    let host = getEnv("PHARAOH_HOST", "localhost")
    let wwwRoot = getEnv("PHARAOH_WWW_ROOT", "/var/www")
    let dynlibRoot = getEnv("PHARAOH_DYNLIB_PATH", "lib")
    let nimCmd = getEnv("PHARAOH_NIM_PATH", "nim")
    let nimCachePath = getEnv("PHARAOH_NIM_CACHE", "cache")
    let outputErrors = getEnv("PHARAOH_OUTPUT_ERRORS", "true").parseBool
    let logErrors = getEnv("PHARAOH_LOG_ERRORS", "true").parseBool

    let logger = newFileLogger(stdout)

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

PHARAOH_PORT             2347
PHARAOH_HOST             localhost
PHARAOH_WWW_ROOT         /var/www
PHARAOH_DYNLIB_ROOT      [working directory]/lib
PHARAOH_NIM_PATH         nim
PHARAOH_NIM_CACHE        [working directory]/cache
PHARAOH_OUTPUT_ERRORS    true
PHARAOH_LOG_ERRORS       true

"""
            quit(0)

      of cmdArgument:
        usage()

    var routes: Table[string, PharaoRoute]

    createDir(dynlibRoot)

    const DynlibPattern = DynlibFormat.replace("$1", "$+")


    ## load existing dynlibs into routes on startup
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
            logger.error(e.msg)
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
            logger.debug(output)
          else:
            route.lock.release
            request.respond(500, defaultHeaders, if outputErrors: output else: "internal server error")
            if logErrors:
              logger.error(output)
            return
          try:
            route.initLibrary(dynlibPath)
          except LibraryError as e:
            route.lock.release
            request.respond(500, defaultHeaders, if outputErrors: e.msg else: "internal server error")
            if logErrors:
              logger.error(e.msg)
            return
        route.lock.release
        route.requestProc(request)
        if not request.responded:
          request.respond(503, defaultHeaders, "unavailable")
      else:
        request.respond(404, defaultHeaders, "not found")

    let server = newServer(handler)
    server.serve(port, host)

  init()

