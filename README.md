
Pharao - quick 'n easy Nim web programming 
==========================================

Pharao is for quick 'n easy web programming.

Start up a pharao server (once) and point it at a web root.

Place a Nim file anywhere in the web root. Then open that path in the browser. Pharao will compile your file into a request handler and call it.

If this sounds familiar, it's because it's the only thing the author missed about programming in PHP.

Basic Usage
-----------

Install pharao using nimble

```
$ nimble install pharao
```

Run it.

```
$ export PHARAO_WEB_ROOT=/var/www  # optional
$ pharao
```

Create a Nim file somewhere in the web root. 

```nim
# /var/www/hello.nim
echo "Hello, ancient world!"
```

Call it. Voila!

```
$ curl localhost:2347/hello.nim
Hello, ancient world!
```

Simple examples
---------------

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

You can use templating engines

```nim
# /var/www/template.nim
import std/random, nimja/parser
randomize()

let battleCry = ["Hee", "Hoo", "Haa-ya"].sample
compileTemplateStr """
I'm a Nimja

{{ battleCry }}!
"""
```

```
$ curl localhost:2347/nimja.nim
```
I'm a Nimja

Haa-ya!
```

Reading data
------------

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

Showing a specific page for each query string key is a great way to handle different requests in one file. Old school web apps call this having "actions". In this case, the "action" is `foo` or `bar`. 

# /var/www/actions.nim
if "foo" in request.queryParams:
  echo "Foo"
elif "bar" in request.queryParams"
  echo "Bar"
else:
  code = 404
  echo "Not found"

```
$ curl localhost:2347/actions.nim?foo
<h1>Foo</h1>
$ curl localhost:2347/actions.nim?bar
<h2>Bar</h2>
$ curl localhost:2347/actions.nim?fuz
Not found
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

You may prefer multipart, as in `<form enctype='multipart/form-data'`

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

multipart supports file uploads

```
$ echo foo > /tmp/foo.txt
$ curl -F uploadme=@/tmp/foo.txt localhost:2347/multi.nim
foo
# the server just returns file content but could store
# in on disk or in database
```

You can use JSON

```nim
# /var/www/json.nim
import std/json
headers["Content-Type"] = "application/json"

if request.httpMethod == "POST":
  let j = request.body.parseJson
  echo j{"foo"}.getStr()
else:
  let j = %* { "foo" : "bar" }
  echo j
```

Fancy
-----

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
$ curl localhost:2347/stayingalive.nim & && tail -f /tmp/later.log
done

```

More than one file
------------------

Use includes to easily have different files

```nim
# /var/www/this.nim

echo "this"

include that
```

```nim
# /var/www/that.nim

echo "that"
```

```sh
$ localhost:2347/this.nim
this
that
```

Imports work too.

If you want to use pharao's variables in imported files, add `import pharao/tools`.
This is not necessary if you have no side effects (recommended) or use includes.

```nim
# /var/www/imp.nim
import imped
foo()
```

```nim
# /var/www/imped.nim
import pharao/tools
proc foo*() =
  echo "I was imported!!!\n"
```

```
# curl localhost:2347/imp.nim
I was imported!!!
```


.. warning::
  For security, keep your imports and includes out of your web root (recommended) or make sure the module scope doesn't do anything.

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
import pharao/tools
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
sensitive user data
$ # whoops
```

Storing data
------------

You can use "global" variables. They only get written when your code is compiled or the server is restarted.

```nim
# /var/www/persist.nim

proc calculate(): int =
  # stand-in for something that takes a while 
  2 + 2 

let num {.global.} = calculate()  # calculate is only run once

body = $num

```

