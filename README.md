
Pharao - quick 'n easy Nim web app
==================================

Pharao is the quick 'n easy way to run Nim web apps.

Start up a pharao server and point it at a web root.

Place a Nim file anywhere in the web root. Opening that path in the browser will compile, run and return the output.

If this sounds familiar, that's because it's the author's best effort to replicate some of the beginner friendliness and easy-of-use of PHP while keeping the amazingness and extreme performance of Nim.

Basic Usage
-----------

Install pharao using nimble

```
$ nimble install pharao
```

Run it.

```
$ ./pharaoh
```

Create a Nim file somewhere in the web root. 

```nim
# /var/www/foo.nim
echo "Hello, ancient world!"
```

Call it. Voila!

```
$ curl localhost:2347/foo.nim
Hello, ancient world!
```

You can write any nim code
```nim
# /var/www/rando.nim
import std/random

randomize()

body.add "I'm a rando.\n\n"
body.add $rand(10000)
body.add "\n|
```

```
$ curl localhost:2347/rando.nim
I'm a rando.

4592
```

You can use source code filters

```nim
#? stdtmpl
## /var/www/scf.nim
# import std/random
# let r = random(10000)
I'm a rando.

$r
```

```
$ curl localhost:2347/scf.nim
I'm a rando.

7917
```

You can set headers and request variables

```nim
headers["Content-Type"] = "text/plain"
body = "Yowzy\n"
code = 409
```

```
$ curl -i localhost:2347/yowzy.nim
HTTP/1.1 409
Content-Type: text/plain
Content-Length: 5

Yowzy
```

You can check out the get parameters

```nim
# /var/www/query.nim
body.add request.queryParams.getOrDefault("a", "empty") & "\n"
```

```nim
$ curl localhost:2347/query.nim?a=b
b
```

Or post parameters 

```nim
# /var/www/form.nim
let params = request.body.parseSearch:
echo params.getOrDefault("foo", "-")
```

```
$ curl -d foo=bar localhost:2347/query.nim
bar
```

or as a multipart

```nim
# /var/www/multi.nim
for m in request.decodeMultipart:
  if m.data.isSome:
    let (a, z) = m.data.get
    body.add request.body[a..z]
    body.add "\n"
```

```
$ curl -F foo=bar localhost:2347/multi.nim
bar
```

Multipart supports file upload

```
$ echo foo > /tmp/foo.txt
$ curl -F uploadme=@/tmp/foo.txt localhost:2347/multi.nim
foo
# the server just returns file content but could store
# in on disk or in database
```

You can keep doing stuff after the request.

```nim
# /var/www/stayingalive.nim
import os, times
body = "done " & $now() & "\n"
let f = open("/tmp/later.log", fmWrite)
respond()
sleep 1000
f.writeLine($now() & " is one second after the request!\n")
f.close
body = "blackhole"  # this doesn't do anything any more
```

```
$ curl localhost:2457/stayingalive.nim & && tail -f /tmp/later.log
done

```

Imports and includes work as normal

```nim
# /var/www/imp.nim
import imped
foo()
```

```nim
# /var/www/imped.nim
proc foo*() =
  echo "I was imported!!!\n"
```

```
# curl localhost:2347/imp.nim
I was imported!!!
```

.. warning:: Just like with any system that allows executing source code from a directory, exercise caution when providing files that aren't meant to be called directly. This is a trade-off for the convenience- if you feel you cannot keep this in mind, I advise against using pharao.


This is ok

```nim
# /var/www/iimport.nim

import importme

```

```nim
# /var/www/importme.nim

proc foo() =
  echo "foo"

# no side effects here, just definitions

```

This is also ok

```nim
# /var/app/importme2.nim

# /var/app could be any directory that is not in the web root

# side effect here
echo "foobar fuz buz"

```

```nim
# /var/www/iimport2.nim

import ../app/importme2"

```

This is not ok

```nim
# /var/www/badidea.nim

echo "sensitive user data"

```

```nim
# /var/www/importer3.nim

if request.headers.getOrDefault("Authorization", "") != "Bearer my-secure-token":
  code = 401
  body = unauthorized
  return

import badidea

```

Because then anyone can do

