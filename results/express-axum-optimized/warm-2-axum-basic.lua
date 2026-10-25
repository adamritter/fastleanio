threads = {}
function setup(thread) table.insert(threads, thread) end
valid=0; errors=0
wrk.method="GET"
wrk.path="/basic"
wrk.body=""
wrk.headers["Authorization"]="Basic YmVuY2g6c2VjcmV0"
expected="\097\117\116\104\101\110\116\105\099\097\116\101\100"
function response(status, headers, body)
 if status == 200 and body == expected and headers["x-middleware"] == "ran" then valid=valid+1 else errors=errors+1 end
end
function done(summary, latency, requests)
 local n,e=0,0
 for _,t in ipairs(threads) do n=n+t:get("valid");e=e+t:get("errors") end
 io.write(string.format("VALIDATED %d ERRORS %d REQUESTS %d\n",n,e,summary.requests))
end