This is also great way to set up a database connection, such as [LimDB](https://github.com/capocasa/limdb).

```
$ nimble install limdb
```

```nim
import limdb

let db {.global.} = initDb("foo.db")

db["text"].add(".")  # this is both in-memory and on disk now
body = db["text"]

```

.. info ::
    every pharao program runs inside one of a fixed number worker threads, which are sub-programs that run within pharao and have access to the same data. If you mark a variable `{.global.}` to keep it around to make your program faster, you have to make sure that any changes to that variable are done in a "thread safe" way.

    The easiest way to have thread safety is to use libraries that already are written that way, as LimDB is. Just use it.



Sometimes it's more useful for each worker to have its own copy of a variable that gets re-used each time a request is handled by that worker. That way, you have about 40 copies of the variable, but no more.

The sqlite3 database expects to be use this way.

Mark the variable as a thread-local variable- or `{.threadvar.}`


```nim
import db_connector/db_sqlite, random
randomize()
var data = "asdf"
data.shuffle()

# can't do this, has to be on two lines
# var db {. threadvar .} = open("foo.db", "", "", "")
var db {. threadvar .}: DbConn
db = open("foo.db", "", "", "")

db.exec sql" INSERT INTO foo (foo) VALUES (?) ", data

headers["Content-Type"] = "text/tsv"
for row in db.fastRows sql" SELECT * FROM foo":
  echo row[0], "\t", row[1]
```

And a minimal, but workable script to create and maintain your database.

```nim
# /var/www/initdb-av0k2ja15v2347rbwchexz48.nim
# obscure URL is a crude but workable authentication method

import db_connector/db_sqlite, strutils

var db {.threadvar.}: DbConn

db = open("foo.db", "", "", "")

let version = try:
  parseInt(db.getValue sql"SELECT version FROM version")
except DbError:
  db.exec sql" PRAGMA journal_mode=WAL "
  db.exec sql" PRAGMA busy_timeout = 30000 "
  0

db.exec sql" BEGIN "

if version < 1:
  # use sqlite's fast-and-practical mode
  # this is good enough for most web app needs

  # create tables
  db.exec sql" CREATE TABLE version (version INT) "
  db.exec sql" INSERT INTO version (version) VALUES (0) "
  db.exec sql" CREATE TABLE IF NOT EXISTS foo (id INTEGER PRIMARY KEY AUTOINCREMENT, foo string) "

db.exec sql"UPDATE version SET version=1"

db.exec sql" COMMIT "


```

Then you can initialize the database and run the example program a few times.


```
$ curl localhost:2347/initdb-av0k2ja15v2347rbwchexz48.nim
$ curl localhost:2347/sqlite.nim
1	dsaf
$ curl localhost:2347/sqlite.nim
1	dsaf
2	safd
$ curl localhost:2347/sqlite.nim
1	dsaf
2	safd
3	sadf
```

This is a perfectly suitable starting point for a production web app. You may want to run the migration script on the command line, or use more advanced authentication.

Personally, I prefer the typed tiny_sqlite.

```
nimble install tiny_sqlite
```

.. warning::
  For security, keep your database files out of the web root.

.. info::

  A convenient way to do that is to start pharao from a current working directory that is not in the web root, such as /var/lib/pharao, and use relative paths such as "foo.db".


Configuration options
---------------------

You can do some general configuration on the command line, and the nitty gritty with environment variables, or an .env file.

```
$ pharao --help

Usage: pharao [options]

Starts a web server that will compile and execute Nim files in a web
root directory and serve the result.

-h, --help              Show this help
-p, --port:PORT         Set port
-H, --host:HOST         Set host
-W, --www-root:WWWROOT   Set the web root
-e, --env:ENV           Set an environment file

The following environment variables are read for configuration.

Variable              Default value

PHARAO_PORT                  2347                         The port to listen on
PHARAO_HOST                  localhost                    The host to bind to
PHARAO_WWW_ROOT              /var/www                     The web root
PHARAO_DYNLIB_PATH           lib                          Compiled code path
PHARAO_NIM_COMMAND           nim                          Nim command
PHARAO_NIM_ARGS                                           Additional compiler arguments
PHARAO_NIM_CACHE             cache                        Nim cache directory
PHARAO_OUTPUT_ERRORS         true                         Add errors to response body
PHARAO_LOG_ERRORS            true                         Add errors to log file
PHARAO_LOG_FILE              -                            Log file path or - for stdout
PHARAO_LOG_LEVEL             DEBUG                        Minimum level to log, DEBUG INFO or ERROR
PHARAO_LOG_DATETIME_PATTERN  yyyy-MM-dd'T'HH:mm:sszzz     Nim datetime format pattern for log
PHARAO_LOG_PATTERN           [$1 $2] $3                   Log format with $1 date, $2 level, $3 message

Option takes precedence before environment value from file before environment.

```



Limitatons
----------

.. info :: There is a [Nim compiler bug](https://github.com/nim-lang/Nim/issues/19071) the author was unable to work around that prevents pharao files from having their own type definitions, they have to be put into imports. Sorry!

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


Useful examples
---------------

The most obvious use for pharao are quick throwaway scripts. Those are very very important, because they tend to evolve into more useful applications over time- and every little bit of friction you don't have makes you reach for your programming language more to solve problems. This is the main point why the author made pharao.

Here are some small but real-world examples.

**Fancy Email collect form **

This is the motivating example for pharao. Having a quick form to collect some data should be easy.

This is the fancy old-school version: It redirects with a cookie-based one-time message on success.

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

The easiest way and most secure way to run pharao on a Linux web server is with systemd. You can get an isolated system with its own user by creating the file below. systemd will create an isolated state directory in /var/lib/pharao for you, so if you open a database "foo.db" it will go into /var/lib/pharao/foo.db and be accessible only by the pharao user.


```
# /etc/systemd/system/pharao.service
[Unit]
Description=pharao
After=network.target httpd.service
Wants=network-online.target

[Service]
DynamicUser=True
ExecStart=/opt/nimble/bin/pharao
Restart=always
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
Environment=PHARAO_NIM_COMMAND=/opt/nim/bin/nim
Environment=PHARAO_WWW_ROOT=/var/www
Environment=PHARAO_LOG_LEVEL=INFO
Environment=PHARAO_LOG_PATTERN=[$2] $3
StateDirectory=pharao
WorkingDirectory=%S/pharao

[Install]
WantedBy=multi-user.target
```

A good way to run nimble binaries with systemd dynamic users is with a system-wide Nim installation.

```sh
$ export VERSION=2.2.2
$ wget https://nim-lang.org/download/nim-$VERSION-linux_x64.tar.xz
$ tar -xvJf nim-$VERSION-linux_x64.tar.xz -C /opt
$ ln -sf nim-$VERSION /opt/nim
```

Repeat the commands above to upgrade, or run only the last to switch versions.

Now add your paths so you can call the compiler and use installed packages. Log out and back in after creating this file.

```
# /etc/profile.d/nim.sh
export NIMBLE_DIR=/opt/nimble
PATH=$PATH:/opt/nim/bin:/opt/nimble/bin
```

Now install pharao. It will go to /opt/nimble/bin/pharao

```
$ nimble install pharao
$ ls /opt/nimble/bin/pharao
/opt/nimble/bin/pharao  # yep, it's there
```

Now you can start your pharao service, and enable it to run it at boot.

```
$ systemctl start pharao
$ systemctl enable pharao
```

Check it works

```
systemctl status pharao
```

Check logs

```
journalctl -u pharao --since '5 minutes ago'
```

Trace logs

```
journalctl -u pharao --since '5 minutes ago' -f
```


Reverse proxy configuration
---------------------------

Most of us like to run web applications with a public facing reverse proxy server that handles SSL and static files, passing apprequests to our program

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
    rewrite ^/(.*)$ /example.org/$1 break;
    proxy_pass http://127.0.0.1:2347;
    proxy_buffering off;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
  }
}
```

Something I like to do is have a few domains where each subdomain has a directory for even more convenience. You create directory and file `/var/www/_.example.org/foo/bar.nim` and can call it at `curl foo.example.org/bar.nim`.

```
# /etc/nginx/sites-available/_.example.org

