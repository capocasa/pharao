from mummy import Request,HttpHeaders,LogLevel

# types and other shared definitions

type
  CHeaderPair* = object
    name*: cstring
    nameLen*: cint
    value*: cstring
    valueLen*: cint

  RespondProc* = proc(request: Request, code: cint,
                      headerPairs: ptr CHeaderPair, headerCount: cint,
                      body: cstring, bodyLen: cint) {.nimcall,gcsafe.}
  ErrorProc* = proc(request: Request, code: cint,
                    message: cstring, messageLen: cint) {.closure,gcsafe.}
  PresetProc* = proc(code: cint, body: cstring, bodyLen: cint) {.nimcall,gcsafe.}
  RequestProc* = proc(request: Request) {.nimcall,gcsafe.}
  LogProc* = proc(level: LogLevel, message: cstring) {.closure, gcsafe}
  InitProc* = proc(respondProc: RespondProc, logProc: LogProc, errorProc: ErrorProc, stdoutArg, stderrArg, stdinArg: File) {.nimcall,gcsafe.}
  DeinitProc* = proc() {.nimcall,gcsafe.}
  VersionProc* = proc(): cstring {.nimcall,gcsafe.}

