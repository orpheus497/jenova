local fs_sync = {}
local db = require("db")
local git = require("git")
local ffi = require("ffi")

local home_dir = os.getenv("HOME") or "/tmp"
local jca_home = os.getenv("JCA_HOME") or (home_dir .. "/Jenova")
local workspaces_dir = os.getenv("JENOVA_WORKSPACES") or (jca_home .. "/Workspaces")
local global_trash = jca_home .. "/.trash"

local function recursive_mkdir(path)
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
end

recursive_mkdir(global_trash)

-- Traverse db to construct physical path
local function get_physical_path_for_note(note)
    if not note.folderId or note.folderId == "" then return nil end
    local folder = nil
    local folders, _ = db.get_folders(note.folderId)
    if folders and #folders > 0 then folder = folders[1] else return nil end
    
    local project = nil
    local projects, _ = db.get_projects(folder.projectId)
    if projects and #projects > 0 then project = projects[1] else return nil end
    
    local workspace = nil
    local workspaces, _ = db.get_workspaces()
    for _, w in ipairs(workspaces) do if w.id == project.workspaceId then workspace = w break end end
    if not workspace then return nil end
    
    return string.format("%s/%s/%s/%s/%s.md", workspaces_dir, workspace.name, project.name, folder.name, note.title), workspace.name
end

local function get_physical_path_for_asset(asset)
    if not asset.folderId or asset.folderId == "" then return nil end
    local folder = nil
    local folders, _ = db.get_folders(asset.folderId)
    if folders and #folders > 0 then folder = folders[1] else return nil end
    
    local project = nil
    local projects, _ = db.get_projects(folder.projectId)
    if projects and #projects > 0 then project = projects[1] else return nil end
    
    local workspace = nil
    local workspaces, _ = db.get_workspaces()
    for _, w in ipairs(workspaces) do if w.id == project.workspaceId then workspace = w break end end
    if not workspace then return nil end
    
    return string.format("%s/%s/%s/%s/%s", workspaces_dir, workspace.name, project.name, folder.name, asset.name), workspace.name
end

local function get_workspace_trash(workspace_name)
    local path = workspaces_dir .. "/" .. workspace_name .. "/.trash"
    recursive_mkdir(path)
    return path
end

function fs_sync.sync_workspace(workspace)
    local path = workspaces_dir .. "/" .. workspace.name
    recursive_mkdir(path)
    git.init(path)
end

function fs_sync.sync_note(note)
    local path, ws_name = get_physical_path_for_note(note)
    if not path then return false end
    
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
    if not path then return false end
    
    local dir = path:match("(.+)/[^/]+$")
    recursive_mkdir(dir)
    
    local f = io.open(path, "wb")
    if f then
        -- Decode base64 if needed? Assuming content is raw or base64 from UI.
        -- We will just write it.
        f:write(asset.content or "")
        f:close()
        git.add(workspaces_dir .. "/" .. ws_name, path)
        return true
    end
    return false
end

function fs_sync.trash_note(note)
    local path, ws_name = get_physical_path_for_note(note)
    if not path then return false end
    
    local trash_dir = get_workspace_trash(ws_name)
    local filename = path:match("([^/]+)$")
    local trash_path = trash_dir .. "/" .. os.time() .. "_" .. filename
    os.execute("mv '" .. path:gsub("'", "'\\''") .. "' '" .. trash_path:gsub("'", "'\\''") .. "' 2>/dev/null")
    return true
end

function fs_sync.trash_fileAsset(asset)
    local path, ws_name = get_physical_path_for_asset(asset)
    if not path then return false end
    
    local trash_dir = get_workspace_trash(ws_name)
    local filename = path:match("([^/]+)$")
    local trash_path = trash_dir .. "/" .. os.time() .. "_" .. filename
    os.execute("mv '" .. path:gsub("'", "'\\''") .. "' '" .. trash_path:gsub("'", "'\\''") .. "' 2>/dev/null")
    return true
end

function fs_sync.trash_workspace(workspace)
    local path = workspaces_dir .. "/" .. workspace.name
    local trash_path = global_trash .. "/" .. os.time() .. "_" .. workspace.name
    os.execute("mv '" .. path:gsub("'", "'\\''") .. "' '" .. trash_path:gsub("'", "'\\''") .. "' 2>/dev/null")
    return true
end

return fs_sync
