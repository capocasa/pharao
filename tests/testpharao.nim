import std/[strutils, os, osproc, strtabs,exitprocs,unittest,compilesettings, pegs,streams], curly, webby


suite "tests for different source files":

  let wd = currentSourcePath().parentDir.parentDir
  let wwwRoot = currentSourcePath().parentDir / "www"
  let tmp = getTempDir()

  let dynlibPath = tmp / "pharaoTestLib"
  let cachePath = tmp / "pharaoTestCache"

  const nimblePaths = querySettingSeq(MultipleValueSetting.nimblePaths)
  var args: seq[string]

  var env = {
    "PHARAO_PORT": "9999",
    "PHARAO_HOST": "localhost",
    "PHARAO_NIM_COMMAND": getCurrentCompilerExe(),
    "PHARAO_WWW_ROOT": wwwRoot,
    "PHARAO_DYNLIB_PATH": dynlibPath,
    "PHARAO_NIM_CACHE_PATH": cachePath
  }.newStringTable

  for k, v in envPairs():
    if k notin env:
      env[k] = v

  removeDir dynlibPath

  let p = startProcess("./pharao.out", wd, args, env, {poDaemon,poInteractive,poEvalCommand,poParentStreams})
  addExitProc proc() =
    p.terminate
    for i in 1..20:
      if p.running:
        sleep 100
      else:
        return
    p.kill


  sleep 100

  let curl = newCurly()

  test "bar":
    let r = curl.get("localhost:9999/bar.nim")
    check(r.code == 200)
    echo typeof r.body
    check(r.body == "1\n")

  test "collect":
    let r = curl.get("localhost:9999/collect.nim")
    check(r.code == 200)
    check("""<form method="post"""" in r.body)

  test "foo":
    let r = curl.get("localhost:9999/foo.nim")
    check(r.code == 200)
    check(r.body == "foo")

  test "form":
    let r = curl.get("localhost:9999/form.nim")
    check(r.code == 200)
    check(r.body == "")

  test "fuz":
    let r = curl.get("localhost:9999/fuz.nim")
    check(r.code == 200)
    check("fuz.nim" in r.body)

  test "imped":
    let r = curl.get("localhost:9999/imped.nim")
    check(r.code == 200)
    check(r.body == "I was imported!!!\n")

  test "impedtypes":
    let r = curl.get("localhost:9999/impedtypes.nim")
    check(r.code == 200)
    check(r.body == "0\n")

  test "multi":

    var m: MultipartEntry
    m.name="FOO"
    m.payload="BAR"
    let (header, body) = encodeMultipart(@[m])
    let r = curl.post("localhost:9999/multi.nim", @{"Content-Type": header}.HttpHeaders, body)
    check(r.code == 200)
    check(r.body == "BAR")

  test "onlytypes":
    let r = curl.get("localhost:9999/onlytypes.nim")
    check(r.code == 200)
    check(r.body == "")

  test "query":
    let r = curl.get("localhost:9999/query.nim?foo=bar")
    check(r.code == 200)
    check(r.body == "bar")

  test "rando":
    let r = curl.get("localhost:9999/rando.nim")
    check(r.code == 200)
    check(r.body[^4 .. ^1] =~ peg"\d\d\d\d")

  test "return":
    let r = curl.get("localhost:9999/return.nim")
    check(r.code == 200)
    check(r.body == "foo")

  test "scf":
    let r = curl.get("localhost:9999/scf.nim")
    check(r.code == 200)
    check(r.body[^5..^2] =~ peg"\d\d\d\d")

  test "sqlite":
    let r = curl.get("localhost:9999/sqlite.nim")
    check(r.code == 200)
    check(r.body == "1\tasdf\n2\tsdaf\n3\tdfsa\n4\tsdfa\n")

  test "stayingalive":
    let r = curl.get("localhost:9999/stayingalive.nim")
    check(r.code == 200)
    check(r.body.startsWith "done ")

  test "template":
    let r = curl.get("localhost:9999/template.nim")
    check(r.code == 200)
    echo r.body
    check(r.body.startsWith("I'm a Nimja\n"))

  # TODO: This one doesn't work due to longstanding compiler bug
  #test "types":
  #  let r = curl.get("localhost:9999/types.nim")
  #  check(r.code == 200)
  #  check(r.body == "0")

  test "yowzy":
    let r = curl.get("localhost:9999/yowzy.nim")
    check(r.code == 409)
    check(r.body == "Yowzy")

