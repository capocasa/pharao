# /var/www/sqlite.nim

#import waterpark/sqlite
import random, os, db_connector/db_sqlite
randomize(123)
var asdf = "asdf"

var db {.threadvar.}: DbConn
let path = getTempDir() / "testpharao_sqlite.db"
db = open(path,"","","")
db.exec sql""" DROP TABLE IF EXISTS foo """
db.exec sql""" CREATE TABLE foo (id INTEGER PRIMARY KEY AUTOINCREMENT, foo string) """
db.exec sql""" INSERT INTO foo (foo) VALUES (?) """, asdf
asdf.shuffle
db.exec sql""" INSERT INTO foo (foo) VALUES (?) """, asdf
asdf.shuffle
db.exec sql""" INSERT INTO foo (foo) VALUES (?) """, asdf
asdf.shuffle
db.exec sql""" INSERT INTO foo (foo) VALUES (?) """, asdf
for row in db.fastRows(sql"SELECT * FROM foo"):
  echo row[0], "\t", row[1]

