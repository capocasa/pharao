import mummy

# types and other shared definitions

type
  RespondProc* = proc(request: Request, code: int, headers: sink HttpHeaders, body: sink string) {.nimcall,gcsafe.}
  RequestProc* = proc(request: Request) {.nimcall,gcsafe.}
  InitProc* = proc(respondProc: RespondProc, f: File) {.nimcall,gcsafe.}

