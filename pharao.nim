
import
  std/[os, osproc, parseopt,envvars,strutils,paths,dirs,files,tables,dynlib,times],
  mummy, mummy/routers

export mummy

# create actual mummy routes from request handlers in dll dynamically
# wrap global mummy router for load/unload logic
# allow disable time check, perhaps granually
# .nim files in www contain get(request), post(request) or request(request) by convention which are loaded into routes

# pharao nim file include

proc NimMain() {.cdecl, importc.}

proc library_init() {.exportc, dynlib, cdecl.} =
  NimMain()
  echo "Hello from our dynamic library!"

proc library_do_something(arg: cint): cint {.exportc, dynlib, cdecl.} =
  echo "We got the argument ", arg
  echo "Returning 0 to indicate that everything went fine!"
  return 0 # This will be automatically converted to a cint

proc library_deinit() {.exportc, dynlib, cdecl.} =
  GC_FullCollect()

type
  PharaoRouteObj = object
    path: string
    requestHandler: proc(request: Request)
    libHandle: LibHandle
    libModificationTime: Time
  PharaoRoute = ref PharaoRouteObj

when isMainModule:
  # pharao server

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
      echo request.path
      echo request.httpMethod
      echo request.headers

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
          if exitCode == 0:
            route.libModificationTime = dynlibPath.getLastModificationTime
          else:
            request.respond(500, emptyHttpHeaders(), output)
            return
        request.respond(200, emptyHttpHeaders(), "ok")
      else:
        request.respond(404, emptyHttpHeaders(), "not found")

    let server = newServer(handler)
    server.serve(port, host)

  init()

