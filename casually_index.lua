#!/usr/bin/env lua

-- casually_index: one sorted listing of one or more directory trees.
-- The command line, the config checks, the listing line format, the walk,
-- the publisher, and the progress panel live here.

local VERSION = "0.1.0"

if _VERSION ~= "Lua 5.5" then
    io.stderr:write("casually_index: need Lua 5.5\n")
    os.exit(1)
end

local function prepend(current, piece)
    if not piece or piece == "" then
        return current or ""
    end
    if not current or current == "" then
        return piece
    end
    return piece .. ";" .. current
end

do
    local home = os.getenv("HOME")
    local path = {
        "/usr/local/share/lua/5.5/?.lua",
        "/usr/local/share/lua/5.5/?/init.lua",
    }
    local cpath = {
        "/usr/local/lib/lua/5.5/?.so",
    }
    if home and home ~= "" then
        path[#path + 1] = home .. "/.luarocks/share/lua/5.5/?.lua"
        path[#path + 1] = home .. "/.luarocks/share/lua/5.5/?/init.lua"
        cpath[#cpath + 1] = home .. "/.luarocks/lib/lua/5.5/?.so"
        cpath[#cpath + 1] = home .. "/.luarocks/lib64/lua/5.5/?.so"
    end
    package.path = prepend(package.path, table.concat(path, ";"))
    package.cpath = prepend(package.cpath, table.concat(cpath, ";"))
end

local function load_library(name)
    local ok, mod = pcall(require, name)
    if not ok then
        io.stderr:write("casually_index: cannot load " .. name .. "\n")
        os.exit(1)
    end
    return mod
end

local lfs = load_library("lfs")
local dkjson = load_library("dkjson")
local terminal = load_library("terminal")

local M = {
    VERSION = VERSION,
    lfs = lfs,
    dkjson = dkjson,
    terminal = terminal,
}

local SWITCHES = {
    ["--help"] = true,
    ["--version"] = true,
}

local VALUE_KIND = {
    ["--config"] = "file",
    ["--source"] = "value",
    ["--index"] = "value",
}

function M.parse_args(argv)
    local n = #argv
    if n == 0 then
        return nil, "missing arguments", "config"
    end
    local seen = {}
    local values = {}
    local switch = nil
    local i = 1
    while i <= n do
        local tok = argv[i]
        if switch then
            return nil, switch .. " does not take other arguments", "config"
        end
        if SWITCHES[tok] then
            if next(seen) ~= nil then
                return nil, tok .. " does not take other arguments", "config"
            end
            switch = tok
            seen[tok] = true
            i = i + 1
        elseif VALUE_KIND[tok] then
            if seen[tok] then
                return nil, "repeated argument: " .. tok, "config"
            end
            local val = argv[i + 1]
            if val == nil then
                if tok == "--config" then
                    return nil, "--config requires a file", "config"
                end
                return nil, tok .. " requires a value", "config"
            end
            if val:sub(1, 1) == "-" then
                return nil, "unknown argument: " .. val, "config"
            end
            seen[tok] = true
            values[tok] = val
            i = i + 2
        elseif tok:sub(1, 1) == "-" then
            return nil, "unknown argument: " .. tok, "config"
        else
            return nil, "unexpected argument: " .. tok, "config"
        end
    end
    if switch == "--help" then
        return { help = true }
    end
    if switch == "--version" then
        return { version = true }
    end
    local has_config = seen["--config"]
    local has_source = seen["--source"]
    local has_index = seen["--index"]
    if has_config and (has_source or has_index) then
        return nil, "use either --config or --source with --index", "config"
    end
    if has_config then
        return { config = values["--config"] }
    end
    if has_source and not has_index then
        return nil, "--source requires --index", "config"
    end
    if has_index and not has_source then
        return nil, "--index requires --source", "config"
    end
    return {
        source = values["--source"],
        index = values["--index"],
    }
end

function M.help_text()
    return table.concat({
        "./casually_index.lua --config <file>",
        "./casually_index.lua --source <root> --index <file>",
        "./casually_index.lua --help",
        "./casually_index.lua --version",
        "",
        "--config <file>   JSON file with roots, work_dir, output_dir, and optional exclude.",
        "--source <root>   Directory to walk. Requires --index.",
        "--index <file>    Listing file to write. Requires --source.",
        "--help            Show this help and exit.",
        "--version         Show the script, Lua, and terminal.lua versions.",
        "",
    }, "\n")
end

function M.version_lines()
    return {
        "casually_index " .. VERSION,
        _VERSION,
        "terminal.lua " .. tostring(terminal._VERSION),
    }
end

local JSON_NULL = {}

local ROOT_KEYS = { path = true, alias = true }
local CONFIG_KEYS = {
    roots = true,
    work_dir = true,
    output_dir = true,
    exclude = true,
}

local function one_line(text)
    text = tostring(text)
    text = text:gsub("\t", "\\t")
    text = text:gsub("\n", "\\n")
    text = text:gsub("\r", "\\r")
    return text
end

local function fail(reason)
    return nil, reason, "config"
end

local function json_kind(value)
    if type(value) ~= "table" or value == JSON_NULL then
        return nil
    end
    local mt = getmetatable(value)
    if type(mt) == "table" then
        return mt.__jsontype
    end
    return nil
end

local function normalize(path)
    path = path:gsub("/+", "/")
    if path ~= "/" then
        path = path:gsub("/+$", "")
    end
    return path
end

local function has_dot_component(path)
    if path == "/" then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then
            return true
        end
    end
    return false
end

-- a is a strict path-prefix of b. "/" is a prefix of every other absolute path.
local function is_prefix(a, b)
    if a == b then
        return false
    end
    if a == "/" then
        return b:sub(1, 1) == "/"
    end
    return #b > #a and b:sub(1, #a) == a and b:sub(#a + 1, #a + 1) == "/"
end

local function overlaps(a, b)
    return a == b or is_prefix(a, b) or is_prefix(b, a)
end

local function sits_inside(dir, root)
    return dir == root or is_prefix(root, dir)
end

local function parent_of(path)
    if path == "/" then
        return nil
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then
        return "/"
    end
    return parent
end

local function check_syntax(label, raw, allow_slash)
    if raw == nil or raw == JSON_NULL then
        return fail(label .. " is required")
    end
    if type(raw) ~= "string" then
        return fail(label .. " must be a string")
    end
    if raw == "" then
        return fail(label .. " is empty")
    end
    local path = normalize(raw)
    if path:sub(1, 1) ~= "/" then
        return fail(label .. " must be absolute")
    end
    if has_dot_component(path) then
        return fail(label .. " contains '.' or '..'")
    end
    if path == "/" and not allow_slash then
        return fail(label .. " must not be /")
    end
    return path
end

local function lstat(fs, path)
    return fs.lstat(path)
end

local function check_real_dir(label, raw, fs, allow_slash)
    local path, err = check_syntax(label, raw, allow_slash)
    if not path then
        return nil, err, "config"
    end
    local attr = lstat(fs, path)
    if not attr then
        return fail(label .. " does not exist")
    end
    if attr.mode == "link" then
        return fail(label .. " is not a real directory")
    end
    if attr.mode ~= "directory" then
        return fail(label .. " is not a directory")
    end
    return path, attr
end

local function process_id()
    local f = io.open("/proc/self/stat", "r")
    if f then
        local n = f:read("*n")
        f:close()
        if n then
            return tostring(n)
        end
    end
    return tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000))
end

local function probe_writable(dir)
    local name = dir .. "/.casually_index.probe." .. process_id()
    local f = io.open(name, "w")
    if not f then
        return false
    end
    f:close()
    os.remove(name)
    return true
end

local function check_dir_pair(work_raw, output_raw, roots, fs)
    local work, work_attr, err
    work, err = check_real_dir("work_dir", work_raw, fs, true)
    if not work then
        return nil, err, "config"
    end
    work_attr = err
    local output, output_attr
    output, err = check_real_dir("output_dir", output_raw, fs, true)
    if not output then
        return nil, err, "config"
    end
    output_attr = err
    if work_attr.dev ~= output_attr.dev then
        return fail("work_dir and output_dir are on different filesystems")
    end
    if not probe_writable(work) then
        return fail("work_dir is not writable")
    end
    if output ~= work and not probe_writable(output) then
        return fail("output_dir is not writable")
    end
    for i = 1, #roots do
        if sits_inside(work, roots[i].path) then
            return fail("work_dir sits inside root " .. roots[i].path)
        end
        if sits_inside(output, roots[i].path) then
            return fail("output_dir sits inside root " .. roots[i].path)
        end
    end
    return work, output
end

local function check_roots(entries, fs)
    if entries == nil or entries == JSON_NULL then
        return fail("roots is required")
    end
    if json_kind(entries) ~= "array" then
        return fail("roots must be an array")
    end
    if #entries == 0 then
        return fail("roots is empty")
    end
    local roots = {}
    for i = 1, #entries do
        local entry = entries[i]
        local label = "roots[" .. i .. "]"
        if json_kind(entry) ~= "object" then
            return fail(label .. " must be an object")
        end
        local unknown = {}
        for key in pairs(entry) do
            if not ROOT_KEYS[key] then
                unknown[#unknown + 1] = tostring(key)
            end
        end
        table.sort(unknown)
        if unknown[1] then
            return fail(label .. " unknown key: " .. unknown[1])
        end
        local path, err = check_real_dir(label .. ".path", entry.path, fs, false)
        if not path then
            return nil, err, "config"
        end
        local alias
        alias, err = check_syntax(label .. ".alias", entry.alias, true)
        if not alias then
            return nil, err, "config"
        end
        roots[i] = { path = path, alias = alias }
    end
    for i = 1, #roots do
        for j = i + 1, #roots do
            if overlaps(roots[i].path, roots[j].path) then
                return fail("roots overlap: " .. roots[i].path .. " and " .. roots[j].path)
            end
            if overlaps(roots[i].alias, roots[j].alias) then
                return fail("aliases overlap: " .. roots[i].alias .. " and " .. roots[j].alias)
            end
        end
    end
    return roots
end

local function check_exclude(entries, roots)
    if entries == nil then
        return {}
    end
    if entries == JSON_NULL or json_kind(entries) ~= "array" then
        return fail("exclude must be an array")
    end
    local exclude = {}
    for i = 1, #entries do
        local label = "exclude[" .. i .. "]"
        local path, err = check_syntax(label, entries[i], true)
        if not path then
            return nil, err, "config"
        end
        for r = 1, #roots do
            local alias = roots[r].alias
            if path == alias or is_prefix(path, alias) then
                return fail(label .. " covers alias " .. alias)
            end
        end
        exclude[i] = path
    end
    return exclude
end

local function decode_config(text)
    if type(text) ~= "string" then
        return fail("config is not valid JSON")
    end
    local value, pos, err = dkjson.decode(text, 1, JSON_NULL)
    if err then
        return fail("config is not valid JSON: " .. err)
    end
    local rest = text:sub(pos or 1)
    if rest:find("%S") then
        return fail("config is not valid JSON: trailing data")
    end
    if value == JSON_NULL or json_kind(value) ~= "object" then
        return fail("config is not a JSON object")
    end
    return value
end

local function unknown_key(obj)
    local unknown = {}
    for key in pairs(obj) do
        if not CONFIG_KEYS[key] then
            unknown[#unknown + 1] = tostring(key)
        end
    end
    table.sort(unknown)
    return unknown[1]
end

local function finish_config(roots, work_raw, output_raw, exclude_raw, fs, output_path)
    local work, output_or_err, err = check_dir_pair(work_raw, output_raw, roots, fs)
    if not work then
        return nil, output_or_err, err
    end
    local exclude
    exclude, err = check_exclude(exclude_raw, roots)
    if not exclude then
        return nil, err, "config"
    end
    local cfg = {
        roots = roots,
        exclude = exclude,
        work_dir = work,
        output_dir = output_or_err,
    }
    if output_path then
        cfg.output_path = output_path
    end
    return cfg
end

local function load_json(path, fs)
    local f, open_err = io.open(path, "rb")
    if not f then
        return fail("cannot read config " .. path .. ": " .. tostring(open_err))
    end
    local text = f:read("a")
    f:close()
    if text == nil then
        text = ""
    end
    local obj, err = decode_config(text)
    if not obj then
        return nil, err, "config"
    end
    local bad = unknown_key(obj)
    if bad then
        return fail("unknown config key: " .. bad)
    end
    local roots
    roots, err = check_roots(obj.roots, fs)
    if not roots then
        return nil, err, "config"
    end
    return finish_config(obj and roots, obj.work_dir, obj.output_dir, obj.exclude, fs, nil)
end

local function load_flags(source_raw, index_raw, fs)
    local source, err = check_real_dir("--source", source_raw, fs, false)
    if not source then
        return nil, err, "config"
    end
    local index
    index, err = check_syntax("--index", index_raw, true)
    if not index then
        return nil, err, "config"
    end
    local existing = lstat(fs, index)
    if existing then
        if existing.mode == "directory" then
            return fail("--index is a directory")
        end
    else
        local parent = parent_of(index)
        local parent_attr = lstat(fs, parent)
        if not parent_attr then
            return fail("--index parent does not exist")
        end
        if parent_attr.mode == "link" then
            return fail("--index parent is not a real directory")
        end
        if parent_attr.mode ~= "directory" then
            return fail("--index parent is not a directory")
        end
    end
    local parent = parent_of(index)
    if sits_inside(parent, source) then
        return fail("--index parent sits inside the source")
    end
    local roots = { { path = source, alias = source } }
    local cfg, work_err, class = finish_config(roots, parent, parent, nil, fs, index)
    if not cfg then
        return nil, work_err, class
    end
    return cfg
end

function M.load_config(cmd, fs)
    if type(cmd) ~= "table" then
        return fail("missing arguments")
    end
    fs = fs or {
        lstat = function(path)
            return lfs.symlinkattributes(path)
        end,
    }
    if cmd.config then
        return load_json(cmd.config, fs)
    end
    if cmd.source or cmd.index then
        return load_flags(cmd.source, cmd.index, fs)
    end
    return fail("missing arguments")
end

-- format_line(record) returns one listing line with no trailing newline.
-- record fields: path, kind ("file", "dir", "link"), size, mtime (seconds),
-- user, group, uid, gid, target (links), and either permissions (9 chars,
-- as from lfs) or numeric mode (permission bits; file-type bits ignored).
local KIND_CHAR = {
    file = "-",
    dir = "d",
    link = "l",
}

local SPECIAL_BYTE = {
    [92] = "\\\\",
    [9] = "\\t",
    [10] = "\\n",
    [13] = "\\r",
}

local function has_special(text)
    for i = 1, #text do
        if SPECIAL_BYTE[text:byte(i)] then
            return true
        end
    end
    return false
end

local function escape_field(text)
    local parts = {}
    for i = 1, #text do
        local byte = text:byte(i)
        parts[i] = SPECIAL_BYTE[byte] or text:sub(i, i)
    end
    return table.concat(parts)
end

local function nine_permissions(mode)
    local bits = math.tointeger(mode)
    if bits == nil then
        return nil
    end
    local masks = {
        0x100, 0x80, 0x40,
        0x20, 0x10, 0x8,
        0x4, 0x2, 0x1,
    }
    local letters = { "r", "w", "x", "r", "w", "x", "r", "w", "x" }
    local chars = {}
    for i = 1, 9 do
        if (bits & masks[i]) ~= 0 then
            chars[i] = letters[i]
        else
            chars[i] = "-"
        end
    end
    if (bits & 0x800) ~= 0 then
        chars[3] = ((bits & 0x40) ~= 0) and "s" or "S"
    end
    if (bits & 0x400) ~= 0 then
        chars[6] = ((bits & 0x8) ~= 0) and "s" or "S"
    end
    if (bits & 0x200) ~= 0 then
        chars[9] = ((bits & 0x1) ~= 0) and "t" or "T"
    end
    return table.concat(chars)
end

local function forbidden_owner(text)
    for i = 1, #text do
        local byte = text:byte(i)
        if byte == 58 or byte == 9 or byte == 32 then
            return true
        end
    end
    return false
end

local function decimal_id(id)
    local n = math.tointeger(id)
    if n == nil or n < 0 then
        return nil
    end
    return string.format("%d", n)
end

local function owner_side(name, id)
    if type(name) == "string" and not forbidden_owner(name) then
        return name
    end
    if type(name) == "number" then
        return decimal_id(name)
    end
    return decimal_id(id)
end

local function format_mtime(seconds)
    if type(seconds) ~= "number" then
        return nil
    end
    local whole = math.modf(seconds)
    local sec = math.tointeger(whole)
    if sec == nil then
        return nil
    end
    local text = os.date("!%Y%m%d:%H%M%S", sec)
    if type(text) ~= "string" or #text ~= 15 then
        return nil
    end
    return text
end

function M.format_line(record)
    if type(record) ~= "table" then
        return nil, "record is required"
    end
    if type(record.path) ~= "string" then
        return nil, "path is required"
    end
    local type_char = KIND_CHAR[record.kind]
    if not type_char then
        return nil, "kind must be file, dir, or link"
    end
    local nine
    if record.permissions ~= nil then
        if type(record.permissions) ~= "string" or #record.permissions ~= 9 then
            return nil, "permissions must be 9 characters"
        end
        nine = record.permissions
    else
        nine = nine_permissions(record.mode)
        if not nine then
            return nil, "mode is required"
        end
    end
    local size = math.tointeger(record.size)
    if size == nil then
        return nil, "size must be an integer"
    end
    local mtime = format_mtime(record.mtime)
    if not mtime then
        return nil, "mtime is required"
    end
    local user = owner_side(record.user, record.uid)
    if not user then
        return nil, "user is required"
    end
    local group = owner_side(record.group, record.gid)
    if not group then
        return nil, "group is required"
    end
    local target
    if record.kind == "link" then
        if type(record.target) ~= "string" then
            return nil, "link target is required"
        end
        target = record.target
    end
    local bang = has_special(record.path) or (target ~= nil and has_special(target))
    local out_path = bang and escape_field(record.path) or record.path
    local out_link
    if record.kind ~= "link" then
        out_link = "-"
    elseif target == "-" then
        -- The inserted backslash is not run through the escape table.
        out_link = "\\-"
    elseif bang then
        out_link = escape_field(target)
    else
        out_link = target
    end
    local head = (bang and "!" or "") .. mtime
    return table.concat({
        head,
        user .. ":" .. group,
        type_char .. nine,
        string.format("%d", size),
        out_link,
        out_path,
    }, "\t")
end

local function fail_walk(reason)
    return nil, reason, "walk"
end

local function remap(root_path, alias, full)
    if full == root_path then
        return alias
    end
    local rest = full:sub(#root_path + 1)
    if alias == "/" then
        return rest
    end
    return alias .. rest
end

local function join_path(dir, name)
    if dir == "/" then
        return "/" .. name
    end
    return dir .. "/" .. name
end

local function is_excluded(path, rules)
    for i = 1, #rules do
        local rule = rules[i]
        if path == rule or is_prefix(rule, path) then
            return true
        end
    end
    return false
end

local function inode_key(attr)
    local dev = math.tointeger(attr.dev)
    local ino = math.tointeger(attr.ino)
    if dev == nil or ino == nil then
        return nil
    end
    return string.format("%d:%d", dev, ino)
end

local function forbidden_name(name)
    return name == "" or name:find("[: \t]", 1) ~= nil
end

local function id_key(id)
    local n = math.tointeger(id)
    if n == nil or n < 0 then
        return nil
    end
    return string.format("%d", n)
end

local function run_getent(database)
    local handle, open_err = io.popen("getent " .. database, "r")
    if not handle then
        return nil, "cannot read " .. database .. " names: " .. tostring(open_err)
    end
    local text = handle:read("a") or ""
    local ok = handle:close()
    if ok ~= true then
        return nil, "cannot read " .. database .. " names"
    end
    return text
end

-- Third field is the uid in passwd and the gid in group.
local function id_map(database)
    local text, err = run_getent(database)
    if not text then
        return nil, err
    end
    local map = {}
    for line in text:gmatch("[^\n]+") do
        local name, id = line:match("^([^:]*):[^:]*:([^:\n]*)")
        if name and id and id ~= "" and map[id] == nil and not forbidden_name(name) then
            map[id] = name
        end
    end
    return map
end

local function resolve_name(map, id)
    local key = id_key(id)
    if not key then
        return nil
    end
    return map[key] or key
end

local function list_names(fs, path)
    local iter, dir = fs.dir(path)
    if not iter then
        return nil, dir or ("cannot open " .. path)
    end
    local names = {}
    local read_ok, read_err = pcall(function()
        while true do
            local name = iter(dir)
            if name == nil then
                break
            end
            if name ~= "." and name ~= ".." then
                names[#names + 1] = name
            end
        end
    end)
    if (type(dir) == "table" or type(dir) == "userdata") and type(dir.close) == "function" then
        pcall(dir.close, dir)
    end
    if not read_ok then
        return nil, read_err
    end
    return names
end

local function make_record(attr, remapped, users, groups)
    local kind
    if attr.mode == "file" then
        kind = "file"
    elseif attr.mode == "directory" then
        kind = "dir"
    elseif attr.mode == "link" then
        kind = "link"
    end
    if not kind then
        return nil
    end
    local uid = math.tointeger(attr.uid) or attr.uid
    local gid = math.tointeger(attr.gid) or attr.gid
    local user = resolve_name(users, uid)
    local group = resolve_name(groups, gid)
    if not user or not group then
        return nil, "cannot resolve owner of " .. remapped
    end
    local size = attr.size
    if type(size) == "number" and math.tointeger(size) ~= nil then
        size = math.tointeger(size)
    end
    local rec = {
        path = remapped,
        kind = kind,
        size = size,
        mtime = attr.modification,
        uid = uid,
        gid = gid,
        user = user,
        group = group,
        dev = attr.dev,
        ino = attr.ino,
    }
    if type(attr.permissions) == "string" and #attr.permissions == 9 then
        rec.permissions = attr.permissions
    end
    if kind == "link" then
        if type(attr.target) ~= "string" then
            return nil, "cannot read target " .. remapped
        end
        rec.target = attr.target
    end
    return rec
end

local function default_fs()
    return {
        lstat = function(path)
            return lfs.symlinkattributes(path)
        end,
        dir = function(path)
            local ok, iter, dir = pcall(lfs.dir, path)
            if not ok then
                return nil, iter
            end
            return iter, dir
        end,
    }
end

-- walk(config, fs, progress) -> { records, warnings }, or nil, err, "walk".
-- records use kind "file", "dir", or "link". warnings are skipped inodes,
-- one per (dev, ino), with the LuaFileSystem mode string and the remapped path.
-- fs.lstat(path) and fs.dir(path) default to LuaFileSystem. fs.dir returns
-- an iterator and a directory object; the iterator is called as iter(dir)
-- until nil, then dir:close(). Names are read and the directory is closed
-- before any child is visited.
-- progress is nil when stdout is not a terminal. Otherwise the walker calls
-- progress:tick(info) for each record and each new skip. A false tick result
-- aborts the walk.
function M.walk(config, fs, progress)
    if type(config) ~= "table" or type(config.roots) ~= "table" then
        return fail_walk("roots are required")
    end
    local exclude = config.exclude or {}
    fs = fs or default_fs()
    local users, uerr = id_map("passwd")
    if not users then
        return fail_walk(uerr)
    end
    local groups, gerr = id_map("group")
    if not groups then
        return fail_walk(gerr)
    end
    local records = {}
    local warnings = {}
    local seen = {}
    local warned = {}

    local function observe(info)
        if not progress then
            return true
        end
        local ok, why, why_class = progress:tick(info)
        if not ok then
            return nil, why or "aborted", why_class or "walk"
        end
        return true
    end

    local function warn_once(attr, remapped)
        local key = inode_key(attr)
        if key and warned[key] then
            return false
        end
        if key then
            warned[key] = true
        end
        warnings[#warnings + 1] = {
            type = attr.mode,
            path = remapped,
        }
        return true
    end

    local function visit(abs, root_path, alias, root_dev)
        if is_excluded(remap(root_path, alias, abs), exclude) then
            return true
        end
        local attr, err = fs.lstat(abs)
        if not attr then
            return fail_walk("cannot read " .. abs .. ": " .. tostring(err))
        end
        if root_dev == nil and attr.mode ~= "directory" then
            return fail_walk("cannot read " .. abs .. ": not a directory")
        end
        local remapped = remap(root_path, alias, abs)
        if attr.mode ~= "file" and attr.mode ~= "directory" and attr.mode ~= "link" then
            if warn_once(attr, remapped) then
                local ok, why, why_class = observe({
                    kind = "skip",
                    path = remapped,
                    alias = alias,
                    type = attr.mode,
                })
                if not ok then
                    return nil, why, why_class
                end
            end
            return true
        end
        local rec, rec_err = make_record(attr, remapped, users, groups)
        if not rec then
            return fail_walk(rec_err or ("cannot read " .. abs))
        end
        records[#records + 1] = rec
        local seen_ok, seen_err, seen_class = observe({
            kind = rec.kind,
            path = rec.path,
            alias = alias,
        })
        if not seen_ok then
            return nil, seen_err, seen_class
        end
        if attr.mode ~= "directory" then
            return true
        end
        local dev = root_dev
        if dev == nil then
            dev = attr.dev
        elseif attr.dev ~= dev then
            return true
        end
        local key = inode_key(attr)
        if key and seen[key] then
            return true
        end
        if key then
            seen[key] = true
        end
        local children, list_err = list_names(fs, abs)
        if not children then
            return fail_walk(tostring(list_err))
        end
        for i = 1, #children do
            local ok, child_err, class = visit(join_path(abs, children[i]), root_path, alias, dev)
            if not ok then
                return nil, child_err, class
            end
        end
        return true
    end

    for i = 1, #config.roots do
        local root = config.roots[i]
        local ok, err, class = visit(root.path, root.path, root.alias, nil)
        if not ok then
            return nil, err, class
        end
    end
    return {
        records = records,
        warnings = warnings,
    }
end

local function fail_publish(reason)
    return nil, reason, "publish"
end

local function listing_path(config, stamp)
    if type(config.output_path) == "string" and config.output_path ~= "" then
        return config.output_path
    end
    if type(config.output_dir) ~= "string" or config.output_dir == "" then
        return nil, "output_dir is required"
    end
    local minute = os.date("!%Y%m%d-%H%M", stamp)
    if type(minute) ~= "string" then
        return nil, "stamp is required"
    end
    return join_path(config.output_dir, "index-" .. minute .. ".listing")
end

local function partial_path(work_dir, listing, pid)
    if type(work_dir) ~= "string" or work_dir == "" then
        return nil, "work_dir is required"
    end
    local base = listing:match("([^/]+)$")
    if not base or base == "" then
        return nil, "listing name is required"
    end
    return join_path(work_dir, base .. "." .. pid .. ".partial")
end

local function resolve_stamp(clock)
    local stamp
    if type(clock) == "number" then
        stamp = clock
    elseif type(clock) == "function" then
        stamp = clock()
    elseif type(clock) == "table" and type(clock.now) == "function" then
        stamp = clock.now()
    else
        stamp = os.time()
    end
    if type(stamp) ~= "number" then
        return nil
    end
    local whole = math.modf(stamp)
    return math.tointeger(whole)
end

local function publish_ops(seam)
    seam = seam or {}
    local open = seam.open
    if type(open) ~= "function" then
        open = function(path)
            return io.open(path, "wb")
        end
    end
    local exists = seam.exists
    if type(exists) ~= "function" then
        exists = function(path)
            return lfs.symlinkattributes(path) ~= nil
        end
    end
    local rename = seam.rename
    if type(rename) ~= "function" then
        rename = os.rename
    end
    local pid = seam.pid
    if type(pid) == "function" then
        pid = pid()
    end
    if pid == nil or pid == "" then
        pid = process_id()
    end
    return open, exists, rename, tostring(pid)
end

local function abandon(file)
    if not file then
        return
    end
    pcall(function()
        file:flush()
    end)
    pcall(function()
        file:close()
    end)
end

local function phase_step(progress, name, current, total)
    if not progress then
        return true
    end
    local ok, why, why_class = progress:phase(name, current, total)
    if not ok then
        return nil, why or "aborted", why_class or "walk"
    end
    return true
end

-- publish(records, config, stamp, seam, progress) -> listing path, or nil, err, class.
-- Sorts a copy by raw remapped path. A duplicate path is class "walk" and
-- creates no partial. The partial is <listing-name>.<pid>.partial in work_dir.
-- seam.open, seam.exists, seam.rename, and seam.pid override the defaults.
-- progress is nil off a terminal. It receives phase("sort"|"publish", current, total).
-- An abort leaves any partial in place and does not rename. The path is not printed.
function M.publish(records, config, stamp, seam, progress)
    if type(records) ~= "table" then
        return fail_publish("records are required")
    end
    if type(config) ~= "table" then
        return fail_publish("config is required")
    end
    local sec = resolve_stamp(stamp)
    if not sec then
        return fail_publish("stamp is required")
    end
    local open, exists, rename, pid = publish_ops(seam)
    local listing, lerr = listing_path(config, sec)
    if not listing then
        return fail_publish(lerr)
    end
    if exists(listing) then
        return fail_publish("listing exists " .. listing)
    end

    local sorted = {}
    for i = 1, #records do
        local rec = records[i]
        if type(rec) ~= "table" or type(rec.path) ~= "string" then
            return fail_publish("path is required")
        end
        sorted[i] = rec
    end
    local stepped, step_err, step_class = phase_step(progress, "sort", 0, #sorted)
    if not stepped then
        return nil, step_err, step_class
    end
    table.sort(sorted, function(a, b)
        return a.path < b.path
    end)
    for i = 1, #sorted do
        if i > 1 and sorted[i].path == sorted[i - 1].path then
            return fail_walk("duplicate path " .. sorted[i].path)
        end
        stepped, step_err, step_class = phase_step(progress, "sort", i, #sorted)
        if not stepped then
            return nil, step_err, step_class
        end
    end

    local lines = {}
    for i = 1, #sorted do
        local text, ferr = M.format_line(sorted[i])
        if not text then
            return fail_publish("cannot format " .. sorted[i].path .. ": " .. tostring(ferr))
        end
        lines[i] = text .. "\n"
    end

    local partial, perr = partial_path(config.work_dir, listing, pid)
    if not partial then
        return fail_publish(perr)
    end
    stepped, step_err, step_class = phase_step(progress, "publish", 0, #lines)
    if not stepped then
        return nil, step_err, step_class
    end
    local file, oerr = open(partial)
    if not file then
        return fail_publish("cannot write " .. partial .. ": " .. tostring(oerr))
    end
    for i = 1, #lines do
        local ok, werr = file:write(lines[i])
        if not ok then
            abandon(file)
            return fail_publish("cannot write " .. partial .. ": " .. tostring(werr))
        end
        stepped, step_err, step_class = phase_step(progress, "publish", i, #lines)
        if not stepped then
            abandon(file)
            return nil, step_err, step_class
        end
    end
    local flushed, ferr = file:flush()
    if not flushed then
        abandon(file)
        return fail_publish("cannot flush " .. partial .. ": " .. tostring(ferr))
    end
    local closed, cerr = file:close()
    if not closed then
        pcall(function()
            file:close()
        end)
        return fail_publish("cannot close " .. partial .. ": " .. tostring(cerr))
    end
    if exists(listing) then
        return fail_publish("listing exists " .. listing)
    end
    local renamed, rerr = rename(partial, listing)
    if not renamed then
        return fail_publish("cannot rename " .. partial .. " to " .. listing .. ": " .. tostring(rerr))
    end
    return listing
end

local function prepare_run(config, clock, seam)
    local sec = resolve_stamp(clock)
    if not sec then
        return fail_publish("stamp is required")
    end
    if type(config) ~= "table" then
        return fail_publish("config is required")
    end
    local _, exists = publish_ops(seam)
    local listing, lerr = listing_path(config, sec)
    if not listing then
        return fail_publish(lerr)
    end
    if exists(listing) then
        return fail_publish("listing exists " .. listing)
    end
    return sec
end

-- run(config, fs, clock, seam, progress) -> path, nil, nil, warnings
-- or nil, err, class, warnings.
-- clock is a number, a function, or a table with now(). The listing path is
-- checked before the walk. An existing listing does not call the walker.
-- progress is nil when stdout is not a terminal.
function M.run(config, fs, clock, seam, progress)
    local sec, err, class = prepare_run(config, clock, seam)
    if not sec then
        return nil, err, class
    end
    local walked
    walked, err, class = M.walk(config, fs, progress)
    if not walked then
        return nil, err, class
    end
    local path, perr, pclass = M.publish(walked.records, config, sec, seam, progress)
    if not path then
        return nil, perr, pclass, walked.warnings
    end
    return path, nil, nil, walked.warnings
end

local system = require("system")

local EIGHTHS = {
    utf8.char(0x258F),
    utf8.char(0x258E),
    utf8.char(0x258D),
    utf8.char(0x258C),
    utf8.char(0x258B),
    utf8.char(0x258A),
    utf8.char(0x2589),
    utf8.char(0x2588),
}

local PANEL_ATTR = {
    title = { fg = "yellow", brightness = "bright" },
    value = { fg = "green", brightness = "bright" },
    sub = { fg = "cyan", brightness = "bright" },
    path = { fg = "white", brightness = "dim" },
    skip = { fg = "red", brightness = "bright" },
    bar_on = { fg = "green", brightness = "bright" },
    bar_off = { fg = "white", brightness = "dim" },
}

local BAR_BG = 236
local ACTIVITY_CELLS = 8
local REDRAW_SECONDS = 0.1
local REDRAW_RECORDS = 200

-- display_text strips a path for the panel. Tabs become four spaces, CSI
-- sequences are removed, and the remaining control bytes are dropped.
-- Listing bytes are not passed through this function.
function M.display_text(text)
    text = tostring(text or "")
    text = text:gsub("\t", "    ")
    text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
    text = text:gsub("[%z\1-\31\127]", "")
    return text
end

local function bar_attr(base)
    return {
        fg = base.fg,
        brightness = base.brightness,
        bg = BAR_BG,
    }
end

-- progress_eighths(current, total) -> cells, percent.
-- cells[i].ch is a space or one eighths block. The cell math matches
-- schemahelper: each cell covers eight steps, and the last cell is shorter
-- when the total is not a multiple of eight.
function M.progress_eighths(current, total)
    current = tonumber(current) or 0
    total = tonumber(total) or 0
    if current < 0 then
        current = 0
    end
    if total < 0 then
        total = 0
    end
    current = math.floor(current)
    total = math.floor(total)
    if current > total then
        current = total
    end
    local n = 0
    if total >= 1 then
        n = math.ceil(total / 8)
    end
    local cells = {}
    for i = 1, n do
        local start = (i - 1) * 8
        local cap = math.min(8, total - start)
        local filled = current - start
        if filled < 0 then
            filled = 0
        end
        if filled > cap then
            filled = cap
        end
        local ch = " "
        local attr = PANEL_ATTR.bar_off
        if filled > 0 then
            ch = EIGHTHS[filled]
            attr = PANEL_ATTR.bar_on
        end
        cells[i] = { ch = ch, attr = bar_attr(attr) }
    end
    local pct = 0
    if total > 0 then
        pct = math.floor(100 * current / total)
    end
    return cells, pct
end

local function columns(text)
    local ok, width = pcall(terminal.text.width.utf8swidth, text)
    if ok and type(width) == "number" then
        return width
    end
    return #text
end

local function fit(text, width)
    text = M.display_text(text)
    if width < 1 then
        return ""
    end
    local ok, shown = pcall(terminal.text.width.truncate_ellipsis, width, text, "right")
    if ok and type(shown) == "string" then
        return shown
    end
    return text:sub(1, width)
end

local function write_parts(row, col, width, parts)
    if width < 1 then
        return
    end
    terminal.cursor.position.set(row, col)
    local used = 0
    for i = 1, #parts do
        local room = width - used
        if room < 1 then
            break
        end
        local shown = fit(parts[i][1], room)
        terminal.output.write(
            terminal.text.push_seq(parts[i][2]),
            shown,
            terminal.text.pop_seq()
        )
        used = used + columns(shown)
    end
end

local function paint_panel(panel, state)
    local row0 = panel.inner_row or 1
    local col = panel.inner_col or 1
    local width = panel.inner_width or 1
    local height = panel.inner_height or 1
    local function at(index, parts)
        if index < 1 or index > height then
            return
        end
        write_parts(row0 + index - 1, col, width, parts)
    end
    at(1, { { state.phase_name or "walk", PANEL_ATTR.title } })
    at(2, { { state.alias or "", PANEL_ATTR.value } })
    at(3, { { state.path or "", PANEL_ATTR.path } })
    at(4, {
        { "dirs ", PANEL_ATTR.sub },
        { tostring(state.dirs or 0), PANEL_ATTR.value },
        { "  files ", PANEL_ATTR.sub },
        { tostring(state.files or 0), PANEL_ATTR.value },
        { "  links ", PANEL_ATTR.sub },
        { tostring(state.links or 0), PANEL_ATTR.value },
        { "  skipped ", PANEL_ATTR.sub },
        { tostring(state.skipped or 0), PANEL_ATTR.value },
    })
    if height >= 5 and width >= 1 then
        local cells, pct
        if state.activity_mode then
            local span = ACTIVITY_CELLS * 8
            local step = (state.activity or 0) % (span + 1)
            cells = M.progress_eighths(step, span)
        else
            cells, pct = M.progress_eighths(state.current or 0, state.total or 0)
        end
        local label = ""
        if pct then
            label = string.format("  %d%%", pct)
        end
        local label_w = columns(label)
        local room = width - label_w
        if room < 1 then
            room = width
            label = ""
        end
        terminal.cursor.position.set(row0 + 4, col)
        local shown = math.min(#cells, room)
        for i = 1, shown do
            terminal.output.write(
                terminal.text.push_seq(cells[i].attr),
                cells[i].ch,
                terminal.text.pop_seq()
            )
        end
        if label ~= "" then
            terminal.output.write(
                terminal.text.push_seq(PANEL_ATTR.sub),
                label,
                terminal.text.pop_seq()
            )
        end
    end
    local room = height - 5
    if room > 0 then
        local skips = state.skips or {}
        local first = math.max(1, #skips - room + 1)
        local line = 6
        for i = first, #skips do
            at(line, { { skips[i], PANEL_ATTR.skip } })
            line = line + 1
        end
    end
end

local progress_methods = {}

function progress_methods:maybe(force)
    if self.aborted then
        return nil, "aborted", "walk"
    end
    self.since = self.since + 1
    local now = system.gettime()
    if not force and self.since < REDRAW_RECORDS and (now - self.drawn) < REDRAW_SECONDS then
        return true
    end
    if self.activity_mode then
        self.activity = self.activity + 1
    end
    self.since = 0
    self.drawn = now
    if not self.laid_out then
        self.screen:calculate_layout()
        self.laid_out = true
    else
        self.screen:check_resize(true)
    end
    self.screen:render()
    return self:poll()
end

function progress_methods:poll()
    if self.aborted then
        return nil, "aborted", "walk"
    end
    for _ = 1, 32 do
        local raw = terminal.input.readansi(0)
        if raw == nil or raw == "" then
            break
        end
        if raw == "q" or raw == "\3" then
            self.aborted = true
            return nil, "aborted", "walk"
        end
    end
    return true
end

function progress_methods:tick(info)
    info = info or {}
    if info.kind == "dir" then
        self.dirs = self.dirs + 1
    elseif info.kind == "file" then
        self.files = self.files + 1
    elseif info.kind == "link" then
        self.links = self.links + 1
    elseif info.kind == "skip" then
        self.skipped = self.skipped + 1
        local label = tostring(info.type or "other") .. " " .. tostring(info.path or "")
        self.skips[#self.skips + 1] = label
    end
    if type(info.alias) == "string" then
        self.alias = info.alias
    end
    if type(info.path) == "string" then
        self.path = info.path
    end
    self.activity_mode = true
    if self.phase_name == nil or self.phase_name == "" then
        self.phase_name = "walk"
    end
    return self:maybe(false)
end

function progress_methods:phase(name, current, total)
    local force = self.phase_name ~= name
    self.phase_name = name
    self.current = current or 0
    self.total = total or 0
    self.activity_mode = false
    if (self.total or 0) > 0 and self.current == self.total then
        force = true
    end
    return self:maybe(force)
end

local function open_progress()
    local Panel = require("terminal.ui.panel")
    local Screen = require("terminal.ui.panel.screen")
    local state = setmetatable({
        dirs = 0,
        files = 0,
        links = 0,
        skipped = 0,
        skips = {},
        alias = "",
        path = "",
        phase_name = "walk",
        current = 0,
        total = 0,
        activity = 0,
        activity_mode = true,
        since = 0,
        drawn = 0,
        aborted = false,
        laid_out = false,
    }, { __index = progress_methods })
    local body = Panel {
        name = "progress",
        content = function(panel)
            paint_panel(panel, state)
        end,
        border = {
            format = terminal.draw.box_fmt.single,
            attr = { fg = "red", brightness = "bright" },
            title = " casually_index ",
            title_attr = { fg = "yellow", brightness = "bright" },
        },
    }
    state.screen = Screen {
        body = body,
        name = "casually_index",
    }
    return state
end

local function stdout_is_tty()
    local ok, yes = pcall(system.isatty, io.stdout)
    return ok and yes == true
end

local function exit_code(class)
    if class == "walk" then
        return 2
    end
    if class == "publish" then
        return 3
    end
    return 1
end

function M.main(argv)
    local cmd, err, class = M.parse_args(argv)
    if not cmd then
        io.stderr:write("casually_index: " .. one_line(err) .. "\n")
        return exit_code(class)
    end
    if cmd.help then
        io.stdout:write(M.help_text())
        return 0
    end
    if cmd.version then
        io.stdout:write(table.concat(M.version_lines(), "\n") .. "\n")
        return 0
    end
    local cfg
    cfg, err, class = M.load_config(cmd)
    if not cfg then
        io.stderr:write("casually_index: " .. one_line(err) .. "\n")
        return exit_code(class)
    end
    local sec
    sec, err, class = prepare_run(cfg)
    if not sec then
        io.stderr:write("casually_index: " .. one_line(err) .. "\n")
        return exit_code(class)
    end

    local function emit_warnings(warnings)
        if type(warnings) ~= "table" then
            return
        end
        for i = 1, #warnings do
            local skipped = warnings[i]
            io.stderr:write("casually_index: skipped "
                .. one_line(skipped.type)
                .. " "
                .. one_line(skipped.path)
                .. "\n")
        end
    end

    local path, warnings
    if not stdout_is_tty() then
        path, err, class, warnings = M.run(cfg, nil, sec)
        emit_warnings(warnings)
        if not path then
            io.stderr:write("casually_index: " .. one_line(err) .. "\n")
            return exit_code(class)
        end
        return 0
    end

    local outcome = {}
    local function wrapped()
        outcome = { M.run(cfg, nil, sec, nil, open_progress()) }
    end
    local runner = terminal.initwrap(wrapped, {
        displaybackup = true,
        filehandle = io.stdout,
        skip_width_detection = true,
        disable_sigint = true,
        autotermrestore = true,
    })
    local ok, blown = xpcall(runner, debug.traceback)
    if not ok then
        io.stderr:write("casually_index: " .. one_line(blown) .. "\n")
        return 1
    end
    path, err, class, warnings = outcome[1], outcome[2], outcome[3], outcome[4]
    emit_warnings(warnings)
    if not path then
        io.stderr:write("casually_index: " .. one_line(err) .. "\n")
        return exit_code(class)
    end
    return 0
end

local function invoked_as_script()
    if type(arg) ~= "table" or type(arg[0]) ~= "string" then
        return false
    end
    return arg[0]:match("casually_index%.lua$") ~= nil
end

if invoked_as_script() then
    local code = M.main(arg)
    os.exit(code)
end

return M
