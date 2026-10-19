#!/usr/bin/env lua

-- casually_backup: one snapshot per backup folder from a finished listing.
-- The command line, the config checks, the listing parser, the plan, the
-- copy, and the terminal screen live here.

local VERSION = "0.1.0"

if _VERSION ~= "Lua 5.5" then
    io.stderr:write("casually_backup: need Lua 5.5\n")
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
        io.stderr:write("casually_backup: cannot load " .. name .. "\n")
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

local FLAGS = {
    ["--dry-run"] = true,
}

local REPEAT = {
    ["--dest"] = true,
    ["--source-map"] = true,
}

local ONCE = {
    ["--config"] = true,
    ["--index"] = true,
    ["--omit-limit"] = true,
    ["--omit-fraction"] = true,
    ["--workers"] = true,
    ["--report"] = true,
    ["--report-dir"] = true,
}

local function one_line(text)
    text = tostring(text)
    text = text:gsub("\t", "\\t")
    text = text:gsub("\n", "\\n")
    text = text:gsub("\r", "\\r")
    return text
end

local function fail_args(reason)
    return nil, reason, "config"
end

function M.parse_args(argv)
    local n = #argv
    if n == 0 then
        return fail_args("missing arguments")
    end
    local seen = {}
    local values = {}
    local destinations = {}
    local source_map = {}
    local dry_run = false
    local switch = nil
    local i = 1
    while i <= n do
        local tok = argv[i]
        if switch then
            return fail_args(switch .. " does not take other arguments")
        end
        if SWITCHES[tok] then
            if next(seen) ~= nil or dry_run or #destinations > 0 or #source_map > 0 then
                return fail_args(tok .. " does not take other arguments")
            end
            switch = tok
            seen[tok] = true
            i = i + 1
        elseif FLAGS[tok] then
            if seen[tok] then
                return fail_args("repeated argument: " .. tok)
            end
            seen[tok] = true
            dry_run = true
            i = i + 1
        elseif REPEAT[tok] or ONCE[tok] then
            if ONCE[tok] and seen[tok] then
                return fail_args("repeated argument: " .. tok)
            end
            local val = argv[i + 1]
            if val == nil then
                if tok == "--config" then
                    return fail_args("--config requires a file")
                end
                return fail_args(tok .. " requires a value")
            end
            if val:sub(1, 1) == "-" then
                return fail_args("unknown argument: " .. val)
            end
            if tok == "--source-map" and val:find("=", 1, true) == nil then
                return fail_args("--source-map requires alias=path")
            end
            seen[tok] = true
            if tok == "--dest" then
                destinations[#destinations + 1] = val
            elseif tok == "--source-map" then
                local eq = val:find("=", 1, true)
                source_map[#source_map + 1] = {
                    alias = val:sub(1, eq - 1),
                    path = val:sub(eq + 1),
                }
            else
                values[tok] = val
            end
            i = i + 2
        elseif tok:sub(1, 1) == "-" then
            return fail_args("unknown argument: " .. tok)
        else
            return fail_args("unexpected argument: " .. tok)
        end
    end
    if switch == "--help" then
        return { help = true }
    end
    if switch == "--version" then
        return { version = true }
    end

    local has_config = values["--config"] ~= nil
    local has_index = values["--index"] ~= nil
    local has_dest = #destinations > 0
    local has_map = #source_map > 0
    if has_config and (has_index or has_dest or has_map) then
        return fail_args("use either --config or --index with --dest")
    end
    if has_map and not has_index then
        return fail_args("--source-map requires --index")
    end
    if has_index and not has_dest then
        return fail_args("--index requires --dest")
    end
    if has_dest and not has_index then
        return fail_args("--dest requires --index")
    end
    if not has_config and not has_index then
        return fail_args("use either --config or --index with --dest")
    end

    local cmd = {
        dry_run = dry_run,
        omit_limit = values["--omit-limit"],
        omit_fraction = values["--omit-fraction"],
        workers = values["--workers"],
        report = values["--report"],
        report_dir = values["--report-dir"],
    }
    if has_config then
        cmd.config = values["--config"]
        return cmd
    end
    cmd.index = values["--index"]
    cmd.destinations = destinations
    cmd.source_map = source_map
    return cmd
end

function M.help_text()
    return table.concat({
        "./casually_backup.lua --config <file>",
        "./casually_backup.lua --index <listing> --dest <dir> [--dest <dir>...] [--source-map <alias>=<path>...]",
        "./casually_backup.lua --help",
        "./casually_backup.lua --version",
        "",
        "--config <file>              JSON file with the listing, destinations, and optional limits.",
        "--index <listing>            Finished listing to read. Requires --dest.",
        "--dest <dir>                 Backup folder. Repeat for another folder. Requires --index.",
        "--source-map <alias>=<path>  Read one listing prefix from another directory. Requires --index.",
        "--dry-run                     Print the plan and change nothing.",
        "--omit-limit <n>             Refuse a snapshot that drops more than n paths. Default 1000.",
        "--omit-fraction <number>     Refuse a snapshot that drops more than this fraction. Default 0.02.",
        "--workers <n>                Copy files with n processes. Default 4. From 1 to 64.",
        "--report <email>              Print a backup summary to stderr after running.",
        "--report-dir <dir>            Write detailed report lines to <dir>/<stamp>.log instead of stderr.",
        "--help                       Show this help and exit.",
        "--version                    Show the script, Lua, and terminal.lua versions.",
        "",
    }, "\n")
end

function M.version_lines()
    return {
        "casually_backup " .. VERSION,
        _VERSION,
        "terminal.lua " .. tostring(terminal._VERSION),
    }
end

local JSON_NULL = {}

local CONFIG_KEYS = {
    index = true,
    destinations = true,
    source_map = true,
    exclude = true,
    omit_limit = true,
    omit_fraction = true,
    workers = true,
    report = true,
    report_dir = true,
}

local MAP_KEYS = {
    alias = true,
    path = true,
}

local DEFAULT_OMIT_LIMIT = 1000
local DEFAULT_OMIT_FRACTION = 0.02
local DEFAULT_WORKERS = 4
local MAX_WORKERS = 64

local function config_fail(reason)
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

local function sits_inside(path, dir)
    return path == dir or is_prefix(dir, path)
end

local function check_syntax(label, raw, allow_slash)
    if raw == nil or raw == JSON_NULL then
        return config_fail(label .. " is required")
    end
    if type(raw) ~= "string" then
        return config_fail(label .. " must be a string")
    end
    if raw == "" then
        return config_fail(label .. " is empty")
    end
    local path = normalize(raw)
    if path:sub(1, 1) ~= "/" then
        return config_fail(label .. " must be absolute")
    end
    if has_dot_component(path) then
        return config_fail(label .. " contains '.' or '..'")
    end
    if path == "/" and not allow_slash then
        return config_fail(label .. " must not be /")
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
        return config_fail(label .. " does not exist")
    end
    if attr.mode == "link" then
        return config_fail(label .. " is not a real directory")
    end
    if attr.mode ~= "directory" then
        return config_fail(label .. " is not a directory")
    end
    return path
end

local function check_regular_file(label, raw, fs)
    local path, err = check_syntax(label, raw, true)
    if not path then
        return nil, err, "config"
    end
    local attr = lstat(fs, path)
    if not attr then
        return config_fail(label .. " does not exist")
    end
    if attr.mode == "link" then
        return config_fail(label .. " is not a real file")
    end
    if attr.mode ~= "file" then
        return config_fail(label .. " is not a regular file")
    end
    local base = path:match("[^/]+$")
    if base and base:sub(-8) == ".partial" then
        return config_fail(label .. " ends in .partial")
    end
    return path
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
    local name = dir .. "/.casually_backup.probe." .. process_id()
    local f = io.open(name, "w")
    if not f then
        return false
    end
    f:close()
    os.remove(name)
    return true
end

local function check_dest_list(entries, fs, label_for)
    local dests = {}
    for i = 1, #entries do
        local label = label_for(i)
        local path, err = check_real_dir(label, entries[i], fs, false)
        if not path then
            return nil, err, "config"
        end
        if not probe_writable(path) then
            return config_fail(label .. " is not writable")
        end
        dests[i] = path
    end
    for i = 1, #dests do
        for j = i + 1, #dests do
            if overlaps(dests[i], dests[j]) then
                return config_fail("destinations overlap: " .. dests[i] .. " and " .. dests[j])
            end
        end
    end
    return dests
end

local function ensure_index_outside(index, dests)
    for i = 1, #dests do
        if sits_inside(index, dests[i]) then
            return config_fail("index sits inside destination " .. dests[i])
        end
    end
    return true
end

local function unknown_map_key(entry)
    local unknown = {}
    for key in pairs(entry) do
        if not MAP_KEYS[key] then
            unknown[#unknown + 1] = tostring(key)
        end
    end
    table.sort(unknown)
    return unknown[1]
end

local function check_source_map(entries, fs, prefix, from_json)
    if entries == nil then
        return {}
    end
    if from_json then
        if entries == JSON_NULL or json_kind(entries) ~= "array" then
            return config_fail(prefix .. " must be an array")
        end
    elseif type(entries) ~= "table" then
        return config_fail(prefix .. " must be an array")
    end
    local map = {}
    for i = 1, #entries do
        local label = prefix .. "[" .. i .. "]"
        local entry = entries[i]
        if type(entry) ~= "table" or entry == JSON_NULL then
            return config_fail(label .. " must be an object")
        end
        if from_json and json_kind(entry) ~= "object" then
            return config_fail(label .. " must be an object")
        end
        local bad = unknown_map_key(entry)
        if bad then
            return config_fail(label .. " unknown key: " .. bad)
        end
        local alias, err = check_syntax(label .. ".alias", entry.alias, true)
        if not alias then
            return nil, err, "config"
        end
        local path
        path, err = check_real_dir(label .. ".path", entry.path, fs, true)
        if not path then
            return nil, err, "config"
        end
        map[i] = { alias = alias, path = path }
    end
    for i = 1, #map do
        for j = i + 1, #map do
            if overlaps(map[i].alias, map[j].alias) then
                return config_fail(prefix .. " aliases overlap: "
                    .. map[i].alias .. " and " .. map[j].alias)
            end
        end
    end
    return map
end

local function check_exclude(entries)
    if entries == nil then
        return {}
    end
    if entries == JSON_NULL or json_kind(entries) ~= "array" then
        return config_fail("exclude must be an array")
    end
    local exclude = {}
    for i = 1, #entries do
        local label = "exclude[" .. i .. "]"
        local path, err = check_syntax(label, entries[i], false)
        if not path then
            return nil, err, "config"
        end
        exclude[i] = path
    end
    return exclude
end

-- Zero is a valid omit_limit. Callers branch on the class, not on the number.
local function flag_limit(text)
    if type(text) ~= "string" or text:match("^%d+$") == nil then
        return config_fail("--omit-limit must be an integer >= 0")
    end
    local n = math.tointeger(text)
    if n == nil or n < 0 then
        return config_fail("--omit-limit must be an integer >= 0")
    end
    return n
end

local function flag_fraction(text)
    if type(text) ~= "string"
        or (text:match("^%d+$") == nil and text:match("^%d+%.%d+$") == nil) then
        return config_fail("--omit-fraction must be a number from 0 to 1")
    end
    local n = tonumber(text)
    if n == nil or n ~= n or n < 0 or n > 1 then
        return config_fail("--omit-fraction must be a number from 0 to 1")
    end
    return n
end

local function check_omit_limit(value, label)
    if value == nil then
        return DEFAULT_OMIT_LIMIT
    end
    if value == JSON_NULL or type(value) ~= "number" then
        return config_fail(label .. " must be an integer >= 0")
    end
    local n = math.tointeger(value)
    if n == nil or n < 0 then
        return config_fail(label .. " must be an integer >= 0")
    end
    return n
end

local function check_omit_fraction(value, label)
    if value == nil then
        return DEFAULT_OMIT_FRACTION
    end
    if value == JSON_NULL or type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
        return config_fail(label .. " must be a number from 0 to 1")
    end
    return value
end

local function check_workers(value, label)
    if value == nil then
        return DEFAULT_WORKERS
    end
    if value == JSON_NULL or type(value) ~= "number" then
        return config_fail(label .. " must be an integer from 1 to " .. MAX_WORKERS)
    end
    local n = math.tointeger(value)
    if n == nil or n < 1 or n > MAX_WORKERS then
        return config_fail(label .. " must be an integer from 1 to " .. MAX_WORKERS)
    end
    return n
end

local function flag_workers(text)
    if type(text) ~= "string" or text:match("^%d+$") == nil then
        return config_fail("--workers must be an integer from 1 to " .. MAX_WORKERS)
    end
    return check_workers(tonumber(text), "--workers")
end

local function resolve_limits(cmd, obj)
    local limit, fraction, err, class
    if cmd.omit_limit ~= nil then
        limit, err, class = flag_limit(cmd.omit_limit)
    else
        local raw = nil
        if obj ~= nil then
            raw = obj.omit_limit
        end
        limit, err, class = check_omit_limit(raw, "omit_limit")
    end
    if class then
        return nil, nil, err, class
    end
    if cmd.omit_fraction ~= nil then
        fraction, err, class = flag_fraction(cmd.omit_fraction)
    else
        local raw = nil
        if obj ~= nil then
            raw = obj.omit_fraction
        end
        fraction, err, class = check_omit_fraction(raw, "omit_fraction")
    end
    if class then
        return nil, nil, err, class
    end
    return limit, fraction
end

local function take_string_array(entries, label)
    if entries == nil or entries == JSON_NULL then
        return config_fail(label .. " is required")
    end
    if type(entries) ~= "table" or json_kind(entries) ~= "array" then
        return config_fail(label .. " must be an array")
    end
    if #entries == 0 then
        return config_fail(label .. " is empty")
    end
    return entries
end

local function finish_config(index, dests, map, exclude, limit, fraction, workers, report, report_dir)
    return {
        index = index,
        destinations = dests,
        source_map = map,
        exclude = exclude,
        omit_limit = limit,
        omit_fraction = fraction,
        workers = workers,
        report = report,
        report_dir = report_dir,
    }
end

local function resolve_workers(cmd, obj)
    if cmd.workers ~= nil then
        return flag_workers(cmd.workers)
    end
    local raw = nil
    if obj ~= nil then
        raw = obj.workers
    end
    return check_workers(raw, "workers")
end

local function resolve_report(cmd, obj)
    if cmd.report ~= nil then
        return cmd.report
    end
    if obj ~= nil and obj.report ~= nil and obj.report ~= JSON_NULL then
        return obj.report
    end
    return nil
end

local function resolve_report_dir(cmd, obj)
    if cmd.report_dir ~= nil then
        return cmd.report_dir
    end
    if obj ~= nil and obj.report_dir ~= nil and obj.report_dir ~= JSON_NULL then
        return obj.report_dir
    end
    return nil
end

local function assemble(index, dests, map, exclude, cmd, obj)
    local limit, fraction, err, class = resolve_limits(cmd, obj)
    if class then
        return nil, err, class
    end
    local workers
    workers, err, class = resolve_workers(cmd, obj)
    if class then
        return nil, err, class
    end
    local report = resolve_report(cmd, obj)
    local report_dir = resolve_report_dir(cmd, obj)
    return finish_config(index, dests, map, exclude, limit, fraction, workers, report, report_dir)
end

local function decode_config(text)
    if type(text) ~= "string" then
        return config_fail("config is not valid JSON")
    end
    local value, pos, err = dkjson.decode(text, 1, JSON_NULL)
    if err then
        return config_fail("config is not valid JSON: " .. err)
    end
    local rest = text:sub(pos or 1)
    if rest:find("%S") then
        return config_fail("config is not valid JSON: trailing data")
    end
    if value == JSON_NULL or json_kind(value) ~= "object" then
        return config_fail("config is not a JSON object")
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

local function checked_paths(index, dests, map_entries, exclude_raw, fs, map_prefix, from_json)
    local outside, err, class = ensure_index_outside(index, dests)
    if not outside then
        return nil, nil, err, class
    end
    local map
    map, err, class = check_source_map(map_entries, fs, map_prefix, from_json)
    if not map then
        return nil, nil, err, class
    end
    local exclude
    exclude, err, class = check_exclude(exclude_raw)
    if not exclude then
        return nil, nil, err, class
    end
    return map, exclude
end

local function load_json(cmd, fs)
    local path = cmd.config
    local f, open_err = io.open(path, "rb")
    if not f then
        return config_fail("cannot read config " .. path .. ": " .. tostring(open_err))
    end
    local text, read_err = f:read("a")
    f:close()
    if text == nil then
        return config_fail("cannot read config " .. path .. ": " .. tostring(read_err))
    end
    local obj, err, class = decode_config(text)
    if not obj then
        return nil, err, class
    end
    local bad = unknown_key(obj)
    if bad then
        return config_fail("unknown config key: " .. bad)
    end
    local index
    index, err, class = check_regular_file("index", obj.index, fs)
    if not index then
        return nil, err, class
    end
    local entries
    entries, err, class = take_string_array(obj.destinations, "destinations")
    if not entries then
        return nil, err, class
    end
    local dests
    dests, err, class = check_dest_list(entries, fs, function(i)
        return "destinations[" .. i .. "]"
    end)
    if not dests then
        return nil, err, class
    end
    local map, exclude
    map, exclude, err, class = checked_paths(
        index, dests, obj.source_map, obj.exclude, fs, "source_map", true)
    if not map then
        return nil, err, class
    end
    return assemble(index, dests, map, exclude, cmd, obj)
end

local function load_flags(cmd, fs)
    local index, err, class = check_regular_file("--index", cmd.index, fs)
    if not index then
        return nil, err, class
    end
    if type(cmd.destinations) ~= "table" or cmd.destinations == JSON_NULL then
        return config_fail("destinations is required")
    end
    if #cmd.destinations == 0 then
        return config_fail("destinations is empty")
    end
    local dests
    dests, err, class = check_dest_list(cmd.destinations, fs, function(i)
        return "--dest[" .. i .. "]"
    end)
    if not dests then
        return nil, err, class
    end
    local map, exclude
    map, exclude, err, class = checked_paths(
        index, dests, cmd.source_map, nil, fs, "--source-map", false)
    if not map then
        return nil, err, class
    end
    return assemble(index, dests, map, exclude, cmd, nil)
end

function M.load_config(cmd, fs)
    if type(cmd) ~= "table" then
        return config_fail("missing arguments")
    end
    fs = fs or {
        lstat = function(path)
            return lfs.symlinkattributes(path)
        end,
    }
    if cmd.config then
        return load_json(cmd, fs)
    end
    if cmd.index or cmd.destinations or cmd.source_map then
        return load_flags(cmd, fs)
    end
    return config_fail("missing arguments")
end

local TYPE_KIND = {
    ["-"] = "file",
    d = "dir",
    l = "link",
}

local MODE_GROUPS = {
    { r = 0x100, w = 0x80, x = 0x40, special = 0x800, on = "s", off = "S" },
    { r = 0x20, w = 0x10, x = 0x8, special = 0x400, on = "s", off = "S" },
    { r = 0x4, w = 0x2, x = 0x1, special = 0x200, on = "t", off = "T" },
}

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

-- os.time reads the fields as local time. A single offset is wrong when that
-- guess and the UTC fields sit in different daylight-saving rules, so correct
-- the guess until the UTC rendering matches. Forcing standard time can map
-- two different hours onto one epoch. When that delta is zero, step again
-- with daylight saving left unset.
local function utc_epoch(text)
    local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)(%d%d)(%d%d):(%d%d)(%d%d)(%d%d)$")
    if not y then
        return nil
    end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
    local function civil(yy, mm, dd, hh, mii, ss, isdst)
        local fields = {
            year = yy, month = mm, day = dd,
            hour = hh, min = mii, sec = ss,
        }
        if isdst ~= nil then
            fields.isdst = isdst
        end
        return os.time(fields)
    end
    local guess = civil(y, mo, d, h, mi, s, false)
    if guess == nil then
        return nil
    end
    for _ = 1, 4 do
        local got = os.date("!*t", guess)
        if type(got) ~= "table" then
            return nil
        end
        if got.year == y and got.month == mo and got.day == d
            and got.hour == h and got.min == mi and got.sec == s then
            return math.tointeger(guess)
        end
        local want = civil(y, mo, d, h, mi, s, false)
        local have = civil(got.year, got.month, got.day, got.hour, got.min, got.sec, false)
        if want == nil or have == nil then
            return nil
        end
        local delta = os.difftime(want, have)
        if delta == 0 then
            want = civil(y, mo, d, h, mi, s, nil)
            have = civil(got.year, got.month, got.day, got.hour, got.min, got.sec, nil)
            if want == nil or have == nil then
                return nil
            end
            delta = os.difftime(want, have)
            if delta == 0 then
                return nil
            end
        end
        guess = guess + delta
    end
    return nil
end

local function parse_mode(text)
    if type(text) ~= "string" or #text ~= 10 then
        return nil
    end
    local kind = TYPE_KIND[text:sub(1, 1)]
    if not kind then
        return nil
    end
    local nine = text:sub(2)
    local bits = 0
    for group = 1, 3 do
        local spec = MODE_GROUPS[group]
        local base = (group - 1) * 3
        local rc = nine:sub(base + 1, base + 1)
        local wc = nine:sub(base + 2, base + 2)
        local xc = nine:sub(base + 3, base + 3)
        if rc == "r" then
            bits = bits | spec.r
        elseif rc ~= "-" then
            return nil
        end
        if wc == "w" then
            bits = bits | spec.w
        elseif wc ~= "-" then
            return nil
        end
        if xc == "x" then
            bits = bits | spec.x
        elseif xc == spec.on then
            bits = bits | spec.x | spec.special
        elseif xc == spec.off then
            bits = bits | spec.special
        elseif xc ~= "-" then
            return nil
        end
    end
    return kind, bits
end

local function parse_owner(field)
    local colon = field:find(":", 1, true)
    if not colon or field:find(":", colon + 1, true) then
        return nil
    end
    local user = field:sub(1, colon - 1)
    local group = field:sub(colon + 1)
    if user == "" or group == "" then
        return nil
    end
    return user, group
end

local function parse_size(field)
    if type(field) ~= "string" or field:match("^%d+$") == nil then
        return nil
    end
    local n = tonumber(field)
    if n == nil then
        return nil
    end
    return math.tointeger(n)
end

local function unescape_field(field)
    local parts = {}
    local i = 1
    while i <= #field do
        local byte = field:byte(i)
        if byte ~= 92 then
            parts[#parts + 1] = field:sub(i, i)
            i = i + 1
        else
            local next_byte = field:byte(i + 1)
            if next_byte == 92 then
                parts[#parts + 1] = "\\"
            elseif next_byte == 116 then
                parts[#parts + 1] = "\t"
            elseif next_byte == 110 then
                parts[#parts + 1] = "\n"
            elseif next_byte == 114 then
                parts[#parts + 1] = "\r"
            else
                return nil
            end
            i = i + 2
        end
    end
    return table.concat(parts)
end

local function field_count(line)
    local n = 1
    for i = 1, #line do
        if line:byte(i) == 9 then
            n = n + 1
        end
    end
    return n
end

local function split_fields(line)
    local fields = {}
    local start_at = 1
    for _ = 1, 5 do
        local tab = line:find("\t", start_at, true)
        if not tab then
            return nil
        end
        fields[#fields + 1] = line:sub(start_at, tab - 1)
        start_at = tab + 1
    end
    fields[6] = line:sub(start_at)
    return fields
end

local function normal_line_has_backslash(fields)
    for i = 1, 6 do
        if i == 5 and fields[5] == "\\-" then
            -- The link field that is exactly \- names a target of "-".
        elseif fields[i]:find("\\", 1, true) then
            return true
        end
    end
    return false
end

local function check_listing_path(path)
    if path == "" or path:sub(1, 1) ~= "/" then
        return "path must be absolute"
    end
    if path == "/" then
        return nil
    end
    local i = 1
    while i <= #path do
        local next_slash = path:find("/", i + 1, true)
        local part
        if next_slash then
            part = path:sub(i + 1, next_slash - 1)
            i = next_slash
        else
            part = path:sub(i + 1)
            i = #path + 1
        end
        if part == "." or part == ".." then
            return "path contains '.' or '..'"
        end
        if part == "" then
            return "path contains an empty component"
        end
    end
    return nil
end

local function parse_line(line, n, prev)
    if line == "" then
        return nil, "line " .. n .. " is empty"
    end
    local count = field_count(line)
    if count ~= 6 then
        return nil, "line " .. n .. " has " .. count .. " fields"
    end
    local fields = split_fields(line)
    local bang = fields[1]:sub(1, 1) == "!"
    if not bang and normal_line_has_backslash(fields) then
        return nil, "line " .. n .. " contains a backslash"
    end
    local mtime_text = fields[1]
    if bang then
        mtime_text = fields[1]:sub(2)
    end
    local epoch = utc_epoch(mtime_text)
    if epoch == nil then
        return nil, "line " .. n .. " has a bad mtime"
    end
    local user, group = parse_owner(fields[2])
    if not user then
        return nil, "line " .. n .. " has a bad owner"
    end
    local kind, bits = parse_mode(fields[3])
    if not kind then
        return nil, "line " .. n .. " has a bad mode"
    end
    local size = parse_size(fields[4])
    if size == nil then
        return nil, "line " .. n .. " has a bad size"
    end
    local link_field = fields[5]
    local path_field = fields[6]
    if kind == "link" and link_field == "-" then
        return nil, "line " .. n .. " link target is -"
    end
    local target
    local path
    if bang then
        if kind == "link" and link_field == "\\-" then
            target = "-"
        elseif kind == "link" then
            target = unescape_field(link_field)
            if target == nil then
                return nil, "line " .. n .. " has an unknown escape"
            end
        elseif link_field ~= "-" then
            return nil, "line " .. n .. " has a link target"
        end
        path = unescape_field(path_field)
        if path == nil then
            return nil, "line " .. n .. " has an unknown escape"
        end
    else
        if kind == "link" then
            if link_field == "\\-" then
                target = "-"
            else
                target = link_field
            end
        elseif link_field ~= "-" then
            return nil, "line " .. n .. " has a link target"
        end
        path = path_field
    end
    if kind == "link" and size ~= #target then
        return nil, "line " .. n .. " symlink size is not the target length"
    end
    local path_err = check_listing_path(path)
    if path_err then
        return nil, "line " .. n .. " " .. path_err
    end
    if prev then
        if path == prev then
            return nil, "line " .. n .. " repeats a path"
        end
        if path < prev then
            return nil, "line " .. n .. " is out of order"
        end
    end
    local rec = {
        path = path,
        kind = kind,
        size = size,
        mtime_text = mtime_text,
        mtime = epoch,
        user = user,
        group = group,
        mode_text = fields[3],
        mode = bits,
    }
    if kind == "link" then
        rec.target = target
    end
    return rec
end

-- The indexer sorts full paths. A sibling can sit between a directory and a
-- later child, so a branch stack would forget a parent that is still present.
local function check_parents(records)
    local dirs = {}
    local seen = {}
    for i = 1, #records do
        local rec = records[i]
        local parent = parent_of(rec.path)
        if not (parent ~= nil and dirs[parent]) then
            local covered = false
            local anc = parent
            while anc ~= nil do
                if seen[anc] then
                    covered = true
                    break
                end
                anc = parent_of(anc)
            end
            if covered then
                return "line " .. i .. " parent is missing"
            end
            if rec.kind ~= "dir" then
                return "line " .. i .. " root is not a directory"
            end
        end
        seen[rec.path] = true
        if rec.kind == "dir" then
            dirs[rec.path] = true
        end
    end
    return nil
end

function M.parse_listing(text)
    if type(text) ~= "string" then
        return config_fail("listing must be a string")
    end
    if text == "" then
        return config_fail("listing is empty")
    end
    if text:sub(-1) ~= "\n" then
        return config_fail("listing is missing a final newline")
    end
    local body = text:sub(1, -2)
    if body == "" then
        return config_fail("listing has no records")
    end
    local records = {}
    local prev = nil
    local line_no = 1
    local start_at = 1
    while start_at <= #body + 1 do
        local nl = body:find("\n", start_at, true)
        local line
        local last = false
        if nl then
            line = body:sub(start_at, nl - 1)
            start_at = nl + 1
        else
            line = body:sub(start_at)
            last = true
        end
        local rec, err = parse_line(line, line_no, prev)
        if not rec then
            return config_fail(err)
        end
        records[#records + 1] = rec
        prev = rec.path
        line_no = line_no + 1
        if last then
            break
        end
    end
    local parent_err = check_parents(records)
    if parent_err then
        return config_fail(parent_err)
    end
    return records
end

function M.listing_stamp(filename)
    if type(filename) ~= "string" or filename == "" then
        return nil
    end
    local base = filename:match("([^/]+)$")
    if not base then
        return nil
    end
    return base:match("^index%-(%d%d%d%d%d%d%d%d%-%d%d%d%d)%.listing$")
end

-- Plan. lstat and directory reads only. No create, remove, rename, chmod,
-- chown, hardlink, or copy. fs.lstat and fs.dir default to LuaFileSystem.
-- fs.euid skips /proc. fs.getent(database) skips the getent process.
-- euid 0 compares owner. Any other euid skips owner and records one warning.
-- A missing _Base is a full copy: dated directories left in the folder are
-- not link sources. Link sources are the latest dated snapshot, else _Base.

local LFS_TYPE_CHAR = {
    file = "-",
    directory = "d",
    link = "l",
}

local STAMP_DIR = "^%d%d%d%d%d%d%d%d%-%d%d%d%d$"

local function plan_fail(reason, class)
    return nil, reason, class or "plan"
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

local function resolve_source(path, map)
    local best
    local best_len = -1
    for i = 1, #map do
        local alias = map[i].alias
        if path == alias or is_prefix(alias, path) then
            if #alias > best_len then
                best = map[i]
                best_len = #alias
            end
        end
    end
    if not best then
        return path
    end
    local rest = path:sub(#best.alias + 1)
    if best.path == "/" then
        if rest == "" then
            return "/"
        end
        return rest
    end
    if rest == "" then
        return best.path
    end
    return best.path .. rest
end

local function published_path(dest, snap, listing)
    if listing == "/" then
        return dest .. "/" .. snap
    end
    return dest .. "/" .. snap .. listing
end

local function snapshot_join(root, listing)
    if listing == "/" then
        return root
    end
    return root .. listing
end

local enoent_tail

local function is_missing(err)
    if err == nil then
        return true
    end
    if type(err) ~= "string" then
        return false
    end
    if not enoent_tail then
        local _, sample = lfs.symlinkattributes("/\1casually-backup-missing")
        if type(sample) == "string" then
            enoent_tail = sample:match(": (.+)$")
        end
        if not enoent_tail then
            enoent_tail = "No such file or directory"
        end
    end
    return #err >= #enoent_tail and err:sub(-#enoent_tail) == enoent_tail
end

local function list_names(dir_fn, path)
    local iter, dir_obj = dir_fn(path)
    if not iter then
        return nil, dir_obj or "cannot open"
    end
    local names = {}
    local read_ok, read_err = pcall(function()
        while true do
            local name = iter(dir_obj)
            if name == nil then
                break
            end
            if name ~= "." and name ~= ".." then
                names[#names + 1] = name
            end
        end
    end)
    if (type(dir_obj) == "table" or type(dir_obj) == "userdata")
        and type(dir_obj.close) == "function" then
        pcall(dir_obj.close, dir_obj)
    end
    if not read_ok then
        return nil, read_err
    end
    table.sort(names)
    return names
end

local function read_text(path, label, class)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, "cannot read " .. label .. " " .. path .. ": " .. tostring(err), class
    end
    local text, read_err = f:read("a")
    f:close()
    if text == nil then
        return nil, "cannot read " .. label .. " " .. path .. ": " .. tostring(read_err), class
    end
    return text
end

local function effective_uid(fs)
    if fs and fs.euid ~= nil then
        local n = math.tointeger(fs.euid)
        if n == nil or n < 0 then
            return plan_fail("cannot read uid")
        end
        return n
    end
    local f, err = io.open("/proc/self/status", "rb")
    if not f then
        return plan_fail("cannot read uid: " .. tostring(err))
    end
    local text = f:read("a")
    f:close()
    if type(text) ~= "string" then
        return plan_fail("cannot read uid")
    end
    local line = text:match("Uid:[^\n]*")
    local euid = line and line:match("Uid:%s*%d+%s+(%d+)")
    euid = euid and math.tointeger(tonumber(euid))
    if euid == nil then
        return plan_fail("cannot read uid")
    end
    return euid
end

local function run_getent(database)
    local handle, open_err = io.popen("getent " .. database, "r")
    if not handle then
        return nil, "cannot read " .. database .. " names: " .. tostring(open_err)
    end
    local text = handle:read("a")
    local ok = handle:close()
    if text == nil or ok ~= true then
        return nil, "cannot read " .. database .. " names"
    end
    return text
end

local function name_to_id(text)
    local by_name = {}
    for line in text:gmatch("[^\n]+") do
        local name, id = line:match("^([^:]*):[^:]*:([^:\n]*)")
        if name and name ~= "" and id and id ~= "" and by_name[name] == nil then
            local n = tonumber(id)
            n = n and math.tointeger(n)
            if n ~= nil and n >= 0 then
                by_name[name] = n
            end
        end
    end
    return by_name
end

local function load_names(fs, database)
    local text, err
    if fs and fs.getent then
        text, err = fs.getent(database)
    else
        text, err = run_getent(database)
    end
    if type(text) ~= "string" then
        return nil, err or ("cannot read " .. database .. " names"), "scan"
    end
    return name_to_id(text)
end

-- A known name wins. All digits that are not a name are that id.
local function resolve_side(side, by_name)
    local named = by_name[side]
    if named ~= nil then
        return named
    end
    if type(side) == "string" and side:match("^%d+$") then
        return math.tointeger(tonumber(side))
    end
    return nil
end

local function resolve_owners(records, users, groups)
    local owners = {}
    for i = 1, #records do
        local rec = records[i]
        local uid = resolve_side(rec.user, users)
        if uid == nil then
            return nil, "unknown user " .. rec.user, "scan"
        end
        local gid = resolve_side(rec.group, groups)
        if gid == nil then
            return nil, "unknown group " .. rec.group, "scan"
        end
        owners[rec.path] = { uid = uid, gid = gid }
    end
    return owners
end

local function ten_mode(attr)
    if type(attr.mode_text) == "string" and #attr.mode_text == 10 then
        return attr.mode_text
    end
    local flag = LFS_TYPE_CHAR[attr.mode]
    if not flag then
        return nil
    end
    if type(attr.permissions) ~= "string" or #attr.permissions ~= 9 then
        return nil
    end
    -- lfs 1.9.0 permissions are the low nine letters. Setuid, setgid, and
    -- sticky are not in that string, so they cannot force a new copy.
    return flag .. attr.permissions
end

local function mtime_text_of(modification)
    if type(modification) ~= "number" then
        return nil
    end
    local whole = math.modf(modification)
    local sec = math.tointeger(whole)
    if sec == nil then
        return nil
    end
    return os.date("!%Y%m%d:%H%M%S", sec)
end

local function same_owner(attr, own)
    local uid = math.tointeger(attr.uid)
    local gid = math.tointeger(attr.gid)
    return own ~= nil and uid == own.uid and gid == own.gid
end

local function file_matches(attr, rec, apply_owner, owners)
    if attr.mode ~= "file" then
        return false
    end
    local size = math.tointeger(attr.size)
    if size == nil or size ~= rec.size then
        return false
    end
    if mtime_text_of(attr.modification) ~= rec.mtime_text then
        return false
    end
    if ten_mode(attr) ~= rec.mode_text then
        return false
    end
    if apply_owner and not same_owner(attr, owners[rec.path]) then
        return false
    end
    return true
end

local function link_matches(attr, rec)
    return attr.mode == "link" and attr.target == rec.target
end

local function nests(source, dest, is_directory)
    if source == dest or is_prefix(dest, source) then
        return true
    end
    if is_directory and is_prefix(source, dest) then
        return true
    end
    return false
end

local function nest_check(records, sources, destinations)
    for i = 1, #records do
        local rec = records[i]
        local source = sources[rec.path]
        local is_directory = rec.kind == "dir"
        for d = 1, #destinations do
            local dest = destinations[d]
            if nests(source, dest, is_directory) then
                return "source and destination nest: " .. source .. " and " .. dest
            end
        end
    end
    return nil
end

local function choose_snapshot(dest, stamp, lstat_fn, dir_fn)
    local base = dest .. "/_Base"
    local attr, err = lstat_fn(base)
    if not attr then
        if not is_missing(err) then
            return nil, "cannot read " .. base .. ": " .. tostring(err), "scan"
        end
        return { snapshot = "_Base", previous = nil }
    end
    if attr.mode ~= "directory" then
        return nil, "not a directory: " .. base, "plan"
    end
    local names, nerr = list_names(dir_fn, dest)
    if not names then
        return nil, "cannot read " .. dest .. ": " .. tostring(nerr), "scan"
    end
    local latest
    for i = 1, #names do
        local name = names[i]
        if name:match(STAMP_DIR) then
            local child = dest .. "/" .. name
            local cattr, cerr = lstat_fn(child)
            if not cattr then
                if not is_missing(cerr) then
                    return nil, "cannot read " .. child .. ": " .. tostring(cerr), "scan"
                end
            elseif cattr.mode ~= "directory" then
                return nil, "not a directory: " .. child, "plan"
            elseif latest == nil or name > latest then
                latest = name
            end
        end
    end
    local previous = latest and (dest .. "/" .. latest) or base
    local snap = dest .. "/" .. stamp
    local sattr, serr = lstat_fn(snap)
    if sattr then
        return nil, "snapshot exists: " .. snap, "plan"
    end
    if not is_missing(serr) then
        return nil, "cannot read " .. snap .. ": " .. tostring(serr), "scan"
    end
    return { snapshot = stamp, previous = previous }
end

local function walk_previous(previous, root_dev, exclude, lstat_fn, dir_fn)
    local entries = {}
    local mounts = {}

    local function visit(abs, listing)
        local names, err = list_names(dir_fn, abs)
        if not names then
            return nil, "cannot read " .. abs .. ": " .. tostring(err), "scan"
        end
        for i = 1, #names do
            local name = names[i]
            local child_abs = abs .. "/" .. name
            local child_listing = listing and (listing .. "/" .. name) or ("/" .. name)
            local attr, aerr = lstat_fn(child_abs)
            if not attr then
                return nil, "cannot read " .. child_abs .. ": " .. tostring(aerr), "scan"
            end
            entries[child_listing] = attr
            if is_excluded(child_listing, exclude) then
                -- The excluded path is an omission. Its children are not read.
            elseif attr.mode == "directory" then
                if attr.dev ~= root_dev then
                    mounts[#mounts + 1] = child_listing
                else
                    local ok, child_err, class = visit(child_abs, child_listing)
                    if not ok then
                        return nil, child_err, class
                    end
                end
            end
        end
        return true
    end

    local ok, err, class = visit(previous, nil)
    if not ok then
        return nil, err, class
    end
    return { entries = entries, mounts = mounts }
end

local function ancestor_paths(records)
    local have = {}
    for i = 1, #records do
        if records[i].kind == "dir" then
            have[records[i].path] = true
        end
    end
    local paths = {}
    local seen = {}
    for i = 1, #records do
        if records[i].kind == "dir" then
            local parent = parent_of(records[i].path)
            while parent and parent ~= "/" and not have[parent] do
                if not seen[parent] then
                    seen[parent] = true
                    paths[#paths + 1] = parent
                end
                parent = parent_of(parent)
            end
        end
    end
    table.sort(paths)
    return paths
end

local function check_ancestors(previous, ancestors, entries)
    for i = 1, #ancestors do
        local listing = ancestors[i]
        local attr = entries[listing]
        if attr and attr.mode ~= "directory" and attr.mode ~= "file" then
            return nil, "ancestor is not a directory: " .. snapshot_join(previous, listing), "plan"
        end
    end
    return true
end

local function check_mounts(records, mounts)
    for i = 1, #records do
        local path = records[i].path
        for m = 1, #mounts do
            if is_prefix(mounts[m], path) then
                return nil, "path is on another device: " .. path, "plan"
            end
        end
    end
    return true
end

local function blank_actions()
    return {
        mkdir = {},
        copy = {},
        hardlink = {},
        symlink = {},
        omit = {},
    }
end

local function action_meta(rec, owners)
    local row = {
        listing = rec.path,
        mode = rec.mode,
        mode_text = rec.mode_text,
        mtime = rec.mtime,
        mtime_text = rec.mtime_text,
        user = rec.user,
        group = rec.group,
        size = rec.size,
    }
    local own = owners and owners[rec.path]
    if own then
        row.uid = own.uid
        row.gid = own.gid
    end
    if rec.target ~= nil then
        row.target = rec.target
    end
    return row
end

local function add_create(actions, kind, dest, snap, rec, source, owners)
    local path = published_path(dest, snap, rec.path)
    local row = action_meta(rec, owners)
    row.path = path
    if kind == "mkdir" then
        actions.mkdir[#actions.mkdir + 1] = row
    elseif kind == "copy" then
        row.source = source
        actions.copy[#actions.copy + 1] = row
    else
        actions.symlink[#actions.symlink + 1] = row
    end
end

local function classify_dest(dest, choice, desired, desired_set, ancestors, ancestor_set, walked, sources, owners, apply_owner)
    local actions = blank_actions()
    local warnings = {}
    local snap = choice.snapshot
    local previous = choice.previous
    local entries = walked and walked.entries or {}

    for i = 1, #ancestors do
        local listing = ancestors[i]
        actions.mkdir[#actions.mkdir + 1] = {
            path = published_path(dest, snap, listing),
            listing = listing,
            ancestor = true,
        }
    end

    for i = 1, #desired do
        local rec = desired[i]
        local attr = entries[rec.path]
        if rec.kind == "dir" or not attr then
            if rec.kind == "dir" then
                add_create(actions, "mkdir", dest, snap, rec, nil, owners)
            elseif rec.kind == "file" then
                add_create(actions, "copy", dest, snap, rec, sources[rec.path], owners)
            else
                add_create(actions, "symlink", dest, snap, rec, nil, owners)
            end
        elseif rec.kind == "file" then
            if file_matches(attr, rec, apply_owner, owners) then
                local row = action_meta(rec, owners)
                row.path = published_path(dest, snap, rec.path)
                row.previous = snapshot_join(previous, rec.path)
                actions.hardlink[#actions.hardlink + 1] = row
            else
                add_create(actions, "copy", dest, snap, rec, sources[rec.path], owners)
            end
        elseif link_matches(attr, rec) then
            local row = action_meta(rec, owners)
            row.path = published_path(dest, snap, rec.path)
            row.previous = snapshot_join(previous, rec.path)
            actions.hardlink[#actions.hardlink + 1] = row
        else
            add_create(actions, "symlink", dest, snap, rec, nil, owners)
        end
    end

    if previous then
        local omitted = {}
        for listing, attr in pairs(entries) do
            if not desired_set[listing] and not ancestor_set[listing] then
                if attr.mode == "file" or attr.mode == "directory" or attr.mode == "link" then
                    omitted[#omitted + 1] = listing
                else
                    warnings[#warnings + 1] = "casually_backup: left " .. attr.mode
                        .. " " .. one_line(snapshot_join(previous, listing))
                end
            end
        end
        table.sort(omitted)
        for i = 1, #omitted do
            local listing = omitted[i]
            actions.omit[#actions.omit + 1] = {
                path = snapshot_join(previous, listing),
                listing = listing,
            }
        end
        table.sort(warnings)
    end

    local function by_path(a, b)
        return a.path < b.path
    end
    table.sort(actions.mkdir, by_path)
    table.sort(actions.copy, by_path)
    table.sort(actions.hardlink, by_path)
    table.sort(actions.symlink, by_path)

    return {
        destination = dest,
        snapshot = snap,
        previous = previous,
        actions = actions,
        warnings = warnings,
        counts = {
            mkdir = #actions.mkdir,
            copy = #actions.copy,
            hardlink = #actions.hardlink,
            symlink = #actions.symlink,
            omit = #actions.omit,
            skip = 0,
            read = #actions.copy,
        },
    }
end

local function render_plan(plan)
    local grouped = {
        mkdir = {},
        copy = {},
        hardlink = {},
        symlink = {},
        omit = {},
    }
    for i = 1, #plan.destinations do
        local actions = plan.destinations[i].actions
        for kind, list in pairs(actions) do
            for n = 1, #list do
                local action = list[n]
                local line
                if kind == "mkdir" then
                    line = "mkdir " .. action.path
                elseif kind == "copy" then
                    line = "copy " .. action.source .. " " .. action.path
                elseif kind == "hardlink" then
                    line = "hardlink " .. action.previous .. " " .. action.path
                elseif kind == "symlink" then
                    line = "symlink " .. action.path
                elseif kind == "omit" then
                    line = "omit " .. action.path
                end
                if line then
                    grouped[kind][#grouped[kind] + 1] = { path = action.path, line = line }
                end
            end
        end
    end
    local lines = {}
    for _, kind in ipairs({ "mkdir", "copy", "hardlink", "symlink", "omit" }) do
        table.sort(grouped[kind], function(a, b)
            return a.path < b.path
        end)
        for n = 1, #grouped[kind] do
            lines[#lines + 1] = grouped[kind][n].line
        end
    end
    local c = plan.counts
    lines[#lines + 1] = string.format(
        "plan copy=%d mkdir=%d hardlink=%d symlink=%d omit=%d skip=0 read=%d",
        c.copy, c.mkdir, c.hardlink, c.symlink, c.omit, c.read
    )
    return table.concat(lines, "\n") .. "\n"
end

-- The screen is an observer. Headless runs and dry-runs pass nil and paint
-- nothing. The frame is drawn here, not as a panel border, so the name can
-- sit in the corner. A tab, newline, carriage return, or DEL is drawn as "?".

local system = require("system")

-- Seconds. Zero returns as soon as the terminal has no byte. If a run blocks
-- in this poll, the lesson is to use 0.001.
local READANSI_TIMEOUT = 0

local SPIN = { "|", "/", "-", "\\" }

local FRAME_ATTR = { fg = "cyan" }
local NAME_ATTR = { fg = "white", brightness = "bright" }
local LABEL_ATTR = { fg = "white" }
local NUM_ATTR = { fg = "white", brightness = "bright" }
local ELAPSED_ATTR = { fg = "yellow", brightness = "bright" }
local SNAP_ATTR = { fg = "cyan", brightness = "bright" }
local COPIED_ATTR = { fg = "green", brightness = "bright" }
local SPIN_ATTR = { fg = "yellow", brightness = "bright" }
local PATH_ATTR = { fg = "white" }
local MARKER_ATTR = {
    C = COPIED_ATTR,
    S = { fg = "cyan" },
    L = { fg = "magenta", brightness = "bright" },
    D = { fg = "blue", brightness = "bright" },
}

local function sanitize_display(text)
    return (tostring(text):gsub("[\t\n\r" .. string.char(127) .. "]", "?"))
end

local function display_units(text)
    local units = {}
    local total = 0
    local i = 1
    local n = #text
    while i <= n do
        local ok = pcall(utf8.codepoint, text, i)
        if ok then
            local nxt = utf8.offset(text, 2, i)
            if not nxt then
                nxt = n + 1
            end
            local chunk = text:sub(i, nxt - 1)
            local width = 1
            local wok, w = pcall(terminal.text.width.utf8cwidth, chunk)
            if wok and type(w) == "number" and w >= 0 then
                width = w
            end
            units[#units + 1] = { chunk, width }
            total = total + width
            i = nxt
        else
            units[#units + 1] = { text:sub(i, i), 1 }
            total = total + 1
            i = i + 1
        end
    end
    return units, total
end

local function columns_of(text)
    local _, total = display_units(text)
    return total
end

function M.format_elapsed(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then
        seconds = 0
    end
    seconds = math.floor(seconds)
    local hours = math.floor(seconds / 3600)
    local mins = math.floor(seconds / 60) % 60
    local secs = seconds % 60
    return string.format("%d:%02d:%02d", hours, mins, secs)
end

function M.format_bytes(n)
    -- Stay in bytes until 10 KiB, so 1536 is "1536 B" and 10240 is "10 KiB".
    -- Higher units step at 1024. A value below 10 of a larger unit shows one
    -- decimal. Ten and above are integers.
    n = tonumber(n) or 0
    if n < 0 then
        n = 0
    end
    n = math.floor(n)
    local names = { "B", "KiB", "MiB", "GiB", "TiB" }
    local step = 1
    local scaled = n
    if n >= 10 * 1024 then
        scaled = n / 1024
        step = 2
        while step < #names and scaled >= 1024 do
            scaled = scaled / 1024
            step = step + 1
        end
    end
    if step == 1 or scaled >= 10 then
        return string.format("%d %s", math.floor(scaled + 0.5), names[step])
    end
    local text = string.format("%.1f", scaled)
    if tonumber(text) >= 10 then
        return string.format("%d %s", math.floor(scaled + 0.5), names[step])
    end
    return text .. " " .. names[step]
end

local function count_rate(count, elapsed)
    if elapsed < 1 then
        return "0"
    end
    local rate = count / elapsed
    if rate <= 0 then
        return "0"
    end
    if rate >= 10 then
        return string.format("%d", math.floor(rate + 0.5))
    end
    local text = string.format("%.1f", rate)
    if tonumber(text) >= 10 then
        return string.format("%d", math.floor(rate + 0.5))
    end
    return text
end

function M.middle_clip(text, width)
    width = math.floor(tonumber(width) or 0)
    if width < 1 then
        return ""
    end
    text = sanitize_display(text)
    local units, total = display_units(text)
    local function pad(body, cols)
        if cols < width then
            return body .. string.rep(" ", width - cols)
        end
        return body
    end
    if total <= width then
        return pad(text, total)
    end
    if width <= 3 then
        return string.rep(".", width)
    end
    local remain = width - 3
    local head_cols = math.ceil(remain / 2)
    local tail_cols = remain - head_cols
    local function take_head(cols)
        local parts = {}
        local used = 0
        for i = 1, #units do
            local w = units[i][2]
            if used + w > cols then
                break
            end
            parts[#parts + 1] = units[i][1]
            used = used + w
        end
        return table.concat(parts), used
    end
    local function take_tail(cols)
        local parts = {}
        local used = 0
        for i = #units, 1, -1 do
            local w = units[i][2]
            if used + w > cols then
                break
            end
            table.insert(parts, 1, units[i][1])
            used = used + w
        end
        return table.concat(parts), used
    end
    local head, head_w = take_head(head_cols)
    local tail, tail_w = take_tail(tail_cols)
    return pad(head .. "..." .. tail, head_w + 3 + tail_w)
end

local function measure_parts(parts)
    local n = 0
    for i = 1, #parts do
        n = n + columns_of(parts[i][1])
    end
    return n
end

local function drop_left_text(text, cols)
    if cols <= 0 then
        return text
    end
    local units = display_units(text)
    local i = 1
    while i <= #units and cols > 0 do
        cols = cols - units[i][2]
        i = i + 1
    end
    local parts = {}
    for j = i, #units do
        parts[#parts + 1] = units[j][1]
    end
    return table.concat(parts)
end

local function clip_parts_left(parts, width)
    if width < 1 then
        return {}
    end
    if measure_parts(parts) <= width then
        return parts
    end
    local drop = measure_parts(parts) - width
    local out = {}
    for i = 1, #parts do
        local text = parts[i][1]
        local attr = parts[i][2]
        local w = columns_of(text)
        if drop >= w then
            drop = drop - w
        else
            if drop > 0 then
                text = drop_left_text(text, drop)
                drop = 0
            end
            if text ~= "" then
                out[#out + 1] = { text, attr }
            end
        end
    end
    return out
end

local function copy_parts(parts)
    local out = {}
    for i = 1, #parts do
        out[i] = parts[i]
    end
    return out
end

local function pad_parts(parts, width)
    local shown = copy_parts(clip_parts_left(parts, width))
    local used = measure_parts(shown)
    if used < width then
        shown[#shown + 1] = { string.rep(" ", width - used), LABEL_ATTR }
    end
    return shown
end

local function status_parts(left, name, width)
    if width < 1 then
        return {}
    end
    local name_w = measure_parts(name)
    if name_w >= width then
        return pad_parts(name, width)
    end
    local budget = width - name_w
    local shown = clip_parts_left(left, budget)
    local out = copy_parts(shown)
    local gap = budget - measure_parts(out)
    if gap > 0 then
        out[#out + 1] = { string.rep(" ", gap), LABEL_ATTR }
    end
    for i = 1, #name do
        out[#out + 1] = name[i]
    end
    return out
end

local function place_parts(dest, snapshot, scanning, width)
    if width < 1 then
        return {}
    end
    if scanning or dest == nil then
        return pad_parts({ { "scanning", LABEL_ATTR } }, width)
    end
    local snap = {
        { "   ", LABEL_ATTR },
        { snapshot or "", SNAP_ATTR },
    }
    local snap_w = measure_parts(snap)
    if snap_w >= width then
        return pad_parts({
            { dest, LABEL_ATTR },
            { "   ", LABEL_ATTR },
            { snapshot or "", SNAP_ATTR },
        }, width)
    end
    local dest_parts = clip_parts_left({ { dest, LABEL_ATTR } }, width - snap_w)
    local out = copy_parts(dest_parts)
    for i = 1, #snap do
        out[#out + 1] = snap[i]
    end
    local used = measure_parts(out)
    if used < width then
        out[#out + 1] = { string.rep(" ", width - used), LABEL_ATTR }
    end
    return out
end

local function write_at(row, col, text, attr)
    terminal.cursor.position.set(row, col)
    terminal.output.write(terminal.text.push_seq(attr), text, terminal.text.pop_seq())
end

local function write_parts(row, col, parts)
    terminal.cursor.position.set(row, col)
    for i = 1, #parts do
        local text = parts[i][1]
        if text ~= "" then
            terminal.output.write(
                terminal.text.push_seq(parts[i][2]),
                text,
                terminal.text.pop_seq()
            )
        end
    end
end

local function paint_frame(panel, state)
    local row0 = panel.inner_row or 1
    local col0 = panel.inner_col or 1
    local height = panel.inner_height or 0
    local width = panel.inner_width or 0
    if width < 2 or height < 2 then
        return
    end
    local fmt = terminal.draw.box_fmt.rounded
    local content_w = width - 2
    local function glyph_row(row, text)
        write_at(row0 + row - 1, col0, text, FRAME_ATTR)
    end
    local function side_borders(row)
        local abs = row0 + row - 1
        write_at(abs, col0, fmt.l, FRAME_ATTR)
        write_at(abs, col0 + width - 1, fmt.r, FRAME_ATTR)
    end
    local function content_row(row, parts)
        write_parts(row0 + row - 1, col0 + 1, parts)
    end

    glyph_row(1, fmt.tl .. string.rep(fmt.t, content_w) .. fmt.tr)
    glyph_row(height, fmt.bl .. string.rep(fmt.b, content_w) .. fmt.br)
    if height < 8 then
        return
    end

    local total = state.total or 0
    local done = state.done or 0
    if done > total then
        done = total
    end
    local left_parts = {
        { tostring(total), NUM_ATTR },
        { " files   ", LABEL_ATTR },
        { tostring(done), NUM_ATTR },
        { " done   ", LABEL_ATTR },
        { tostring(total - done), NUM_ATTR },
        { " left   ", LABEL_ATTR },
        { M.format_elapsed(state.elapsed or 0), ELAPSED_ATTR },
    }
    side_borders(2)
    content_row(2, status_parts(left_parts, { { "Casually Backup", NAME_ATTR } }, content_w))
    side_borders(3)
    content_row(3, place_parts(state.dest, state.snapshot, state.scanning ~= false, content_w))
    glyph_row(4, fmt.post .. string.rep(fmt.t, content_w) .. fmt.pre)

    local file_rows = height - 8
    local shown = state:visible_lines(file_rows)
    for i = 1, file_rows do
        local row = 4 + i
        side_borders(row)
        local line = shown[i]
        if not line then
            content_row(row, { { string.rep(" ", content_w), LABEL_ATTR } })
        else
            local attr = line.open and SPIN_ATTR or (MARKER_ATTR[line.marker] or NUM_ATTR)
            local parts
            if content_w <= 1 then
                parts = { { (line.marker or " "):sub(1, content_w), attr } }
            else
                parts = {
                    { line.marker, attr },
                    { " ", PATH_ATTR },
                    { M.middle_clip(line.path or "", content_w - 2), PATH_ATTR },
                }
            end
            content_row(row, parts)
        end
    end

    local rule2 = height - 3
    glyph_row(rule2, fmt.post .. string.rep(fmt.t, content_w) .. fmt.pre)
    local elapsed_s = state.elapsed or 0
    local byte_rate = "0"
    if elapsed_s >= 1 then
        byte_rate = M.format_bytes((state.copied_bytes or 0) / elapsed_s) .. "/s"
    end
    side_borders(height - 2)
    content_row(height - 2, pad_parts({
        { "files ", LABEL_ATTR },
        { tostring(state.finished or 0), NUM_ATTR },
        { "   copied ", LABEL_ATTR },
        { tostring(state.copied_records or 0), NUM_ATTR },
        { "   ", LABEL_ATTR },
        { count_rate(state.finished or 0, elapsed_s), NUM_ATTR },
        { " files/s", LABEL_ATTR },
    }, content_w))
    side_borders(height - 1)
    content_row(height - 1, pad_parts({
        { "seen ", LABEL_ATTR },
        { M.format_bytes(state.seen or 0), NUM_ATTR },
        { "   copied ", LABEL_ATTR },
        { M.format_bytes(state.copied_bytes or 0), COPIED_ATTR },
        { "   ", LABEL_ATTR },
        { byte_rate, NUM_ATTR },
    }, content_w))
end

local screen_methods = {}

function screen_methods:visible_lines(rows)
    if rows < 0 then
        rows = 0
    end
    local room = rows
    if self.open then
        room = rows - 1
        if room < 0 then
            room = 0
        end
    end
    local first = #self.lines - room + 1
    if first < 1 then
        first = 1
    end
    if first > 1 then
        local kept = {}
        for i = first, #self.lines do
            kept[#kept + 1] = self.lines[i]
        end
        self.lines = kept
    end
    local shown = {}
    for i = 1, #self.lines do
        shown[i] = self.lines[i]
    end
    if self.open and rows >= 1 then
        self.open.open = true
        shown[#shown + 1] = self.open
    end
    return shown
end

function screen_methods:poll()
    if self.aborted then
        return nil, "aborted", "apply"
    end
    for _ = 1, 32 do
        local raw = terminal.input.readansi(READANSI_TIMEOUT)
        if raw == nil or raw == "" then
            break
        end
        if raw == "q" or raw == "\3" then
            self.aborted = true
            return nil, "aborted", "apply"
        end
    end
    return true
end

function screen_methods:redraw()
    if self.aborted then
        return nil, "aborted", "apply"
    end
    local now = system.monotime()
    self.elapsed = now - (self.opened or now)
    if now - self.status_at >= 1 then
        self.status_at = now
        if self.open then
            self.spin_i = self.spin_i % #SPIN + 1
            self.open.marker = SPIN[self.spin_i]
        end
    end
    if not self.laid_out then
        self.ui:calculate_layout()
        self.laid_out = true
    end
    self.ui:check_resize(true)
    self.ui:render()
    return self:poll()
end

function screen_methods:pulse(nbytes)
    if self.aborted then
        return nil, "aborted", "apply"
    end
    if type(nbytes) == "number" and nbytes > 0 then
        self.copied_bytes = self.copied_bytes + nbytes
    end
    if system.monotime() - self.status_at >= 1 then
        return self:redraw()
    end
    return self:poll()
end

function screen_methods:start(total)
    self.total = total or 0
    self.opened = system.monotime()
    self.status_at = self.opened
    self.elapsed = 0
    self.scanning = true
    self.done = 0
    self.finished = 0
    self.copied_records = 0
    self.copied_bytes = 0
    self.seen = 0
    self.lines = {}
    self.open = nil
    self.dest = nil
    self.snapshot = nil
    self.spin_i = 1
    return self:redraw()
end

function screen_methods:begin_line(dest, snapshot, path)
    if self.aborted then
        return nil, "aborted", "apply"
    end
    self.scanning = false
    self.dest = dest
    self.snapshot = snapshot
    self.open = {
        marker = SPIN[self.spin_i],
        path = path or "",
        open = true,
    }
    return self:redraw()
end

function screen_methods:finish_line(marker, size, close_record)
    if self.aborted then
        return nil, "aborted", "apply"
    end
    local line = self.open or { path = "" }
    line.marker = marker
    line.open = nil
    self.lines[#self.lines + 1] = line
    self.open = nil
    self.finished = self.finished + 1
    if marker == "C" then
        self.copied_records = self.copied_records + 1
    end
    self.seen = self.seen + (size or 0)
    if close_record then
        self.done = self.done + 1
    end
    return self:redraw()
end

function M.open_screen()
    local Panel = require("terminal.ui.panel")
    local Screen = require("terminal.ui.panel.screen")
    local now = system.monotime()
    local state = setmetatable({
        total = 0,
        done = 0,
        finished = 0,
        copied_records = 0,
        copied_bytes = 0,
        seen = 0,
        lines = {},
        open = nil,
        scanning = true,
        spin_i = 1,
        opened = now,
        status_at = now,
        elapsed = 0,
        aborted = false,
        laid_out = false,
    }, { __index = screen_methods })
    local body = Panel {
        name = "backup",
        content = function(panel)
            paint_frame(panel, state)
        end,
    }
    state.ui = Screen {
        body = body,
        name = "casually_backup",
    }
    return state
end

function M.plan(config, fs, screen)
    if type(config) ~= "table" then
        return plan_fail("missing config", "config")
    end
    if type(config.index) ~= "string" or type(config.destinations) ~= "table" then
        return plan_fail("missing config", "config")
    end
    local lstat_fn = (fs and fs.lstat) or function(path)
        return lfs.symlinkattributes(path)
    end
    local dir_fn = (fs and fs.dir) or function(path)
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then
            return nil, iter
        end
        return iter, dir_obj
    end
    local exclude = config.exclude or {}
    local map = config.source_map or {}
    local limit = config.omit_limit
    local fraction = config.omit_fraction
    if type(limit) ~= "number" or type(fraction) ~= "number" then
        return plan_fail("omit numbers are required", "config")
    end

    local text, err, class = read_text(config.index, "listing", "config")
    if not text then
        return nil, err, class
    end
    local records
    records, err, class = M.parse_listing(text)
    if not records then
        return nil, err, class
    end

    local desired = {}
    local desired_set = {}
    for i = 1, #records do
        local rec = records[i]
        if not is_excluded(rec.path, exclude) then
            desired[#desired + 1] = rec
            desired_set[rec.path] = rec
        end
    end
    if #desired == 0 then
        return plan_fail("exclude covers the listing")
    end

    local stamp = M.listing_stamp(config.index)
    if not stamp then
        stamp = os.date("!%Y%m%d-%H%M")
    end

    if screen then
        local sok, serr, sclass = screen:start(#desired)
        if not sok then
            return nil, serr, sclass
        end
    end

    local sources = {}
    for i = 1, #desired do
        sources[desired[i].path] = resolve_source(desired[i].path, map)
    end
    local nest = nest_check(desired, sources, config.destinations)
    if nest then
        return plan_fail(nest)
    end

    local euid
    euid, err, class = effective_uid(fs)
    if euid == nil then
        return nil, err, class
    end
    local apply_owner = euid == 0
    local owners
    local warnings = {}
    if apply_owner then
        local users, uerr, uclass = load_names(fs, "passwd")
        if not users then
            return nil, uerr, uclass
        end
        local groups, gerr, gclass = load_names(fs, "group")
        if not groups then
            return nil, gerr, gclass
        end
        owners, err, class = resolve_owners(desired, users, groups)
        if not owners then
            return nil, err, class
        end
    else
        warnings[1] = "casually_backup: owner not applied"
    end

    local ancestors = ancestor_paths(desired)
    local ancestor_set = {}
    for i = 1, #ancestors do
        ancestor_set[ancestors[i]] = true
    end

    local choices = {}
    for i = 1, #config.destinations do
        local choice
        choice, err, class = choose_snapshot(config.destinations[i], stamp, lstat_fn, dir_fn)
        if not choice then
            return nil, err, class
        end
        choices[i] = choice
    end

    local built = {}
    for i = 1, #config.destinations do
        local dest = config.destinations[i]
        local choice = choices[i]
        local walked
        if screen then
            local sok, serr, sclass = screen:pulse()
            if not sok then
                return nil, serr, sclass
            end
        end
        if choice.previous then
            local prev_attr
            prev_attr, err, class = (function()
                local dest_attr, dest_err = lstat_fn(dest)
                if not dest_attr or dest_attr.mode ~= "directory" then
                    return nil, "cannot read " .. dest .. ": " .. tostring(dest_err), "scan"
                end
                local attr, perr = lstat_fn(choice.previous)
                if not attr then
                    return nil, "cannot read " .. choice.previous .. ": " .. tostring(perr), "scan"
                end
                if attr.mode ~= "directory" then
                    return nil, "not a directory: " .. choice.previous, "plan"
                end
                if attr.dev ~= dest_attr.dev then
                    return nil, "previous snapshot is on another device: " .. choice.previous, "plan"
                end
                return attr
            end)()
            if not prev_attr then
                return nil, err, class
            end
            walked, err, class = walk_previous(choice.previous, prev_attr.dev, exclude, lstat_fn, dir_fn)
            if not walked then
                return nil, err, class
            end
            local blocked
            blocked, err, class = check_ancestors(choice.previous, ancestors, walked.entries)
            if not blocked then
                return nil, err, class
            end
            blocked, err, class = check_mounts(desired, walked.mounts)
            if not blocked then
                return nil, err, class
            end
        end
        local one = classify_dest(
            dest, choice, desired, desired_set, ancestors, ancestor_set,
            walked, sources, owners, apply_owner
        )
        if choice.previous then
            local omitted = one.counts.omit
            if omitted > limit and omitted > fraction * #desired then
                return plan_fail(string.format(
                    "too many omissions: %s omitted %d limit %d fraction %s",
                    dest, omitted, limit, tostring(fraction)
                ))
            end
        end
        built[i] = one
        for w = 1, #one.warnings do
            warnings[#warnings + 1] = one.warnings[w]
        end
    end

    local counts = {
        mkdir = 0,
        copy = 0,
        hardlink = 0,
        symlink = 0,
        omit = 0,
        skip = 0,
        read = 0,
    }
    local seen_read = {}
    local reads = {}
    for i = 1, #built do
        local c = built[i].counts
        counts.mkdir = counts.mkdir + c.mkdir
        counts.copy = counts.copy + c.copy
        counts.hardlink = counts.hardlink + c.hardlink
        counts.symlink = counts.symlink + c.symlink
        counts.omit = counts.omit + c.omit
        local copies = built[i].actions.copy
        for n = 1, #copies do
            local source = copies[n].source
            if not seen_read[source] then
                seen_read[source] = true
                reads[#reads + 1] = source
            end
        end
    end
    table.sort(reads)
    counts.read = #reads

    local plan = {
        stamp = stamp,
        desired = #desired,
        records = desired,
        reads = reads,
        warnings = warnings,
        counts = counts,
        destinations = built,
        apply_owner = apply_owner,
    }
    plan.text = render_plan(plan)
    return plan
end

-- Apply. One source read feeds every destination that needs a new inode.
-- The tree is built under <dest>/<snapshot>.<pid>.partial and renamed only
-- after every destination has its bytes, metadata, and directory mtimes.
-- fs.open_source(path) and fs.open_dest(path, dest) wrap the file handles.
-- fs.chmod(mode, nul_payload) and fs.chown(uid, gid, nul_payload) replace the
-- xargs batches. A false or missing hook runs the real GNU command.

local COPY_CHUNK = 1048576

local function lfs_dir(path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then
        return nil, iter
    end
    return iter, dir_obj
end

local function apply_fail(reason, class)
    return nil, reason, class or "apply"
end

local function is_source_error(reason)
    if reason:find("cannot write", 1, true) == 1 then
        return false
    end
    return reason:find("cannot read source", 1, true) ~= nil
        or reason:find("source is shorter than the listing", 1, true) ~= nil
        or reason:find("source is longer than the listing", 1, true) ~= nil
        or reason:find("source is not a regular file", 1, true) ~= nil
        or reason:find("source is a symlink", 1, true) ~= nil
        or reason:match("^cannot read %S") ~= nil
end

local function run_batch(command, payload)
    local handle, open_err = io.popen(command, "w")
    if not handle then
        return nil, tostring(open_err)
    end
    local wrote, write_err = handle:write(payload)
    if not wrote then
        handle:close()
        return nil, tostring(write_err)
    end
    local closed, why, code = handle:close()
    if closed ~= true then
        return nil, tostring(why) .. " " .. tostring(code)
    end
    return true
end

function M.metadata_batch(kind, arg, payload)
    local command
    if kind == "chmod" then
        command = "xargs -0 chmod " .. string.format("%o", arg) .. " --"
    elseif kind == "chown" then
        command = string.format("xargs -0 chown -h %d:%d --", arg.uid, arg.gid)
    else
        return nil, "unknown metadata batch"
    end
    return run_batch(command, payload)
end

local function nul_join(paths)
    local parts = {}
    for i = 1, #paths do
        parts[i] = paths[i] .. "\0"
    end
    return table.concat(parts)
end

local function queue_path(map, key, path)
    local list = map[key]
    if not list then
        list = {}
        map[key] = list
    end
    list[#list + 1] = path
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function remove_tree(path)
    local attr, err = lfs.symlinkattributes(path)
    if not attr then
        if is_missing(err) then
            return true
        end
        return nil, tostring(err)
    end
    if attr.mode ~= "directory" then
        local ok, remove_err = os.remove(path)
        if not ok then
            return nil, tostring(remove_err)
        end
        return true
    end
    local names, list_err = list_names(lfs_dir, path)
    if not names then
        return nil, tostring(list_err)
    end
    for i = 1, #names do
        local ok, child_err = remove_tree(path .. "/" .. names[i])
        if not ok then
            return nil, child_err
        end
    end
    local ok, remove_err = os.remove(path)
    if not ok then
        return nil, tostring(remove_err)
    end
    return true
end

local function pid_alive(pid)
    local attr = lfs.symlinkattributes("/proc/" .. pid)
    return attr ~= nil and attr.mode == "directory"
end

local function read_owner(dir)
    local f = io.open(dir .. "/owner", "rb")
    if not f then
        return nil
    end
    local text = f:read("a")
    f:close()
    if type(text) ~= "string" then
        return nil
    end
    return text:match("^(%d+)\n$") or text:match("^(%d+)$")
end

local function write_owner(dir, pid)
    local f, err = io.open(dir .. "/owner", "wb")
    if not f then
        return nil, tostring(err)
    end
    local ok, write_err = f:write(pid .. "\n")
    f:close()
    if not ok then
        return nil, tostring(write_err)
    end
    return true
end

local function take_lock(dest, pid)
    local dir = dest .. "/.casually_backup.lock"
    local function acquire()
        local existing = lfs.symlinkattributes(dir)
        if existing and existing.mode ~= "directory" then
            return nil, dir .. " is not a directory"
        end
        if not existing then
            local made, mkdir_err = lfs.mkdir(dir)
            if not made then
                return nil, tostring(mkdir_err)
            end
        end
        return lfs.lock_dir(dir)
    end
    local lock, err = acquire()
    if not lock then
        local owner = read_owner(dir)
        if owner and pid_alive(owner) then
            return nil, "destination locked: " .. dest .. " (pid " .. owner .. ")", "config"
        end
        local removed, remove_err = remove_tree(dir)
        if not removed then
            return nil, "cannot remove lock " .. dir .. ": " .. tostring(remove_err), "apply"
        end
        lock, err = acquire()
        if not lock then
            return nil, "cannot lock " .. dest .. ": " .. tostring(err), "apply"
        end
    end
    local wrote, write_err = write_owner(dir, pid)
    if not wrote then
        pcall(function() lock:free() end)
        return nil, "cannot lock " .. dest .. ": " .. tostring(write_err), "apply"
    end
    return { lock = lock, dir = dir }
end

local function release_lock(item)
    if item.lock then
        pcall(function() item.lock:free() end)
        item.lock = nil
    end
    os.remove(item.dir .. "/owner")
    os.remove(item.dir .. "/lockfile.lfs")
    os.remove(item.dir)
end

local function check_dest_components(dest)
    local acc = ""
    for part in dest:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        local attr, err = lfs.symlinkattributes(acc)
        if not attr then
            return apply_fail("cannot read " .. acc .. ": " .. tostring(err))
        end
        if attr.mode == "link" then
            return apply_fail("symlink in destination: " .. acc)
        end
    end
    return true
end

local function check_source_file(path, cache)
    local acc = ""
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    local n = #parts
    for i = 1, n do
        local part = parts[i]
        acc = acc .. "/" .. part
        if i < n and cache and cache[acc] then
            -- This worker already lstat'd this directory.
        else
            local attr, err = lfs.symlinkattributes(acc)
            if not attr then
                return apply_fail("cannot read " .. acc .. ": " .. tostring(err))
            end
            if attr.mode == "link" then
                return apply_fail("source is a symlink: " .. acc)
            end
            if i == n then
                if attr.mode ~= "file" then
                    return apply_fail("source is not a regular file: " .. acc)
                end
            elseif attr.mode ~= "directory" then
                return apply_fail("source is not a directory: " .. acc)
            elseif cache then
                cache[acc] = true
            end
        end
    end
    return true
end

local function partial_of(root, listing)
    if listing == "/" then
        return root
    end
    return root .. listing
end

local function close_files(files)
    for i = 1, #files do
        pcall(function() files[i]:close() end)
    end
end

local function open_input(open_source, path)
    local handle, err = open_source(path)
    if not handle then
        return apply_fail("cannot read " .. path .. ": " .. tostring(err))
    end
    return handle
end

local function copy_into(handle, size, writers, pulse, source)
    local function beat(nbytes)
        if not pulse then
            return true
        end
        return pulse(nbytes)
    end
    local beat_ok, beat_err, beat_class = beat(0)
    if not beat_ok then
        return nil, beat_err, beat_class
    end
    local remaining = size
    while remaining > 0 do
        local want = remaining
        if want > COPY_CHUNK then
            want = COPY_CHUNK
        end
        local buf, read_err = handle:read(want)
        if buf == nil and read_err ~= nil then
            local msg = "cannot read source"
            if source then
                msg = msg .. ": " .. source
            end
            return apply_fail(msg .. ": " .. tostring(read_err))
        end
        if type(buf) ~= "string" or #buf ~= want then
            local msg = "source is shorter than the listing"
            if source then
                msg = msg .. ": " .. source
            end
            return apply_fail(msg)
        end
        for i = 1, #writers do
            local wrote, write_err = writers[i].handle:write(buf)
            if not wrote then
                return apply_fail("cannot write " .. writers[i].path .. ": " .. tostring(write_err))
            end
        end
        remaining = remaining - want
        beat_ok, beat_err, beat_class = beat(#buf)
        if not beat_ok then
            return nil, beat_err, beat_class
        end
    end
    local extra, extra_err = handle:read(1)
    if extra == nil and extra_err ~= nil then
        local msg = "cannot read source"
        if source then
            msg = msg .. ": " .. source
        end
        return apply_fail(msg .. ": " .. tostring(extra_err))
    end
    if extra ~= nil then
        local msg = "source is longer than the listing"
        if source then
            msg = msg .. ": " .. source
        end
        return apply_fail(msg)
    end
    return true
end

local function finish_outputs(writers, mtime)
    for i = 1, #writers do
        local handle = writers[i].handle
        local flushed, flush_err = handle:flush()
        if not flushed then
            return apply_fail("cannot write " .. writers[i].path .. ": " .. tostring(flush_err))
        end
        local closed, close_err = handle:close()
        writers[i].handle = nil
        if not closed then
            return apply_fail("cannot write " .. writers[i].path .. ": " .. tostring(close_err))
        end
        local touched, touch_err = lfs.touch(writers[i].path, mtime, mtime)
        if not touched then
            return apply_fail("cannot set mtime " .. writers[i].path .. ": " .. tostring(touch_err))
        end
    end
    return true
end

-- A headless copy uses OS processes. Lua coroutines share one thread, and a
-- blocking read does not yield, so another file cannot be in flight on the
-- same interpreter. Each worker reads one source and writes every destination
-- that needs a new inode. The parent creates directories, hardlinks, and the
-- metadata batches. workers 1, a terminal screen, or an open_source / open_dest
-- seam stays in the parent.

local MAX_JOB_BYTES = 8 * 1024 * 1024

local function sh_quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function this_script()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) ~= "@" then
        return nil
    end
    return src:sub(2)
end

local function lua_bin()
    if type(arg) == "table" and type(arg[-1]) == "string" and arg[-1] ~= "" then
        return arg[-1]
    end
    return "lua"
end

local function num_token(value)
    local whole = math.tointeger(value)
    if whole ~= nil then
        return tostring(whole)
    end
    return string.format("%.0f", tonumber(value) or 0)
end

local function encode_job(job)
    local parts = {
        job.source, "\0",
        num_token(job.size), "\0",
        num_token(job.mtime), "\0",
    }
    local writers = job.writers
    for i = 1, #writers do
        parts[#parts + 1] = writers[i].path
        parts[#parts + 1] = "\0"
    end
    return table.concat(parts)
end

local function write_frame(handle, payload)
    if #payload > MAX_JOB_BYTES then
        return nil, "copy job is too large"
    end
    local wrote, err = handle:write(string.pack(">I4", #payload))
    if not wrote then
        return nil, err
    end
    wrote, err = handle:write(payload)
    if not wrote then
        return nil, err
    end
    return handle:flush()
end

local function read_exact(handle, n)
    if n == 0 then
        return ""
    end
    local parts, got = {}, 0
    while got < n do
        local chunk, err = handle:read(n - got)
        if type(chunk) ~= "string" or #chunk == 0 then
            if got == 0 and chunk == nil and err == nil then
                return nil, "eof"
            end
            return nil, err or "eof"
        end
        parts[#parts + 1] = chunk
        got = got + #chunk
    end
    return table.concat(parts)
end

local function read_frame(handle)
    local header, err = read_exact(handle, 4)
    if not header then
        return nil, err
    end
    local n = string.unpack(">I4", header)
    if n > MAX_JOB_BYTES then
        return nil, "copy job is too large"
    end
    return read_exact(handle, n)
end

local function split_nul(payload)
    local fields = {}
    local i = 1
    while i <= #payload do
        local j = payload:find("\0", i, true)
        if not j then
            fields[#fields + 1] = payload:sub(i)
            break
        end
        fields[#fields + 1] = payload:sub(i, j - 1)
        i = j + 1
    end
    return fields
end

local function close_writers(writers)
    local handles = {}
    for i = 1, #writers do
        if writers[i].handle then
            handles[#handles + 1] = writers[i].handle
            writers[i].handle = nil
        end
    end
    close_files(handles)
end

local function perform_copy_job(payload, cache)
    local fields = split_nul(payload)
    if #fields < 4 then
        return nil, "bad copy job"
    end
    local source = fields[1]
    local size = math.tointeger(tonumber(fields[2]))
    local mtime = tonumber(fields[3])
    if source == "" or size == nil or size < 0 or mtime == nil then
        return nil, "bad copy job"
    end
    local dests = {}
    for i = 4, #fields do
        if fields[i] == "" then
            return nil, "bad copy job"
        end
        dests[#dests + 1] = fields[i]
    end
    local ready, err, class = check_source_file(source, cache)
    if not ready then
        return nil, err, is_source_error(err) and "source" or class
    end
    local input, open_err = io.open(source, "rb")
    if not input then
        return nil, "cannot read " .. source .. ": " .. tostring(open_err), "source"
    end
    local writers = {}
    for i = 1, #dests do
        local handle, dest_err = io.open(dests[i], "wb")
        if not handle then
            input:close()
            close_writers(writers)
            return nil, "cannot write " .. dests[i] .. ": " .. tostring(dest_err)
        end
        writers[i] = { handle = handle, path = dests[i] }
    end
    local copied, copy_err, copy_class = copy_into(input, size, writers, nil, source)
    input:close()
    if not copied then
        close_writers(writers)
        return nil, copy_err, is_source_error(copy_err) and "source" or copy_class
    end
    local finished, fin_err, fin_class = finish_outputs(writers, mtime)
    if not finished then
        close_writers(writers)
        return nil, fin_err, fin_class
    end
    return true
end

function M.copy_worker()
    io.stdin:setvbuf("full")
    io.stdout:setvbuf("line")
    io.stdout:write("ready " .. process_id() .. "\n")
    io.stdout:flush()
    local cache = {}
    while true do
        local payload, err = read_frame(io.stdin)
        if not payload then
            if err == "eof" then
                return true
            end
            io.stdout:write("fail " .. one_line(err) .. "\n")
            io.stdout:flush()
            return nil, err
        end
        local ok, reason, class = perform_copy_job(payload, cache)
        if not ok then
            if class == "source" then
                io.stdout:write("skip " .. one_line(reason) .. "\n")
                io.stdout:flush()
                goto continue
            else
                io.stdout:write("fail " .. one_line(reason) .. "\n")
                io.stdout:flush()
                return nil, reason
            end
        end
        io.stdout:write("ok\n")
        io.stdout:flush()
        ::continue::
    end
end

local WORKER_CLOSER = [[
shopt -s nullglob
fds=()
for fd in /proc/self/fd/*; do
  n=${fd##*/}
  case $n in
    ''|*[!0-9]*) ;;
    0|1|2) ;;
    *) fds+=("$n") ;;
  esac
done
for n in "${fds[@]}"; do
  eval "exec ${n}>&-"
done
exec "$1" "$2" --copy-worker
]]

local function file_tail(path)
    local handle = io.open(path, "r")
    if not handle then
        return ""
    end
    local text = handle:read("a") or ""
    handle:close()
    text = text:gsub("%s+$", "")
    if #text > 400 then
        text = text:sub(-400)
    end
    if text == "" then
        return ""
    end
    return ": " .. one_line(text)
end

local function signal_pid(pid, sig)
    pid = tonumber(pid)
    if not pid or pid < 2 then
        return
    end
    os.execute("kill -" .. sig .. " " .. tostring(pid) .. " >/dev/null 2>&1")
end

local function configured_workers(config)
    local n = config and config.workers
    if type(n) ~= "number" then
        return DEFAULT_WORKERS
    end
    n = math.tointeger(n)
    if n == nil or n < 1 then
        return 1
    end
    if n > MAX_WORKERS then
        return MAX_WORKERS
    end
    return n
end

local function pool_wanted(config, fs, screen)
    if screen ~= nil then
        return false
    end
    if fs.open_source ~= nil or fs.open_dest ~= nil then
        return false
    end
    return configured_workers(config) > 1
end

local function copy_with_workers(jobs, workers, on_copied, on_skipped)
    local system = require("system")
    local script = this_script()
    if not script then
        return nil, "cannot find casually_backup.lua", "apply"
    end
    local count = workers
    if count > #jobs then
        count = #jobs
    end
    if count < 1 then
        return true
    end
    local dir = os.tmpname()
    os.remove(dir)
    local made, mkdir_err = lfs.mkdir(dir)
    if not made then
        return nil, "cannot create " .. dir .. ": " .. tostring(mkdir_err), "apply"
    end
    local pool = {}
    local function shutdown(graceful)
        for i = 1, #pool do
            local worker = pool[i]
            if worker.input then
                pcall(function() worker.input:close() end)
                worker.input = nil
            end
            if worker.keeper then
                pcall(function() worker.keeper:close() end)
                worker.keeper = nil
            end
        end
        local function each_pid(fn)
            local seen = {}
            for i = 1, #pool do
                local worker = pool[i]
                for _, pid in ipairs({ worker.pid, worker.shell_pid }) do
                    pid = tonumber(pid)
                    if pid and pid > 1 and not seen[pid] then
                        seen[pid] = true
                        fn(pid)
                    end
                end
            end
        end
        local function any_alive()
            local found = false
            each_pid(function(pid)
                if pid_alive(pid) then
                    found = true
                end
            end)
            return found
        end
        local deadline = system.monotime() + (graceful and 2 or 0.2)
        while any_alive() and system.monotime() < deadline do
            system.sleep(0.01)
        end
        each_pid(function(pid)
            if pid_alive(pid) then
                signal_pid(pid, "TERM")
            end
        end)
        deadline = system.monotime() + 1
        while any_alive() and system.monotime() < deadline do
            system.sleep(0.01)
        end
        each_pid(function(pid)
            if pid_alive(pid) then
                signal_pid(pid, "KILL")
            end
        end)
        deadline = system.monotime() + 0.5
        while any_alive() and system.monotime() < deadline do
            system.sleep(0.01)
        end
        for i = 1, #pool do
            if pool[i].reply then
                pcall(function() pool[i].reply:close() end)
                pool[i].reply = nil
            end
        end
        pcall(remove_tree, dir)
    end
    local function fail_pool(reason)
        shutdown(false)
        return nil, reason, "apply"
    end
    for i = 1, count do
        local job_path = dir .. "/job-" .. i
        local reply_path = dir .. "/reply-" .. i
        local err_path = dir .. "/err-" .. i
        local pid_path = dir .. "/pid-" .. i
        local fifo_ok = os.execute("mkfifo " .. sh_quote(job_path))
        if fifo_ok ~= true then
            return fail_pool("cannot create " .. job_path)
        end
        local blank = io.open(reply_path, "w")
        if not blank then
            return fail_pool("cannot create " .. reply_path)
        end
        blank:close()
        local keeper = io.open(job_path, "r+")
        local input = io.open(job_path, "a")
        local reply = io.open(reply_path, "r")
        if not keeper or not input or not reply then
            if keeper then keeper:close() end
            if input then input:close() end
            if reply then reply:close() end
            return fail_pool("cannot open worker pipes")
        end
        input:setvbuf("full")
        local cmd = string.format(
            "bash -c %s _ %s %s <%s >>%s 2>%s & echo $! > %s",
            sh_quote(WORKER_CLOSER),
            sh_quote(lua_bin()),
            sh_quote(script),
            sh_quote(job_path),
            sh_quote(reply_path),
            sh_quote(err_path),
            sh_quote(pid_path)
        )
        local spawned = os.execute(cmd)
        if spawned ~= true then
            keeper:close()
            input:close()
            reply:close()
            return fail_pool("cannot start copy worker")
        end
        local pid_file = io.open(pid_path, "r")
        local shell_pid = pid_file and pid_file:read("*n")
        if pid_file then
            pid_file:close()
        end
        pool[i] = {
            keeper = keeper,
            input = input,
            reply = reply,
            err_path = err_path,
            shell_pid = shell_pid,
            pending = "",
            got = 0,
            busy = false,
        }
    end
    local function drain(worker)
        worker.reply:seek("set", worker.got)
        local more = worker.reply:read("a")
        if type(more) == "string" and #more > 0 then
            worker.got = worker.got + #more
            worker.pending = worker.pending .. more
        end
    end
    local function take_line(worker)
        drain(worker)
        local nl = worker.pending:find("\n", 1, true)
        if not nl then
            return nil
        end
        local line = worker.pending:sub(1, nl - 1)
        worker.pending = worker.pending:sub(nl + 1)
        return line
    end
    local ready_deadline = system.monotime() + 10
    for i = 1, #pool do
        local worker = pool[i]
        local line
        while not line do
            line = take_line(worker)
            if line then
                break
            end
            if system.monotime() > ready_deadline then
                return fail_pool("copy worker did not start" .. file_tail(worker.err_path))
            end
            local watch = worker.pid or worker.shell_pid
            if watch and not pid_alive(watch) then
                return fail_pool("copy worker exited" .. file_tail(worker.err_path))
            end
            system.sleep(0.01)
        end
        local pid = line:match("^ready (%d+)$")
        if not pid then
            return fail_pool("copy worker: " .. one_line(line) .. file_tail(worker.err_path))
        end
        worker.pid = tonumber(pid)
        if worker.keeper then
            worker.keeper:close()
            worker.keeper = nil
        end
    end
    local next_job = 1
    local function fill()
        for i = 1, #pool do
            local worker = pool[i]
            if not worker.busy and next_job <= #jobs then
                local job = jobs[next_job]
                local wrote, err = write_frame(worker.input, encode_job(job))
                if not wrote then
                    return nil, "cannot write copy job: " .. tostring(err)
                end
                worker.busy = true
                worker.current = job
                next_job = next_job + 1
            end
        end
        return true
    end
    local function busy()
        for i = 1, #pool do
            if pool[i].busy then
                return true
            end
        end
        return false
    end
    while next_job <= #jobs or busy() do
        local wrote, err = fill()
        if not wrote then
            return fail_pool(err)
        end
        local progressed = false
        for i = 1, #pool do
            local worker = pool[i]
            if worker.busy then
                local line = take_line(worker)
                if not line and worker.pid and not pid_alive(worker.pid) then
                    line = take_line(worker)
                    if not line then
                        return fail_pool("copy worker exited" .. file_tail(worker.err_path))
                    end
                end
                if line then
                    progressed = true
                    worker.busy = false
                    local job = worker.current
                    worker.current = nil
                     if line == "ok" then
                        on_copied(job)
                    elseif line:sub(1, 5) == "fail " then
                        return fail_pool(line:sub(6))
                    elseif line:sub(1, 5) == "skip " then
                        if on_skipped then
                            on_skipped(job, line:sub(6))
                        end
                    else
                        return fail_pool("copy worker: " .. one_line(line))
                    end
                end
            end
        end
        if not progressed then
            system.sleep(0.001)
        end
    end
    shutdown(true)
    return true
end

function M.apply(config, fs, plan, screen)
    fs = fs or {}
    local err, class
    if plan == nil then
        plan, err, class = M.plan(config, fs, screen)
        if not plan then
            return nil, err, class
        end
    end
    local open_source = fs.open_source or function(path)
        return io.open(path, "rb")
    end
    local open_dest = fs.open_dest or function(path, _dest)
        return io.open(path, "wb")
    end
    local chmod_batch = fs.chmod or function(mode, payload)
        return M.metadata_batch("chmod", mode, payload)
    end
    local chown_batch = fs.chown or function(uid, gid, payload)
        return M.metadata_batch("chown", { uid = uid, gid = gid }, payload)
    end
    local pid = fs.pid or process_id()
    local locks = {}
    local function release_all()
        for i = #locks, 1, -1 do
            release_lock(locks[i])
            locks[i] = nil
        end
    end
    local function fail(reason, fail_class)
        release_all()
        return nil, reason, fail_class or "apply"
    end
    local warnings = {}
    local function warn(reason)
        warnings[#warnings + 1] = reason
    end
    local stats = {
        copy_bytes = 0,
    }
    local function add_bytes(n)
        stats.copy_bytes = stats.copy_bytes + n
    end

    if screen then
        local sok, serr, sclass = screen:pulse()
        if not sok then
            return fail(serr, sclass)
        end
    end

    for i = 1, #plan.destinations do
        local dest = plan.destinations[i].destination
        local item, lock_err, lock_class = take_lock(dest, pid)
        if not item then
            return fail(lock_err, lock_class)
        end
        locks[#locks + 1] = item
    end

    for i = 1, #plan.destinations do
        local dest = plan.destinations[i].destination
        if not probe_writable(dest) then
            return fail("destination is not writable: " .. dest, "plan")
        end
        local ok
        ok, err, class = check_dest_components(dest)
        if not ok then
            return fail(err, class)
        end
    end

    for i = 1, #plan.destinations do
        local dest = plan.destinations[i].destination
        local names, list_err = list_names(lfs_dir, dest)
        if not names then
            return fail("cannot read " .. dest .. ": " .. tostring(list_err))
        end
        for n = 1, #names do
            local name = names[n]
            if name:sub(-8) == ".partial" then
                local path = dest .. "/" .. name
                local attr = lfs.symlinkattributes(path)
                if attr and attr.mode == "directory" then
                    local removed, remove_err = remove_tree(path)
                    if not removed then
                        return fail("cannot remove partial " .. path .. ": " .. tostring(remove_err))
                    end
                end
            end
        end
    end

    local roots = {}
    for i = 1, #plan.destinations do
        local built = plan.destinations[i]
        local root = built.destination .. "/" .. built.snapshot .. "." .. pid .. ".partial"
        local made, mkdir_err = lfs.mkdir(root)
        if not made then
            return fail("cannot create " .. root .. ": " .. tostring(mkdir_err))
        end
        roots[i] = root
        local index = {}
        local ancestors = {}
        local mkdirs = built.actions.mkdir
        for n = 1, #mkdirs do
            local action = mkdirs[n]
            if action.ancestor then
                ancestors[#ancestors + 1] = action
            else
                index[action.listing] = { kind = "mkdir", action = action }
            end
        end
        for _, kind in ipairs({ "copy", "hardlink", "symlink" }) do
            local list = built.actions[kind]
            for n = 1, #list do
                index[list[n].listing] = { kind = kind, action = list[n] }
            end
        end
        built.index = index
        built.ancestors = ancestors
        built.root = root
    end

    local chmod_paths = {}
    local chown_paths = {}
    local dir_touches = {}

    local function queue_new(action, path, with_mode)
        if with_mode then
            queue_path(chmod_paths, action.mode, path)
        end
        if plan.apply_owner then
            queue_path(chown_paths, string.format("%d:%d", action.uid, action.gid), path)
        end
    end

    local ancestor_listings = {}
    if plan.destinations[1] then
        local seen = {}
        for i = 1, #plan.destinations do
            local ancestors = plan.destinations[i].ancestors
            for n = 1, #ancestors do
                local listing = ancestors[n].listing
                if not seen[listing] then
                    seen[listing] = true
                    ancestor_listings[#ancestor_listings + 1] = listing
                end
            end
        end
        table.sort(ancestor_listings)
    end
    for a = 1, #ancestor_listings do
        local listing = ancestor_listings[a]
        for i = 1, #plan.destinations do
            local path = partial_of(roots[i], listing)
            local made, mkdir_err = lfs.mkdir(path)
            if not made then
                return fail("cannot create " .. path .. ": " .. tostring(mkdir_err))
            end
        end
    end

    local function hardlink_one(action, root)
        local new_path = partial_of(root, action.listing)
        local linked, link_err = lfs.link(action.previous, new_path)
        if not linked then
            return apply_fail("cannot link " .. new_path .. ": " .. tostring(link_err))
        end
        return true
    end

    local function apply_pooled()
        local jobs = {}
        local file_links = {}
        local link_records = {}
        for r = 1, #plan.records do
            local rec = plan.records[r]
            if rec.kind == "dir" then
                for i = 1, #plan.destinations do
                    local built = plan.destinations[i]
                    local found = built.index[rec.path]
                    if not found or found.kind ~= "mkdir" then
                        return nil, "missing directory action " .. rec.path, "apply"
                    end
                    local path = partial_of(roots[i], rec.path)
                    local made, mkdir_err = lfs.mkdir(path)
                    if not made then
                        return nil, "cannot create " .. path .. ": " .. tostring(mkdir_err), "apply"
                    end
                    queue_new(found.action, path, true)
                    dir_touches[#dir_touches + 1] = { path = path, mtime = found.action.mtime }
                end
            elseif rec.kind == "file" then
                local writers = {}
                local links = {}
                local source_path
                for i = 1, #plan.destinations do
                    local built = plan.destinations[i]
                    local found = built.index[rec.path]
                    if not found then
                        return nil, "missing file action " .. rec.path, "apply"
                    end
                    if found.kind == "copy" then
                        source_path = found.action.source
                        writers[#writers + 1] = {
                            path = partial_of(roots[i], rec.path),
                            action = found.action,
                        }
                    elseif found.kind == "hardlink" then
                        links[#links + 1] = {
                            root = roots[i],
                            action = found.action,
                        }
                    else
                        return nil, "missing file action " .. rec.path, "apply"
                    end
                end
                if #writers > 0 then
                    jobs[#jobs + 1] = {
                        source = source_path,
                        size = rec.size,
                        mtime = rec.mtime,
                        writers = writers,
                    }
                end
                for i = 1, #links do
                    file_links[#file_links + 1] = links[i]
                end
            else
                link_records[#link_records + 1] = rec
            end
        end
        if #jobs > 0 then
            local copied, err, class = copy_with_workers(
                jobs, configured_workers(config), function(job)
                    for w = 1, #job.writers do
                        queue_new(job.writers[w].action, job.writers[w].path, true)
                    end
                end, function(job, reason)
                    for w = 1, #job.writers do
                        local dest = job.writers[w].path
                        pcall(function() os.remove(dest) end)
                    end
                    warn(reason .. " (skipped)")
                end)
            if not copied then
                return nil, err, class
            end
        end
        for i = 1, #file_links do
            local linked, err, class = hardlink_one(file_links[i].action, file_links[i].root)
            if not linked then
                return nil, err, class
            end
        end
        for r = 1, #link_records do
            local rec = link_records[r]
            local links = {}
            for i = 1, #plan.destinations do
                local built = plan.destinations[i]
                local found = built.index[rec.path]
                if not found then
                    return nil, "missing symlink action " .. rec.path, "apply"
                end
                local path = partial_of(roots[i], rec.path)
                if found.kind == "symlink" then
                    local linked, link_err = lfs.link(found.action.target, path, true)
                    if not linked then
                        return nil, "cannot link " .. path .. ": " .. tostring(link_err), "apply"
                    end
                    queue_new(found.action, path, false)
                elseif found.kind == "hardlink" then
                    links[#links + 1] = {
                        root = roots[i],
                        action = found.action,
                    }
                else
                    return nil, "missing symlink action " .. rec.path, "apply"
                end
            end
            for i = 1, #links do
                local linked, err, class = hardlink_one(links[i].action, links[i].root)
                if not linked then
                    return nil, err, class
                end
            end
        end
        return true
    end

    local function apply_serial()
    for r = 1, #plan.records do
        local rec = plan.records[r]
        local show_i = 0
        local show_n = #plan.destinations
        local function close_record()
            show_i = show_i + 1
            return show_i == show_n
        end
        local function begin_show(dest, snapshot, published)
            if not screen then
                return true
            end
            return screen:begin_line(dest, snapshot, published)
        end
        local function finish_show(marker, size)
            if not screen then
                return true
            end
            return screen:finish_line(marker, size, close_record())
        end
        if rec.kind == "dir" then
            for i = 1, #plan.destinations do
                local built = plan.destinations[i]
                local found = built.index[rec.path]
                if not found or found.kind ~= "mkdir" then
                    return fail("missing directory action " .. rec.path)
                end
                local path = partial_of(roots[i], rec.path)
                local sok, serr, sclass = begin_show(built.destination, built.snapshot, found.action.path)
                if not sok then
                    return fail(serr, sclass)
                end
                local made, mkdir_err = lfs.mkdir(path)
                if not made then
                    return fail("cannot create " .. path .. ": " .. tostring(mkdir_err))
                end
                queue_new(found.action, path, true)
                dir_touches[#dir_touches + 1] = { path = path, mtime = found.action.mtime }
                sok, serr, sclass = finish_show("D", rec.size)
                if not sok then
                    return fail(serr, sclass)
                end
            end
        elseif rec.kind == "file" then
            local writers = {}
            local links = {}
            local source_path
            for i = 1, #plan.destinations do
                local built = plan.destinations[i]
                local found = built.index[rec.path]
                if not found then
                    return fail("missing file action " .. rec.path)
                end
                if found.kind == "copy" then
                    source_path = found.action.source
                    writers[#writers + 1] = {
                        dest = built.destination,
                        snapshot = built.snapshot,
                        path = partial_of(roots[i], rec.path),
                        published = found.action.path,
                        action = found.action,
                    }
                elseif found.kind == "hardlink" then
                    links[#links + 1] = {
                        root = roots[i],
                        destination = built.destination,
                        snapshot = built.snapshot,
                        published = found.action.path,
                        action = found.action,
                    }
                else
                    return fail("missing file action " .. rec.path)
                end
            end
            if #writers > 0 then
                local sok, serr, sclass = begin_show(
                    writers[1].dest, writers[1].snapshot, writers[1].published)
                if not sok then
                    return fail(serr, sclass)
                end
                local ready
                ready, err, class = check_source_file(source_path)
                if not ready then
                    if is_source_error(err) then
                        warn(err .. " (skipped)")
                        if screen then show_i = show_n - 1; finish_show("S", rec.size) end
                        goto next_record
                    end
                    return fail(err, class)
                end
                local input
                input, err = open_input(open_source, source_path)
                if not input then
                    if is_source_error(err) then
                        warn(err .. " (skipped)")
                        if screen then show_i = show_n - 1; finish_show("S", rec.size) end
                        goto next_record
                    end
                    return fail(err, class)
                end
                for w = 1, #writers do
                    local handle, dest_err = open_dest(writers[w].path, writers[w].dest)
                    if not handle then
                        input:close()
                        close_files((function()
                            local open_handles = {}
                            for k = 1, w - 1 do
                                open_handles[k] = writers[k].handle
                            end
                            return open_handles
                        end)())
                        return fail("cannot write " .. writers[w].path .. ": " .. tostring(dest_err))
                    end
                    writers[w].handle = handle
                end
                local copied
                copied, err, class = copy_into(input, rec.size, writers, function(nbytes)
                    if not screen then
                        return true
                    end
                    return screen:pulse(nbytes)
                end, source_path)
                input:close()
                if not copied then
                    close_files((function()
                        local open_handles = {}
                        for w = 1, #writers do
                            if writers[w].handle then
                                open_handles[#open_handles + 1] = writers[w].handle
                            end
                        end
                        return open_handles
                    end)())
                    if is_source_error(err) then
                        for w = 1, #writers do
                            pcall(function() os.remove(writers[w].path) end)
                        end
                        warn(err .. " (skipped)")
                        if screen then show_i = show_n - 1; finish_show("S", rec.size) end
                        goto next_record
                    end
                    return fail(err, class)
                end
                local finished
                finished, err, class = finish_outputs(writers, rec.mtime)
                if not finished then
                    return fail(err, class)
                end
                for w = 1, #writers do
                    queue_new(writers[w].action, writers[w].path, true)
                end
                sok, serr, sclass = finish_show("C", rec.size)
                if not sok then
                    return fail(serr, sclass)
                end
                for w = 2, #writers do
                    sok, serr, sclass = begin_show(
                        writers[w].dest, writers[w].snapshot, writers[w].published)
                    if not sok then
                        return fail(serr, sclass)
                    end
                    sok, serr, sclass = finish_show("C", rec.size)
                    if not sok then
                        return fail(serr, sclass)
                    end
                end
            end
            for i = 1, #links do
                local sok, serr, sclass = begin_show(
                    links[i].destination, links[i].snapshot, links[i].published)
                if not sok then
                    return fail(serr, sclass)
                end
                local linked
                linked, err, class = hardlink_one(links[i].action, links[i].root)
                if not linked then
                    return fail(err, class)
                end
                sok, serr, sclass = finish_show("S", rec.size)
                if not sok then
                    return fail(serr, sclass)
                end
            end
        else
            local links = {}
            for i = 1, #plan.destinations do
                local built = plan.destinations[i]
                local found = built.index[rec.path]
                if not found then
                    return fail("missing symlink action " .. rec.path)
                end
                local path = partial_of(roots[i], rec.path)
                if found.kind == "symlink" then
                    local sok, serr, sclass = begin_show(
                        built.destination, built.snapshot, found.action.path)
                    if not sok then
                        return fail(serr, sclass)
                    end
                    local linked, link_err = lfs.link(found.action.target, path, true)
                    if not linked then
                        return fail("cannot link " .. path .. ": " .. tostring(link_err))
                    end
                    queue_new(found.action, path, false)
                    sok, serr, sclass = finish_show("L", rec.size)
                    if not sok then
                        return fail(serr, sclass)
                    end
                elseif found.kind == "hardlink" then
                    links[#links + 1] = {
                        root = roots[i],
                        destination = built.destination,
                        snapshot = built.snapshot,
                        published = found.action.path,
                        action = found.action,
                    }
                else
                    return fail("missing symlink action " .. rec.path)
                end
            end
            for i = 1, #links do
                local sok, serr, sclass = begin_show(
                    links[i].destination, links[i].snapshot, links[i].published)
                if not sok then
                    return fail(serr, sclass)
                end
                local linked
                linked, err, class = hardlink_one(links[i].action, links[i].root)
                if not linked then
                    return fail(err, class)
                end
                sok, serr, sclass = finish_show("S", rec.size)
                if not sok then
                    return fail(serr, sclass)
                end
            end
        end
        ::next_record::
    end
    return true
    end

    local ran, run_err, run_class
    if pool_wanted(config, fs, screen) then
        ran, run_err, run_class = apply_pooled()
    else
        ran, run_err, run_class = apply_serial()
    end
    if not ran then
        return fail(run_err, run_class)
    end

    for _, mode in ipairs(sorted_keys(chmod_paths)) do
        local payload = nul_join(chmod_paths[mode])
        local ran, batch_err = chmod_batch(mode, payload)
        if not ran then
            return fail("cannot chmod: " .. tostring(batch_err))
        end
    end
    if plan.apply_owner then
        for _, spec in ipairs(sorted_keys(chown_paths)) do
            local uid, gid = spec:match("^(%d+):(%d+)$")
            local payload = nul_join(chown_paths[spec])
            local ran, batch_err = chown_batch(tonumber(uid), tonumber(gid), payload)
            if not ran then
                return fail("cannot chown: " .. tostring(batch_err))
            end
        end
    end
    for i = 1, #dir_touches do
        local item = dir_touches[i]
        local touched, touch_err = lfs.touch(item.path, item.mtime, item.mtime)
        if not touched then
            return fail("cannot set mtime " .. item.path .. ": " .. tostring(touch_err))
        end
    end

    if screen then
        local sok, serr, sclass = screen:pulse()
        if not sok then
            return fail(serr, sclass)
        end
    end

    for i = 1, #plan.destinations do
        local built = plan.destinations[i]
        local final = built.destination .. "/" .. built.snapshot
        local renamed, rename_err = os.rename(roots[i], final)
        if not renamed then
            return fail("cannot publish " .. final .. ": " .. tostring(rename_err))
        end
    end

    release_all()
    return true, nil, nil, warnings
end

local function exit_code(class)
    if class == "scan" or class == "apply" then
        return 2
    end
    return 1
end

local function stdout_is_tty()
    local ok, yes = pcall(system.isatty, io.stdout)
    return ok and yes == true
end

local function extract_branch(path)
    local segments = {}
    for seg in path:gmatch("[^/]+") do
        segments[#segments + 1] = seg
        if #segments >= 6 then break end
    end
    if #segments == 0 then return "(root)" end
    return table.concat(segments, "/")
end

local function warning_type(warning)
    local msg = warning:match("^%S+:%s*(.*)$") or warning
    local patterns = {
        { "cannot read source", "skipped source" },
        { "cannot read", "read error" },
        { "source is shorter", "size mismatch" },
        { "source is longer", "size mismatch" },
        { "source is not a regular file", "source not regular file" },
        { "source is a symlink", "source is a symlink" },
        { "left ", "left behind" },
    }
    for _, p in ipairs(patterns) do
        if msg:find(p[1], 1, true) then
            return p[2]
        end
    end
    return msg:match("^([^:]+)") or "unknown"
end

local function report_stats(plan, elapsed, apply_warnings, log_path)
    local records = plan.records or {}
    local total_files = 0
    local total_bytes = 0
    local rec
    for i = 1, #records do
        rec = records[i]
        if rec.kind == "file" then
            total_files = total_files + 1
            total_bytes = total_bytes + (rec.size or 0)
        end
    end
    local added_files = 0
    local added_bytes = 0
    local dest_count = #plan.destinations
    for i = 1, dest_count do
        local copies = plan.destinations[i].actions.copy
        for n = 1, #copies do
            added_files = added_files + 1
            added_bytes = added_bytes + (copies[n].size or 0)
        end
    end
    if apply_warnings == nil then
        apply_warnings = {}
    end
    local warn_count = #plan.warnings + #apply_warnings
    local unique_bytes = added_bytes
    if dest_count > 1 then
        unique_bytes = math.floor(added_bytes / dest_count)
    end
    local lines = {}
    lines[#lines + 1] = "=== casually_backup report ==="
    lines[#lines + 1] = string.format("stamp:            %s", plan.stamp or "(unknown)")
    lines[#lines + 1] = string.format("elapsed:          %s", M.format_elapsed(elapsed))
    lines[#lines + 1] = string.format("files added:      %d", added_files)
    lines[#lines + 1] = string.format("bytes added:      %s", M.format_bytes(unique_bytes))
    lines[#lines + 1] = string.format("files tracked:    %d", total_files)
    lines[#lines + 1] = string.format("bytes tracked:    %s", M.format_bytes(total_bytes))
    lines[#lines + 1] = string.format("destinations:     %d", dest_count)
    lines[#lines + 1] = string.format("warnings:         %d", warn_count)
    if log_path then
        lines[#lines + 1] = string.format("details log:    %s", log_path)
    end
    if warn_count > 0 then
        local by_type = {}
        local function add_count(t, branch)
            if not by_type[t] then by_type[t] = {} end
            if not by_type[t][branch] then by_type[t][branch] = 0 end
            by_type[t][branch] = by_type[t][branch] + 1
        end
        for i = 1, #plan.warnings do
            local w = plan.warnings[i]
            add_count(warning_type(w), extract_branch(w))
        end
        for i = 1, #apply_warnings do
            local w = apply_warnings[i]
            add_count(warning_type(w), extract_branch(w))
        end
        lines[#lines + 1] = string.format("%d warnings in %d groups:", warn_count, (function() local c=0 for _ in pairs(by_type) do c=c+1 end return c end)())
        local sorted_types = {}
        for t in pairs(by_type) do sorted_types[#sorted_types + 1] = t end
        table.sort(sorted_types)
        for _, t in ipairs(sorted_types) do
            local type_total = 0
            for b, count in pairs(by_type[t]) do
                type_total = type_total + count
            end
            lines[#lines + 1] = string.format("  %s: %d instances", t, type_total)
            local sorted_branches = {}
            for b, count in pairs(by_type[t]) do sorted_branches[#sorted_branches + 1] = { branch = b, count = count } end
            table.sort(sorted_branches, function(a, b) return a.count > b.count or (a.count == b.count and a.branch < b.branch) end)
            local branches_shown = 0
            for _, entry in ipairs(sorted_branches) do
                if branches_shown >= 4 then break end
                lines[#lines + 1] = string.format("    - %s: %d instances", entry.branch, entry.count)
                branches_shown = branches_shown + 1
            end
        end
    end
    lines[#lines + 1] = "=== end report ==="
    return table.concat(lines, "\n") .. "\n"
end

function M.perform(config, opts, fs, out, err_out, screen)
    out = out or io.stdout
    err_out = err_out or io.stderr
    opts = opts or {}
    if opts.dry_run then
        screen = nil
    end
    local start_time = system.monotime()
    local plan, err, class = M.plan(config, fs, screen)
    if not plan then
        if screen then
            screen.failure = err
            screen.class = class
            return exit_code(class)
        end
        err_out:write("casually_backup: " .. one_line(err) .. "\n")
        return exit_code(class)
    end
    if opts.dry_run then
        for i = 1, #plan.warnings do
            err_out:write(plan.warnings[i] .. "\n")
        end
        out:write(plan.text)
        return 0
    end
    local ok
    ok, err, class, apply_warnings = M.apply(config, fs, plan, screen)
    if not ok then
        if screen then
            screen.failure = err
            screen.class = class
            return exit_code(class)
        end
        err_out:write("casually_backup: " .. one_line(err) .. "\n")
        return exit_code(class)
    end
      if screen then
        screen.warnings = plan.warnings
        if apply_warnings then
            for i = 1, #apply_warnings do
                screen.warnings[#screen.warnings + 1] = apply_warnings[i]
            end
        end
        if config.report then
            local elapsed = system.monotime() - start_time
            local log_path = config.report_dir and (config.report_dir .. "/" .. (plan.stamp or "unknown") .. ".log")
            err_out:write(report_stats(plan, elapsed, apply_warnings, log_path))
        end
        return 0
    end
    if config.report then
        local elapsed = system.monotime() - start_time
        local log_path = config.report_dir and (config.report_dir .. "/" .. (plan.stamp or "unknown") .. ".log")
        err_out:write(report_stats(plan, elapsed, apply_warnings, log_path))
    end
    if config.report_dir then
        local stamp = plan.stamp or "unknown"
        local log_path = config.report_dir .. "/" .. stamp .. ".log"
        local lf = io.open(log_path, "w")
        if lf then
            if apply_warnings then
                for i = 1, #apply_warnings do
                    lf:write(apply_warnings[i] .. "\n")
                end
            end
            for i = 1, #plan.warnings do
                lf:write(plan.warnings[i] .. "\n")
            end
            lf:close()
        end
    else
        if apply_warnings then
            for i = 1, #apply_warnings do
                err_out:write(apply_warnings[i] .. "\n")
            end
        end
        for i = 1, #plan.warnings do
            err_out:write(plan.warnings[i] .. "\n")
        end
    end
    return 0
end

function M.main(argv)
    if argv[1] == "--copy-worker" then
        if #argv ~= 1 then
            io.stderr:write("casually_backup: --copy-worker does not take other arguments\n")
            return 1
        end
        local ok = M.copy_worker()
        if not ok then
            return 2
        end
        return 0
    end
    local cmd, err, class = M.parse_args(argv)
    if not cmd then
        io.stderr:write("casually_backup: " .. one_line(err) .. "\n")
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
        io.stderr:write("casually_backup: " .. one_line(err) .. "\n")
        return exit_code(class)
    end
    if cmd.dry_run or not stdout_is_tty() then
        return M.perform(cfg, { dry_run = cmd.dry_run == true })
    end
    local screen
    local code
    local function wrapped()
        screen = M.open_screen()
        code = M.perform(cfg, { dry_run = false }, nil, nil, nil, screen)
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
        io.stderr:write("casually_backup: " .. one_line(blown) .. "\n")
        return 1
    end
    if screen and screen.failure then
        io.stderr:write("casually_backup: " .. one_line(screen.failure) .. "\n")
        return code or exit_code(screen.class)
    end
    local warnings = (screen and screen.warnings) or {}
    for i = 1, #warnings do
        io.stderr:write(warnings[i] .. "\n")
    end
    return code or 0
end

local function invoked_as_script()
    if type(arg) ~= "table" or type(arg[0]) ~= "string" then
        return false
    end
    return arg[0]:match("casually_backup%.lua$") ~= nil
end

if invoked_as_script() then
    local code = M.main(arg)
    os.exit(code)
end

return M
