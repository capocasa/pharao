import mummy, pharao/common
import webby/httpheaders

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
  # Serialize headers to C-compatible format for cross-dynlib boundary
  let headerSeq = seq[(string, string)](headers)
  var pairs = newSeq[CHeaderPair](headerSeq.len)
  for i, (name, value) in headerSeq:
    pairs[i] = CHeaderPair(
      name: name.cstring, nameLen: name.len.cint,
      value: value.cstring, valueLen: value.len.cint
    )
  let pairsPtr = if pairs.len > 0: addr pairs[0] else: nil
  respondProc(request, code.cint, pairsPtr, pairs.len.cint,
              body.cstring, body.len.cint)

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
  log(DebugLevel, message.cstring)
proc info*(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(InfoLevel, message.cstring)
proc error*(message: string) {.hint[XDeclaredButNotUsed]: off.} =
  log(ErrorLevel, message.cstring)

