# /var/www/sqlite.nim
import waterpark/sqlite
#import db_connector/db_sqlite
import random
body = "foo"
randomize()
var asdf = "asdf"
asdf.shuffle

var db = newSqlitePool(10, "example.sqlite3")
db.withConnection c:
  discard
#c.exec sql""" INSERT INTO foo (foo) VALUES (?) """, asdf
#for row in c.fastRows(sql"SELECT * FROM foo"):
#  body.add row[0]
#  body.add "\t"
#  body.add row[1]
#  body.add "\n"

