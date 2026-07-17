local fs_sync = {}
local db = require("db")
local git = require("git")
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
    int mkdir(const char *pathname, int mode);
    int access(const char *pathname, int mode);
    int rmdir(const char *pathname);
]]

local home_dir = os.getenv("HOME") or "/tmp"
local jca_home = os.getenv("JCA_HOME") or (home_dir .. "/Jenova")
local workspaces_dir = os.getenv("JENOVA_WORKSPACES") or (jca_home .. "/Workspaces")
local global_trash = jca_home .. "/.trash"

local function recursive_mkdir(path)
    local p = ""
    if path:sub(1,1) == "/" then
        p = "/"
    end
    for dir in path:gmatch("[^/]+") do
        if p == "/" then p = p .. dir else p = p .. "/" .. dir end
        ffi.C.mkdir(p, 511) -- 0777 octal is 511 decimal
    end
end

local function sanitize(str)
    if not str then return "" end
    return str:gsub("[/\\]", "_"):gsub("^%.+", "")
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64dec = {}
for i = 1, 64 do b64dec[b64chars:byte(i)] = i - 1 end

local function base64_decode(data)
    data = data:gsub("[^A-Za-z0-9+/=]", "")
    local res = {}
    local len = #data
    local i = 1
    while i <= len do
        local b1_val, b2_val = data:byte(i), data:byte(i+1)
        local c1 = b1_val and b64dec[b1_val] or 0
        local c2 = b2_val and b64dec[b2_val] or 0
        local b3_val = data:byte(i+2)
        local c3 = b3_val and b64dec[b3_val] or nil
        local b4_val = data:byte(i+3)
        local c4 = b4_val and b64dec[b4_val] or nil
        
        local b1 = bit.bor(bit.lshift(c1, 2), bit.rshift(c2, 4))
        table.insert(res, string.char(b1))
        
        if c3 then
            local b2 = bit.bor(bit.lshift(bit.band(c2, 15), 4), bit.rshift(c3, 2))
            table.insert(res, string.char(b2))
            if c4 then
                local b3 = bit.bor(bit.lshift(bit.band(c3, 3), 6), c4)
                table.insert(res, string.char(b3))
            end
        end
        i = i + 4
    end
    return table.concat(res)
end

recursive_mkdir(global_trash)

-- Traverse db to construct physical path
local function get_physical_path_for_note(note)
    local safe_title = sanitize(note.title)
    if note.folderId and type(note.folderId) == "string" and note.folderId ~= "" and note.folderId ~= "null" then
        local folder = db.get_folder(note.folderId)
        local project = folder and db.get_project(folder.projectId)
        local workspace = project and db.get_workspace(project.workspaceId)
        if workspace then
            return string.format("%s/%s/%s/%s/%s_%s.md", workspaces_dir, sanitize(workspace.name), sanitize(project.name), sanitize(folder.name), safe_title, note.id), sanitize(workspace.name)
        end
    elseif note.projectId and type(note.projectId) == "string" and note.projectId ~= "" and note.projectId ~= "null" then
        local project = db.get_project(note.projectId)
        local workspace = project and db.get_workspace(project.workspaceId)
        if workspace then
            return string.format("%s/%s/%s/%s_%s.md", workspaces_dir, sanitize(workspace.name), sanitize(project.name), safe_title, note.id), sanitize(workspace.name)
        end
    elseif note.workspaceId and type(note.workspaceId) == "string" and note.workspaceId ~= "" and note.workspaceId ~= "null" then
        local workspace = db.get_workspace(note.workspaceId)
        if workspace then
            return string.format("%s/%s/%s_%s.md", workspaces_dir, sanitize(workspace.name), safe_title, note.id), sanitize(workspace.name)
        end
    end
    return string.format("%s/unassigned/%s_%s.md", workspaces_dir, safe_title, note.id), "unassigned"
end

local function get_physical_path_for_asset(asset)
    local safe_name = sanitize(asset.name)
    if asset.folderId and type(asset.folderId) == "string" and asset.folderId ~= "" and asset.folderId ~= "null" then
        local folder = db.get_folder(asset.folderId)
        local project = folder and db.get_project(folder.projectId)
        local workspace = project and db.get_workspace(project.workspaceId)
        if workspace then
            return string.format("%s/%s/%s/%s/%s_%s", workspaces_dir, sanitize(workspace.name), sanitize(project.name), sanitize(folder.name), safe_name, asset.id), sanitize(workspace.name)
        end
    elseif asset.projectId and type(asset.projectId) == "string" and asset.projectId ~= "" and asset.projectId ~= "null" then
        local project = db.get_project(asset.projectId)
        local workspace = project and db.get_workspace(project.workspaceId)
        if workspace then
            return string.format("%s/%s/%s/%s_%s", workspaces_dir, sanitize(workspace.name), sanitize(project.name), safe_name, asset.id), sanitize(workspace.name)
        end
    elseif asset.workspaceId and type(asset.workspaceId) == "string" and asset.workspaceId ~= "" and asset.workspaceId ~= "null" then
        local workspace = db.get_workspace(asset.workspaceId)
        if workspace then
            return string.format("%s/%s/%s_%s", workspaces_dir, sanitize(workspace.name), safe_name, asset.id), sanitize(workspace.name)
        end
    end
    return string.format("%s/unassigned/%s_%s", workspaces_dir, safe_name, asset.id), "unassigned"
