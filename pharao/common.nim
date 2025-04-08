import mummy, mummy/fileloggers, times, strutils

# types and other shared definitions

type
  RespondProc* = proc(request: Request, code: int, headers: sink HttpHeaders, body: sink string) {.nimcall,gcsafe.}
  RequestProc* = proc(request: Request) {.nimcall,gcsafe.}
  LogProc* = proc(level: LogLevel, message: string) {.closure, gcsafe}
  InitProc* = proc(respondProc: RespondProc, logProc: LogProc) {.nimcall,gcsafe.}


