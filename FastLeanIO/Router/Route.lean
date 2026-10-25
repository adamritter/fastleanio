module

public import Std.Http
public import FastLeanIO.Router.RoutePattern

namespace FastLeanIO.Router
open Std Http
open Std.Async


public abbrev Middleware (H : Type) := H → H

/-- Carries captured path parameters through request extensions. -/
public structure RouteParams where
  params : List (String × String)
deriving TypeName, Inhabited

public def RouteParams.lookup (self : RouteParams) (key : String) : Option String :=
  self.params.find? (·.1 == key) |>.map (·.2)

public structure Route (H : Type) where
  method     : Method
  pat        : RoutePattern
  handler    : H
  middlewares : Array (Middleware H) := #[]

/--
Appends a middleware to this route. Route middlewares run **after** router-level middlewares,
just before the handler.

Example:
```lean4
  GET "/admin" adminRoute (req : Request Body.Stream) := ...
  def router := Router.empty |>.addRoute (adminRoute.addMiddleware auth)
```
-/
public def Route.addMiddleware {H : Type} (middleware : Middleware H) (self : Route H) : Route H :=
  { self with middlewares := self.middlewares.push middleware }

/--
Runtime route constructor. Prefer the `GET`/`POST`/... term macros for
compile-time pattern validation and extractor support.
Use this only when the handler is already built as an application handler.
-/
public def Route.new {H : Type} (method : Method) (pattern : String) (handler : H) : Route H :=
  { method, handler, pat := RoutePattern.ofString pattern }

end FastLeanIO.Router
