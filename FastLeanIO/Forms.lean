import FastLeanIO.App

def Option.toExcept (value : Option α) (error : ε) : Except ε α :=
  match value with | some a => .ok a | none => .error error

namespace FastLeanIO
open Std.Http

/-- Decode URL form components strictly, including `+` as space. -/
def decodeFormComponent (s : String) : Except String String := do
  let encoded ← (URI.EncodedQueryParam.fromString? (s.replace "+" "%20")).toExcept "invalid percent encoding"
  encoded.decode.toExcept "invalid UTF-8"

def decodeForm (body : ByteArray) (maxFields : Nat := 128) : Except String (Std.HashMap String String) := do
  let s ← (String.fromUTF8? body).toExcept "invalid UTF-8"
  if s.isEmpty then return {}
  let fields := s.splitOn "&"
  unless fields.length ≤ maxFields do throw "too many form fields"
  let mut query : Std.HashMap String String := {}
  for field in fields do
    let pair := field.splitOn "="
    let key ← decodeFormComponent pair.head!
    let value ← decodeFormComponent (String.intercalate "=" pair.tail!)
    if query.contains key then throw "duplicate form field"
    query := query.insert key value
  return query

instance [FromForm α] : HTTP.FromBody (Form α) := ⟨fun r => do
  let mime := ((r.header? "content-type").getD "").splitOn ";" |>.head! |>.trimAscii |>.toString |>.toLower
  unless mime == "application/x-www-form-urlencoded" do
    throw (.bad_media_error "expected application/x-www-form-urlencoded")
  let query ← (decodeForm r.body).mapError FromRequestBodyError.syntax_error
  return ⟨← (FromForm.fromForm query).mapError FromRequestBodyError.semantic_error⟩⟩

structure MultipartPart where
  name : String
  filename : Option String
  contentType : Option String
  body : ByteArray

/-- Save to an application-selected path; never derives a path from the uploaded filename.
The caller controls overwrite policy and directory permissions. -/
def MultipartPart.saveTo (part : MultipartPart) (destination : System.FilePath) : FastHTTP.Action Unit :=
  FastHTTP.Action.ofAsync do
    Std.Async.EAsync.ofTask (← IO.asTask (IO.FS.writeBinFile destination part.body))

/-- Buffered, bounded upload. Filenames are metadata and never destination paths. -/
structure Multipart where
  parts : Array MultipartPart

structure MultipartLimits where
  maxBytes : Nat := 1024 * 1024
  maxParts : Nat := 128
  maxHeaderBytes : Nat := 8192

/-- Split header parameters, respecting quoted semicolons and backslash escapes. -/
def headerParameters (s : String) : Except String (Array String) := do
  let mut fields := #[]
  let mut field := ""
  let mut quoted := false
  let mut escaped := false
  for c in s.toList do
    if escaped then
      field := field.push c
      escaped := false
    else if c == '\\' && quoted then
      escaped := true
    else if c == '"' then
      quoted := !quoted
    else if c == ';' && !quoted then
      fields := fields.push field.trimAscii.toString
      field := ""
    else
      field := field.push c
  if quoted || escaped then throw "unterminated quoted parameter"
  return fields.push field.trimAscii.toString

private def parameter (fields : Array String) (key : String) : Except String (Option String) := do
  let mut found := none
  for field in fields.toList.drop 1 do
    let parts := field.splitOn "="
    if parts.head!.trimAscii.toString.toLower == key then
      if found.isSome then throw "duplicate header parameter"
      unless parts.length ≥ 2 do throw "missing parameter value"
      found := some (String.intercalate "=" parts.tail!).trimAscii.toString
  return found

private def parsePartHeaders (bytes : ByteArray) : Except String (String × Option String × Option String) := do
  let s ← (String.fromUTF8? bytes).toExcept "invalid multipart headers"
  let mut disposition := none
  let mut contentType := none
  for line in s.splitOn "\r\n" do
    let pieces := line.splitOn ":"
    unless pieces.length ≥ 2 do throw "invalid multipart header"
    let key := pieces.head!.toLower
    let value := (String.intercalate ":" pieces.tail!).trimAscii.toString
    if key == "content-disposition" then
      if disposition.isSome then throw "duplicate Content-Disposition"
      disposition := some value
    else if key == "content-type" then
      if contentType.isSome then throw "duplicate Content-Type"
      contentType := some value
  let fields ← headerParameters (← disposition.toExcept "missing Content-Disposition")
  unless (fields[0]?.getD "").toLower == "form-data" do throw "expected form-data disposition"
  let name ← (← parameter fields "name").toExcept "missing part name"
  let filename ← parameter fields "filename"
  return (name, filename, contentType)

/-- KMP scans binary data; only complete delimiter lines terminate a part. -/
def parseMultipart (contentType : String) (body : ByteArray)
    (limits : MultipartLimits := {}) : Except String Multipart := do
  unless body.size ≤ limits.maxBytes do throw "multipart body too large"
  let params ← headerParameters contentType
  unless (params[0]?.getD "").toLower == "multipart/form-data" do throw "expected multipart/form-data"
  let boundary ← (← parameter params "boundary").toExcept "missing boundary"
  unless boundary.utf8ByteSize > 0 && boundary.utf8ByteSize ≤ 70 &&
      boundary.toList.all (fun c => c.toNat ≥ 32 && c.toNat < 127) && !boundary.endsWith " " do
    throw "invalid boundary"
  let initial := ("--" ++ boundary).toUTF8
  unless body.extract 0 initial.size == initial do throw "missing initial boundary"
  let delimiter := Search.new ("\r\n--" ++ boundary).toUTF8
  let headerEnd := Search.new "\r\n\r\n".toUTF8
  let mut cursor := initial.size
  let mut parts := #[]
  while cursor < body.size do
    let suffix := body.extract cursor (cursor + 2)
    if suffix == "--".toUTF8 then
      let rest := body.extract (cursor + 2) body.size
      unless rest.isEmpty || rest == "\r\n".toUTF8 do throw "unexpected multipart epilogue"
      return ⟨parts⟩
    unless suffix == "\r\n".toUTF8 do throw "invalid boundary line"
    unless parts.size < limits.maxParts do throw "too many multipart parts"
    cursor := cursor + 2
    let stop ← (headerEnd.search body cursor).toExcept "incomplete part headers"
    unless stop - cursor ≤ limits.maxHeaderBytes do throw "part headers too large"
    let (name, filename, contentType) ← parsePartHeaders (body.extract cursor stop)
    let start := stop + 4
    let mut scan := start
    let mut ending := none
    while scan < body.size do
      let position ← (delimiter.search body scan).toExcept "missing closing boundary"
      let after := position + delimiter.needle.size
      let tail := body.extract after (after + 2)
      let finalLine := tail == "--".toUTF8 && (after + 2 == body.size || body.extract (after + 2) (after + 4) == "\r\n".toUTF8)
      if tail == "\r\n".toUTF8 || finalLine then
        ending := some position
        break
      scan := position + 1
    let position ← ending.toExcept "missing closing boundary"
    parts := parts.push { name, filename, contentType, body := body.extract start position }
    cursor := position + delimiter.needle.size
  throw "incomplete multipart body"

instance : HTTP.FromBody Multipart := ⟨fun r => do
  let mime := (r.header? "content-type").getD ""
  unless (mime.splitOn ";").head!.trimAscii.toString.toLower == "multipart/form-data" do
    throw (.bad_media_error "expected multipart/form-data")
  (parseMultipart mime r.body).mapError FromRequestBodyError.syntax_error⟩

end FastLeanIO
