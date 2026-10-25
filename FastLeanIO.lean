import FastLeanIO.Macro
import FastLeanIO.Forms
import FastLeanIO.Middleware
import FastLeanIO.Files
namespace FastLeanIO
abbrev Router := App.Router
abbrev Route := App.Route
abbrev Handler := App.Handler
abbrev Middleware := App.Middleware
abbrev Request := HTTP.Request
abbrev Response := HTTP.Response
abbrev Action := FastHTTP.Action
export App (empty serve compile mapResponse around extractSync extractAsync)
export HTTP (text stream sse)
abbrev IntoResponse := HTTP.IntoResponse
abbrev FromBody := HTTP.FromBody
abbrev FromParts := HTTP.FromParts
end FastLeanIO
