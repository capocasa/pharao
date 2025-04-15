import mummy, pharao/common

type
  ## dummy result variable to redirect it
  Result* = distinct string

## Include and preprocess user supplied code (macros prefixed with pharao)
var
  respondProc*: RespondProc  # call web server responder
  log*: LogProc  # write to log
  code* {.threadvar.}: int
  headers* {.threadvar.}: HttpHeaders
  body* {.threadvar.}: string
  request* {.threadvar.}: Request
  result* {.threadvar.}: Result

proc respond*() =
  respondProc(request, code, headers, body)

proc add*(r: Result, s: string) =
  body.add s

template echo*(x: varargs[string, `$`]) =
  for s in x:
    body.add s
  body.add "\n"

template `=`*(x: varargs[string, `$`]) =
  for s in x:
    body.add s
  body.add "\n"

## logging tools

# these are duplicated from pharao.nim so we only have to
# receive the log proc on intialization

proc debug*(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(DebugLevel, message)
proc info*(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(InfoLevel, message)
proc error*(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(ErrorLevel, message)


