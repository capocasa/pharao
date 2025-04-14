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

