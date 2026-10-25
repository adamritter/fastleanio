import FastLeanIO.HTTP

namespace FastLeanIO.HTTP

/-- The actual cached path is extensionally equal to reconstructing the response
through FastHTTP's certified constructor on the current response data. -/
theorem prepare_eq_constructor (response : Response) :
    response.prepare = response.data.prepare := by
  cases response with
  | fresh data => rfl
  | prepared data wire valid => exact valid.symm

/-- Both synchronous and deferred buffered completions enforce the same bound
and then use the same certified response data. -/
theorem prepareBounded_within (response : Response) (limit : Nat)
    (within : response.data.body.size ≤ limit) :
    response.prepareBounded limit = response.data.prepare := by
  simp [Response.prepareBounded, Nat.not_lt.mpr within, prepare_eq_constructor]

theorem prepareBounded_exceeded (response : Response) (limit : Nat)
    (exceeded : limit < response.data.body.size) :
    response.prepareBounded limit = .error "native response limit exceeded" := by
  simp [Response.prepareBounded, exceeded]

theorem withHeader_body (response : Response) (name value : String) :
    (response.withHeader name value).data.body = response.data.body := rfl

theorem withHeader_prepare (response : Response) (name value : String) :
    (response.withHeader name value).prepare =
      ({ response.data with headers := response.data.headers.push (name, value) } : ResponseData).prepare := rfl

theorem withStatus_prepare (response : Response) (status : Std.Http.Status) :
    (response.withStatus status).prepare =
      ({ response.data with status := status.toCode.toNat, reason := status.reasonPhrase } : ResponseData).prepare := rfl

theorem withHeader_stream (response : Response) (name value : String) :
    (response.withHeader name value).data.stream = response.data.stream := rfl

theorem withStatus_stream (response : Response) (status : Std.Http.Status) :
    (response.withStatus status).data.stream = response.data.stream := rfl

theorem withHeader_buffered (response : Response) (name value : String)
    (buffered : response.data.stream = none) :
    (response.withHeader name value).prepare =
      FastHTTP.Response.create response.data.body response.data.status response.data.reason
        response.data.contentType (response.data.headers.push (name, value)) := by
  simp [Response.withHeader, Response.prepare, ResponseData.prepare, buffered]

theorem withStatus_buffered (response : Response) (status : Std.Http.Status)
    (buffered : response.data.stream = none) :
    (response.withStatus status).prepare =
      FastHTTP.Response.create response.data.body status.toCode.toNat status.reasonPhrase
        response.data.contentType response.data.headers := by
  simp [Response.withStatus, Response.prepare, ResponseData.prepare, buffered]

/-- The executable binary-body extractor returns precisely the parser's bytes. -/
theorem binary_extractor_exact (request : FastHTTP.Request) :
    FromBody.fromBody (α := ByteArray) request = .ok request.body := rfl

end FastLeanIO.HTTP

#print axioms FastLeanIO.HTTP.prepare_eq_constructor
#print axioms FastLeanIO.HTTP.prepareBounded_within
#print axioms FastLeanIO.HTTP.prepareBounded_exceeded
#print axioms FastLeanIO.HTTP.withHeader_body
#print axioms FastLeanIO.HTTP.withHeader_prepare
#print axioms FastLeanIO.HTTP.withStatus_prepare
#print axioms FastLeanIO.HTTP.binary_extractor_exact
#print axioms FastLeanIO.HTTP.withHeader_stream
#print axioms FastLeanIO.HTTP.withStatus_stream
#print axioms FastLeanIO.HTTP.withHeader_buffered
#print axioms FastLeanIO.HTTP.withStatus_buffered
