local ffi = require("ffi")
local json = require("json")

ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    
    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const char *sql, int (*callback)(void*,int,char**,char**), void *, char **errmsg);
    const char *sqlite3_errmsg(sqlite3*);
    
    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt *pStmt);
    int sqlite3_reset(sqlite3_stmt *pStmt);
    
    int sqlite3_bind_int(sqlite3_stmt*, int, int);
    int sqlite3_bind_int64(sqlite3_stmt*, int, int64_t);
    int sqlite3_bind_double(sqlite3_stmt*, int, double);
    int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
    int sqlite3_bind_null(sqlite3_stmt*, int);
    
    int sqlite3_column_count(sqlite3_stmt *pStmt);
    const char *sqlite3_column_name(sqlite3_stmt*, int N);
    int sqlite3_column_type(sqlite3_stmt*, int iCol);
    int sqlite3_column_int(sqlite3_stmt*, int iCol);
    int64_t sqlite3_column_int64(sqlite3_stmt*, int iCol);
    double sqlite3_column_double(sqlite3_stmt*, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
    int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
    const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
    int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, void(*)(void*));
    int sqlite3_bind_parameter_count(sqlite3_stmt*);
    
    void sqlite3_free(void*);
]]

local sql3 = ffi.load("sqlite3")

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_BLOB = 4
local SQLITE_NULL = 5

local db = {}
local db_ptr = ffi.new("sqlite3*[1]")

