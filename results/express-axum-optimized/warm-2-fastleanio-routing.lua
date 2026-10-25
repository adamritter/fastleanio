threads = {}
function setup(thread) table.insert(threads, thread) end
valid=0; errors=0
wrk.method="GET"
wrk.path="/api/hello/name-287868488"
wrk.body=""
expected="\104\101\108\108\111\032\110\097\109\101\045\050\056\055\056\054\056\052\056\056"
function response(status, headers, body)
 if status == 200 and body == expected and headers["x-middleware"] == "ran" then valid=valid+1 else errors=errors+1 end
end
function done(summary, latency, requests)
 local n,e=0,0
 for _,t in ipairs(threads) do n=n+t:get("valid");e=e+t:get("errors") end
 io.write(string.format("VALIDATED %d ERRORS %d REQUESTS %d\n",n,e,summary.requests))
end