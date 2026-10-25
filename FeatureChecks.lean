import FastLeanIO

open FastLeanIO
private def require (ok : Bool) (message : String) : IO Unit :=
  unless ok do throw (IO.userError message)

private def multipart (bytes : ByteArray) : ByteArray :=
  "--abc\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a;\\\"b.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".toUTF8 ++ bytes ++ "\r\n--abc--\r\n".toUTF8

def main : IO Unit := do
  let fields ← IO.ofExcept ((decodeForm "name=a%2Bb+c&count=7".toUTF8).mapError IO.userError)
  require (fields["name"]? == some "a+b c") "form plus/space regression"
  require (decodeForm ByteArray.empty |>.isOk) "empty form"
  for bad in ["name=%", "name=%0", "name=%GG", "name=%FF", "a=1&a=2", "%61=1&a=2"] do
    require (decodeForm bad.toUTF8 |> fun result => !result.isOk) s!"accepted malformed form: {bad}"
  require (decodeForm "a=1&b=2".toUTF8 1 |> fun result => !result.isOk) "form field limit"
  let data := ByteArray.mk #[0,255,128,13,10,65] ++ "\r\n--abcoops\r\n--abc--oops".toUTF8
  let body := multipart data
  let parsed ← IO.ofExcept ((parseMultipart "multipart/form-data; boundary=\"abc\"" body).mapError IO.userError)
  require (parsed.parts.size == 1) "multipart count"
  let some part := parsed.parts[0]? | throw (IO.userError "missing upload")
  let destination := System.FilePath.mk s!"/tmp/fastleanio-upload-{← IO.monoNanosNow}"
  let context ← Std.CancellationContext.new
  try
    (FastHTTP.Action.inContext (part.saveTo destination) context).block
    require ((← IO.FS.readBinFile destination) == data) "saved upload differs"
  finally
    context.cancel .cancel
    IO.FS.removeFile destination
  require (parsed.parts[0]?.map (·.body) == some data) "multipart binary delimiter lookalikes"
  require (parsed.parts[0]?.bind (·.filename) == some "a;\"b.bin") "quoted filename"
  require (parseMultipart "multipart/form-data; boundary=abc" body { maxBytes := body.size - 1 } |> fun result => !result.isOk) "multipart byte limit"
  require (parseMultipart "multipart/form-data; boundary=abc" body { maxParts := 0 } |> fun result => !result.isOk) "multipart part limit"
  require (parseMultipart "multipart/form-data; boundary=abc" body { maxHeaderBytes := 4 } |> fun result => !result.isOk) "multipart header limit"
  for typ in ["multipart/form-data", "multipart/form-data; boundary=", "multipart/form-data; boundary=\"abc", "multipart/form-data; boundary=abc; boundary=abc"] do
    require (parseMultipart typ body |> fun result => !result.isOk) "invalid boundary accepted"
  for size in [:51] do
    for start in [:56] do
      for ending in [:56] do
        let parsed := (byteRange s!"bytes={start}-{ending}" size).map Except.toOption
        -- Independent reference: enumerate the bytes selected by the interval.
        let selected := (List.range size).filter fun i => start ≤ i && i ≤ ending
        let expected := selected.head?.map fun first => (first, selected.length)
        require (parsed == some expected) "closed range differs from enumerated bytes"
      let parsed := (byteRange s!"bytes=-{start}" size).map Except.toOption
      let selected := ((List.range size).reverse.take start).reverse
      let expected := selected.head?.map fun first => (first, selected.length)
      require (parsed == some expected) "suffix range differs from enumerated bytes"
  IO.println "Feature checks passed: form, bounded binary multipart, 162792 exhaustive closed/suffix ranges"
