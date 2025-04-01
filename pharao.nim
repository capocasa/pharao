
import
  std/[os, osproc, parseopt,envvars,strutils,paths,dirs,files,tables,dynlib,times],
  mummy, mummy/routers
export mummy except request, respond

# shared code
type
  RespondProc = proc(request: Request, code: int, headers: sink HttpHeaders, body: sink string) {.nimcall,gcsafe.}
  RequestProc = proc(request: Request) {.nimcall,gcsafe.}
  InitProc = proc(respondProcArg: RespondProc) {.nimcall,gcsafe.}

# This is like a custom pragma {.pragma: .} but those can't be imported from other modules 
template entomb(body: untyped) =
  {.push exportc, dynlib, nimcall, gcsafe .}
  body
  {.pop.}

# boilerplate to import in .nim file in web root
when not isMainModule:
  # simpler pragma

  # dynlib interface
  proc NimMain() {.cdecl, importc.}
  proc library_init() {.exportc, dynlib, cdecl.} =
    NimMain()
  proc library_deinit() {.exportc, dynlib, cdecl.} =
    GC_FullCollect()
  
  proc init(respondProc: RespondProc) {.entomb.} =
    respond = respondProc
 
  #  interface
  var
    respond*: RespondProc


  #proc respond*(request: Request, code: int, headers: sink HttpHeaders, body: sink string) =
  #  respondProc(request, code, headers, body)

when isMainModule:

  type
    PharaoRouteObj = object
      path: string
      libHandle: LibHandle
      libModificationTime: Time
      getProc: RequestProc
      postProc: RequestProc
      headProc: RequestProc
      optionsProc: RequestProc
      putProc: RequestProc
      deleteProc: RequestProc
      patchProc: RequestProc
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

    proc handler(request: Request) =
      let sourcePath = wwwRoot / request.path
      let (dir, name, _) = request.path.splitFile
      let defaultHeaders = @{"Content-Type": "text/plain"}.HttpHeaders
      if fileExists(sourcePath):

        var route = routes.mgetOrPut(request.path, PharaoRoute(path: request.path))
        if route.libModificationTime < sourcePath.getLastModificationTime:
          const dynlibFormat = when defined(windows): "$#.dll" elif defined(macosx): "$#.dylib" else: "lib$#.so"
          let dynlibPath = dynlibRoot / dir / dynlibFormat % name
          createDir(dynlibPath.parentDir)
          let cmd = "$# c --nimcache:$# --app:lib --d:useMalloc -o:$# $#" % [nimCmd, nimCachePath, dynlibPath, sourcePath]
          let (output, exitCode) = execCmdEx(cmd)
          if exitCode != 0:
            request.respond(500, defaultHeaders, output)
            return
          route.libHandle = loadLib(dynlibPath)
          let init = cast[InitProc](route.libHandle.symAddr("init"))
          init(respond)
          if init.isNil:
            let error = "Could not find proc init in $#, please import module pharao\n" % sourcePath
            route.libHandle.unloadLib
            request.respond(500, defaultHeaders, error)
            return
          route.getProc = cast[RequestProc](route.libHandle.symAddr("get"))
          route.postProc = cast[RequestProc](route.libHandle.symAddr("post"))
          route.headProc = cast[RequestProc](route.libHandle.symAddr("head"))
          route.optionsProc = cast[RequestProc](route.libHandle.symAddr("options"))
          route.putProc = cast[RequestProc](route.libHandle.symAddr("put"))
          route.deleteProc = cast[RequestProc](route.libHandle.symAddr("delete"))
          route.patchProc = cast[RequestProc](route.libHandle.symAddr("patch"))
          route.requestProc = cast[RequestProc](route.libHandle.symAddr("request"))
          route.libModificationTime = dynlibPath.getLastModificationTime
       
        block byMethod:
          case request.httpMethod:
          of "GET":
            if not route.getProc.isNil:
              route.getProc(request)
              break byMethod
          of "POST":
            if not route.postProc.isNil:
              route.postProc(request)
              break byMethod
          of "HEAD":
            if not route.headProc.isNil:
              route.headProc(request)
              break byMethod
          of "OPTIONS":
            if not route.optionsProc.isNil:
              route.optionsProc(request)
              break byMethod
          of "PUT":
            if not route.putProc.isNil:
              route.putProc(request)
              break byMethod
          of "DELETE":
            if not route.deleteProc.isNil:
              route.deleteProc(request)
              break byMethod
          of "PATCH":
            if not route.patchProc.isNil:
              route.patchProc(request)
              break byMethod

          if not route.requestProc.isNil:
            route.requestProc(request)
            break byMethod

          request.respond(405, defaultHeaders, "method not allowed")

      else:
        request.respond(404, defaultHeaders, "not found")

    let server = newServer(handler)
    server.serve(port, host)

  init()