server {
  listen 80;
  listen [::]:80;
  
  server_name ~^(?<subdomain>.+)\.example\.org$;
  if (!-d /var/www/_.example.org/$subdomain) {
    return 444;
  }
  root /var/www/_.example.org/$subdomain;
  access_log /var/log/nginx/$subdomain.example.org.access.log;
  error_log /var/log/nginx/$subdomain.example.org.error.log;

  index index.html index.htm index.nim;

  location / {
    try_files $uri $uri/ /index.nim$is_args$args;
  }

  location ~ \.nim$ {
    rewrite ^/(.*)$ /$subdomain/$1 break;
    proxy_pass http://127.0.0.1:2347
    proxy_buffering off;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
  }
}

```

You may of course use any reverse proxy you like.

Combine this with a wildcard SSL certificate and you can create new sites extremely easily.

You can use [certbot](https://certbot.eff.org/) to get SSL certificates.

Inner workings
--------------

Pharao contains a mummy webserver and a single request handler for everything.

When a request comes in, the web root is checked for a file with the relative path of the request. If the file exists, it is wrapped in a special boilerplate file in `pharao/lib`, and the interface `pharao/tools` is imported before compiling it into a request handler in a dynamic library that is called to process the request. On subsequent requests, a recompile is only done if the source file is newer than the library file. Existing compiled requests get loaded on boot so there is no unnecessary compiling.

Limitations
-----------

- Even though mummy is strong on websockets, pharao doesn't support them yet. It would be cool though! It would take a really cool simplistic API to be worth it though. Can you think of one?
- Pharao has no mechanism for handling static files and is unaware of the concept of file extensions. The assumption is that your proxy server will handle that. A quick workaround is to use a one-liner source code filter for e.g. a CSS file. This would be rather interesting to build but would require a mummy patch to support download streaming, in the author's humble opinion.
- Pharao does not cover all CGI features yet, for example, there is no mechanism to have /foo.nim/bar/fuz call foo.nim with /bar/fuz in the request path. Also, pharao is usually pointed at the web root /var/www, so if you have a file in a virtual host /var/www/example.org/foo.nim, then /example.org will be part of the path /example.org/foo.nim, as far as pharao is concerned. CGI resolves this by shortening the path to /foo.nim. This is quite donable with pharao too, it just hasn't been done yet.

Thanks
------

Pharao uses the [mummy](https://github.com/guzba/mummy) webserver which is so good it's the reason pharao seemed worth making. Thanks!!!

The mechanism is inspired by [nimcr](https://github.com/PMunch/nimcr). Thanks!!!

What's in a name?
-----------------

*Why is it called Pharao?*

Pharao acts as a source for the mummy webserver. And... the source... of a mummy... is a pharaoh! *Boom-tss*

And a pharaoh have much in common with PHP! Both start with the letters P and H, lord over vast empires, and are deformed by excessive inbreeding.

*Pharaoh isn't spelled Pharao!*

"Pharaoh" is spelled with trailing "h" in english, but we use the German spelling "Pharao" everywhere.

