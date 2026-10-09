#!/usr/bin/env lua

-- casually_backup: one snapshot per backup folder from a finished listing.
-- The command line, the config checks, and the listing parser live here.
-- Later phases add the plan and the copy.

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
}

local MAP_KEYS = {
    alias = true,
    path = true,
}

local DEFAULT_OMIT_LIMIT = 1000
local DEFAULT_OMIT_FRACTION = 0.02

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

local function finish_config(index, dests, map, exclude, limit, fraction)
    return {
        index = index,
        destinations = dests,
        source_map = map,
        exclude = exclude,
        omit_limit = limit,
        omit_fraction = fraction,
    }
end

local function assemble(index, dests, map, exclude, cmd, obj)
    local limit, fraction, err, class = resolve_limits(cmd, obj)
    if class then
        return nil, err, class
    end
    return finish_config(index, dests, map, exclude, limit, fraction)
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
-- the guess until the UTC rendering matches.
local function utc_epoch(text)
    local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)(%d%d)(%d%d):(%d%d)(%d%d)(%d%d)$")
    if not y then
        return nil
    end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
    local guess = os.time({
        year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false,
    })
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
        local want = os.time({
            year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false,
        })
        local have = os.time({
            year = got.year, month = got.month, day = got.day,
            hour = got.hour, min = got.min, sec = got.sec, isdst = false,
        })
        if want == nil or have == nil then
            return nil
        end
        local delta = os.difftime(want, have)
        if delta == 0 then
            return nil
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

local function check_parents(records)
    local stack = {}
    for i = 1, #records do
        local rec = records[i]
        while #stack > 0 and not is_prefix(stack[#stack].path, rec.path) do
            stack[#stack] = nil
        end
        if #stack == 0 then
            if rec.kind ~= "dir" then
                return "line " .. i .. " root is not a directory"
            end
        else
            local parent = parent_of(rec.path)
            if stack[#stack].path ~= parent or stack[#stack].kind ~= "dir" then
                return "line " .. i .. " parent is missing"
            end
        end
        if rec.kind == "dir" then
            stack[#stack + 1] = rec
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

local function exit_code(class)
    if class == "scan" or class == "apply" then
        return 2
    end
    return 1
end

function M.main(argv)
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
    return 0
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
