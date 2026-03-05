
version = "0.2.0"
author = "Carlo Capocasa"
description = "Compile, run and serve Nim files on the fly in a www directory like PHP"
license = "MIT"
installExt = @["nim"]
bin = @["pharao"]
binDir = "bin"

requires "nim >= 2.0.0"
requires "mummy >= 0.4.6"
requires "scf >= 0.1.0"

when not defined(release):
  requires "curly"
  requires "db_connector"