end

local function get_workspace_trash(workspace_name)
    local path = workspaces_dir .. "/" .. workspace_name .. "/.trash"
    recursive_mkdir(path)
    return path
end

function fs_sync.sync_workspace(workspace)
    local safe_workspace = sanitize(workspace.name)
    local path = workspaces_dir .. "/" .. safe_workspace
    recursive_mkdir(path)
    local ok, out = git.init(path)
    if not ok then
        ffi.C.rmdir(path)
    end
    return ok, out
end

function fs_sync.sync_note(note)
    local path, ws_name = get_physical_path_for_note(note)
    if not path then 
        return false 
    end
    
    local dir = path:match("(.+)/[^/]+$")
    recursive_mkdir(dir)
    
    local f = io.open(path, "w")
    if f then
        f:write(note.content or "")
        f:close()
        git.add(workspaces_dir .. "/" .. ws_name, path)
        return true
    end
    return false
end

function fs_sync.sync_fileAsset(asset)
    local path, ws_name = get_physical_path_for_asset(asset)
    if not path then
        return false
    end
    
    local out_content = asset.content or ""
    local b64 = out_content:match("^data:.-;base64,(.*)")
    if b64 then
        local clean = b64:gsub("[^A-Za-z0-9+/=]", "")
        if #clean % 4 ~= 0 then return false end
        local ok, decoded = pcall(base64_decode, clean)
        if not ok then return false end
        out_content = decoded
    end
    
    local dir = path:match("(.+)/[^/]+$")
    recursive_mkdir(dir)
    
    local f = io.open(path, "wb")
    if f then
        f:write(out_content)
        f:close()
        git.add(workspaces_dir .. "/" .. ws_name, path)
        return true
    end
    return false
end

function fs_sync.trash_note(note)
    local path, ws_name = get_physical_path_for_note(note)
    if not path then
        if ws_name == "unassigned" then return true end
        return false
    end
    
    local trash_dir = get_workspace_trash(ws_name)
    local filename = path:match("([^/]+)$")
    local trash_path = trash_dir .. "/" .. os.time() .. "_" .. filename
    local ok, err = os.rename(path, trash_path)
    return ok ~= nil
end

function fs_sync.trash_fileAsset(asset)
    local path, ws_name = get_physical_path_for_asset(asset)
    if not path then
        if ws_name == "unassigned" then return true end
        return false
    end
    
    local trash_dir = get_workspace_trash(ws_name)
    local filename = path:match("([^/]+)$")
    local trash_path = trash_dir .. "/" .. os.time() .. "_" .. filename
    local ok, err = os.rename(path, trash_path)
    return ok ~= nil
end

function fs_sync.trash_workspace(workspace)
    local safe_workspace = sanitize(workspace.name)
    local path = workspaces_dir .. "/" .. safe_workspace
    local trash_path = global_trash .. "/" .. os.time() .. "_" .. safe_workspace
    local ok, err = os.rename(path, trash_path)
    return ok ~= nil
end

function fs_sync.trash_project(project)
    local workspace = db.get_workspace(project.workspaceId)
    if not workspace then return false end
    local safe_workspace = sanitize(workspace.name)
    local safe_project = sanitize(project.name)
    local path = workspaces_dir .. "/" .. safe_workspace .. "/" .. safe_project
    if ffi.C.access(path, 0) ~= 0 then
        local err = ffi.errno()
        if err == 2 then return true, nil, path end -- ENOENT
        return false, "access error: " .. tostring(err), path
    end
    local trash_dir = get_workspace_trash(safe_workspace)
    local trash_path = trash_dir .. "/" .. os.time() .. "_" .. safe_project
    local ok, err = os.rename(path, trash_path)
    return ok ~= nil, trash_path, path
end

function fs_sync.trash_folder(folder)
    local project = db.get_project(folder.projectId)
    if not project then return false end
    local workspace = db.get_workspace(project.workspaceId)
    if not workspace then return false end
    local safe_workspace = sanitize(workspace.name)
    local safe_project = sanitize(project.name)
    local safe_folder = sanitize(folder.name)
    local path = workspaces_dir .. "/" .. safe_workspace .. "/" .. safe_project .. "/" .. safe_folder
    if ffi.C.access(path, 0) ~= 0 then
        local err = ffi.errno()
        if err == 2 then return true, nil, path end -- ENOENT
        return false, "access error: " .. tostring(err), path
    end
    local trash_dir = get_workspace_trash(safe_workspace)
    local trash_path = trash_dir .. "/" .. os.time() .. "_" .. safe_folder
    local ok, err = os.rename(path, trash_path)
    return ok ~= nil, trash_path, path
end

function fs_sync.trash_path(base_dir, relative_path)
    local path = base_dir .. "/" .. relative_path
    local trash_dir = base_dir .. "/.trash"
    local trash_path = trash_dir .. "/" .. os.time() .. "/" .. relative_path
    
    local dir_part = trash_path:match("(.+)/[^/]+$")
    if dir_part then recursive_mkdir(dir_part) end
    
    local ok, err = os.rename(path, trash_path)
    return ok ~= nil, trash_path, path
end

return fs_sync
