-- Phase 2 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 2
-- A rejection exits 1, names the reason, and leaves the destination tree
-- unchanged. A valid config is loaded through load_config, not main.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase2.lua")
    if here == "test" then
        return "."
    end
    if here:match("/test$") then
        return here:gsub("/test$", "")
    end
    return "."
end

local root = repo_root()
local exe = root .. "/casually_backup.lua"

os.setlocale("C")

local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("FAIL " .. msg .. "\n")
end

local function expect(cond, msg)
    if not cond then
        fail(msg)
    end
end

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
    local ok, how, code = os.execute(cmd)
    if ok ~= true then
        error("command failed (" .. tostring(how) .. " " .. tostring(code) .. "): " .. cmd)
    end
end

local api = dofile(exe)
expect(type(api.load_config) == "function", "load_config is exported")

local base
local listing, partial_file, plain, fifo
local dest_a, dest_b, dest_ab, nested, inside, boundary
local mapdir, map_b, map_file, locked
local link_dest, link_list, link_map

local function cleanup()
    if base then
        os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
        os.execute("rm -rf " .. sh_quote(base))
    end
    os.execute("rm -f /.casually_backup.probe.* >/dev/null 2>&1")
end

local function jq(s)
    return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function arr(items)
    local parts = {}
    for i = 1, #items do
        parts[i] = jq(items[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function map_obj(alias, path, extra)
    local body = '"alias":' .. jq(alias) .. ',"path":' .. jq(path)
    if extra then
        body = body .. "," .. extra
    end
    return "{" .. body .. "}"
end

local function document(opts)
    local parts = {}
    if opts.index ~= nil then
        parts[#parts + 1] = '"index":' .. opts.index
    end
    if opts.destinations ~= nil then
        parts[#parts + 1] = '"destinations":' .. opts.destinations
    end
    if opts.source_map ~= nil then
        parts[#parts + 1] = '"source_map":' .. opts.source_map
    end
    if opts.exclude ~= nil then
        parts[#parts + 1] = '"exclude":' .. opts.exclude
    end
    if opts.omit_limit ~= nil then
        parts[#parts + 1] = '"omit_limit":' .. opts.omit_limit
    end
    if opts.omit_fraction ~= nil then
        parts[#parts + 1] = '"omit_fraction":' .. opts.omit_fraction
    end
    if opts.workers ~= nil then
        parts[#parts + 1] = '"workers":' .. opts.workers
    end
    if opts.extra then
        parts[#parts + 1] = opts.extra
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function slashy(path)
    return "//" .. path .. "///"
end

local seq = 0

local function write_cfg(text)
    seq = seq + 1
    local path = base .. "/cfg-" .. seq .. ".json"
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    return path
end

local function entries(dir)
    local names = {}
    for name in api.lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return table.concat(names, "\n")
end

local function read_all(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a") or ""
    f:close()
    return text
end

local function keys_of(t)
    local names = {}
    for key in pairs(t) do
        names[#names + 1] = key
    end
    table.sort(names)
    return table.concat(names, ",")
end

local stable = {}

local function snapshot()
    stable = {
        dest_a = entries(dest_a),
        nested = entries(nested),
        dest_b = entries(dest_b),
        dest_ab = entries(dest_ab),
        mapdir = entries(mapdir),
        map_b = entries(map_b),
        locked = entries(locked),
        listing = read_all(listing),
        inside = read_all(inside),
        partial = read_all(partial_file),
        boundary = read_all(boundary),
        plain = read_all(plain),
    }
end

local function expect_stable(label)
    expect(entries(dest_a) == stable.dest_a, label .. " changed dest-a: " .. entries(dest_a))
    expect(entries(nested) == stable.nested, label .. " changed nested: " .. entries(nested))
    expect(entries(dest_b) == stable.dest_b, label .. " changed dest-b: " .. entries(dest_b))
    expect(entries(dest_ab) == stable.dest_ab, label .. " changed dest-ab: " .. entries(dest_ab))
    expect(entries(mapdir) == stable.mapdir, label .. " changed map: " .. entries(mapdir))
    expect(entries(map_b) == stable.map_b, label .. " changed map-b: " .. entries(map_b))
    expect(entries(locked) == stable.locked, label .. " changed locked: " .. entries(locked))
    expect(read_all(listing) == stable.listing, label .. " changed listing")
    expect(read_all(inside) == stable.inside, label .. " changed inside listing")
    expect(read_all(partial_file) == stable.partial, label .. " changed partial file")
    expect(read_all(boundary) == stable.boundary, label .. " changed boundary listing")
    expect(read_all(plain) == stable.plain, label .. " changed plain file")
end

local function root_probes()
    local names = {}
    local pipe = io.popen("ls -a /")
    if not pipe then
        return "?"
    end
    for line in pipe:lines() do
        if line:find(".casually_backup.probe.", 1, true) then
            names[#names + 1] = line
        end
    end
    pipe:close()
    table.sort(names)
    return table.concat(names, "\n")
end

local function run(args)
    local outp = os.tmpname()
    local errp = os.tmpname()
    local cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT LC_ALL=C " .. sh_quote(exe)
    for i = 1, #args do
        cmd = cmd .. " " .. sh_quote(args[i])
    end
    cmd = cmd .. " > " .. sh_quote(outp) .. " 2> " .. sh_quote(errp)
    local ok, how, code = os.execute(cmd)
    local out_f = assert(io.open(outp, "rb"))
    local out = out_f:read("a") or ""
    out_f:close()
    os.remove(outp)
    local err_f = assert(io.open(errp, "rb"))
    local err = err_f:read("a") or ""
    err_f:close()
    os.remove(errp)
    if ok == true then
        code = 0
    elseif how == "exit" then
        code = code or 1
    else
        code = -1
    end
    return code, out, err
end

local function reject_module(cfg, err, class, reason, label)
    expect(cfg == nil, label .. " accepted a bad config")
    expect(err == reason, label .. " module reason got " .. string.format("%q", tostring(err)))
    expect(class == "config", label .. " class got " .. tostring(class))
end

local function reject_config(text, reason)
    local path = write_cfg(text)
    local code, out, err = run({ "--config", path })
    expect(code == 1, "exit 1 for " .. reason .. " got " .. tostring(code) .. " err " .. err)
    expect(out == "", "stdout for " .. reason .. " got " .. string.format("%q", out))
    expect(err == "casually_backup: " .. reason .. "\n",
        "stderr for " .. reason .. " got " .. string.format("%q", err))
    local cfg, merr, class = api.load_config({ config = path })
    reject_module(cfg, merr, class, reason, reason)
    expect_stable(reason)
end

local function reject_cmd(cmd, reason)
    local cfg, err, class = api.load_config(cmd)
    reject_module(cfg, err, class, reason, reason)
    expect_stable(reason)
end

local function reject_flags(args, reason)
    local code, out, err = run(args)
    local shown = table.concat(args, " ")
    expect(code == 1, "exit 1 for " .. reason .. " got " .. tostring(code) .. " err " .. err)
    expect(out == "", "stdout for [" .. shown .. "] got " .. string.format("%q", out))
    expect(err == "casually_backup: " .. reason .. "\n",
        "stderr for [" .. shown .. "] got " .. string.format("%q", err))
    local parsed, perr = api.parse_args(args)
    if parsed then
        local cfg, merr, class = api.load_config(parsed)
        reject_module(cfg, merr, class, reason, reason)
    else
        expect(perr == reason, "parse reason for [" .. shown .. "] got " .. tostring(perr))
    end
    expect_stable(reason)
end

local function expect_shape(cfg, want, label)
    if type(cfg) ~= "table" then
        fail(label .. " did not return a config (" .. tostring(cfg) .. ")")
        return
    end
    expect(cfg.index == want.index, label .. " index " .. tostring(cfg.index))
    expect(#cfg.destinations == #want.destinations,
        label .. " dest count " .. tostring(cfg.destinations and #cfg.destinations))
    for i = 1, #want.destinations do
        expect(cfg.destinations[i] == want.destinations[i],
            label .. " dest " .. i .. " " .. tostring(cfg.destinations[i]))
    end
    expect(#cfg.source_map == #want.source_map,
        label .. " map count " .. tostring(cfg.source_map and #cfg.source_map))
    for i = 1, #want.source_map do
        local got = cfg.source_map[i]
        if type(got) ~= "table" then
            fail(label .. " missing map " .. i)
        else
            expect(got.alias == want.source_map[i].alias,
                label .. " alias " .. i .. " " .. tostring(got.alias))
            expect(got.path == want.source_map[i].path,
                label .. " map path " .. i .. " " .. tostring(got.path))
            expect(keys_of(got) == "alias,path", label .. " map keys " .. keys_of(got))
        end
    end
    expect(#cfg.exclude == #want.exclude, label .. " exclude count " .. tostring(#cfg.exclude))
    for i = 1, #want.exclude do
        expect(cfg.exclude[i] == want.exclude[i],
            label .. " exclude " .. i .. " " .. tostring(cfg.exclude[i]))
    end
    expect(cfg.omit_limit == want.omit_limit,
        label .. " omit_limit " .. tostring(cfg.omit_limit))
    expect(cfg.omit_fraction == want.omit_fraction,
        label .. " omit_fraction " .. tostring(cfg.omit_fraction))
    local want_workers = want.workers
    if want_workers == nil then
        want_workers = 4
    end
    expect(cfg.workers == want_workers,
        label .. " workers " .. tostring(cfg.workers))
    expect(keys_of(cfg) == "destinations,exclude,index,omit_fraction,omit_limit,source_map,workers",
        label .. " keys " .. keys_of(cfg))
end

local function configs_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.index ~= b.index or a.omit_limit ~= b.omit_limit
        or a.omit_fraction ~= b.omit_fraction or a.workers ~= b.workers then
        return false
    end
    if #a.destinations ~= #b.destinations or #a.source_map ~= #b.source_map
        or #a.exclude ~= #b.exclude then
        return false
    end
    for i = 1, #a.destinations do
        if a.destinations[i] ~= b.destinations[i] then
            return false
        end
    end
    for i = 1, #a.source_map do
        if a.source_map[i].alias ~= b.source_map[i].alias
            or a.source_map[i].path ~= b.source_map[i].path then
            return false
        end
    end
    for i = 1, #a.exclude do
        if a.exclude[i] ~= b.exclude[i] then
            return false
        end
    end
    return keys_of(a) == keys_of(b)
end

local function accept_config(text, want, label)
    local path = write_cfg(text)
    local first, err1, class1 = api.load_config({ config = path })
    if not first then
        fail(label .. " rejected: " .. tostring(err1) .. " class " .. tostring(class1))
        expect_stable(label)
        return nil
    end
    expect_shape(first, want, label)
    local second, err2 = api.load_config({ config = path })
    expect(second ~= nil, label .. " second load: " .. tostring(err2))
    expect(configs_equal(first, second), label .. " second run returned different paths")
    expect_stable(label)
    return first
end

local function with_mode(path, mode, restore, fn)
    sh("chmod " .. mode .. " " .. sh_quote(path))
    local ok, err = xpcall(fn, debug.traceback)
    sh("chmod " .. restore .. " " .. sh_quote(path))
    if not ok then
        error(err, 0)
    end
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /tmp/casually-backup-phase2.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end

    listing = base .. "/listing.listing"
    partial_file = base .. "/snap.partial"
    plain = base .. "/plain"
    fifo = base .. "/index.fifo"
    boundary = base .. "/dest-a-listing"
    dest_a = base .. "/dest-a"
    dest_b = base .. "/dest-b"
    dest_ab = base .. "/dest-ab"
    nested = dest_a .. "/nested"
    inside = dest_a .. "/inside.listing"
    mapdir = base .. "/map"
    map_b = base .. "/map-b"
    map_file = base .. "/map-file"
    locked = base .. "/locked"
    link_dest = base .. "/link-dest"
    link_list = base .. "/link-list"
    link_map = base .. "/link-map"

    local function mkdir(path)
        local ok, err = api.lfs.mkdir(path)
        if not ok then
            error("mkdir " .. path .. ": " .. tostring(err))
        end
    end

    local function write_file(path, text)
        local f = assert(io.open(path, "wb"))
        f:write(text)
        f:close()
    end

    mkdir(dest_a)
    mkdir(nested)
    mkdir(dest_b)
    mkdir(dest_ab)
    mkdir(mapdir)
    mkdir(map_b)
    mkdir(locked)
    write_file(listing, "listing-bytes\n")
    write_file(partial_file, "partial-name\n")
    write_file(plain, "plain\n")
    write_file(boundary, "boundary\n")
    write_file(inside, "inside\n")
    write_file(map_file, "not-a-dir\n")
    sh("mkfifo " .. sh_quote(fifo))
    assert(api.lfs.link(dest_a, link_dest, true))
    assert(api.lfs.link(listing, link_list, true))
    assert(api.lfs.link(mapdir, link_map, true))
    snapshot()
    expect(stable.dest_a == "inside.listing\nnested", "dest-a fixture " .. stable.dest_a)
    expect(stable.listing == "listing-bytes\n", "listing fixture")

    local one_dest = arr({ dest_a })
    local two_dest = arr({ dest_a, dest_b })

    reject_config("not json", "config is not valid JSON: no valid JSON value at line 1, column 1")
    reject_config("", "config is not valid JSON: no valid JSON value (reached the end)")
    reject_config("{", "config is not valid JSON: unterminated object at line 1, column 1")
    reject_config("{}\n[]", "config is not valid JSON: trailing data")
    reject_config("[1]", "config is not a JSON object")
    reject_config("null", "config is not a JSON object")
    reject_config("true", "config is not a JSON object")
    reject_config('"x"', "config is not a JSON object")
    reject_config("{}", "index is required")
    reject_config('{"index":null}', "index is required")
    reject_config('{"index":1}', "index must be a string")
    reject_config('{"index":""}', "index is empty")
    reject_config('{"index":"relative"}', "index must be absolute")
    reject_config('{"index":"/tmp/../x"}', "index contains '.' or '..'")
    reject_config('{"index":"/tmp/./x"}', "index contains '.' or '..'")
    reject_config('{"index":"/"}', "index is not a regular file")
    reject_config('{"index":"///"}', "index is not a regular file")
    reject_config(document({ index = jq(base .. "/missing.listing") }), "index does not exist")
    reject_config(document({ index = jq(dest_a) }), "index is not a regular file")
    reject_config(document({ index = jq(link_list) }), "index is not a real file")
    reject_config(document({ index = jq(fifo) }), "index is not a regular file")
    reject_config(document({ index = jq(slashy(partial_file)) }), "index ends in .partial")
    reject_config(document({ index = jq(listing) }), "destinations is required")
    reject_config(document({ index = jq(listing), destinations = "null" }), "destinations is required")
    reject_config(document({ index = jq(listing), destinations = "{}" }), "destinations must be an array")
    reject_config(document({ index = jq(listing), destinations = "[]" }), "destinations is empty")
    reject_config(document({ index = jq(listing), destinations = "[1]" }), "destinations[1] must be a string")
    reject_config(document({ index = jq(listing), destinations = '[""]' }), "destinations[1] is empty")
    reject_config(document({ index = jq(listing), destinations = '["relative"]' }),
        "destinations[1] must be absolute")
    reject_config(document({ index = jq(listing), destinations = '["/tmp/../x"]' }),
        "destinations[1] contains '.' or '..'")
    reject_config(document({ index = jq(listing), destinations = '["/"]' }),
        "destinations[1] must not be /")
    reject_config(document({ index = jq(listing), destinations = '["///"]' }),
        "destinations[1] must not be /")
    reject_config(document({ index = jq(listing), destinations = arr({ base .. "/missing-dest" }) }),
        "destinations[1] does not exist")
    reject_config(document({ index = jq(listing), destinations = arr({ plain }) }),
        "destinations[1] is not a directory")
    reject_config(document({ index = jq(listing), destinations = arr({ link_dest }) }),
        "destinations[1] is not a real directory")
    reject_config(document({
        index = jq(listing),
        destinations = arr({ base .. "/missing-dest" }),
        omit_limit = "-1",
    }), "destinations[1] does not exist")
    reject_config(document({
        index = jq(listing),
        destinations = arr({ dest_a, dest_a .. "/" }),
    }), "destinations overlap: " .. dest_a .. " and " .. dest_a)
    reject_config(document({
        index = jq(listing),
        destinations = arr({ slashy(dest_a), nested }),
    }), "destinations overlap: " .. dest_a .. " and " .. nested)
    reject_config(document({
        index = jq(inside),
        destinations = one_dest,
        source_map = '[{"alias":"relative","path":' .. jq(mapdir) .. "}]" ,
    }), "index sits inside destination " .. dest_a)
    reject_config(document({ index = jq(listing), destinations = one_dest, source_map = "null" }),
        "source_map must be an array")
    reject_config(document({ index = jq(listing), destinations = one_dest, source_map = "{}" }),
        "source_map must be an array")
    reject_config(document({ index = jq(listing), destinations = one_dest, source_map = '["nope"]' }),
        "source_map[1] must be an object")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl", mapdir, '"a_key":1,"z_key":2') .. "]",
    }), "source_map[1] unknown key: a_key")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = '[{"path":' .. jq(mapdir) .. "}]" ,
    }), "source_map[1].alias is required")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("", mapdir) .. "]",
    }), "source_map[1].alias is empty")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("fvl", mapdir) .. "]",
    }), "source_map[1].alias must be absolute")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl/../a", mapdir) .. "]",
    }), "source_map[1].alias contains '.' or '..'")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl", base .. "/missing-map") .. "]",
    }), "source_map[1].path does not exist")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl", map_file) .. "]",
    }), "source_map[1].path is not a directory")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl", link_map) .. "]",
    }), "source_map[1].path is not a real directory")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl/a", mapdir) .. "," .. map_obj("/fvl/a/child", map_b) .. "]",
    }), "source_map aliases overlap: /fvl/a and /fvl/a/child")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/fvl/", mapdir) .. "," .. map_obj("/fvl", map_b) .. "]",
    }), "source_map aliases overlap: /fvl and /fvl")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/", mapdir) .. "," .. map_obj("/fvl", map_b) .. "]",
    }), "source_map aliases overlap: / and /fvl")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("relative", mapdir) .. "]",
        exclude = '["/"]',
    }), "source_map[1].alias must be absolute")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = "null" }),
        "exclude must be an array")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = "{}" }),
        "exclude must be an array")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = "[1]" }),
        "exclude[1] must be a string")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = '[""]' }),
        "exclude[1] is empty")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = '["relative"]' }),
        "exclude[1] must be absolute")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = '["/tmp/../x"]' }),
        "exclude[1] contains '.' or '..'")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = '["/"]' }),
        "exclude[1] must not be /")
    reject_config(document({ index = jq(listing), destinations = one_dest, exclude = '["///"]' }),
        "exclude[1] must not be /")
    reject_config(document({
        index = jq(listing),
        destinations = one_dest,
        exclude = '["/"]',
        omit_limit = "-1",
    }), "exclude[1] must not be /")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_limit = "null" }),
        "omit_limit must be an integer >= 0")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_limit = '"12"' }),
        "omit_limit must be an integer >= 0")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_limit = "-1" }),
        "omit_limit must be an integer >= 0")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_limit = "1.5" }),
        "omit_limit must be an integer >= 0")
    reject_config(document({ index = jq(listing), destinations = one_dest, workers = "null" }),
        "workers must be an integer from 1 to 64")
    reject_config(document({ index = jq(listing), destinations = one_dest, workers = '"4"' }),
        "workers must be an integer from 1 to 64")
    reject_config(document({ index = jq(listing), destinations = one_dest, workers = "0" }),
        "workers must be an integer from 1 to 64")
    reject_config(document({ index = jq(listing), destinations = one_dest, workers = "65" }),
        "workers must be an integer from 1 to 64")
    reject_config(document({ index = jq(listing), destinations = one_dest, workers = "1.5" }),
        "workers must be an integer from 1 to 64")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_fraction = "null" }),
        "omit_fraction must be a number from 0 to 1")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_fraction = '"0.02"' }),
        "omit_fraction must be a number from 0 to 1")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_fraction = "-0.1" }),
        "omit_fraction must be a number from 0 to 1")
    reject_config(document({ index = jq(listing), destinations = one_dest, omit_fraction = "1.1" }),
        "omit_fraction must be a number from 0 to 1")
    reject_config(document({
        index = jq(listing),
        destinations = two_dest,
        extra = '"a_extra":true,"z_extra":true',
    }), "unknown config key: a_extra")

    local missing = base .. "/no-such-config.json"
    local code, out, err = run({ "--config", missing })
    local missing_reason = "cannot read config " .. missing .. ": " .. missing .. ": No such file or directory"
    expect(code == 1, "missing config exit " .. tostring(code))
    expect(out == "", "missing config stdout")
    expect(err == "casually_backup: " .. missing_reason .. "\n",
        "missing config stderr " .. string.format("%q", err))
    local mcfg, merr, mclass = api.load_config({ config = missing })
    reject_module(mcfg, merr, mclass, missing_reason, "missing config")
    expect_stable("missing config")

    local denied = write_cfg("{")
    with_mode(denied, "000", "644", function()
        local reason = "cannot read config " .. denied .. ": " .. denied .. ": Permission denied"
        local dcode, dout, derr = run({ "--config", denied })
        expect(dcode == 1, "unreadable config exit " .. tostring(dcode) .. " " .. derr)
        expect(dout == "", "unreadable config stdout")
        expect(derr == "casually_backup: " .. reason .. "\n",
            "unreadable config stderr " .. string.format("%q", derr))
        local dcfg, derr_m, dclass = api.load_config({ config = denied })
        reject_module(dcfg, derr_m, dclass, reason, "unreadable config")
    end)
    expect_stable("unreadable config")

    local dir_reason = "cannot read config " .. dest_a .. ": Is a directory"
    local dircode, dirout, direrr = run({ "--config", dest_a })
    expect(dircode == 1, "directory config exit " .. tostring(dircode) .. " " .. direrr)
    expect(dirout == "", "directory config stdout")
    expect(direrr == "casually_backup: " .. dir_reason .. "\n",
        "directory config stderr " .. string.format("%q", direrr))
    expect_stable("directory config")

    with_mode(locked, "555", "755", function()
        reject_config(document({
            index = jq(listing),
            destinations = arr({ locked }),
        }), "destinations[1] is not writable")
        reject_config(document({
            index = jq(listing),
            destinations = arr({ dest_a, locked }),
        }), "destinations[2] is not writable")
    end)

    expect(root_probes() == "", "probe left on /: " .. root_probes())

    local valid_text = document({
        index = jq(slashy(listing)),
        destinations = arr({ slashy(dest_a), dest_b .. "///" }),
        source_map = "[" .. map_obj("/fvl/a///", slashy(mapdir)) .. "]",
        exclude = arr({ "/fvl/a/skip///" }),
    })
    accept_config(valid_text, {
        index = listing,
        destinations = { dest_a, dest_b },
        source_map = { { alias = "/fvl/a", path = mapdir } },
        exclude = { "/fvl/a/skip" },
        omit_limit = 1000,
        omit_fraction = 0.02,
    }, "valid two-destination config")

    with_mode(listing, "000", "644", function()
        local path = write_cfg(valid_text)
        local cfg, uerr, uclass = api.load_config({ config = path })
        if not cfg then
            fail("unreadable listing rejected: " .. tostring(uerr) .. " class " .. tostring(uclass))
        else
            expect(cfg.index == listing, "unreadable listing path")
        end
    end)
    expect_stable("unreadable listing")

    accept_config(document({
        index = jq(boundary),
        destinations = arr({ dest_a, dest_ab }),
        source_map = "[]",
        exclude = "[]",
        omit_limit = "0",
        omit_fraction = "1",
    }), {
        index = boundary,
        destinations = { dest_a, dest_ab },
        source_map = {},
        exclude = {},
        omit_limit = 0,
        omit_fraction = 1,
    }, "boundary dest and zero limits")

    accept_config(document({
        index = jq(listing),
        destinations = one_dest,
        source_map = "[" .. map_obj("/", "/") .. "]",
        exclude = arr({ "/no/such/exclude" }),
        omit_fraction = "0",
    }), {
        index = listing,
        destinations = { dest_a },
        source_map = { { alias = "/", path = "/" } },
        exclude = { "/no/such/exclude" },
        omit_limit = 1000,
        omit_fraction = 0,
    }, "sole alias / and map path /")

    accept_config(document({
        index = jq(listing),
        destinations = two_dest,
        omit_limit = "1000",
        omit_fraction = "0.02",
    }), {
        index = listing,
        destinations = { dest_a, dest_b },
        source_map = {},
        exclude = {},
        omit_limit = 1000,
        omit_fraction = 0.02,
        workers = 4,
    }, "explicit default omission numbers")

    accept_config(document({
        index = jq(listing),
        destinations = one_dest,
        workers = "1",
    }), {
        index = listing,
        destinations = { dest_a },
        source_map = {},
        exclude = {},
        omit_limit = 1000,
        omit_fraction = 0.02,
        workers = 1,
    }, "one worker")

    local override_text = document({
        index = jq(listing),
        destinations = two_dest,
        source_map = "[" .. map_obj("/fvl", mapdir) .. "," .. map_obj("/other", map_b) .. "]",
        exclude = arr({ "/skip" }),
        omit_limit = "-1",
        omit_fraction = "5",
    })
    local override_path = write_cfg(override_text)
    local override_cmd = api.parse_args({
        "--omit-fraction", "0.25",
        "--config", override_path,
        "--omit-limit", "50",
        "--dry-run",
    })
    local overridden, oerr, oclass = api.load_config(override_cmd)
    if not overridden then
        fail("override rejected: " .. tostring(oerr) .. " class " .. tostring(oclass))
    else
        expect_shape(overridden, {
            index = listing,
            destinations = { dest_a, dest_b },
            source_map = {
                { alias = "/fvl", path = mapdir },
                { alias = "/other", path = map_b },
            },
            exclude = { "/skip" },
            omit_limit = 50,
            omit_fraction = 0.25,
        }, "omit-limit 50 overrides JSON")
    end
    expect_stable("override")

    local flag_cmd = api.parse_args({
        "--dest", slashy(dest_b),
        "--index", slashy(listing),
        "--dest", dest_a .. "/",
        "--dry-run",
    })
    local flagged, ferr, fclass = api.load_config(flag_cmd)
    if not flagged then
        fail("flag form rejected: " .. tostring(ferr) .. " class " .. tostring(fclass))
    else
        expect_shape(flagged, {
            index = listing,
            destinations = { dest_b, dest_a },
            source_map = {},
            exclude = {},
            omit_limit = 1000,
            omit_fraction = 0.02,
        }, "flag form")
        expect(flagged.dry_run == nil, "dry_run is not part of the config")
        local flagged2 = api.load_config(flag_cmd)
        expect(configs_equal(flagged, flagged2), "flag form second run differs")
    end
    expect_stable("flag form")

    local zero_cmd = api.parse_args({
        "--index", listing,
        "--dest", dest_a,
        "--omit-limit", "0",
        "--omit-fraction", "0.0",
    })
    local zeroed, zerr, zclass = api.load_config(zero_cmd)
    if not zeroed then
        fail("zero flags rejected: " .. tostring(zerr) .. " class " .. tostring(zclass))
    else
        expect(zeroed.omit_limit == 0 and zeroed.omit_fraction == 0, "zero flag values")
        expect(zeroed.workers == 4, "workers default " .. tostring(zeroed.workers))
    end
    expect_stable("zero flags")

    local worker_cmd = api.parse_args({
        "--index", listing,
        "--dest", dest_a,
        "--workers", "8",
    })
    local worked, werr, wclass = api.load_config(worker_cmd)
    if not worked then
        fail("workers flag rejected: " .. tostring(werr) .. " class " .. tostring(wclass))
    else
        expect(worked.workers == 8, "workers flag " .. tostring(worked.workers))
    end
    expect_stable("workers flag")
    reject_flags({ "--index", listing, "--dest", dest_a, "--workers", "0" },
        "--workers must be an integer from 1 to 64")
    reject_flags({ "--index", listing, "--dest", dest_a, "--workers", "65" },
        "--workers must be an integer from 1 to 64")

    reject_flags({ "--index", "relative", "--dest", dest_a }, "--index must be absolute")
    reject_flags({ "--index", "", "--dest", dest_a }, "--index is empty")
    reject_flags({ "--index", listing .. "/../listing.listing", "--dest", dest_a },
        "--index contains '.' or '..'")
    reject_flags({ "--index", base .. "/missing.listing", "--dest", dest_a },
        "--index does not exist")
    reject_flags({ "--index", link_list, "--dest", dest_a }, "--index is not a real file")
    reject_flags({ "--index", dest_a, "--dest", dest_b }, "--index is not a regular file")
    reject_flags({ "--index", slashy(partial_file), "--dest", dest_a }, "--index ends in .partial")
    reject_flags({ "--index", listing, "--dest", "relative" }, "--dest[1] must be absolute")
    reject_flags({ "--index", listing, "--dest", "" }, "--dest[1] is empty")
    reject_flags({ "--index", listing, "--dest", base .. "/no-dest" }, "--dest[1] does not exist")
    reject_flags({ "--index", listing, "--dest", "/" }, "--dest[1] must not be /")
    reject_flags({ "--index", listing, "--dest", "///" }, "--dest[1] must not be /")
    expect(root_probes() == "", "dest / created a probe: " .. root_probes())
    reject_flags({ "--index", listing, "--dest", plain }, "--dest[1] is not a directory")
    reject_flags({ "--index", listing, "--dest", link_dest }, "--dest[1] is not a real directory")
    reject_flags({ "--index", listing, "--dest", dest_a, "--dest", nested },
        "destinations overlap: " .. dest_a .. " and " .. nested)
    reject_flags({ "--index", inside, "--dest", dest_a },
        "index sits inside destination " .. dest_a)
    reject_flags({ "--source-map", "nopath" }, "--source-map requires alias=path")
    reject_flags({ "--index", listing, "--dest", dest_a, "--source-map", "=/srv" },
        "--source-map[1].alias is empty")
    reject_flags({ "--index", listing, "--dest", dest_a, "--source-map", "/fvl=" },
        "--source-map[1].path is empty")
    reject_flags({ "--index", listing, "--dest", dest_a, "--source-map", "/fvl=" .. link_map },
        "--source-map[1].path is not a real directory")
    reject_flags({ "--index", listing, "--dest", dest_a, "--omit-limit", "foo" },
        "--omit-limit must be an integer >= 0")
    reject_flags({ "--index", listing, "--dest", dest_a, "--omit-limit", "1.5" },
        "--omit-limit must be an integer >= 0")
    reject_flags({ "--index", listing, "--dest", dest_a, "--omit-fraction", "2" },
        "--omit-fraction must be a number from 0 to 1")
    reject_flags({ "--index", listing, "--dest", dest_a, "--omit-fraction", "1.5" },
        "--omit-fraction must be a number from 0 to 1")
    reject_flags({ "--index", listing, "--dest", dest_a, "--omit-limit", "4", "--omit-fraction", "nope" },
        "--omit-fraction must be a number from 0 to 1")

    reject_cmd(nil, "missing arguments")
    reject_cmd({}, "missing arguments")

    local probe = io.popen("find " .. sh_quote(base) .. " -name '.casually_backup.probe.*' -print")
    local probes = probe:read("a") or ""
    probe:close()
    expect(probes == "", "probe files left behind: " .. probes)
    expect(root_probes() == "", "root probe files left behind")
end

local ok, err = xpcall(gate, debug.traceback)
cleanup()
if not ok then
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
end
if failures > 0 then
    io.stderr:write(failures .. " failure(s)\n")
    os.exit(1)
end

local phase1_out = os.tmpname()
local phase1_err = os.tmpname()
local phase1_cmd = sh_quote(root .. "/test/run.sh") .. " backup 1 > "
    .. sh_quote(phase1_out) .. " 2> " .. sh_quote(phase1_err)
local pok, phow, pcode = os.execute(phase1_cmd)
local phase1_text = read_all(phase1_out)
local phase1_err_text = read_all(phase1_err)
os.remove(phase1_out)
os.remove(phase1_err)
if pok == true then
    pcode = 0
elseif phow ~= "exit" then
    pcode = -1
end
if pcode ~= 0 or phase1_text:find("backup phase 1 gate passed", 1, true) == nil then
    io.stderr:write("backup phase 1 did not pass, exit " .. tostring(pcode) .. "\n")
    io.stderr:write(phase1_err_text)
    io.stderr:write(phase1_text)
    os.exit(1)
end

io.stdout:write("backup phase 2 gate passed\n")
