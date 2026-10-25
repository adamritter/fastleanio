import FastLeanIO.Forms

namespace FastLeanIO
open Std.Async

/-- Blocking filesystem operations run on Lean's task pool, not the libuv worker. -/
private def disk (action : IO α) : Async α := do
  EAsync.ofTask (← IO.asTask action)

/-- Single byte range. Multiple/malformed ranges are ignored; unsatisfiable ranges give 416. -/
def byteRange (value : String) (size : Nat) : Option (Except Unit (Nat × Nat)) := do
  let unit := value.splitOn "="
  unless unit.length == 2 && unit[0]!.trimAscii.toString.toLower == "bytes" do none
  let parts := unit[1]!.trimAscii.toString.splitOn "-"
  unless parts.length == 2 do none
  if parts[0]! == "" then
    let suffix ← parts[1]!.toNat?
    return Standards.suffixSelection size suffix
  let start ← parts[0]!.toNat?
  let ending ← if parts[1]! == "" then some (size - 1) else parts[1]!.toNat?
  if !parts[1]!.isEmpty && ending < start then none
  return Standards.closedSelection size start ending

private def weakTag (tag : String) : String :=
  (tag.dropPrefix? "W/").map (·.toString) |>.getD tag

private def matchesTag (value tag : String) : Bool :=
  value.trimAscii.toString == "*" || (value.splitOn ",").any fun v => weakTag v.trimAscii.toString == weakTag tag

/-- Root is canonicalized at startup. Only serve a deployment-owned, immutable tree;
concurrent symlink replacement by an untrusted writer is not supported. -/
structure StaticFiles where
  root : System.FilePath
  cacheControl : String := "public, max-age=0"
  chunkBytes : Nat := 65536

def StaticFiles.create (root : System.FilePath) : IO StaticFiles := do
  return { root := ← IO.FS.realPath root }

private def fileMime (path : System.FilePath) : String :=
  match path.extension.getD "" with
  | "html" => "text/html; charset=utf-8"
  | "css" => "text/css; charset=utf-8"
  | "js" => "text/javascript; charset=utf-8"
  | "json" => "application/json"
  | "txt" => "text/plain; charset=utf-8"
  | "svg" => "image/svg+xml"
  | "png" => "image/png"
  | "jpg" | "jpeg" => "image/jpeg"
  | _ => "application/octet-stream"

private def fileSource (path : System.FilePath) (start count chunkBytes : Nat) :
    ContextAsync FastHTTP.AsyncStream.Source := fun context => do
  let handle ← disk (IO.FS.Handle.mk path .read)
  -- Std has no portable seek operation; skip in bounded chunks.
  let mut skip := start
  while skip > 0 do
    if ← context.isCancelled then throw (IO.userError "file stream cancelled")
    let bytes ← disk (handle.read (min skip 65536).toUSize)
    if bytes.isEmpty then throw (IO.userError "file changed during range read")
    skip := skip - bytes.size
  let state ← Std.Mutex.new (some handle, count)
  return {
    next := fun context => do
      if ← context.isCancelled then throw (IO.userError "file stream cancelled")
      let (handle, remaining) ← state.atomically (m := IO) get
      let some handle := handle | return none
      if remaining == 0 then
        state.atomically (m := IO) (set ((none : Option IO.FS.Handle), 0))
        return none
      let chunk ← disk (handle.read (min remaining (max chunkBytes 1)).toUSize)
      if chunk.isEmpty then throw (IO.userError "file changed during response")
      state.atomically (m := IO) do
        let (current, _) ← get
        if current.isSome then set (some handle, remaining - chunk.size)
      return some chunk
    close := state.atomically (m := IO) (set ((none : Option IO.FS.Handle), 0)) }

/-- Stream a regular file with weak metadata ETag and single-range support.
Weak validators cannot satisfy If-Range, so it correctly falls back to a full response. -/
def StaticFiles.respond (files : StaticFiles) (relative : String) (req : HTTP.Request) : FastHTTP.Action HTTP.Response := do
  let missing := (HTTP.text "Not Found").withStatus .notFound
  let parts := relative.splitOn "/"
  if relative.startsWith "/" || parts.any (fun p => p == ".." || p == "." || p.startsWith "." || p.contains '\\' || p.contains '\x00') then
    return missing
  let result ← FastHTTP.Action.ofAsync <| disk do
    try
      let path ← IO.FS.realPath (files.root / relative)
      unless path.toString.startsWith (files.root.toString ++ "/") do return none
      let metadata ← path.metadata
      unless metadata.type == .file do return none
      return some (path, metadata)
    catch _ => return none
  let some (path, metadata) := result | return missing
  let size := metadata.byteSize.toNat
  let tag := s!"W/\"{size}-{metadata.modified.sec}-{metadata.modified.nsec}\""
  let headers (r : HTTP.Response) := r.withHeader "etag" tag |>.withHeader "cache-control" files.cacheControl |>.withHeader "accept-ranges" "bytes" |>.withHeader "x-content-type-options" "nosniff"
  if let some value := req.http.header? "if-none-match" then
    if matchesTag value tag then return headers ((HTTP.text "").withStatus .notModified)
  let selected := if Standards.applyFileRange req.http.method size (req.http.header? "if-range").isSome then
      (req.http.header? "range").bind (byteRange · size)
    else none
  match selected with
  | some (.error _) =>
    return headers (((HTTP.text "").withStatus .rangeNotSatisfiable).withHeader "content-range" s!"bytes */{size}")
  | some (.ok (start, count)) =>
    return headers (((HTTP.stream (fileSource path start count files.chunkBytes) (fileMime path)).withStatus .partialContent).withHeader "content-range" s!"bytes {start}-{start + count - 1}/{size}")
  | none => return headers (HTTP.stream (fileSource path 0 size files.chunkBytes) (fileMime path))

end FastLeanIO