```nim
$ curl localhost:2347/importer3.nim
unauthorized
$ curl localhost:2347/badidea.nim
secret account password
$ # whoops
```

You can have a variable that only gets written to the first time your program runs. This goes away again if the pharao server is restarted.



```nim
# /var/www/persist.nim

proc calculate(): int =
  # this would be more useful for a more complex calculation that takes a while
  2 + 2 

let num {.global.} = calculate()  # calculate is only run once

# let num {.threadvar.} = calculate()  # this would be run for about the first 40 requests but no more than that

# let num = calculate()  # this would be run at every request

body = $num

```

This is a great way to set up a database connection, such as [LimDB](https://github.com/capocasa/limdb).

```
$ nimble install limdb
```

```nim
import limdb

let db {.global.} = initDb("/var/lib/pharao/foo.db")  # don't put the database in /var/www or sub-directories

db["text"].add(".")  # this is both in-memory and on disk now
body = db["text"]

```

.. warning:: every pharao program runs inside one of a fixed number worker threads, which are sub-programs that run within pharao and have access to the same data. If you use regular variables or `{.threadvar.}` variables, you don't have to worry about that too much. Otherwise, you have to use make sure that all procs that work on that variable are "thread safe".

The easiest way to have thread safety is to use libraries that already are written that way. This means they make sure that their procs are set up so that when they are called in threads they play nice with each other- usually through a so-called lock.

Some libraries such as LimDB are inherently thread safe- you can just go ahead and use it and ignore all this. Other libraries have wrappers that make them thread safe- the best I know for the Nim stdlib databases is `waterpark`.

```
$ nimble install waterpark
```

```nim
# /var/www/miglite.nim
# this is for creating and updating tables
# only one connection needed
if request.headers.getOrDefault("Authorization", "") == "myInternalSecret":
  let db {.global.} = newSqlitePool(1, "/var/lib/pharao/foo.sqlite3")
  c.exec "CREATE TABLE IF NOT EXISTS foo (id primary key, foo TEXT")"  # put this in a seperate file for a real app
else:
  code = 401
  body = "Unauthorized\n"
```

```nim
# /var/www/sqlite.nim
import waterpark/sqlite, random
randomize()
var asdf = "asdf"
asdf.shuffle
let db {.global.} = newSqlitePool(50, "/var/lib/pharao/foo.sqlite3")
db.withConnection c:
  c.exec """ INSERT INTO foo (foo) VALUES (?) """, asdf
  for row in c.fastRows("SELECT * FROM foo"):
    body.add row[0]
    body.add "\t"
    body.add row[1]
    body.add "\n"
```


.. warning:: There is a [Nim compiler bug](https://github.com/nim-lang/Nim/issues/19071) that prevents using types with a feature pharao can't do without. Sorry!

```nim
# /var/www/types.nim
type
  FooObj = object
    bar: int
  Foo = ref FooObj

var foo = Foo(bar: 123)

body.add $foo.bar
body.add "\n"
```

```
$ curl localhost:2347/imp.nim
Error: inconsistent typing for reintroduced symbol 'foo'
$ # whoops
```

Until there is a fix, import your types as a workaround

```nim
# /var/www/onlytypes.nim
type
  FooObj* = object
    bar*: int
  Foo* = ref FooObj
```

```nim
# /var/www/imptypes.nim
import onlytypes

var foo = Foo(bar: 123)

body.add $foo.bar
body.add "\n"

```

```
$ curl localhost:2347/imptypes.nim
123
```


Useful things you can do with Pharao
------------------------------------

The most obvious use for pharao are quick throwaway scripts, but there is nothing stopping you from building more involved applications as well.

While the examples above are more for introduction, these are secure mini web applications you can use as starting point and change into your own.

Quick 'n clean forms
--------------------

There is a neat way to have old school web forms that work as expected with both form submit and history: Do a post, display error messages (if any) in the post,POST-and-redirect-with-message.

The somewhat hairy vanilla javascript is made up for by being short.

**Collect emails into a file**

```nim
# /var/www/collect.nim
import times, uri, sequtils,tables
if request.httpMethod == "POST":
  let f = open("/tmp/collect.tsv", fmAppend)
  let vars = request.body.decodeQuery.toSeq.toTable
  f.writeLine($now(),vars.getOrDefault("name", "-"), vars.getOrDefault("email", "-"))
  f.close
  code = 302
  headers["Set-Cookie"]="OnetimeMessage=Thank you, your email address " & vars["email"] & " was collected."
  headers["Location"] = request.path
  body = "redir"
else:
  body = """
<!DOCTYPE html>
<form method="post" action="">
  <script>
  (function () {
    // read cookie
    var onetimeMessage = (document.cookie + ";").match(/OnetimeMessage=(.*);/)[1]
    console.log(onetimeMessage)
    if (onetimeMessage) {
      document.currentScript.insertAdjacentHTML("afterend", "<p>"+onetimeMessage+"</p>")
      document.cookie = "OnetimeMessage=; expires=Thu, 01 Jan 1970 00:00:00 UTC;" // Remove cookie
    }
  })()
  </script>
  <legend>
    Please type in your name and email address
  </legend>
  <input type="Name" name=name placeholder="Name">
  <input type="text" name=email placeholder="Email">
  <input type="submit">
</form>
"""
```



Run in production
-----------------

The easiest way and most secure way tto run pharao on a Linux web server is with systemd. You can get an isolated system with its own user by creating this file:

This is of course also system administration work, but the advantage is that you only have to do it once to have any number of pharao applications.

```
# /etc/systemd/system/pharao.service
[Unit]
Description=frueh
After=network.target httpd.service
Wants=network-online.target

[Service]
DynamicUser=True
ExecStart=frueh
Restart=always
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
Environment=FRUEH_MAIL_FROM=carlo@capocasa.net
Environment=FRUEH_MAIL_TO=carlo@capocasa.net
StateDirectory=frueh
WorkingDirectory=%S/frueh

[Install]
WantedBy=multi-user.target
```

And then running and enabling the service

```
$ systemd daemon-reload
$ systemd start pharao
$ systemd enable pharao
```

Check it works

```
systemd status pharao
```

Check logs

```
journalctl -u pharao --since '5 minutes ago'
```

Trace logs

```
journalctl -u pharao --since '5 minutes ago' -f
```

Other ways to run daemons may of course be used.


Use with reverse proxy
----------------------

Most of us like to run web applications with a public facing reverse proxy server that handles SSL and static files, passing apprequests to our program.

This uses the same mechanism as a PHP setup to only run .nim files through pharao, let nginx handle static files. You still benefit from Nim's superior performance.

```
# /etc/nginx/sites-available/example.org
server {
  server_name example.org;
  listen 80;
  listen [::]:80;
  root /var/www/example.org;
  access_log /var/log/nginx/example.org.access.log;
  error_log /var/log/nginx/example.org.error.log;

  index index.html index.htm index.nim;

  location / {
    try_files $uri $uri/ /index.nim$is_args$args;
  }

  location ~ \.nim$ {
    proxy_pass http://127.0.0.1:2457;
    proxy_buffering off;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
  }
}
```

Something I like to do is have a few domains where each subdomain has a directory for even more convenience.

```
server {
  listen 80;
  listen [::]:80;
  
  server_name ~^(?<subdomain>.+)\.capo\.casa$;
  if (!-d /var/www/_.capo.casa/$subdomain) {
    return 444;
  }
  root /var/www/_.capo.casa/$subdomain;
  access_log /var/log/nginx/$subdomain.capo.casa.access.log;
  error_log /var/log/nginx/$subdomain.capo.casa.error.log;

  index index.html index.htm index.nim;

  location / {
    try_files $uri $uri/ /index.nim$is_args$args;
  }

  location ~ \.nim$ {
    proxy_pass http://127.0.0.1:2457;
    proxy_buffering off;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
  }
}

```

You may of course use any reverse proxy you like.

Please refer to `letsencrypt` to add SSL.


Why is it called pharao?
------------------------

Behind the scenes, pharao uses the mummy webserver to work with Nim source.

And... the source... of a mummy... is a pharao! *Boom-tss*

And Pharaos have much in common with PHP. Both start with the letters P and H, are deformed by excessive inbreeding, and lord over vast empires.

