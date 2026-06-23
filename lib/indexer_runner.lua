#!/usr/bin/env luajit
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
if not package.path:find(_dir, 1, true) then
  package.path = _dir .. "?.lua;" .. package.path
end

local json = require('json')
local search = require('search')
local embed = require('embed')

local home = os.getenv("HOME") or "/tmp"
local jca_home = os.getenv("JCA_HOME") or (home .. "/Jenova")
local state_dir = os.getenv("JENOVA_STATE") or (jca_home .. "/.system")
local qfile = arg and arg[1] or (state_dir .. "/index_queue.json")
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

local embed_ok = embed.init()
if not embed_ok then
  io.stderr:write('[indexer_runner] embed.init() failed — aborting without deleting queue\n')
  os.exit(1)
end
search.init_embeddings(embed)

local res = search.process_embedding_queue(data)
io.write(string.format('[indexer_runner] processed %d files\n', res))
os.remove(qfile)
os.exit(0)
