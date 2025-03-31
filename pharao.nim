
import
  std/[os, osproc, parseopt,envvars,strutils,paths,dirs,files,tables,dynlib,times],
  mummy, mummy/routers
export mummy except request, respond

# shared code
type
  RespondProc = proc(request: Request, code: int, headers: sink HttpHeaders, body: sink string) {.nimcall,gcsafe.}
  RequestProc = proc(request: Request) {.nimcall,gcsafe.}
  InitProc = proc(respondProcArg: RespondProc) {.nimcall,gcsafe.}

# boilerplate to import in .nim file in web root
when not isMainModule:
  
  # dynlib boilerplate
  proc NimMain() {.cdecl, importc.}
  proc library_init() {.exportc, dynlib, cdecl.} =
    NimMain()
  proc library_deinit() {.exportc, dynlib, cdecl.} =
    GC_FullCollect()
 
  #  interface
  var
    respondProc: RespondProc

  proc init(respondProcArg: RespondProc) {.exportc, dynlib.} =
    respondProc = respondProcArg

  proc respond*(request: Request, code: int, headers: sink HttpHeaders, body: sink string) =
    respondProc(request, code, headers, body)

  template entomb*() =
    mixin get, post, put, head, delete, options, patch
    proc request*(request: Request) {.exportc, dynlib.} =
      case request.httpMethod:
      of "GET":
        when compiles(get(request)):
          get(request)
          return
      of "POST":
        when compiles(post(request)):
          post(request)
          return
      of "PUT":
        when compiles(put(request)):
          put(request)
          return
      of "HEAD":
        when compiles(head(request)):
          head(request)
          return
      of "DELETE":
        when compiles(delete(request)):
          delete(request)
          return
      of "OPTIONS":
        when compiles(options(request)):
          options(request)
          return
      of "PATCH":
        when compiles(patch(request)):
          patch(request)
          return

      when compiles(request(request)):
        request(request)
        return
      pharao.respond(request, 405, @{"Content-Type": "text/plain"}.HttpHeaders, "Method not allowed")

when isMainModule:

  type
    PharaoRouteObj = object
      path: string
      requestProc: RequestProc
      libHandle: LibHandle
      libModificationTime: Time
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

    proc handler(request: Request) =
      let sourcePath = wwwRoot / request.path
      let (dir, name, _) = request.path.splitFile
      if fileExists(sourcePath):

        var route = routes.mgetOrPut(request.path, PharaoRoute(path: request.path))
        if route.libModificationTime < sourcePath.getLastModificationTime:
          const dynlibFormat = when defined(windows): "$#.dll" elif defined(macosx): "$#.dylib" else: "lib$#.so"
          let dynlibPath = dynlibRoot / dir / dynlibFormat % name
          createDir(dynlibPath.parentDir)
          let cmd = "$# c --nimcache:$# --app:lib --d:useMalloc -o:$# $#" % [nimCmd, nimCachePath, dynlibPath, sourcePath]
          let (output, exitCode) = execCmdEx(cmd)
          if exitCode != 0:
            request.respond(500, emptyHttpHeaders(), output)
            return
          route.libHandle = loadLib(dynlibPath)
          let init = cast[InitProc](route.libHandle.symAddr("init"))
          init(respond)
          if init.isNil:
            let error = "Could not find proc init in $#, please import module pharao\n" % sourcePath
            route.libHandle.unloadLib
            request.respond(500, emptyHttpHeaders(), error)
            return
          route.requestProc = cast[RequestProc](route.libHandle.symAddr("request"))
          if route.requestProc.isNil:
            let error = "Could not find proc request in $#, please import module pharao\n" % sourcePath
            route.libHandle.unloadLib
            request.respond(500, emptyHttpHeaders(), error)
            return
          route.libModificationTime = dynlibPath.getLastModificationTime
        route.requestProc(request)
      else:
        request.respond(404, emptyHttpHeaders(), "not found")

    let server = newServer(handler)
    server.serve(port, host)

  init()

