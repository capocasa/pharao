
Pharao
======

Create web apps by putting Nim source files directly into your webserver tree.

* Fast- the files become request handlers, powered by mummy
* Easy- no boilerplate, automatic compile-and-run
* Flexible- create quick one-off scripts or full APIs

Usage
-----

Place a Nim source file anywhere in a web server root configured to use pharao
to automatically compile (first time only) and run it when it is called.


**Run Server**

$ ./pharaoh


**Create file**

```nim
# /var/www/foo.nim
import random
code = 201
var s = "abcdefg"
shuffle(s)
echo """
<!DOCTYPE html>

<h1>$1</h1>
""" % s
```

**Open in browser**

And open the URL in your browser or on the command line

$ curl localhost:2347/foo.nim
<!DOCTYPE html>

<h1>efcbdga</h1>

Things you can do with Pharao
-----------------------------

The main reason to use pharao is that you can create yourself a web application by doing nothing more than uploading a file- like you can with the OG web language, PHP. No chosing a port, creating the reverse proxy config, making the daemon run- just upload and that's it.

**One shot form handler**

```nim
# /var/www/collect.nim
if request.method == "POST":
else:
<!DOCTYPE html>
<form method="post" action="">
<input type="text" placeholder="Email">
<input type="submit"
</form>
""" % s
```


Run as a daemon
---------------

The easiest way to run pharao on a Linux web server is by using systemd. You will get a full system-protected chroot setup with its own user with no further setup using this file

```
```

And then running and enabling the service

```
$ systemd daemon-reload
$ systemd start pharao
$ systemd enable pharao
```

Check if it works like so

```
systemd status pharao
```

Trace the logs

```
journalctl -u pharao --since '5 minutes ago' -f
```


Use with reverse proxy
----------------------

The real magic happens when you have a nice web server for some static files, and you can easily have some scripts there too.

Nginx will handle all files while you can now also drop in a quick script to handle some one-off task.

```
try_files
```

Use with apache
```

```

How it works
------------

Pharao uses the mummy webserver. When a request comes in, pharao checks the web server directory tree against the request path. If there is a matching Nim file, it wraps it with some boilerplate code and a request handler procedure. The result is compiled into a dynamic library, and new handler is loaded as a route for mummy to serve.

Nitty gritty
------------

Pharao files get included into a `proc`. Therefore, the pharao file you write is really a proc body. There is one exception, imports get extracted and added to the module. The rest is untouched.

Why?
----

One of the things that works well with PHP is deployment- if you need something quick, you can write a script on a server and you have a web app as soon as you save the file. This also makes it beginner-friendly- no boilerplate code to get things to run and no wizard-level systems administration skills required.

The thing is that there is a strong bias for developers to stick with whatever they already know, which is what they learnt at first. Pharao is an attempt to replicate as much of PHP's beginner friendliness as possible for Nim, in the hopes that beginner programmers see Nim as an easy way to get things done and then stick to it. I hope Nim will power 80% of the web at some point.