function db.init(db_path)
    local rc = sql3.sqlite3_open(db_path, db_ptr)
    if rc ~= SQLITE_OK then
        local err = ffi.string(sql3.sqlite3_errmsg(db_ptr[0]))
        print("[db] Failed to open database: " .. err)
        return false
    end
    print("[db] Connected to SQLite database at " .. db_path)

    -- Create Tables
    local schema = [[
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            name TEXT,
            lastModified INTEGER,
            currNode TEXT,
            folderId TEXT,
            projectId TEXT,
            workspaceId TEXT,
            forkedFromConversationId TEXT,
            mcpServerOverrides TEXT,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            convId TEXT,
            type TEXT,
            role TEXT,
            timestamp INTEGER,
            parent TEXT,
            children TEXT,
            content TEXT,
            thinking TEXT,
            toolCalls TEXT,
            extra TEXT,
            model TEXT,
            timings TEXT,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_messages_convId ON messages(convId);
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            workspaceId TEXT,
            name TEXT,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS folders (
            id TEXT PRIMARY KEY,
            projectId TEXT,
            name TEXT,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY,
            folderId TEXT,
            projectId TEXT,
            workspaceId TEXT,
            title TEXT,
            content TEXT,
            updatedAt INTEGER,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS fileAssets (
            id TEXT PRIMARY KEY,
            folderId TEXT,
            projectId TEXT,
            workspaceId TEXT,
            name TEXT,
            size INTEGER,
            type TEXT,
            uploadDate INTEGER,
            content TEXT,
            is_deleted INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_projects_workspaceId ON projects(workspaceId);
        CREATE INDEX IF NOT EXISTS idx_folders_projectId ON folders(projectId);
        CREATE INDEX IF NOT EXISTS idx_notes_folderId ON notes(folderId);
        CREATE INDEX IF NOT EXISTS idx_fileAssets_folderId ON fileAssets(folderId);
        CREATE TABLE IF NOT EXISTS llm_cache (
            cache_key TEXT PRIMARY KEY,
            response TEXT,
            timestamp INTEGER
        );
    ]]

    
    local errmsg = ffi.new("char*[1]")
    rc = sql3.sqlite3_exec(db_ptr[0], schema, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        print("[db] Schema creation failed: " .. ffi.string(errmsg[0]))
        sql3.sqlite3_free(errmsg[0])
        return false
    end

    -- Migrations: add is_deleted column to existing tables if missing
    local migrations = {
        "ALTER TABLE conversations ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE messages ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE workspaces ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE projects ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE folders ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE notes ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE fileAssets ADD COLUMN is_deleted INTEGER DEFAULT 0;",
        "ALTER TABLE conversations ADD COLUMN workspaceId TEXT;",
        "ALTER TABLE notes ADD COLUMN projectId TEXT;",
        "ALTER TABLE notes ADD COLUMN workspaceId TEXT;",
        "ALTER TABLE fileAssets ADD COLUMN projectId TEXT;",
        "ALTER TABLE fileAssets ADD COLUMN workspaceId TEXT;"
    }
    for _, mig in ipairs(migrations) do
        local mig_errmsg = ffi.new("char*[1]")
        local rc = sql3.sqlite3_exec(db_ptr[0], mig, nil, nil, mig_errmsg)
        if rc ~= SQLITE_OK then
            local err_str = ffi.string(mig_errmsg[0])
            sql3.sqlite3_free(mig_errmsg[0])
            if not string.match(err_str, "duplicate column name") then
                print("[db] Migration failed: " .. err_str .. " | SQL: " .. mig)
                if db_ptr[0] ~= nil then
                    sql3.sqlite3_close(db_ptr[0])
                    db_ptr[0] = nil
                end
                return false
            end
        end
    end

    return true
end

function db.close()
    if db_ptr[0] ~= nil then
        sql3.sqlite3_close(db_ptr[0])
        db_ptr[0] = nil
    end
end

local function execute_query(sql, params)
    local stmt = ffi.new("sqlite3_stmt*[1]")
    local rc = sql3.sqlite3_prepare_v2(db_ptr[0], sql, -1, stmt, nil)
    if rc ~= SQLITE_OK then
        print("[db] Prepare error: " .. ffi.string(sql3.sqlite3_errmsg(db_ptr[0])) .. " | SQL: " .. sql)
        return nil, ffi.string(sql3.sqlite3_errmsg(db_ptr[0]))
    end

    if params then
        local param_count = sql3.sqlite3_bind_parameter_count(stmt[0])
        for i = 1, param_count do
            local v = params[i]
            if type(v) == "number" then
                if math.floor(v) == v then
                    sql3.sqlite3_bind_int64(stmt[0], i, v)
                else
                    sql3.sqlite3_bind_double(stmt[0], i, v)
                end
            elseif type(v) == "string" then
                sql3.sqlite3_bind_text(stmt[0], i, v, #v, ffi.cast("void(*)(void*)", -1)) -- SQLITE_TRANSIENT
            elseif v == nil or v == json.null then
                sql3.sqlite3_bind_null(stmt[0], i)
            else
                local str_v = tostring(v)
                sql3.sqlite3_bind_text(stmt[0], i, str_v, #str_v, ffi.cast("void(*)(void*)", -1)) -- SQLITE_TRANSIENT
            end
        end
    end

    local results = {}
    local cols = sql3.sqlite3_column_count(stmt[0])
    
    while true do
        rc = sql3.sqlite3_step(stmt[0])
        if rc == SQLITE_ROW then
            local row = {}
            for i = 0, cols - 1 do
                local name = ffi.string(sql3.sqlite3_column_name(stmt[0], i))
                local ctype = sql3.sqlite3_column_type(stmt[0], i)
                if ctype == SQLITE_INTEGER then
                    row[name] = tonumber(sql3.sqlite3_column_int64(stmt[0], i))
                elseif ctype == SQLITE_FLOAT then
                    row[name] = tonumber(sql3.sqlite3_column_double(stmt[0], i))
                elseif ctype == SQLITE_TEXT then
                    local text = sql3.sqlite3_column_text(stmt[0], i)
                    local bytes = sql3.sqlite3_column_bytes(stmt[0], i)
                    row[name] = text ~= nil and ffi.string(text, bytes) or ""
                elseif ctype == SQLITE_BLOB then
                    local blob = sql3.sqlite3_column_blob(stmt[0], i)
                    local bytes = sql3.sqlite3_column_bytes(stmt[0], i)
                    row[name] = blob ~= ffi.NULL and ffi.string(blob, bytes) or ""
                elseif ctype == SQLITE_NULL then
                    row[name] = nil
                end
            end
            table.insert(results, row)
        elseif rc == SQLITE_DONE then
            break
        else
            local step_err = ffi.string(sql3.sqlite3_errmsg(db_ptr[0]))
            print("[db] Step error: " .. step_err)
            sql3.sqlite3_finalize(stmt[0])
            return nil, step_err
        end
    end
    
    sql3.sqlite3_finalize(stmt[0])
    return results, nil
end

function db.get_conversations()
    local sql = "SELECT * FROM conversations WHERE is_deleted = 0 ORDER BY lastModified DESC"
    local rows, err = execute_query(sql)
    if err then return nil, err end
    
    for _, row in ipairs(rows) do
        if row.mcpServerOverrides and row.mcpServerOverrides ~= "" then
            local ok, parsed = pcall(json.decode, row.mcpServerOverrides)
            row.mcpServerOverrides = ok and parsed or nil
        else
            row.mcpServerOverrides = nil
        end
    end
    return rows
end

function db.get_conversation(id)
    local sql = "SELECT * FROM conversations WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    
    local row = rows[1]
    if row.mcpServerOverrides and row.mcpServerOverrides ~= "" then
        local ok, parsed = pcall(json.decode, row.mcpServerOverrides)
        row.mcpServerOverrides = ok and parsed or nil
    else
        row.mcpServerOverrides = nil
    end
    return row
end

function db.insert_conversation(c)
    local sql = [[
        INSERT INTO conversations (id, name, lastModified, currNode, folderId, projectId, workspaceId, forkedFromConversationId, mcpServerOverrides, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
    ]]
    local overrides = c.mcpServerOverrides and json.encode(c.mcpServerOverrides) or nil
    local params = {
        c.id, c.name, c.lastModified, c.currNode, c.folderId, c.projectId, c.workspaceId, c.forkedFromConversationId, overrides
    }
    local _, err = execute_query(sql, params)
    return err == nil, err
end

function db.update_conversation(c)
    local sql = [[
        UPDATE conversations SET 
            name = ?, lastModified = ?, currNode = ?, folderId = ?, projectId = ?, workspaceId = ?, forkedFromConversationId = ?, mcpServerOverrides = ?
        WHERE id = ?
    ]]
    local overrides = c.mcpServerOverrides and json.encode(c.mcpServerOverrides) or nil
    local params = {
        c.name, c.lastModified, c.currNode, c.folderId, c.projectId, c.workspaceId, c.forkedFromConversationId, overrides, c.id
    }
    local _, err = execute_query(sql, params)
    return err == nil, err
end

function db.delete_conversation(id, delete_with_forks)
    execute_query("BEGIN TRANSACTION")
    
    if delete_with_forks then
        local sql_descendants = [[
            WITH RECURSIVE descendants AS (
                SELECT id FROM conversations WHERE id = ?
                UNION
                SELECT c.id FROM conversations c
                INNER JOIN descendants d ON c.forkedFromConversationId = d.id
            )
            UPDATE conversations SET is_deleted = 1 WHERE id IN (SELECT id FROM descendants)
        ]]
        local _, err1 = execute_query(sql_descendants, {id})
        
        local sql_messages = [[
            WITH RECURSIVE descendants AS (
                SELECT id FROM conversations WHERE id = ?
                UNION
                SELECT c.id FROM conversations c
                INNER JOIN descendants d ON c.forkedFromConversationId = d.id
            )
            UPDATE messages SET is_deleted = 1 WHERE convId IN (SELECT id FROM descendants)
        ]]
        local _, err2 = execute_query(sql_messages, {id})
        
        if err1 or err2 then
            execute_query("ROLLBACK")
            return false, err1 or err2
        end
    else
        local sql_reparent = "UPDATE conversations SET forkedFromConversationId = (SELECT forkedFromConversationId FROM conversations WHERE id = ?) WHERE forkedFromConversationId = ?"
        local _, err0 = execute_query(sql_reparent, {id, id})
        local _, err1 = execute_query("UPDATE conversations SET is_deleted = 1 WHERE id = ?", {id})
        local _, err2 = execute_query("UPDATE messages SET is_deleted = 1 WHERE convId = ?", {id})
        if err0 or err1 or err2 then
            execute_query("ROLLBACK")
            return false, err0 or err1 or err2
        end
    end
    
    local _, err3 = execute_query("COMMIT")
    if err3 then
        execute_query("ROLLBACK")
        return false, err3
    end
    return true
end

function db.get_messages(convId)
    local sql = "SELECT * FROM messages WHERE convId = ? AND is_deleted = 0 ORDER BY timestamp ASC"
    local rows, err = execute_query(sql, {convId})
    if err then return nil, err end
    
    for _, row in ipairs(rows) do
        if row.children and row.children ~= "" then
            local ok, parsed = pcall(json.decode, row.children)
            row.children = ok and parsed or {}
        else
            row.children = {}
        end
        if row.toolCalls and row.toolCalls ~= "" then
            local ok, parsed = pcall(json.decode, row.toolCalls)
            row.toolCalls = ok and parsed or nil
        else
            row.toolCalls = nil
        end
        if row.extra and row.extra ~= "" then
            local ok, parsed = pcall(json.decode, row.extra)
            row.extra = ok and parsed or nil
        end
        if row.timings and row.timings ~= "" then
            local ok, parsed = pcall(json.decode, row.timings)
            row.timings = ok and parsed or nil
        end
    end
    return rows
end

function db.get_all_messages()
    local sql = "SELECT * FROM messages WHERE is_deleted = 0"
    local rows, err = execute_query(sql)
    if err then return nil, err end
    
    for _, row in ipairs(rows) do
        if row.children and row.children ~= "" then
            local ok, parsed = pcall(json.decode, row.children)
            row.children = ok and parsed or {}
        else
            row.children = {}
        end
        if row.toolCalls and row.toolCalls ~= "" then
            local ok, parsed = pcall(json.decode, row.toolCalls)
            row.toolCalls = ok and parsed or nil
        else
            row.toolCalls = nil
        end
        if row.extra and row.extra ~= "" then
            local ok, parsed = pcall(json.decode, row.extra)
            row.extra = ok and parsed or nil
        end
        if row.timings and row.timings ~= "" then
            local ok, parsed = pcall(json.decode, row.timings)
            row.timings = ok and parsed or nil
        end
    end
    return rows
end

function db.insert_message(m)
    local sql = [[
        INSERT INTO messages (id, convId, type, role, timestamp, parent, children, content, thinking, toolCalls, extra, model, timings, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
    ]]
    local children = m.children and json.encode(m.children) or "[]"
    local extra = m.extra and json.encode(m.extra) or nil
    local timings = m.timings and json.encode(m.timings) or nil
    local toolCalls = type(m.toolCalls) == "table" and json.encode(m.toolCalls) or m.toolCalls
    
    local params = {
        m.id, m.convId, m.type, m.role, m.timestamp, m.parent, children, m.content, m.thinking, toolCalls, extra, m.model, timings
    }
    local _, err = execute_query(sql, params)
    return err == nil, err
end

function db.update_message(m)
    local sql = [[
        UPDATE messages SET 
            type = ?, role = ?, timestamp = ?, parent = ?, children = ?, content = ?, thinking = ?, toolCalls = ?, extra = ?, model = ?, timings = ?
        WHERE id = ?
    ]]
    local children = m.children and json.encode(m.children) or "[]"
    local extra = m.extra and json.encode(m.extra) or nil
    local timings = m.timings and json.encode(m.timings) or nil
    local toolCalls = type(m.toolCalls) == "table" and json.encode(m.toolCalls) or m.toolCalls
    
    local params = {
        m.type, m.role, m.timestamp, m.parent, children, m.content, m.thinking, toolCalls, extra, m.model, timings, m.id
    }
    local _, err = execute_query(sql, params)
    return err == nil, err
end

function db.delete_message(id)
    local sql = "UPDATE messages SET is_deleted = 1 WHERE id = ?"
    local _, err = execute_query(sql, {id})
    return err == nil, err
end

function db.get_message(id)
    local sql = "SELECT * FROM messages WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    
    local row = rows[1]
    if row.children and row.children ~= "" then
        local ok, parsed = pcall(json.decode, row.children)
        row.children = ok and parsed or {}
    else
        row.children = {}
    end
    if row.toolCalls and row.toolCalls ~= "" then
        local ok, parsed = pcall(json.decode, row.toolCalls)
        row.toolCalls = ok and parsed or nil
    else
        row.toolCalls = nil
    end
    if row.extra and row.extra ~= "" then
        local ok, parsed = pcall(json.decode, row.extra)
        row.extra = ok and parsed or nil
    end
    if row.timings and row.timings ~= "" then
        local ok, parsed = pcall(json.decode, row.timings)
        row.timings = ok and parsed or nil
    end
    return row
end

function db.delete_messages_bulk(ids)
    if not ids or #ids == 0 then return true end
    execute_query("BEGIN TRANSACTION")
    for _, id in ipairs(ids) do
        local _, err = execute_query("UPDATE messages SET is_deleted = 1 WHERE id = ?", {id})
        if err then
            execute_query("ROLLBACK")
            return false, err
        end
    end
    local _, err3 = execute_query("COMMIT")
    if err3 then
        execute_query("ROLLBACK")
        return false, err3
    end
    return true
end

function db.get_workspaces()
    local sql = "SELECT * FROM workspaces WHERE is_deleted = 0"
    local rows, err = execute_query(sql)
    return rows, err
end

function db.get_workspace(id)
    local sql = "SELECT * FROM workspaces WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    return rows[1]
end

function db.insert_workspace(w)
    local sql = "INSERT INTO workspaces (id, name, is_deleted) VALUES (?, ?, 0)"
    local _, err = execute_query(sql, {w.id, w.name})
    return err == nil, err
end

function db.delete_workspace(id)
    execute_query("BEGIN TRANSACTION")
    local _, err1 = execute_query("UPDATE workspaces SET is_deleted = 1 WHERE id = ?", {id})
    local _, err2 = execute_query("UPDATE projects SET is_deleted = 1 WHERE workspaceId = ?", {id})
    local _, err3 = execute_query("UPDATE folders SET is_deleted = 1 WHERE projectId IN (SELECT id FROM projects WHERE workspaceId = ?)", {id})
    local _, err4 = execute_query([[
        UPDATE notes SET is_deleted = 1 
        WHERE folderId IN (SELECT id FROM folders WHERE projectId IN (SELECT id FROM projects WHERE workspaceId = ?))
           OR projectId IN (SELECT id FROM projects WHERE workspaceId = ?)
           OR workspaceId = ?
    ]], {id, id, id})
    local _, err5 = execute_query([[
        UPDATE fileAssets SET is_deleted = 1 
        WHERE folderId IN (SELECT id FROM folders WHERE projectId IN (SELECT id FROM projects WHERE workspaceId = ?))
           OR projectId IN (SELECT id FROM projects WHERE workspaceId = ?)
           OR workspaceId = ?
    ]], {id, id, id})
    local _, err6 = execute_query([[
        UPDATE conversations SET is_deleted = 1 
        WHERE folderId IN (SELECT id FROM folders WHERE projectId IN (SELECT id FROM projects WHERE workspaceId = ?))
           OR projectId IN (SELECT id FROM projects WHERE workspaceId = ?)
           OR workspaceId = ?
    ]], {id, id, id})
    local _, err_msg = execute_query([[
        UPDATE messages SET is_deleted = 1 
        WHERE convId IN (
            SELECT id FROM conversations 
            WHERE folderId IN (SELECT id FROM folders WHERE projectId IN (SELECT id FROM projects WHERE workspaceId = ?))
               OR projectId IN (SELECT id FROM projects WHERE workspaceId = ?)
               OR workspaceId = ?
        )
    ]], {id, id, id})
    if err1 or err2 or err3 or err4 or err5 or err6 or err_msg then
        execute_query("ROLLBACK")
        return false, err1 or err2 or err3 or err4 or err5 or err6 or err_msg
    end
    local _, err7 = execute_query("COMMIT")
    if err7 then
        execute_query("ROLLBACK")
        return false, err7
    end
    return true
end

function db.get_projects(workspaceId)
    local sql = "SELECT * FROM projects WHERE workspaceId = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {workspaceId})
    return rows, err
end

function db.get_project(id)
    local sql = "SELECT * FROM projects WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    return rows[1]
end

function db.insert_project(p)
    local sql = "INSERT INTO projects (id, workspaceId, name, is_deleted) VALUES (?, ?, ?, 0)"
    local _, err = execute_query(sql, {p.id, p.workspaceId, p.name})
    return err == nil, err
end

function db.delete_project(id)
    execute_query("BEGIN TRANSACTION")
    local _, err1 = execute_query("UPDATE projects SET is_deleted = 1 WHERE id = ?", {id})
    local _, err2 = execute_query("UPDATE folders SET is_deleted = 1 WHERE projectId = ?", {id})
    local _, err3 = execute_query("UPDATE notes SET is_deleted = 1 WHERE folderId IN (SELECT id FROM folders WHERE projectId = ?) OR projectId = ?", {id, id})
    local _, err4 = execute_query("UPDATE fileAssets SET is_deleted = 1 WHERE folderId IN (SELECT id FROM folders WHERE projectId = ?) OR projectId = ?", {id, id})
    local _, err5 = execute_query("UPDATE conversations SET is_deleted = 1 WHERE folderId IN (SELECT id FROM folders WHERE projectId = ?) OR projectId = ?", {id, id})
    local _, err_msg = execute_query([[
        UPDATE messages SET is_deleted = 1 
        WHERE convId IN (
            SELECT id FROM conversations 
            WHERE folderId IN (SELECT id FROM folders WHERE projectId = ?) OR projectId = ?
        )
    ]], {id, id})
    if err1 or err2 or err3 or err4 or err5 or err_msg then
        execute_query("ROLLBACK")
        return false, err1 or err2 or err3 or err4 or err5 or err_msg
    end
    local _, err6 = execute_query("COMMIT")
    if err6 then
        execute_query("ROLLBACK")
        return false, err6
    end
    return true
end

function db.get_all_projects()
    local sql = "SELECT * FROM projects WHERE is_deleted = 0"
    local rows, err = execute_query(sql)
    return rows, err
end

function db.get_folders(projectId)
    local sql = ""
    local params = {}
    if projectId == nil or projectId == "" or projectId == json.null then
        sql = "SELECT * FROM folders WHERE projectId IS NULL AND is_deleted = 0"
    else
        sql = "SELECT * FROM folders WHERE projectId = ? AND is_deleted = 0"
        params = {projectId}
    end
    local rows, err = execute_query(sql, params)
    return rows, err
end

function db.get_folder(id)
    local sql = "SELECT * FROM folders WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    return rows[1]
end

function db.insert_folder(f)
    local sql = "INSERT INTO folders (id, projectId, name, is_deleted) VALUES (?, ?, ?, 0)"
    local _, err = execute_query(sql, {f.id, f.projectId, f.name})
    return err == nil, err
end

function db.delete_folder(id)
    execute_query("BEGIN TRANSACTION")
    local _, err1 = execute_query("UPDATE folders SET is_deleted = 1 WHERE id = ?", {id})
    local _, err2 = execute_query("UPDATE notes SET is_deleted = 1 WHERE folderId = ?", {id})
    local _, err3 = execute_query("UPDATE fileAssets SET is_deleted = 1 WHERE folderId = ?", {id})
    local _, err4 = execute_query("UPDATE conversations SET is_deleted = 1 WHERE folderId = ?", {id})
    local _, err_msg = execute_query("UPDATE messages SET is_deleted = 1 WHERE convId IN (SELECT id FROM conversations WHERE folderId = ?)", {id})
    if err1 or err2 or err3 or err4 or err_msg then
        execute_query("ROLLBACK")
        return false, err1 or err2 or err3 or err4 or err_msg
    end
    local _, err5 = execute_query("COMMIT")
    if err5 then
        execute_query("ROLLBACK")
        return false, err5
    end
    return true
end

function db.get_all_folders()
    local sql = "SELECT * FROM folders WHERE is_deleted = 0"
    local rows, err = execute_query(sql)
    return rows, err
end

function db.get_notes(folderId, projectId, workspaceId)
    local sql = "SELECT * FROM notes WHERE is_deleted = 0"
    local params = {}
    if folderId and folderId ~= "" and folderId ~= json.null then
        sql = sql .. " AND folderId = ?"
        table.insert(params, folderId)
    else
        sql = sql .. " AND folderId IS NULL"
    end
    if projectId and projectId ~= "" and projectId ~= json.null then
        sql = sql .. " AND projectId = ?"
        table.insert(params, projectId)
    else
        sql = sql .. " AND projectId IS NULL"
    end
    if workspaceId and workspaceId ~= "" and workspaceId ~= json.null then
        sql = sql .. " AND workspaceId = ?"
        table.insert(params, workspaceId)
    else
        sql = sql .. " AND workspaceId IS NULL"
    end
    local rows, err = execute_query(sql, params)
    return rows, err
end

function db.get_note(id)
    local sql = "SELECT * FROM notes WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    return rows[1]
end

function db.get_all_notes()
    local sql = "SELECT * FROM notes WHERE is_deleted = 0"
    local rows, err = execute_query(sql)
    return rows, err
end

function db.insert_note(n)
    local sql = "INSERT INTO notes (id, folderId, projectId, workspaceId, title, content, updatedAt, is_deleted) VALUES (?, ?, ?, ?, ?, ?, ?, 0)"
    local _, err = execute_query(sql, {n.id, n.folderId, n.projectId, n.workspaceId, n.title, n.content, n.updatedAt})
    return err == nil, err
end

function db.update_note(n)
    local sql = "UPDATE notes SET folderId = ?, projectId = ?, workspaceId = ?, title = ?, content = ?, updatedAt = ? WHERE id = ?"
    local _, err = execute_query(sql, {n.folderId, n.projectId, n.workspaceId, n.title, n.content, n.updatedAt, n.id})
    return err == nil, err
end

function db.delete_note(id)
    local sql = "UPDATE notes SET is_deleted = 1 WHERE id = ?"
    local _, err = execute_query(sql, {id})
    return err == nil, err
end

function db.get_fileAssets(folderId, projectId, workspaceId)
    local sql = "SELECT * FROM fileAssets WHERE is_deleted = 0"
    local params = {}
    if folderId and folderId ~= "" and folderId ~= json.null then
        sql = sql .. " AND folderId = ?"
        table.insert(params, folderId)
    else
        sql = sql .. " AND folderId IS NULL"
    end
    if projectId and projectId ~= "" and projectId ~= json.null then
        sql = sql .. " AND projectId = ?"
        table.insert(params, projectId)
    else
        sql = sql .. " AND projectId IS NULL"
    end
    if workspaceId and workspaceId ~= "" and workspaceId ~= json.null then
        sql = sql .. " AND workspaceId = ?"
        table.insert(params, workspaceId)
    else
        sql = sql .. " AND workspaceId IS NULL"
    end
    local rows, err = execute_query(sql, params)
    return rows, err
end

function db.get_fileAsset(id)
    local sql = "SELECT * FROM fileAssets WHERE id = ? AND is_deleted = 0"
    local rows, err = execute_query(sql, {id})
    if err or not rows or #rows == 0 then return nil, err end
    return rows[1]
end

function db.get_all_fileAssets()
    local sql = "SELECT * FROM fileAssets WHERE is_deleted = 0"
    local rows, err = execute_query(sql)
    return rows, err
end

function db.insert_fileAsset(f)
    local sql = "INSERT INTO fileAssets (id, folderId, projectId, workspaceId, name, size, type, uploadDate, content, is_deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)"
    local _, err = execute_query(sql, {f.id, f.folderId, f.projectId, f.workspaceId, f.name, f.size, f.type, f.uploadDate, f.content})
    return err == nil, err
end

function db.update_fileAsset(f)
    local sql = "UPDATE fileAssets SET folderId = ?, projectId = ?, workspaceId = ?, name = ?, size = ?, type = ?, uploadDate = ?, content = ? WHERE id = ?"
    local _, err = execute_query(sql, {f.folderId, f.projectId, f.workspaceId, f.name, f.size, f.type, f.uploadDate, f.content, f.id})
    return err == nil, err
end

function db.delete_fileAsset(id)
    local sql = "UPDATE fileAssets SET is_deleted = 1 WHERE id = ?"
    local _, err = execute_query(sql, {id})
    return err == nil, err
end

function db.get_cache(key)
    local sql = "SELECT * FROM llm_cache WHERE cache_key = ?"
    local rows, err = execute_query(sql, {key})
    if err or not rows or #rows == 0 then return nil, err end
    return rows[1]
end

function db.set_cache(key, response)
    local sql = "INSERT OR REPLACE INTO llm_cache (cache_key, response, timestamp) VALUES (?, ?, ?)"
    local _, err = execute_query(sql, {key, response, os.time()})
    
    local count_sql = "SELECT COUNT(*) as c FROM llm_cache"
    local count_rows = execute_query(count_sql)
    if count_rows and count_rows[1] and count_rows[1].c > 20 then
        local del_sql = "DELETE FROM llm_cache WHERE cache_key IN (SELECT cache_key FROM llm_cache ORDER BY timestamp ASC LIMIT ?)"
        execute_query(del_sql, {count_rows[1].c - 20})
    end
    return err == nil, err
end

function db.import_data(data)
    execute_query("BEGIN TRANSACTION")
    local function check(ok, err) if not ok then error(err) end end
    local ok, final_err = pcall(function()
        if data.conversations then for _, v in ipairs(data.conversations) do check(db.insert_conversation(v)) end end
        if data.messages then for _, v in ipairs(data.messages) do check(db.insert_message(v)) end end
        if data.workspaces then for _, v in ipairs(data.workspaces) do check(db.insert_workspace(v)) end end
        if data.projects then for _, v in ipairs(data.projects) do check(db.insert_project(v)) end end
        if data.folders then for _, v in ipairs(data.folders) do check(db.insert_folder(v)) end end
        if data.notes then for _, v in ipairs(data.notes) do check(db.insert_note(v)) end end
        if data.fileAssets then for _, v in ipairs(data.fileAssets) do check(db.insert_fileAsset(v)) end end
    end)
    if not ok then
        execute_query("ROLLBACK")
        return false, final_err
    end
    local _, err3 = execute_query("COMMIT")
    if err3 then
        execute_query("ROLLBACK")
        return false, err3
    end
    return true
end

return db
