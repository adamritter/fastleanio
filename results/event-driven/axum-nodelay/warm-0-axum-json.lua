threads = {}
function setup(thread) table.insert(threads, thread) end
valid=0; errors=0
wrk.method="POST"
wrk.path="/json"
wrk.body="\123\034\110\097\109\101\034\058\032\034\110\097\109\101\045\056\050\051\048\050\049\052\054\057\034\044\032\034\099\111\117\110\116\034\058\032\050\054\051\055\050\125"
wrk.headers["Content-Type"]="application/json"
expected="\110\097\109\101\045\056\050\051\048\050\049\052\054\057\058\050\054\051\055\051"
function response(status, headers, body)
 if status == 200 and body == expected and headers["x-middleware"] == "ran" then valid=valid+1 else errors=errors+1 end
end
function done(summary, latency, requests)
 local n,e=0,0
 for _,t in ipairs(threads) do n=n+t:get("valid");e=e+t:get("errors") end
 io.write(string.format("VALIDATED %d ERRORS %d REQUESTS %d\n",n,e,summary.requests))
end