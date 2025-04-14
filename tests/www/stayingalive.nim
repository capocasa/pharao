# /var/www/stayingalive.nim
import os, times
body = "done " & $now() & "\n"
let f = open("/tmp/later.log", fmWrite)
respond()
sleep 1000
f.writeLine($now() & " is one second after the request!\n")
f.close
body = "blackhole"  # this doesn't do anything any more

