
version = "0.1.0"
author = "Carlo Capocasa"
description = "Compile, run and serve Nim files on the fly in a www directory like PHP"
license = "MIT"

requires "nim"
requires "mummy"

when not defined(release):
  requires "curly"
  requires "nimja"

