import mummy

# types and other shared definitions

type
  RespondProc* = proc(request: Request, code: int, headers: sink HttpHeaders, body: sink string) {.nimcall,gcsafe.}
  RequestProc* = proc(request: Request, respondProc: RespondProc) {.nimcall,gcsafe.}


