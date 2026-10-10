-- Phase 5 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 5
-- apply publishes one snapshot per destination. A failure does not rename.
-- q and the screen are phase 6. This gate does not need a terminal.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase5.lua")
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
local index_exe = root .. "/casually_index.lua"

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
local index = dofile(index_exe)
local lfs = api.lfs
expect(type(api.plan) == "function", "plan is exported")
expect(type(api.apply) == "function", "apply is exported")
expect(type(api.perform) == "function", "perform is exported")
expect(type(api.metadata_batch) == "function", "metadata_batch is exported")
expect(type(index.format_line) == "function", "format_line is exported")

local COPY_CHUNK = 1048576
local OWNER = "casually_backup: owner not applied\n"
local S1 = "20261008-1430"
local S2 = "20261009-0900"
local S3 = "20261010-0100"

local base

local function cleanup()
    if base then
        os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
        os.execute("rm -rf " .. sh_quote(base))
    end
end

local function mkdir_p(path)
    sh("mkdir -p " .. sh_quote(path))
end

local function write_file(path, text)
    mkdir_p(dirname(path))
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("a")
    f:close()
    return text
end

local function kind_of(mode)
    if mode == "file" then
        return "file"
    end
    if mode == "directory" then
        return "dir"
    end
    if mode == "link" then
        return "link"
    end
    return nil
end

local function line_for(abs, listing, overrides)
    overrides = overrides or {}
    local attr = assert(lfs.symlinkattributes(abs), abs)
    local kind = assert(kind_of(attr.mode), attr.mode .. " " .. abs)
    local rec = {
        path = listing,
        kind = kind,
        size = overrides.size or math.tointeger(attr.size),
        mtime = overrides.mtime or attr.modification,
        user = overrides.user or attr.uid,
        group = overrides.group or attr.gid,
    }
    if overrides.mode ~= nil then
        rec.mode = overrides.mode
    else
        rec.permissions = overrides.permissions or attr.permissions
    end
    if kind == "link" then
        rec.target = overrides.target or attr.target
        rec.size = #rec.target
    end
    local line, err = index.format_line(rec)
    if not line then
        error(err or "format_line")
    end
    return line
end

local function write_listing(dir, stamp, rows)
    table.sort(rows, function(a, b)
        return a.listing < b.listing
    end)
    local lines = {}
    for i = 1, #rows do
        lines[i] = line_for(rows[i].abs, rows[i].listing, rows[i])
    end
    local path = dir .. "/index-" .. stamp .. ".listing"
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    return path
end

local function config_for(index_path, dests, opts)
    opts = opts or {}
    return {
        index = index_path,
        destinations = dests,
        source_map = opts.source_map or {},
        exclude = opts.exclude or {},
        omit_limit = opts.omit_limit ~= nil and opts.omit_limit or 1000,
        omit_fraction = opts.omit_fraction ~= nil and opts.omit_fraction or 0.02,
        workers = opts.workers,
    }
end

local function map_of(src)
    return { { alias = "/fvl", path = src .. "/fvl" } }
end

local function user_fs(extra)
    extra = extra or {}
    if extra.euid == nil then
        extra.euid = 1000
    end
    return extra
end

