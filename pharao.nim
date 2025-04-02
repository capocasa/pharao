
when not defined(useMalloc):
  {.error: "pharao must be compiled with useMalloc (see Nim issue #24816)".}

import
  std/[os, osproc, parseopt,envvars,strutils,paths,dirs,files,tables,dynlib,times,macros,strscans],
  mummy, mummy/routers
export mummy except request, respond

## shared code
type
  RespondProc = proc(request: Request, code: int, headers: sink HttpHeaders, body: sink string) {.nimcall,gcsafe.}
  RequestProc = proc(request: Request, respondProc: RespondProc) {.nimcall,gcsafe.}


## Pharao dynamic library.
#
# This is compiled to a dynamic library by the pharao server
# when a source file is updated. It provides the library
# interface to receive the request from the server and send the
# response, and some variables and utilities as an interface for the source file.
#
when isMainModule and appType == "lib":

  # set the include file passed from server at dynamic lib compile time
  const sourcePath {.strdefine: "pharaoh.sourcePath".} = ""
  when sourcePath == "":
    {.error: "Pharaoh dynamic library requires a source path, please let pharoh server compile it".}
  macro includeFromString(str: static[string]) =
    newNimNode(nnkIncludeStmt).add(newIdentNode(str))

  # dynlib interface
  proc NimMain() {.cdecl, importc.}
  proc library_init() {.exportc, dynlib, cdecl.} =
    NimMain()
  proc library_deinit() {.exportc, dynlib, cdecl.} =
    GC_FullCollect()

  proc request*(request: Request, respondProc: RespondProc) {.exportc, dynlib.} =
    var
      code = 200
      headers = @{"Content-Type":"text/html"}.HttpHeaders
      body = "" 
  
    # local interface
    proc respond() =
      respondProc(request, code, headers, body)

    template add(x: varargs[typed, `$`]) =
      body.add(x)

    includeFromString(sourcePath)

    if not request.responded:
      respond()

## Pharao server
when isMainModule and appType == "console":
  type
    PharaoRouteObj = object
      path: string
      libHandle: LibHandle
      libModificationTime: Time
      requestProc: RequestProc
    PharaoRoute = ref PharaoRouteObj

  # pharao server
  # handle requests, compile .nim file in web root to dynlib and load

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

    for dynlibPath in walkDirRec(dynlibRoot):
      let dynlibName = dynlibPath.lastPathPart
      var name: string
      if scanf(dynlibName, DynlibPattern, name):
        let path = dynlibPath.parentDir[ dynlibRoot.len .. ^1 ] / name
        let route = PharaoRoute(path: path)
        route.libHandle = loadLib(dynlibPath)
        route.requestProc = cast[RequestProc](route.libHandle.symAddr("request"))
        if route.requestProc.isNil:
          stderr.write("Warning: Invalid dynamic library $1, not loading route for path $2" % [dynlibPath, path])
        else:
          route.libModificationTime = dynlibPath.getLastModificationTime
          routes[path] = route

    proc handler(request: Request) =
      let sourcePath = wwwRoot / request.path
      let defaultHeaders = @{"Content-Type": "text/plain"}.HttpHeaders
      if fileExists(sourcePath):

        var route = routes.mgetOrPut(request.path, PharaoRoute(path: request.path))
        if route.libModificationTime < sourcePath.getLastModificationTime:
          let (dir, name, ext) = request.path.splitFile
          let dynlibPath = dynlibRoot / request.path.parentDir / DynlibFormat % request.path.lastPathPart
          createDir(dynlibPath.parentDir)

          # compile the source.
          #

          let cmd = "$# c --nimcache:$# --app:lib --d:useMalloc --d:pharaoh.sourcePath=$# -o:$# $#" % [nimCmd, nimCachePath, sourcePath, dynlibPath, "-"]
          let (output, exitCode) = execCmdEx(cmd, input="include pharao")
          if exitCode != 0:
            request.respond(500, defaultHeaders, output)
            return
          route.libHandle = loadLib(dynlibPath)
          route.requestProc = cast[RequestProc](route.libHandle.symAddr("request"))
          if route.requestProc.isNil:
            let error = "Could not find proc 'request' in $#, please let pharao server compile it\n" % dynlibPath
            route.libHandle.unloadLib
            request.respond(500, defaultHeaders, error)
            return
          route.libModificationTime = dynlibPath.getLastModificationTime

        route.requestProc(request, respond)
      else:
        request.respond(404, defaultHeaders, "not found")

    let server = newServer(handler)
    server.serve(port, host)

  init()

