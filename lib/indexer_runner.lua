local json = require('json')
local search = require('search')
local embed = require('embed')

-- Usage: luajit lib/indexer_runner.lua <queue_file>
local qfile = arg and arg[1] or '.jenova/index_queue.json'
local f = io.open(qfile, 'r')
if not f then
  io.stderr:write('[indexer_runner] queue file not found: ' .. tostring(qfile) .. '\n')
  os.exit(1)
end
local content = f:read('*a')
f:close()
local ok, data = pcall(json.decode, content)
if not ok or type(data) ~= 'table' then
  io.stderr:write('[indexer_runner] failed to parse queue file\n')
  os.remove(qfile)
  os.exit(1)
end

-- initialize embedder if available
pcall(function() embed.init() end)
search.init_embeddings(embed)

local res = search.process_embedding_queue(data)
io.write(string.format('[indexer_runner] processed %d files\n', res))
os.remove(qfile)
return 0