local function run_perform(cfg, opts, fs)
    local out_buf, err_buf = {}, {}
    local function writer(buf)
        return {
            write = function(_, s)
                buf[#buf + 1] = s
                return true
            end,
        }
    end
    local code = api.perform(cfg, opts or {}, fs, writer(out_buf), writer(err_buf))
    return code, table.concat(out_buf), table.concat(err_buf)
end

local function expect_success(code, out, err, msg)
    expect(code == 0, msg .. " exit " .. tostring(code) .. " stderr " .. tostring(err))
    expect(out == "", msg .. " stdout " .. tostring(out))
    expect(err == OWNER, msg .. " stderr " .. tostring(err))
end

local function expect_warn(code, out, err, reason, msg)
    expect(code == 0, msg .. " exit " .. tostring(code) .. " stderr " .. tostring(err))
    expect(out == "", msg .. " stdout " .. tostring(out))
    expect(err == reason .. "\n" .. OWNER, msg .. " stderr " .. tostring(err))
end

local function expect_stderr(code, out, err, want_code, reason, msg)
    expect(code == want_code, msg .. " exit " .. tostring(code) .. " stderr " .. tostring(err))
    expect(out == "", msg .. " stdout " .. tostring(out))
    expect(err == "casually_backup: " .. reason .. "\n", msg .. " stderr " .. tostring(err))
end

local function children(dir)
    local names = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function partial_dirs(dir)
    local found = {}
    for _, name in ipairs(children(dir)) do
        if name:sub(-8) == ".partial" then
            local attr = lfs.symlinkattributes(dir .. "/" .. name)
            if attr and attr.mode == "directory" then
                found[#found + 1] = name
            end
        end
    end
    return found
end

local function expect_clean(dest, msg)
    expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, msg .. " left a lock")
    local parts = partial_dirs(dest)
    expect(#parts == 0, msg .. " left partial " .. table.concat(parts, ","))
    for _, name in ipairs(children(dest)) do
        expect(name:find(".casually_backup.probe.", 1, true) ~= 1, msg .. " left " .. name)
    end
end

local function utc_mtime(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then
        return nil
    end
    local whole = math.modf(attr.modification)
    return os.date("!%Y%m%d:%H%M%S", whole)
end

local function stat_mode(path)
    local handle = io.popen("stat -c " .. sh_quote("%a") .. " -- " .. sh_quote(path))
    if not handle then
        return nil
    end
    local text = handle:read("a") or ""
    handle:close()
    return (text:gsub("%s+$", ""))
end

local function ino_of(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then
        return nil
    end
    return attr.ino, attr.nlink, attr.dev
end

local function expect_file(path, bytes, msg)
    local got = read_all(path)
    if got ~= bytes then
        fail(msg .. " length " .. tostring(got and #got) .. " want " .. tostring(bytes and #bytes))
    end
end

local function self_pid()
    local f = assert(io.open("/proc/self/stat", "rb"))
    local text = f:read("a")
    f:close()
    return assert(text:match("^(%d+)"))
end

local function dead_pid()
    local candidates = { "2147483647", "2147483646", "2147483000" }
    for i = 1, #candidates do
        if lfs.symlinkattributes("/proc/" .. candidates[i]) == nil then
            return candidates[i]
        end
    end
    error("no dead pid")
end

local function plant_lock(dest, pid)
    local dir = dest .. "/.casually_backup.lock"
    mkdir_p(dir)
    write_file(dir .. "/owner", pid .. "\n")
    write_file(dir .. "/lockfile.lfs", "")
    return dir
end

local function counting_open(opens, reads, details)
    return function(path)
        opens[#opens + 1] = path
        local handle, open_err = io.open(path, "rb")
        if not handle then
            return nil, open_err
        end
        return {
            read = function(_, n)
                if reads then
                    reads[#reads + 1] = n
                end
                local buf, read_err = handle:read(n)
                if details then
                    details[#details + 1] = { n = n, buf = buf, err = read_err }
                end
                return buf, read_err
            end,
            close = function()
                return handle:close()
            end,
        }
    end
end

local function payload_parts(payload)
    local parts = {}
    local i = 1
    while i <= #payload do
        local j = payload:find("\0", i, true)
        if not j then
            parts[#parts + 1] = payload:sub(i)
            break
        end
        parts[#parts + 1] = payload:sub(i, j - 1)
        i = j + 1
    end
    return parts
end

local function has_part(payloads, path)
    for i = 1, #payloads do
        local parts = payload_parts(payloads[i])
        for j = 1, #parts do
            if parts[j] == path then
                return true
            end
        end
    end
    return false
end

local real_popen = io.popen

local function collect_popen(fn)
    local commands = {}
    io.popen = function(command, mode)
        commands[#commands + 1] = command
        return real_popen(command, mode)
    end
    local ok, err = xpcall(fn, debug.traceback)
    io.popen = real_popen
    if not ok then
        error(err, 0)
    end
    return commands
end

local function real_euid()
    local f = assert(io.open("/proc/self/status", "rb"))
    local text = f:read("a") or ""
    f:close()
    return tonumber(text:match("Uid:%s*%d+%s+(%d+)"))
end

local seq = 0

local function case_dir(name)
    seq = seq + 1
    local path = base .. "/" .. string.format("%02d-%s", seq, name)
    mkdir_p(path)
    return path
end

local function root_getent(database)
    if database == "passwd" then
        return "root:x:0:0:root:/root:/bin/sh\n"
    end
    if database == "group" then
        return "root:x:0:root\n"
    end
    return nil, "getent failed"
end

local function gate()
    local tmp = os.tmpname()
    os.remove(tmp)
    base = tmp
    mkdir_p(base)
    expect(real_euid() ~= 0, "phase 5 gate expects a non-root euid")

    -- Two destinations, one source open, chunked copy, then a hardlink chain.
    local chain = case_dir("chain")
    local src = chain .. "/src"
    local d1 = chain .. "/d1"
    local d2 = chain .. "/d2"
    mkdir_p(d1)
    mkdir_p(d2)
    local big = string.rep("a", COPY_CHUNK + 8)
    write_file(src .. "/fvl/same", big)
    write_file(src .. "/fvl/changed", "before\n")
    sh("chmod 755 " .. sh_quote(src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(src .. "/fvl/same"))
    sh("chmod 644 " .. sh_quote(src .. "/fvl/changed"))
    local function chain_rows()
        return {
            { abs = src .. "/fvl", listing = "/fvl" },
            { abs = src .. "/fvl/changed", listing = "/fvl/changed" },
            { abs = src .. "/fvl/same", listing = "/fvl/same" },
        }
    end
    local index1 = write_listing(chain, S1, chain_rows())
    local opens, reads = {}, {}
    local fs = user_fs({ open_source = counting_open(opens, reads) })
    local code, out, err = run_perform(config_for(index1, { d1, d2 }, {
        source_map = map_of(src),
    }), {}, fs)
    expect_success(code, out, err, "chain run 1")
    expect(#opens == 2, "chain run 1 opens " .. tostring(#opens))
    expect(opens[1] == src .. "/fvl/changed", "chain run 1 first open " .. tostring(opens[1]))
    expect(opens[2] == src .. "/fvl/same", "chain run 1 second open " .. tostring(opens[2]))
    expect(reads[1] == 7 and reads[2] == 1 and reads[3] == COPY_CHUNK
        and reads[4] == 8 and reads[5] == 1 and #reads == 5,
        "chain chunk reads " .. table.concat(reads, ","))
    local function snap_file(dest, snap, name)
        return dest .. "/" .. snap .. "/fvl/" .. name
    end
    for _, dest in ipairs({ d1, d2 }) do
        expect(lfs.symlinkattributes(dest .. "/" .. S1) == nil, "chain published a date on an empty dest")
        expect(lfs.symlinkattributes(dest .. "/_Base") ~= nil, "chain missing _Base")
        expect_file(snap_file(dest, "_Base", "same"), big, dest .. " same bytes")
        expect_file(snap_file(dest, "_Base", "changed"), "before\n", dest .. " changed bytes")
        expect(utc_mtime(snap_file(dest, "_Base", "same")) == utc_mtime(src .. "/fvl/same"),
            dest .. " same mtime")
        expect(utc_mtime(snap_file(dest, "_Base", "changed")) == utc_mtime(src .. "/fvl/changed"),
            dest .. " changed mtime")
        expect(utc_mtime(dest .. "/_Base/fvl") == utc_mtime(src .. "/fvl"), dest .. " dir mtime")
        expect(stat_mode(snap_file(dest, "_Base", "same")) == "644", dest .. " same mode")
        expect(stat_mode(dest .. "/_Base/fvl") == "755", dest .. " dir mode")
        expect_clean(dest, "chain run 1 " .. dest)
    end
    local d1_same, d1_same_n, d1_dev = ino_of(snap_file(d1, "_Base", "same"))
    local d2_same, _, d2_dev = ino_of(snap_file(d2, "_Base", "same"))
    local d1_changed = ino_of(snap_file(d1, "_Base", "changed"))
    local d1_changed_mtime = utc_mtime(snap_file(d1, "_Base", "changed"))
    expect(d1_dev == d2_dev, "chain destinations are on different devices")
    expect(d1_same ~= d2_same, "chain run 1 destinations share an inode")
    expect(d1_same_n == 1, "chain run 1 nlink " .. tostring(d1_same_n))

    write_file(d1 .. "/_Base/inside.partial/marker", "stay\n")
    write_file(src .. "/fvl/changed", "after\n")
    sh("chmod 644 " .. sh_quote(src .. "/fvl/changed"))
    local index2 = write_listing(chain, S2, chain_rows())
    opens, reads = {}, {}
    fs = user_fs({ open_source = counting_open(opens, reads) })
    code, out, err = run_perform(config_for(index2, { d1, d2 }, {
        source_map = map_of(src),
    }), {}, fs)
    expect_success(code, out, err, "chain run 2")
    expect(#opens == 1 and opens[1] == src .. "/fvl/changed",
        "chain run 2 opens " .. table.concat(opens, ","))
    local day_same, day_same_n = ino_of(snap_file(d1, S2, "same"))
    local day_changed = ino_of(snap_file(d1, S2, "changed"))
    local base_changed = ino_of(snap_file(d1, "_Base", "changed"))
    expect(day_same == d1_same, "unchanged file broke away from _Base")
    expect(day_same_n >= 2, "unchanged nlink " .. tostring(day_same_n))
    expect(day_changed ~= d1_changed, "changed file kept the _Base inode")
    expect(base_changed == d1_changed, "_Base changed inode moved")
    expect_file(snap_file(d1, "_Base", "changed"), "before\n", "_Base changed bytes")
    expect(utc_mtime(snap_file(d1, "_Base", "changed")) == d1_changed_mtime, "_Base changed mtime")
    expect_file(snap_file(d1, S2, "changed"), "after\n", "dated changed bytes")
    expect(utc_mtime(snap_file(d1, S2, "changed")) == utc_mtime(src .. "/fvl/changed"),
        "dated changed mtime")
    local d2_day_same = ino_of(snap_file(d2, S2, "same"))
    local d2_base_same = ino_of(snap_file(d2, "_Base", "same"))
    expect(d2_day_same == d2_base_same, "dest 2 unchanged file broke away")
    expect(d2_day_same ~= day_same, "two destinations share the unchanged inode")
    expect(ino_of(snap_file(d1, S2, "changed")) ~= ino_of(snap_file(d2, S2, "changed")),
        "two destinations share the changed inode")
    expect_file(d1 .. "/_Base/inside.partial/marker", "stay\n", "partial cleanup walked into _Base")
    expect(lfs.symlinkattributes(d1 .. "/" .. S2 .. "/inside.partial") == nil,
        "omitted partial name was published")
    expect_clean(d1, "chain run 2 d1")
    expect_clean(d2, "chain run 2 d2")

    local index3 = write_listing(chain, S3, chain_rows())
    opens = {}
    fs = user_fs({ open_source = counting_open(opens) })
    code, out, err = run_perform(config_for(index3, { d1, d2 }, {
        source_map = map_of(src),
    }), {}, fs)
    expect_success(code, out, err, "chain run 3")
    expect(#opens == 0, "chain run 3 opened " .. table.concat(opens, ","))
    expect(ino_of(snap_file(d1, S3, "changed")) == day_changed,
        "third run did not hardlink the changed file to the previous date")
    expect(ino_of(snap_file(d1, S3, "same")) == d1_same,
        "third run lost the _Base inode")
    local _, third_n = ino_of(snap_file(d1, S3, "same"))
    expect(third_n >= 3, "third run nlink " .. tostring(third_n))
    expect(ino_of(snap_file(d1, "_Base", "changed")) == d1_changed, "third run rewrote _Base")
    expect_file(snap_file(d1, "_Base", "changed"), "before\n", "third run _Base bytes")
    expect(ino_of(snap_file(d2, S3, "same")) ~= ino_of(snap_file(d1, S3, "same")),
        "third run joined destination inodes")
    expect_file(d1 .. "/_Base/inside.partial/marker", "stay\n", "third run removed the nested partial")
    expect_clean(d1, "chain run 3")

    -- A mode-only change is a new inode. _Base keeps the old mode.
    local mode = case_dir("mode")
    local mode_src = mode .. "/src"
    local mode_dest = mode .. "/dest"
    mkdir_p(mode_dest)
    write_file(mode_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(mode_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(mode_src .. "/fvl/readme"))
    local mode_rows = {
        { abs = mode_src .. "/fvl", listing = "/fvl" },
        { abs = mode_src .. "/fvl/readme", listing = "/fvl/readme" },
    }
    code, out, err = run_perform(config_for(write_listing(mode, S1, mode_rows), { mode_dest }, {
        source_map = map_of(mode_src),
    }), {}, user_fs())
    expect_success(code, out, err, "mode run 1")
    local mode_ino = ino_of(mode_dest .. "/_Base/fvl/readme")
    local mode_mtime = utc_mtime(mode_dest .. "/_Base/fvl/readme")
    sh("chmod 755 " .. sh_quote(mode_src .. "/fvl/readme"))
    code, out, err = run_perform(config_for(write_listing(mode, S2, mode_rows), { mode_dest }, {
        source_map = map_of(mode_src),
    }), {}, user_fs())
    expect_success(code, out, err, "mode run 2")
    expect(ino_of(mode_dest .. "/_Base/fvl/readme") == mode_ino, "mode-only rewrote _Base")
    expect(utc_mtime(mode_dest .. "/_Base/fvl/readme") == mode_mtime, "mode-only retimed _Base")
    expect_file(mode_dest .. "/_Base/fvl/readme", "hello\n", "mode-only _Base bytes")
    expect(stat_mode(mode_dest .. "/_Base/fvl/readme") == "644", "_Base mode changed")
    expect(ino_of(mode_dest .. "/" .. S2 .. "/fvl/readme") ~= mode_ino, "mode-only hardlinked")
    expect(stat_mode(mode_dest .. "/" .. S2 .. "/fvl/readme") == "755", "new mode " ..
        tostring(stat_mode(mode_dest .. "/" .. S2 .. "/fvl/readme")))
    expect_file(mode_dest .. "/" .. S2 .. "/fvl/readme", "hello\n", "mode-only new bytes")
    expect_clean(mode_dest, "mode")

    -- A zero-byte file is copied, including the extra read, then hardlinked.
    local zero = case_dir("zero")
    local zero_src = zero .. "/src"
    local zero_dest = zero .. "/dest"
    mkdir_p(zero_dest)
    write_file(zero_src .. "/fvl/empty", "")
    sh("chmod 755 " .. sh_quote(zero_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(zero_src .. "/fvl/empty"))
    local zero_rows = {
        { abs = zero_src .. "/fvl", listing = "/fvl" },
        { abs = zero_src .. "/fvl/empty", listing = "/fvl/empty" },
    }
    local zero_opens, zero_details = {}, {}
    code, out, err = run_perform(config_for(write_listing(zero, S1, zero_rows), { zero_dest }, {
        source_map = map_of(zero_src),
    }), {}, user_fs({
        open_source = counting_open(zero_opens, nil, zero_details),
    }))
    expect_success(code, out, err, "zero run 1")
    expect(#zero_opens == 1, "zero opens " .. tostring(#zero_opens))
    expect(#zero_details == 1 and zero_details[1].n == 1
        and zero_details[1].buf == nil and zero_details[1].err == nil,
        "zero extra read")
    expect_file(zero_dest .. "/_Base/fvl/empty", "", "zero bytes")
    local zero_ino = ino_of(zero_dest .. "/_Base/fvl/empty")
    zero_opens = {}
    code, out, err = run_perform(config_for(write_listing(zero, S2, zero_rows), { zero_dest }, {
        source_map = map_of(zero_src),
    }), {}, user_fs({ open_source = counting_open(zero_opens) }))
    expect_success(code, out, err, "zero run 2")
    expect(#zero_opens == 0, "zero run 2 opened a source")
    expect(ino_of(zero_dest .. "/" .. S2 .. "/fvl/empty") == zero_ino, "zero did not hardlink")
    local _, zero_n = ino_of(zero_dest .. "/" .. S2 .. "/fvl/empty")
    expect(zero_n >= 2, "zero nlink " .. tostring(zero_n))
    expect_clean(zero_dest, "zero")

    -- Symlinks: dangling, a target of "-", then a hardlink that leaves the target mode.
    local links = case_dir("links")
    local link_src = links .. "/src"
    local link_dest = links .. "/dest"
    mkdir_p(link_dest)
    write_file(link_src .. "/fvl/data", "data\n")
    sh("chmod 755 " .. sh_quote(link_src .. "/fvl"))
    sh("chmod 640 " .. sh_quote(link_src .. "/fvl/data"))
    sh("ln -s -- - " .. sh_quote(link_src .. "/fvl/dash"))
    sh("ln -s nowhere " .. sh_quote(link_src .. "/fvl/gone"))
    sh("ln -s data " .. sh_quote(link_src .. "/fvl/rel"))
    local link_rows = {
        { abs = link_src .. "/fvl", listing = "/fvl" },
        { abs = link_src .. "/fvl/dash", listing = "/fvl/dash" },
        { abs = link_src .. "/fvl/data", listing = "/fvl/data" },
        { abs = link_src .. "/fvl/gone", listing = "/fvl/gone" },
        { abs = link_src .. "/fvl/rel", listing = "/fvl/rel" },
    }
    code, out, err = run_perform(config_for(write_listing(links, S1, link_rows), { link_dest }, {
        source_map = map_of(link_src),
    }), {}, user_fs())
    expect_success(code, out, err, "link run 1")
    local function link_target(path)
        local attr = lfs.symlinkattributes(path)
        if not attr or attr.mode ~= "link" then
            return nil
        end
        return attr.target
    end
    expect(link_target(link_dest .. "/_Base/fvl/dash") == "-", "dash target")
    expect(link_target(link_dest .. "/_Base/fvl/gone") == "nowhere", "dangling target")
    expect(link_target(link_dest .. "/_Base/fvl/rel") == "data", "relative target")
    expect(stat_mode(link_dest .. "/_Base/fvl/data") == "640", "link run 1 followed a symlink")
    local dash_ino = ino_of(link_dest .. "/_Base/fvl/dash")
    local gone_ino = ino_of(link_dest .. "/_Base/fvl/gone")
    local rel_ino = ino_of(link_dest .. "/_Base/fvl/rel")
    local data_ino = ino_of(link_dest .. "/_Base/fvl/data")
    local link_opens = {}
    code, out, err = run_perform(config_for(write_listing(links, S2, link_rows), { link_dest }, {
        source_map = map_of(link_src),
    }), {}, user_fs({ open_source = counting_open(link_opens) }))
    expect_success(code, out, err, "link run 2")
    expect(#link_opens == 0, "link run 2 opened a source")
    expect(ino_of(link_dest .. "/" .. S2 .. "/fvl/dash") == dash_ino, "dash was not hardlinked")
    expect(ino_of(link_dest .. "/" .. S2 .. "/fvl/gone") == gone_ino, "dangling was not hardlinked")
    expect(ino_of(link_dest .. "/" .. S2 .. "/fvl/rel") == rel_ino, "relative was not hardlinked")
    expect(link_target(link_dest .. "/" .. S2 .. "/fvl/dash") == "-", "hardlinked dash target")
    expect(link_target(link_dest .. "/" .. S2 .. "/fvl/gone") == "nowhere", "hardlinked dangling target")
    expect(link_target(link_dest .. "/" .. S2 .. "/fvl/rel") == "data", "hardlinked relative target")
    expect(ino_of(link_dest .. "/_Base/fvl/data") == data_ino, "symlink hardlink replaced the target")
    expect(stat_mode(link_dest .. "/_Base/fvl/data") == "640", "symlink hardlink changed the target mode")
    expect(stat_mode(link_dest .. "/" .. S2 .. "/fvl/data") == "640", "dated data mode")
    expect_clean(link_dest, "links")

    -- A name containing a tab is created from a bang line.
    local tabbed = case_dir("tab")
    local tab_src = tabbed .. "/src"
    local tab_dest = tabbed .. "/dest"
    mkdir_p(tab_dest)
    local tab_name = "a\tb"
    write_file(tab_src .. "/fvl/" .. tab_name, "tab\n")
    sh("chmod 755 " .. sh_quote(tab_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(tab_src .. "/fvl/" .. tab_name))
    local tab_index = write_listing(tabbed, S1, {
        { abs = tab_src .. "/fvl", listing = "/fvl" },
        { abs = tab_src .. "/fvl/" .. tab_name, listing = "/fvl/" .. tab_name },
    })
    local tab_text = read_all(tab_index)
    expect(tab_text:find("\\t", 1, true) ~= nil, "tab listing was not a bang escape")
    expect(tab_text:find("!", 1, true) == 1 or tab_text:find("\n!", 1, true) ~= nil,
        "tab listing missed the bang")
    code, out, err = run_perform(config_for(tab_index, { tab_dest }, {
        source_map = map_of(tab_src),
    }), {}, user_fs())
    expect_success(code, out, err, "tab")
    expect_file(tab_dest .. "/_Base/fvl/" .. tab_name, "tab\n", "tab bytes")
    expect_clean(tab_dest, "tab")

    -- The ancestor between the snapshot root and the shallowest record is created.
    local ancestor = case_dir("ancestor")
    local anc_src = ancestor .. "/src"
    local anc_dest = ancestor .. "/dest"
    mkdir_p(anc_dest)
    write_file(anc_src .. "/fvl/a/readme", "nested\n")
    sh("chmod 755 " .. sh_quote(anc_src .. "/fvl"))
    sh("chmod 755 " .. sh_quote(anc_src .. "/fvl/a"))
    sh("chmod 644 " .. sh_quote(anc_src .. "/fvl/a/readme"))
    code, out, err = run_perform(config_for(write_listing(ancestor, S1, {
        { abs = anc_src .. "/fvl/a", listing = "/fvl/a" },
        { abs = anc_src .. "/fvl/a/readme", listing = "/fvl/a/readme" },
    }), { anc_dest }, { source_map = map_of(anc_src) }), {}, user_fs())
    expect_success(code, out, err, "ancestor")
    local anc_attr = lfs.symlinkattributes(anc_dest .. "/_Base/fvl")
    expect(anc_attr ~= nil and anc_attr.mode == "directory", "ancestor /fvl was not created")
    expect_file(anc_dest .. "/_Base/fvl/a/readme", "nested\n", "ancestor file")
    expect_clean(anc_dest, "ancestor")

    -- A path omitted under the limit stays in _Base and is absent from the date.
    local omit = case_dir("omit")
    local omit_src = omit .. "/src"
    local omit_dest = omit .. "/dest"
    mkdir_p(omit_dest)
    write_file(omit_src .. "/fvl/readme", "keep\n")
    write_file(omit_src .. "/fvl/old", "gone\n")
    sh("chmod 755 " .. sh_quote(omit_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(omit_src .. "/fvl/readme"))
    sh("chmod 644 " .. sh_quote(omit_src .. "/fvl/old"))
    code, out, err = run_perform(config_for(write_listing(omit, S1, {
        { abs = omit_src .. "/fvl", listing = "/fvl" },
        { abs = omit_src .. "/fvl/old", listing = "/fvl/old" },
        { abs = omit_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { omit_dest }, { source_map = map_of(omit_src) }), {}, user_fs())
    expect_success(code, out, err, "omit run 1")
    local old_ino = ino_of(omit_dest .. "/_Base/fvl/old")
    code, out, err = run_perform(config_for(write_listing(omit, S2, {
        { abs = omit_src .. "/fvl", listing = "/fvl" },
        { abs = omit_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { omit_dest }, { source_map = map_of(omit_src) }), {}, user_fs())
    expect_success(code, out, err, "omit run 2")
    expect(lfs.symlinkattributes(omit_dest .. "/" .. S2 .. "/fvl/old") == nil, "omit published old")
    expect(ino_of(omit_dest .. "/_Base/fvl/old") == old_ino, "omit deleted _Base")
    expect_file(omit_dest .. "/_Base/fvl/old", "gone\n", "omit _Base bytes")
    expect_file(omit_dest .. "/" .. S2 .. "/fvl/readme", "keep\n", "omit kept file")
    expect_clean(omit_dest, "omit")

    -- Seam: a short read leaves the partial, does not rename, and keeps _Base.
    local short = case_dir("short-seam")
    local short_src = short .. "/src"
    local short_dest = short .. "/dest"
    mkdir_p(short_dest)
    write_file(short_src .. "/fvl/readme", "old\n")
    sh("chmod 755 " .. sh_quote(short_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(short_src .. "/fvl/readme"))
    code, out, err = run_perform(config_for(write_listing(short, S1, {
        { abs = short_src .. "/fvl", listing = "/fvl" },
        { abs = short_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { short_dest }, { source_map = map_of(short_src) }), {}, user_fs())
    expect_success(code, out, err, "short seam base")
    local short_ino = ino_of(short_dest .. "/_Base/fvl/readme")
    write_file(short_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(short_src .. "/fvl/readme"))
    local short_opens = {}
    code, out, err = run_perform(config_for(write_listing(short, S2, {
        { abs = short_src .. "/fvl", listing = "/fvl" },
        { abs = short_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { short_dest }, { source_map = map_of(short_src) }), {}, user_fs({
        open_source = function(path)
            short_opens[#short_opens + 1] = path
            return {
                read = function()
                    return "x"
                end,
                close = function()
                    return true
                end,
            }
        end,
    }))
    expect_warn(code, out, err, "source is shorter than the listing: " .. short_src .. "/fvl/readme (skipped)", "short seam")
    expect(#short_opens == 1, "short seam opens " .. tostring(#short_opens))
    expect(lfs.symlinkattributes(short_dest .. "/" .. S2) ~= nil, "short seam published")
    expect(ino_of(short_dest .. "/_Base/fvl/readme") == short_ino, "short seam moved _Base")
    expect_file(short_dest .. "/_Base/fvl/readme", "old\n", "short seam _Base bytes")
    local short_parts = partial_dirs(short_dest)
    expect(#short_parts == 0, "short seam partial " .. table.concat(short_parts, ","))
    expect(lfs.symlinkattributes(short_dest .. "/.casually_backup.lock") == nil,
        "short seam left a lock")
    expect(err:find("owner not applied", 1, true) ~= nil, "short seam printed a warning")

    -- A real truncate is shorter than the listing. The real open path reports it.
    local trunc = case_dir("truncate")
    local trunc_src = trunc .. "/src"
    local trunc_dest = trunc .. "/dest"
    mkdir_p(trunc_dest)
    write_file(trunc_src .. "/fvl/readme", "old\n")
    sh("chmod 755 " .. sh_quote(trunc_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(trunc_src .. "/fvl/readme"))
    code, out, err = run_perform(config_for(write_listing(trunc, S1, {
        { abs = trunc_src .. "/fvl", listing = "/fvl" },
        { abs = trunc_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { trunc_dest }, { source_map = map_of(trunc_src) }), {}, user_fs())
    expect_success(code, out, err, "truncate base")
    local trunc_ino = ino_of(trunc_dest .. "/_Base/fvl/readme")
    write_file(trunc_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(trunc_src .. "/fvl/readme"))
    local trunc_index = write_listing(trunc, S2, {
        { abs = trunc_src .. "/fvl", listing = "/fvl" },
        { abs = trunc_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    write_file(trunc_src .. "/fvl/readme", "he")
    code, out, err = run_perform(config_for(trunc_index, { trunc_dest }, {
        source_map = map_of(trunc_src),
    }), {}, user_fs())
    expect_warn(code, out, err, "source is shorter than the listing: " .. trunc_src .. "/fvl/readme (skipped)", "truncate")
    expect(lfs.symlinkattributes(trunc_dest .. "/" .. S2) ~= nil, "truncate published")
    expect(ino_of(trunc_dest .. "/_Base/fvl/readme") == trunc_ino, "truncate moved _Base")
    expect_file(trunc_dest .. "/_Base/fvl/readme", "old\n", "truncate _Base bytes")
    local trunc_parts = partial_dirs(trunc_dest)
    expect(#trunc_parts == 0, "truncate partial " .. table.concat(trunc_parts, ","))
    expect(lfs.symlinkattributes(trunc_dest .. "/.casually_backup.lock") == nil,
        "truncate left a lock")

    -- The source is longer than the listing says.
    local longer = case_dir("longer")
    local long_src = longer .. "/src"
    local long_dest = longer .. "/dest"
    mkdir_p(long_dest)
    write_file(long_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(long_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(long_src .. "/fvl/readme"))
    code, out, err = run_perform(config_for(write_listing(longer, S1, {
        { abs = long_src .. "/fvl", listing = "/fvl" },
        { abs = long_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { long_dest }, { source_map = map_of(long_src) }), {}, user_fs())
    expect_success(code, out, err, "longer base")
    local long_ino = ino_of(long_dest .. "/_Base/fvl/readme")
    code, out, err = run_perform(config_for(write_listing(longer, S2, {
        { abs = long_src .. "/fvl", listing = "/fvl" },
        { abs = long_src .. "/fvl/readme", listing = "/fvl/readme", size = 4 },
    }), { long_dest }, { source_map = map_of(long_src) }), {}, user_fs())
    expect_warn(code, out, err, "source is longer than the listing: " .. long_src .. "/fvl/readme (skipped)", "longer")
    expect(lfs.symlinkattributes(long_dest .. "/" .. S2) ~= nil, "longer published")
    expect(ino_of(long_dest .. "/_Base/fvl/readme") == long_ino, "longer moved _Base")
    expect_file(long_dest .. "/_Base/fvl/readme", "hello\n", "longer _Base bytes")
    local long_parts = partial_dirs(long_dest)
    expect(#long_parts == 0, "longer partial " .. table.concat(long_parts, ","))
    expect(lfs.symlinkattributes(long_dest .. "/.casually_backup.lock") == nil,
        "longer left a lock")

    -- A write error on the second destination publishes neither snapshot.
    local disks = case_dir("write")
    local disk_src = disks .. "/src"
    local w1 = disks .. "/d1"
    local w2 = disks .. "/d2"
    mkdir_p(w1)
    mkdir_p(w2)
    write_file(disk_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(disk_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(disk_src .. "/fvl/readme"))
    local write_opens = {}
    local write_path = w2 .. "/_Base.w2.partial/fvl/readme"
    code, out, err = run_perform(config_for(write_listing(disks, S1, {
        { abs = disk_src .. "/fvl", listing = "/fvl" },
        { abs = disk_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { w1, w2 }, { source_map = map_of(disk_src) }), {}, user_fs({
        pid = "w2",
        open_source = counting_open(write_opens),
        open_dest = function(path, dest)
            if dest == w2 then
                return {
                    write = function()
                        return nil, "disk full"
                    end,
                    flush = function()
                        return true
                    end,
                    close = function()
                        return true
                    end,
                }
            end
            return io.open(path, "wb")
        end,
    }))
    expect_stderr(code, out, err, 2, "cannot write " .. write_path .. ": disk full", "write")
    expect(#write_opens == 1, "write opens " .. tostring(#write_opens))
    expect(lfs.symlinkattributes(w1 .. "/_Base") == nil, "write published dest 1")
    expect(lfs.symlinkattributes(w2 .. "/_Base") == nil, "write published dest 2")
    expect(lfs.symlinkattributes(w1 .. "/_Base.w2.partial") ~= nil, "write removed dest 1 partial")
    expect(lfs.symlinkattributes(w2 .. "/_Base.w2.partial") ~= nil, "write removed dest 2 partial")
    expect(lfs.symlinkattributes(w1 .. "/.casually_backup.lock") == nil, "write left dest 1 lock")
    expect(lfs.symlinkattributes(w2 .. "/.casually_backup.lock") == nil, "write left dest 2 lock")

    -- Omission refusal publishes nothing and leaves no lock.
    local mass = case_dir("mass")
    local mass_src = mass .. "/src"
    local mass_dest = mass .. "/dest"
    mkdir_p(mass_dest)
    write_file(mass_src .. "/fvl/a/keep", "keep\n")
    write_file(mass_src .. "/fvl/a/old1", "one\n")
    write_file(mass_src .. "/fvl/a/old2", "two\n")
    sh("chmod 755 " .. sh_quote(mass_src .. "/fvl"))
    sh("chmod 755 " .. sh_quote(mass_src .. "/fvl/a"))
    sh("chmod 644 " .. sh_quote(mass_src .. "/fvl/a/keep"))
    sh("chmod 644 " .. sh_quote(mass_src .. "/fvl/a/old1"))
    sh("chmod 644 " .. sh_quote(mass_src .. "/fvl/a/old2"))
    local mass_map = map_of(mass_src)
    code, out, err = run_perform(config_for(write_listing(mass, S1, {
        { abs = mass_src .. "/fvl", listing = "/fvl" },
        { abs = mass_src .. "/fvl/a", listing = "/fvl/a" },
        { abs = mass_src .. "/fvl/a/keep", listing = "/fvl/a/keep" },
        { abs = mass_src .. "/fvl/a/old1", listing = "/fvl/a/old1" },
        { abs = mass_src .. "/fvl/a/old2", listing = "/fvl/a/old2" },
    }), { mass_dest }, { source_map = mass_map }), {}, user_fs())
    expect_success(code, out, err, "mass base")
    local mass_opened = false
    code, out, err = run_perform(config_for(write_listing(mass, S2, {
        { abs = mass_src .. "/fvl", listing = "/fvl" },
        { abs = mass_src .. "/fvl/a", listing = "/fvl/a" },
        { abs = mass_src .. "/fvl/a/keep", listing = "/fvl/a/keep" },
    }), { mass_dest }, {
        source_map = mass_map,
        omit_limit = 1,
        omit_fraction = 0.02,
    }), {}, user_fs({
        open_source = function(path)
            mass_opened = true
            return io.open(path, "rb")
        end,
    }))
    expect_stderr(code, out, err, 1,
        "too many omissions: " .. mass_dest .. " omitted 2 limit 1 fraction 0.02", "mass")
    expect(mass_opened == false, "mass refusal opened a source")
    expect(lfs.symlinkattributes(mass_dest .. "/" .. S2) == nil, "mass published")
    expect(#partial_dirs(mass_dest) == 0, "mass left a partial")
    expect(lfs.symlinkattributes(mass_dest .. "/.casually_backup.lock") == nil, "mass left a lock")
    expect_file(mass_dest .. "/_Base/fvl/a/old1", "one\n", "mass old1")
    expect_file(mass_dest .. "/_Base/fvl/a/old2", "two\n", "mass old2")
    expect_file(mass_dest .. "/_Base/fvl/a/keep", "keep\n", "mass keep")

    -- The stamp directory already exists. No partial is created.
    local clash = case_dir("clash")
    local clash_src = clash .. "/src"
    local clash_dest = clash .. "/dest"
    mkdir_p(clash_dest)
    write_file(clash_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(clash_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(clash_src .. "/fvl/readme"))
    local clash_rows = {
        { abs = clash_src .. "/fvl", listing = "/fvl" },
        { abs = clash_src .. "/fvl/readme", listing = "/fvl/readme" },
    }
    code, out, err = run_perform(config_for(write_listing(clash, S1, clash_rows), { clash_dest }, {
        source_map = map_of(clash_src),
    }), {}, user_fs())
    expect_success(code, out, err, "clash base")
    write_file(clash_dest .. "/" .. S2 .. "/marker", "keep\n")
    local clash_opened = false
    code, out, err = run_perform(config_for(write_listing(clash, S2, clash_rows), { clash_dest }, {
        source_map = map_of(clash_src),
    }), {}, user_fs({
        open_source = function(path)
            clash_opened = true
            return io.open(path, "rb")
        end,
    }))
    expect_stderr(code, out, err, 1, "snapshot exists: " .. clash_dest .. "/" .. S2, "clash")
    expect(clash_opened == false, "clash opened a source")
    expect(#partial_dirs(clash_dest) == 0, "clash left a partial")
    expect(lfs.symlinkattributes(clash_dest .. "/.casually_backup.lock") == nil, "clash left a lock")
    expect_file(clash_dest .. "/" .. S2 .. "/marker", "keep\n", "clash rewrote the stamp")
    expect_file(clash_dest .. "/_Base/fvl/readme", "hello\n", "clash _Base")

    -- Dry-run prints the plan and does not take a lock or remove a partial.
    local dry = case_dir("dry")
    local dry_src = dry .. "/src"
    local dry_dest = dry .. "/dest"
    mkdir_p(dry_dest)
    write_file(dry_src .. "/fvl/keep", "keep\n")
    write_file(dry_src .. "/fvl/old", "old\n")
    sh("chmod 755 " .. sh_quote(dry_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(dry_src .. "/fvl/keep"))
    sh("chmod 644 " .. sh_quote(dry_src .. "/fvl/old"))
    sh("ln -s keep " .. sh_quote(dry_src .. "/fvl/link"))
    local dry_map = map_of(dry_src)
    code, out, err = run_perform(config_for(write_listing(dry, S1, {
        { abs = dry_src .. "/fvl", listing = "/fvl" },
        { abs = dry_src .. "/fvl/keep", listing = "/fvl/keep" },
        { abs = dry_src .. "/fvl/link", listing = "/fvl/link" },
        { abs = dry_src .. "/fvl/old", listing = "/fvl/old" },
    }), { dry_dest }, { source_map = dry_map }), {}, user_fs())
    expect_success(code, out, err, "dry base")
    write_file(dry_src .. "/fvl/new", "new\n")
    sh("chmod 644 " .. sh_quote(dry_src .. "/fvl/new"))
    sh("rm " .. sh_quote(dry_src .. "/fvl/link"))
    sh("ln -s other " .. sh_quote(dry_src .. "/fvl/link"))
    write_file(dry_dest .. "/stale.9.partial/marker", "partial\n")
    plant_lock(dry_dest, dead_pid())
    local dry_index = write_listing(dry, S2, {
        { abs = dry_src .. "/fvl", listing = "/fvl" },
        { abs = dry_src .. "/fvl/keep", listing = "/fvl/keep" },
        { abs = dry_src .. "/fvl/link", listing = "/fvl/link" },
        { abs = dry_src .. "/fvl/new", listing = "/fvl/new" },
    })
    local dry_cfg = config_for(dry_index, { dry_dest }, { source_map = dry_map })
    local dry_plan = api.plan(dry_cfg, user_fs())
    expect(dry_plan ~= nil, "dry plan")
    local dry_opened = false
    code, out, err = run_perform(dry_cfg, { dry_run = true }, user_fs({
        open_source = function()
            dry_opened = true
            return nil, "dry-run opened a source"
        end,
    }))
    expect(code == 0, "dry exit " .. tostring(code) .. " " .. tostring(err))
    expect(dry_plan ~= nil and out == dry_plan.text, "dry stdout\n" .. tostring(out))
    expect(err == OWNER, "dry stderr " .. tostring(err))
    expect(out:find("\nplan ", 1, true) ~= nil, "dry plan line")
    expect(out:find("skip=0", 1, true) ~= nil, "dry skip")
    expect(out:find("\nhardlink ", 1, true) ~= nil, "dry hardlink")
    expect(out:find("\ncopy ", 1, true) ~= nil, "dry copy")
    expect(out:find("\nsymlink ", 1, true) ~= nil, "dry symlink")
    expect(out:find("\nomit ", 1, true) ~= nil, "dry omit")
    expect(dry_opened == false, "dry opened a source")
    expect(lfs.symlinkattributes(dry_dest .. "/" .. S2) == nil, "dry published")
    expect_file(dry_dest .. "/stale.9.partial/marker", "partial\n", "dry removed a partial")
    expect(read_all(dry_dest .. "/.casually_backup.lock/owner") == dead_pid() .. "\n",
        "dry took the lock")
    expect_file(dry_dest .. "/_Base/fvl/old", "old\n", "dry changed _Base")

    -- A live lock is not stolen. The other destination's lock is released.
    local live = case_dir("live")
    local live_src = live .. "/src"
    local live1 = live .. "/d1"
    local live2 = live .. "/d2"
    mkdir_p(live1)
    mkdir_p(live2)
    write_file(live_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(live_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(live_src .. "/fvl/readme"))
    write_file(live1 .. "/marker", "one\n")
    write_file(live2 .. "/marker", "two\n")
    local live_pid = self_pid()
    plant_lock(live2, live_pid)
    local live_opened = false
    code, out, err = run_perform(config_for(write_listing(live, S1, {
        { abs = live_src .. "/fvl", listing = "/fvl" },
        { abs = live_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { live1, live2 }, { source_map = map_of(live_src) }), {}, user_fs({
        open_source = function(path)
            live_opened = true
            return io.open(path, "rb")
        end,
    }))
    expect_stderr(code, out, err, 1,
        "destination locked: " .. live2 .. " (pid " .. live_pid .. ")", "live")
    expect(live_opened == false, "live lock opened a source")
    expect(lfs.symlinkattributes(live1 .. "/_Base") == nil, "live published dest 1")
    expect(lfs.symlinkattributes(live2 .. "/_Base") == nil, "live published dest 2")
    expect(#partial_dirs(live1) == 0 and #partial_dirs(live2) == 0, "live left a partial")
    expect(lfs.symlinkattributes(live1 .. "/.casually_backup.lock") == nil,
        "live left dest 1 locked")
    expect(read_all(live2 .. "/.casually_backup.lock/owner") == live_pid .. "\n",
        "live lock was stolen")
    expect(lfs.symlinkattributes(live2 .. "/.casually_backup.lock/lockfile.lfs") ~= nil,
        "live lockfile was removed")
    expect_file(live1 .. "/marker", "one\n", "live dest 1 marker")
    expect_file(live2 .. "/marker", "two\n", "live dest 2 marker")

    -- A stale lock whose pid is dead is cleared and the run proceeds.
    local stale = case_dir("stale")
    local stale_src = stale .. "/src"
    local stale_dest = stale .. "/dest"
    mkdir_p(stale_dest)
    write_file(stale_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(stale_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(stale_src .. "/fvl/readme"))
    local stale_dir = plant_lock(stale_dest, dead_pid())
    write_file(stale_dir .. "/junk", "junk\n")
    code, out, err = run_perform(config_for(write_listing(stale, S1, {
        { abs = stale_src .. "/fvl", listing = "/fvl" },
        { abs = stale_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { stale_dest }, { source_map = map_of(stale_src) }), {}, user_fs())
    expect_success(code, out, err, "stale")
    expect(lfs.symlinkattributes(stale_dir) == nil, "stale lock remained")
    expect_file(stale_dest .. "/_Base/fvl/readme", "hello\n", "stale bytes")
    expect_clean(stale_dest, "stale")

    -- A leftover partial directory is removed and is not published.
    local left = case_dir("leftover")
    local left_src = left .. "/src"
    local left_dest = left .. "/dest"
    mkdir_p(left_dest)
    write_file(left_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(left_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(left_src .. "/fvl/readme"))
    write_file(left_dest .. "/crash.4242.partial/MARKER", "secret\n")
    write_file(left_dest .. "/note.partial", "keep-me\n")
    code, out, err = run_perform(config_for(write_listing(left, S1, {
        { abs = left_src .. "/fvl", listing = "/fvl" },
        { abs = left_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { left_dest }, { source_map = map_of(left_src) }), {}, user_fs())
    expect_success(code, out, err, "leftover")
    expect(lfs.symlinkattributes(left_dest .. "/crash.4242.partial") == nil,
        "leftover partial was published")
    expect_file(left_dest .. "/note.partial", "keep-me\n", "leftover removed a partial file")
    expect_file(left_dest .. "/_Base/fvl/readme", "hello\n", "leftover bytes")
    expect(read_all(left_dest .. "/_Base/MARKER") == nil, "leftover published MARKER")
    expect(read_all(left_dest .. "/_Base/fvl/MARKER") == nil, "leftover published MARKER under fvl")
    expect_clean(left_dest, "leftover")

    -- Non-root: one owner warning, no chown, and a later run still hardlinks.
    local owned = case_dir("nonroot")
    local owned_src = owned .. "/src"
    local owned_dest = owned .. "/dest"
    mkdir_p(owned_dest)
    write_file(owned_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(owned_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(owned_src .. "/fvl/readme"))
    local owned_attr = lfs.symlinkattributes(owned_src .. "/fvl/readme")
    local owned_uid = math.tointeger(owned_attr.uid)
    local other_id = owned_uid == 2 and 3 or 2
    local owned_rows = {
        { abs = owned_src .. "/fvl", listing = "/fvl" },
        { abs = owned_src .. "/fvl/readme", listing = "/fvl/readme" },
    }
    local chown_calls = {}
    local function chown_spy(uid, gid, payload)
        chown_calls[#chown_calls + 1] = { uid = uid, gid = gid, payload = payload }
        return true
    end
    local nonroot_commands
    nonroot_commands = collect_popen(function()
        code, out, err = run_perform(config_for(write_listing(owned, S1, owned_rows), { owned_dest }, {
            source_map = map_of(owned_src),
        }), {}, user_fs({ chown = chown_spy }))
    end)
    expect_success(code, out, err, "nonroot run 1")
    expect(#chown_calls == 0, "nonroot run 1 called chown")
    for i = 1, #nonroot_commands do
        expect(nonroot_commands[i]:find("chown", 1, true) == nil,
            "nonroot command " .. nonroot_commands[i])
    end
    local owned_ino = ino_of(owned_dest .. "/_Base/fvl/readme")
    local owned_opens = {}
    nonroot_commands = collect_popen(function()
        code, out, err = run_perform(config_for(write_listing(owned, S2, {
            { abs = owned_src .. "/fvl", listing = "/fvl", user = other_id, group = other_id },
            { abs = owned_src .. "/fvl/readme", listing = "/fvl/readme", user = other_id, group = other_id },
        }), { owned_dest }, { source_map = map_of(owned_src) }), {}, user_fs({
            chown = chown_spy,
            open_source = counting_open(owned_opens),
        }))
    end)
    expect_success(code, out, err, "nonroot run 2")
    expect(#chown_calls == 0, "nonroot run 2 called chown")
    expect(#owned_opens == 0, "nonroot run 2 opened a source")
    expect(ino_of(owned_dest .. "/" .. S2 .. "/fvl/readme") == owned_ino,
        "nonroot later run did not hardlink")
    for i = 1, #nonroot_commands do
        expect(nonroot_commands[i]:find("chown", 1, true) == nil,
            "nonroot later command " .. nonroot_commands[i])
    end
    expect_clean(owned_dest, "nonroot")

    -- chmod NUL batch: space, newline, and setuid arrive intact. A hardlink does not.
    local bits = case_dir("chmod")
    local bit_src = bits .. "/src"
    local bit_dest = bits .. "/dest"
    mkdir_p(bit_dest)
    write_file(bit_src .. "/fvl/keep", "keep\n")
    sh("chmod 755 " .. sh_quote(bit_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(bit_src .. "/fvl/keep"))
    code, out, err = run_perform(config_for(write_listing(bits, S1, {
        { abs = bit_src .. "/fvl", listing = "/fvl" },
        { abs = bit_src .. "/fvl/keep", listing = "/fvl/keep" },
    }), { bit_dest }, { source_map = map_of(bit_src) }), {}, user_fs())
    expect_success(code, out, err, "chmod base")
    local keep_ino = ino_of(bit_dest .. "/_Base/fvl/keep")
    local space_name = "my file"
    local nl_name = "my\nfile"
    write_file(bit_src .. "/fvl/" .. space_name, "space\n")
    write_file(bit_src .. "/fvl/" .. nl_name, "nl\n")
    write_file(bit_src .. "/fvl/setuid", "suid\n")
    sh("chmod 600 " .. sh_quote(bit_src .. "/fvl/" .. space_name))
    sh("chmod 640 " .. sh_quote(bit_src .. "/fvl/" .. nl_name))
    sh("chmod 644 " .. sh_quote(bit_src .. "/fvl/setuid"))
    local chmod_calls = {}
    local chmod_commands
    local bit_fs = user_fs({
        pid = "p5",
        chmod = function(mode, payload)
            chmod_calls[#chmod_calls + 1] = { mode = mode, payload = payload }
            return api.metadata_batch("chmod", mode, payload)
        end,
        chown = function()
            fail("chmod case called chown")
            return true
        end,
    })
    chmod_commands = collect_popen(function()
        code, out, err = run_perform(config_for(write_listing(bits, S2, {
            { abs = bit_src .. "/fvl", listing = "/fvl" },
            { abs = bit_src .. "/fvl/keep", listing = "/fvl/keep" },
            { abs = bit_src .. "/fvl/" .. nl_name, listing = "/fvl/" .. nl_name },
            { abs = bit_src .. "/fvl/" .. space_name, listing = "/fvl/" .. space_name },
            {
                abs = bit_src .. "/fvl/setuid",
                listing = "/fvl/setuid",
                mode = tonumber("4755", 8),
            },
        }), { bit_dest }, { source_map = map_of(bit_src) }), {}, bit_fs)
    end)
    expect_success(code, out, err, "chmod run")
    local partial_root = bit_dest .. "/" .. S2 .. ".p5.partial"
    local payloads = {}
    for i = 1, #chmod_calls do
        payloads[i] = chmod_calls[i].payload
    end
    expect(has_part(payloads, partial_root .. "/fvl/" .. space_name), "space path was split")
    expect(has_part(payloads, partial_root .. "/fvl/" .. nl_name), "newline path was split")
    expect(has_part(payloads, partial_root .. "/fvl/setuid"), "setuid path missing")
    expect(not has_part(payloads, partial_root .. "/fvl/keep"), "hardlink entered the chmod batch")
    expect(not has_part(payloads, bit_dest .. "/_Base/fvl/keep"), "_Base entered the chmod batch")
    local saw_setuid = false
    for i = 1, #chmod_calls do
        if chmod_calls[i].mode == tonumber("4755", 8) then
            saw_setuid = true
        end
    end
    expect(saw_setuid, "setuid mode was not queued")
    expect(ino_of(bit_dest .. "/" .. S2 .. "/fvl/keep") == keep_ino, "chmod case did not hardlink keep")
    expect(stat_mode(bit_dest .. "/_Base/fvl/keep") == "644", "chmod changed the hardlink")
    expect(stat_mode(bit_dest .. "/" .. S2 .. "/fvl/" .. space_name) == "600", "space mode")
    expect(stat_mode(bit_dest .. "/" .. S2 .. "/fvl/" .. nl_name) == "640", "newline mode")
    expect(stat_mode(bit_dest .. "/" .. S2 .. "/fvl/setuid") == "4755",
        "setuid mode " .. tostring(stat_mode(bit_dest .. "/" .. S2 .. "/fvl/setuid")))
    for i = 1, #chmod_commands do
        expect(chmod_commands[i]:find("chown", 1, true) == nil, "chmod case chown " .. chmod_commands[i])
        expect(chmod_commands[i]:match("^xargs %-0 chmod %d+ %-%-$") ~= nil,
            "chmod command " .. chmod_commands[i])
    end
    expect_clean(bit_dest, "chmod")

    -- Root applies chown -h with the resolved ids. The command carries no path.
    local root_case = case_dir("root-chown")
    local root_src = root_case .. "/src"
    local root_dest = root_case .. "/dest"
    mkdir_p(root_dest)
    write_file(root_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(root_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(root_src .. "/fvl/readme"))
    local root_attr = lfs.symlinkattributes(root_src .. "/fvl/readme")
    local root_uid = math.tointeger(root_attr.uid)
    local root_gid = math.tointeger(root_attr.gid)
    local root_commands
    root_commands = collect_popen(function()
        code, out, err = run_perform(config_for(write_listing(root_case, S1, {
            { abs = root_src .. "/fvl", listing = "/fvl" },
            { abs = root_src .. "/fvl/readme", listing = "/fvl/readme" },
        }), { root_dest }, { source_map = map_of(root_src) }), {}, user_fs({
            euid = 0,
            getent = root_getent,
        }))
    end)
    expect(code == 0, "root exit " .. tostring(code) .. " " .. tostring(err))
    expect(out == "", "root stdout " .. tostring(out))
    expect(err == "", "root stderr " .. tostring(err))
    local chown_command = string.format("xargs -0 chown -h %d:%d --", root_uid, root_gid)
    local saw_chown = false
    for i = 1, #root_commands do
        if root_commands[i] == chown_command then
            saw_chown = true
        end
        expect(root_commands[i]:find(root_dest, 1, true) == nil,
            "root command contains a path " .. root_commands[i])
        expect(root_commands[i]:find("/fvl", 1, true) == nil,
            "root command contains a listing path " .. root_commands[i])
    end
    expect(saw_chown, "root chown command missing\n" .. table.concat(root_commands, "\n"))
    expect_file(root_dest .. "/_Base/fvl/readme", "hello\n", "root bytes")
    expect(stat_mode(root_dest .. "/_Base/fvl/readme") == "644", "root mode")
    expect_clean(root_dest, "root")

    -- An owner-only change is a new inode. The old snapshot's owner stays.
    local shift = case_dir("owner-shift")
    local shift_src = shift .. "/src"
    local shift_dest = shift .. "/dest"
    mkdir_p(shift_dest)
    write_file(shift_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(shift_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(shift_src .. "/fvl/readme"))
    code, out, err = run_perform(config_for(write_listing(shift, S1, {
        { abs = shift_src .. "/fvl", listing = "/fvl" },
        { abs = shift_src .. "/fvl/readme", listing = "/fvl/readme" },
    }), { shift_dest }, { source_map = map_of(shift_src) }), {}, user_fs())
    expect_success(code, out, err, "owner base")
    local shift_old = lfs.symlinkattributes(shift_dest .. "/_Base/fvl/readme")
    local shift_dir = lfs.symlinkattributes(shift_dest .. "/_Base/fvl")
    local shift_uid = math.tointeger(shift_old.uid)
    local shift_gid = math.tointeger(shift_old.gid)
    local shift_other = shift_uid == 2 and 3 or 2
    local shift_calls = {}
    local shift_commands
    shift_commands = collect_popen(function()
        code, out, err = run_perform(config_for(write_listing(shift, S2, {
            { abs = shift_src .. "/fvl", listing = "/fvl", user = shift_other, group = shift_other },
            {
                abs = shift_src .. "/fvl/readme",
                listing = "/fvl/readme",
                user = shift_other,
                group = shift_other,
            },
        }), { shift_dest }, { source_map = map_of(shift_src) }), {}, user_fs({
            euid = 0,
            getent = root_getent,
            pid = "own5",
            chown = function(uid, gid, payload)
                shift_calls[#shift_calls + 1] = { uid = uid, gid = gid, payload = payload }
                return true
            end,
        }))
    end)
    expect(code == 0, "owner shift exit " .. tostring(code) .. " " .. tostring(err))
    expect(out == "", "owner shift stdout")
    expect(err == "", "owner shift stderr " .. tostring(err))
    local shift_new = lfs.symlinkattributes(shift_dest .. "/" .. S2 .. "/fvl/readme")
    local shift_old_after = lfs.symlinkattributes(shift_dest .. "/_Base/fvl/readme")
    local shift_dir_after = lfs.symlinkattributes(shift_dest .. "/_Base/fvl")
    expect(shift_new ~= nil and shift_new.ino ~= shift_old.ino, "owner-only hardlinked")
    expect(shift_old_after.ino == shift_old.ino, "owner-only moved the old inode")
    expect(math.tointeger(shift_old_after.uid) == shift_uid, "old uid changed")
    expect(math.tointeger(shift_old_after.gid) == shift_gid, "old gid changed")
    expect(math.tointeger(shift_dir_after.uid) == math.tointeger(shift_dir.uid), "old dir uid changed")
    expect(math.tointeger(shift_dir_after.gid) == math.tointeger(shift_dir.gid), "old dir gid changed")
    expect(#shift_calls >= 1, "owner shift did not chown")
    local shift_root = shift_dest .. "/" .. S2 .. ".own5.partial"
    for i = 1, #shift_calls do
        expect(shift_calls[i].uid == shift_other, "chown uid " .. tostring(shift_calls[i].uid))
        expect(shift_calls[i].gid == shift_other, "chown gid " .. tostring(shift_calls[i].gid))
        expect(math.type(shift_calls[i].uid) == "integer", "chown uid type")
        local parts = payload_parts(shift_calls[i].payload)
        expect(#parts >= 1, "chown payload empty")
        for j = 1, #parts do
            expect(parts[j]:sub(1, #shift_root) == shift_root,
                "chown path outside the partial " .. parts[j])
            expect(parts[j]:find("/_Base/", 1, true) == nil, "chown touched _Base " .. parts[j])
        end
    end
    for i = 1, #shift_commands do
        expect(shift_commands[i]:find("chown", 1, true) == nil,
            "owner shift also ran " .. shift_commands[i])
    end
    expect_file(shift_dest .. "/_Base/fvl/readme", "hello\n", "owner shift _Base bytes")
    expect_clean(shift_dest, "owner shift")

    -- The executable applies a dry-run and a real snapshot.
    local cli = case_dir("cli")
    local cli_src = cli .. "/src"
    local cli_dest = cli .. "/dest"
    mkdir_p(cli_dest)
    write_file(cli_src .. "/fvl/readme", "cli\n")
    sh("chmod 755 " .. sh_quote(cli_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(cli_src .. "/fvl/readme"))
    local cli_index = write_listing(cli, S1, {
        { abs = cli_src .. "/fvl", listing = "/fvl" },
        { abs = cli_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local cli_argv = {
        "--index", cli_index,
        "--dest", cli_dest,
        "--source-map", "/fvl=" .. cli_src .. "/fvl",
    }
    local function run_cli(args)
        local out_path = os.tmpname()
        local err_path = os.tmpname()
        local cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT " .. sh_quote(exe)
        for i = 1, #args do
            cmd = cmd .. " " .. sh_quote(args[i])
        end
        cmd = cmd .. " > " .. sh_quote(out_path) .. " 2> " .. sh_quote(err_path)
        local ok, how, status = os.execute(cmd)
        local got_out = read_all(out_path) or ""
        local got_err = read_all(err_path) or ""
        os.remove(out_path)
        os.remove(err_path)
        local status_code = 0
        if ok ~= true then
            status_code = status or -1
            if how ~= "exit" then
                status_code = -1
            end
        end
        return status_code, got_out, got_err
    end
    local dry_argv = { "--dry-run" }
    for i = 1, #cli_argv do
        dry_argv[#dry_argv + 1] = cli_argv[i]
    end
    local parsed = api.parse_args(dry_argv)
    expect(parsed ~= nil, "cli parse")
    local loaded = parsed and api.load_config(parsed)
    local cli_plan = loaded and api.plan(loaded)
    code, out, err = run_cli(dry_argv)
    expect(code == 0, "cli dry exit " .. tostring(code) .. " " .. err)
    expect(cli_plan ~= nil and out == cli_plan.text, "cli dry stdout\n" .. out)
    expect(err == OWNER, "cli dry stderr " .. err)
    expect(lfs.symlinkattributes(cli_dest .. "/_Base") == nil, "cli dry published")
    expect(lfs.symlinkattributes(cli_dest .. "/.casually_backup.lock") == nil, "cli dry locked")
    code, out, err = run_cli(cli_argv)
    expect(code == 0, "cli apply exit " .. tostring(code) .. " " .. err)
    expect(out == "", "cli apply stdout " .. out)
    expect(err == OWNER, "cli apply stderr " .. err)
    expect_file(cli_dest .. "/_Base/fvl/readme", "cli\n", "cli bytes")
    expect_clean(cli_dest, "cli")

    -- One parent process and four worker processes publish the same bytes.
    -- A directory whose name matches a file inside it (e.g. dir.c/dir.c)
    -- must not confuse check_source_file into treating the dir as the final
    -- path component. Workers must still copy the inner file.
    local same = case_dir("samename")
    local same_src = same .. "/src"
    local same_dest = same .. "/dest"
    mkdir_p(same_dest)
    write_file(same_src .. "/fvl/scripts/dir.c/dir.c", "content\n")
    sh("chmod 755 " .. sh_quote(same_src .. "/fvl"))
    sh("chmod 755 " .. sh_quote(same_src .. "/fvl/scripts"))
    sh("chmod 755 " .. sh_quote(same_src .. "/fvl/scripts/dir.c"))
    sh("chmod 644 " .. sh_quote(same_src .. "/fvl/scripts/dir.c/dir.c"))
    local same_rows = {
        { abs = same_src .. "/fvl", listing = "/fvl" },
        { abs = same_src .. "/fvl/scripts", listing = "/fvl/scripts" },
        { abs = same_src .. "/fvl/scripts/dir.c", listing = "/fvl/scripts/dir.c" },
        { abs = same_src .. "/fvl/scripts/dir.c/dir.c", listing = "/fvl/scripts/dir.c/dir.c" },
    }
    code, out, err = run_perform(config_for(write_listing(same, S1, same_rows), { same_dest }, {
        source_map = map_of(same_src),
    }), {}, user_fs())
    expect_success(code, out, err, "same-name dir")
    expect_file(same_dest .. "/_Base/fvl/scripts/dir.c/dir.c", "content\n",
        "same-name inner file bytes")
    expect(stat_mode(same_dest .. "/_Base/fvl/scripts/dir.c") == "755", "same-name dir mode")
    expect_clean(same_dest, "same-name dir")

    -- A newline in the name stays inside the framed job. A short source does
    -- not publish. workers=1 stays in the parent and matches the pool.
    local function worker_tree(label, workers)
        local dir = case_dir("workers-" .. label)
        local src = dir .. "/src"
        local d1 = dir .. "/d1"
        local d2 = dir .. "/d2"
        mkdir_p(d1)
        mkdir_p(d2)
        local nl_name = "my\nfile"
        write_file(src .. "/fvl/plain", "plain\n")
        write_file(src .. "/fvl/" .. nl_name, "nl\n")
        sh("chmod 755 " .. sh_quote(src .. "/fvl"))
        sh("chmod 644 " .. sh_quote(src .. "/fvl/plain"))
        sh("chmod 640 " .. sh_quote(src .. "/fvl/" .. nl_name))
        local rows = {
            { abs = src .. "/fvl", listing = "/fvl" },
            { abs = src .. "/fvl/plain", listing = "/fvl/plain" },
            { abs = src .. "/fvl/" .. nl_name, listing = "/fvl/" .. nl_name },
        }
        code, out, err = run_perform(config_for(write_listing(dir, S1, rows), { d1, d2 }, {
            source_map = map_of(src),
            workers = workers,
        }), {}, user_fs())
        expect_success(code, out, err, "workers " .. label)
        expect_file(d1 .. "/_Base/fvl/plain", "plain\n", label .. " d1 plain")
        expect_file(d2 .. "/_Base/fvl/plain", "plain\n", label .. " d2 plain")
        expect_file(d1 .. "/_Base/fvl/" .. nl_name, "nl\n", label .. " d1 newline")
        expect_file(d2 .. "/_Base/fvl/" .. nl_name, "nl\n", label .. " d2 newline")
        expect(stat_mode(d1 .. "/_Base/fvl/" .. nl_name) == "640", label .. " newline mode")
        local a, b = ino_of(d1 .. "/_Base/fvl/plain"), ino_of(d2 .. "/_Base/fvl/plain")
        expect(a ~= nil and b ~= nil and a ~= b, label .. " destinations share plain")
        expect_clean(d1, label .. " d1")
        expect_clean(d2, label .. " d2")
    end
    worker_tree("1", 1)
    worker_tree("4", 4)

    local short_w = case_dir("workers-short")
    local short_src = short_w .. "/src"
    local short_dest = short_w .. "/dest"
    mkdir_p(short_dest)
    write_file(short_src .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(short_src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(short_src .. "/fvl/readme"))
    local short_rows = {
        { abs = short_src .. "/fvl", listing = "/fvl" },
        { abs = short_src .. "/fvl/readme", listing = "/fvl/readme", size = 20 },
    }
    code, out, err = run_perform(config_for(write_listing(short_w, S1, short_rows), { short_dest }, {
        source_map = map_of(short_src),
        workers = 4,
    }), {}, user_fs())
    expect_warn(code, out, err, "source is shorter than the listing: " .. short_src .. "/fvl/readme (skipped)", "workers short")
    expect(lfs.symlinkattributes(short_dest .. "/_Base") ~= nil, "workers short published")
    local short_parts = partial_dirs(short_dest)
    expect(#short_parts == 0, "workers short partial " .. table.concat(short_parts, ","))
    expect(lfs.symlinkattributes(short_dest .. "/.casually_backup.lock") == nil,
        "workers short left a lock")
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

local phase_out = os.tmpname()
local phase_err = os.tmpname()
local phase_cmd = sh_quote(root .. "/test/run.sh") .. " backup 4 > "
    .. sh_quote(phase_out) .. " 2> " .. sh_quote(phase_err)
local pok, phow, pcode = os.execute(phase_cmd)
local function read_phase(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a") or ""
    f:close()
    return text
end
local phase_text = read_phase(phase_out)
local phase_err_text = read_phase(phase_err)
os.remove(phase_out)
os.remove(phase_err)
if pok == true then
    pcode = 0
elseif phow ~= "exit" then
    pcode = -1
end
if pcode ~= 0 or phase_text:find("backup phase 4 gate passed", 1, true) == nil then
    io.stderr:write("backup phase 4 did not pass, exit " .. tostring(pcode) .. "\n")
    io.stderr:write(phase_err_text)
    io.stderr:write(phase_text)
    os.exit(1)
end

io.stdout:write("backup phase 5 gate passed\n")
