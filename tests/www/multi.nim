
case request.httpMethod
of "POST":
  for m in request.decodeMultipart:
    if m.data.isSome:
      let (a, z) = m.data.get
      body.add request.body[a..z]
else:
  code = 405
  body = "need POST"

