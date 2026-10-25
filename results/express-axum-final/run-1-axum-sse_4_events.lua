threads = {}
function setup(thread) table.insert(threads, thread) end
valid=0; errors=0
wrk.method="GET"
wrk.path="/sse"
wrk.body=""
expected="\105\100\058\032\048\010\100\097\116\097\058\032\101\118\101\110\116\045\048\010\010\105\100\058\032\049\010\100\097\116\097\058\032\101\118\101\110\116\045\049\010\010\105\100\058\032\050\010\100\097\116\097\058\032\101\118\101\110\116\045\050\010\010\105\100\058\032\051\010\100\097\116\097\058\032\101\118\101\110\116\045\051\010\010"
function response(status, headers, body)
 if status == 200 and body == expected and headers["x-middleware"] == "ran" then valid=valid+1 else errors=errors+1 end
end
function done(summary, latency, requests)
 local n,e=0,0
 for _,t in ipairs(threads) do n=n+t:get("valid");e=e+t:get("errors") end
 io.write(string.format("VALIDATED %d ERRORS %d REQUESTS %d\n",n,e,summary.requests))
end