# /var/www/nimja.nim
import std/random, nimja
randomize()

let battleCry = ["Hee", "Hoo", "Haa-ya"].sample
compileTemplateStr """
I'm a Nimja

{{ battleCry }}
"""
