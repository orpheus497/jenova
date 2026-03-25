local http = require('http')
local host = arg[1] or '127.0.0.1'
local port = arg[2] or '8080'
local timeout = tonumber(arg[3]) or 3
local url = string.format('http://%s:%s/health', host, port)
local code = http.get(url, timeout)
-- Accept 200, 404, 502, 503 as healthy
if code == 200 or code == 404 or code == 502 or code == 503 then
  os.exit(0)
else
  -- Non-zero exit means unhealthy
  os.exit(1)
end
