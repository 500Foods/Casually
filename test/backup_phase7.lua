-- Phase 7 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 7
-- No new behavior. The entry point has to meet the snapshot contract.
-- The terminal check stays the phase 6 pty.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase7.lua")
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

expect(type(api.main) == "function", "main is exported")
expect(type(index.format_line) == "function", "format_line is exported")

local S1 = "20261008-1430"
local S2 = "20261009-0900"
local S3 = "20261010-1200"
local OWNER = "casually_backup: owner not applied\n"
local SETUID_MODE = tonumber("4755", 8)

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
        user = overrides.user ~= nil and overrides.user or attr.uid,
        group = overrides.group ~= nil and overrides.group or attr.gid,
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

local function json_string(s)
    return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function write_config(path, cfg)
    local dests = {}
    for i = 1, #cfg.destinations do
        dests[i] = json_string(cfg.destinations[i])
    end
    local maps = {}
    for i = 1, #(cfg.source_map or {}) do
        local item = cfg.source_map[i]
        maps[i] = '{"alias":' .. json_string(item.alias)
            .. ',"path":' .. json_string(item.path) .. "}"
    end
    local excluded = {}
    for i = 1, #(cfg.exclude or {}) do
        excluded[i] = json_string(cfg.exclude[i])
    end
    local limit = cfg.omit_limit
    if limit == nil then
        limit = 1000
    end
    local fraction = cfg.omit_fraction
    if fraction == nil then
        fraction = 0.02
    end
    local text = "{"
        .. '"index":' .. json_string(cfg.index)
        .. ',"destinations":[' .. table.concat(dests, ",") .. "]"
        .. ',"source_map":[' .. table.concat(maps, ",") .. "]"
        .. ',"exclude":[' .. table.concat(excluded, ",") .. "]"
        .. ',"omit_limit":' .. tostring(limit)
        .. ',"omit_fraction":' .. tostring(fraction)
        .. "}"
    write_file(path, text)
    return path
end

local function run_cli(args, trace_path)
    local out_path = os.tmpname()
    local err_path = os.tmpname()
    local cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT LC_ALL=C " .. sh_quote(exe)
    for i = 1, #args do
        cmd = cmd .. " " .. sh_quote(args[i])
    end
    if trace_path then
        cmd = "strace -f -e trace=openat -o " .. sh_quote(trace_path) .. " -- " .. cmd
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

local function open_count(trace, path)
    if not trace then
        return 0
    end
    local needle = '"' .. path .. '"'
    local n = 0
    local i = 1
    while true do
        local found = trace:find(needle, i, true)
        if not found then
            break
        end
        n = n + 1
        i = found + #needle
    end
    return n
end

local function traced_run(args)
    local trace_path = os.tmpname()
    local code, out, err = run_cli(args, trace_path)
    local trace = read_all(trace_path) or ""
    os.remove(trace_path)
    return code, out, err, trace
end

local function real_euid()
    local f = assert(io.open("/proc/self/status", "rb"))
    local text = f:read("a") or ""
    f:close()
    return tonumber(text:match("Uid:%s*%d+%s+(%d+)"))
end

local function ino_of(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then
        return nil
    end
    return attr.ino, attr.nlink
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

local function snap(dest, stamp, listing)
    return dest .. "/" .. stamp .. listing
end

local function names_of(dir)
    local names = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function partials_of(dir)
    local found = {}
    for _, name in ipairs(names_of(dir)) do
        if name:sub(-8) == ".partial" then
            found[#found + 1] = name
        end
    end
    return found
end

local function expect_only(dir, want, msg)
    local got = names_of(dir)
    local expected = {}
    for i = 1, #want do
        expected[i] = want[i]
    end
    table.sort(expected)
    expect(table.concat(got, ",") == table.concat(expected, ","),
        msg .. " [" .. table.concat(got, ",") .. "]")
end

local function expect_success(code, out, err, msg)
    expect(code == 0, msg .. " exit " .. tostring(code) .. " " .. err)
    expect(out == "", msg .. " stdout [" .. out .. "]")
    expect(err == OWNER, msg .. " stderr [" .. err .. "]")
end

local function expect_warn(code, out, err, reason, msg)
    expect(code == 0, msg .. " exit " .. tostring(code) .. " " .. err)
    expect(out == "", msg .. " stdout [" .. out .. "]")
    expect(err == reason .. "\n" .. OWNER, msg .. " stderr [" .. err .. "]")
end

local function expect_line(code, out, err, status, line, msg)
    expect(code == status, msg .. " exit " .. tostring(code) .. " [" .. err .. "]")
    expect(out == "", msg .. " stdout [" .. out .. "]")
    expect(err == "casually_backup: " .. line .. "\n", msg .. " stderr [" .. err .. "]")
end

local function case_dir(name)
    local dir = base .. "/" .. name
    mkdir_p(dir)
    return dir
end

local function row(tree, listing, extra)
    local item = {
        abs = tree .. listing,
        listing = listing,
        user = 0,
        group = 0,
    }
    if extra then
        for key, value in pairs(extra) do
            item[key] = value
        end
    end
    return item
end

local function config_run(dir, index_path, dests, opts, trace)
    opts = opts or {}
    local path = write_config(dir .. "/backup.json", {
        index = index_path,
        destinations = dests,
        source_map = opts.source_map,
        exclude = opts.exclude,
        omit_limit = opts.omit_limit,
        omit_fraction = opts.omit_fraction,
    })
    local args = {}
    if opts.dry_run then
        args[1] = "--dry-run"
    end
    args[#args + 1] = "--config"
    args[#args + 1] = path
    if trace then
        return traced_run(args)
    end
    return run_cli(args)
end

local function acceptance()
    local dir = case_dir("accept")
    local tree = dir .. "/src"
    local d1 = dir .. "/dest1"
    local d2 = dir .. "/dest2"
    mkdir_p(d1)
    mkdir_p(d2)
    local ff_name = string.char(255)
    local bang_name = "a\tb"
    local KEEP = "/fvl/keep"
    local CHANGED = "/fvl/changed"
    local DOT = "/fvl/.dot"
    local BANG = "/fvl/" .. bang_name
    local FF = "/fvl/" .. ff_name
    local LINK = "/fvl/link"
    local DANGLE = "/fvl/dangling"
    local DASH = "/fvl/dash"
    local SETUID = "/fvl/setuid"
    local SECRET = "/fvl/secret"
    write_file(tree .. KEEP, "keep\n")
    write_file(tree .. CHANGED, "one\n")
    write_file(tree .. DOT, "dot\n")
    write_file(tree .. BANG, "bang\n")
    write_file(tree .. FF, "ff\n")
    write_file(tree .. SETUID, "suid\n")
    write_file(tree .. SECRET, "secret\n")
    assert(lfs.link("keep", tree .. LINK, true))
    assert(lfs.link("missing", tree .. DANGLE, true))
    assert(lfs.link("-", tree .. DASH, true))
    sh("chmod 755 " .. sh_quote(tree .. "/fvl"))
    for _, listing in ipairs({ KEEP, CHANGED, DOT, BANG, FF, SECRET }) do
        sh("chmod 644 " .. sh_quote(tree .. listing))
    end
    sh("chmod 4755 " .. sh_quote(tree .. SETUID))

    local function full_rows()
        return {
            row(tree, "/fvl"),
            row(tree, KEEP),
            row(tree, CHANGED),
            row(tree, DOT),
            row(tree, BANG),
            row(tree, FF),
            row(tree, LINK),
            row(tree, DANGLE),
            row(tree, DASH),
            row(tree, SETUID, { mode = SETUID_MODE }),
            row(tree, SECRET),
        }
    end
    local function later_rows()
        return {
            row(tree, "/fvl"),
            row(tree, KEEP),
            row(tree, CHANGED),
            row(tree, DOT),
            row(tree, BANG),
            row(tree, FF),
            row(tree, LINK),
            row(tree, DASH),
            row(tree, SETUID, { mode = SETUID_MODE }),
        }
    end
    local opts = {
        source_map = { { alias = "/fvl", path = tree .. "/fvl" } },
        exclude = { SECRET },
    }
    local index1 = write_listing(dir, S1, full_rows())
    local code, out, err = config_run(dir, index1, { d1, d2 }, opts)
    expect_success(code, out, err, "base")
    if code ~= 0 then
        return
    end

    local euid = real_euid()
    for _, dest in ipairs({ d1, d2 }) do
        expect_only(dest, { "_Base" }, dest)
        expect(read_all(snap(dest, "_Base", KEEP)) == "keep\n", dest .. " keep")
        expect(read_all(snap(dest, "_Base", CHANGED)) == "one\n", dest .. " changed")
        expect(read_all(snap(dest, "_Base", DOT)) == "dot\n", dest .. " dot")
        expect(read_all(snap(dest, "_Base", BANG)) == "bang\n", dest .. " bang")
        expect(read_all(snap(dest, "_Base", FF)) == "ff\n", dest .. " ff")
        expect(read_all(snap(dest, "_Base", SETUID)) == "suid\n", dest .. " setuid bytes")
        expect(lfs.symlinkattributes(snap(dest, "_Base", SECRET)) == nil, dest .. " excluded secret")
        local link = lfs.symlinkattributes(snap(dest, "_Base", LINK))
        expect(link ~= nil and link.mode == "link" and link.target == "keep", dest .. " link")
        local dangling = lfs.symlinkattributes(snap(dest, "_Base", DANGLE))
        expect(dangling ~= nil and dangling.mode == "link" and dangling.target == "missing",
            dest .. " dangling")
        local dash = lfs.symlinkattributes(snap(dest, "_Base", DASH))
        expect(dash ~= nil and dash.mode == "link" and dash.target == "-", dest .. " dash")
        local dir_attr = lfs.symlinkattributes(snap(dest, "_Base", "/fvl"))
        expect(dir_attr ~= nil and dir_attr.mode == "directory"
            and ("d" .. dir_attr.permissions) == "drwxr-xr-x", dest .. " dir mode")
        local src_setuid = lfs.symlinkattributes(tree .. SETUID)
        local dst_setuid = lfs.symlinkattributes(snap(dest, "_Base", SETUID))
        expect(src_setuid ~= nil and dst_setuid ~= nil
            and src_setuid.permissions == dst_setuid.permissions,
            dest .. " setuid lfs")
        expect(stat_mode(snap(dest, "_Base", SETUID)) == "4755", dest .. " setuid stat")
        expect(dst_setuid.uid == euid, dest .. " uid " .. tostring(dst_setuid and dst_setuid.uid))
        expect(partials_of(dest)[1] == nil, dest .. " partial")
        expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, dest .. " lock")
    end
    expect(read_all(tree .. SECRET) == "secret\n", "source secret removed")
    local keep1, keep2 = ino_of(snap(d1, "_Base", KEEP)), ino_of(snap(d2, "_Base", KEEP))
    expect(keep1 ~= nil and keep2 ~= nil and keep1 ~= keep2, "destinations share keep")
    local dir1, dir2 = ino_of(snap(d1, "_Base", "/fvl")), ino_of(snap(d2, "_Base", "/fvl"))
    expect(dir1 ~= nil and dir2 ~= nil and dir1 ~= dir2, "destinations share the directory")
    local link1, link2 = ino_of(snap(d1, "_Base", LINK)), ino_of(snap(d2, "_Base", LINK))
    expect(link1 ~= nil and link2 ~= nil and link1 ~= link2, "destinations share the symlink")

    write_file(tree .. CHANGED, "changed\n")
    sh("chmod 644 " .. sh_quote(tree .. CHANGED))
    local index2 = write_listing(dir, S2, later_rows())
    local base_keep = ino_of(snap(d1, "_Base", KEEP))
    local base_changed = ino_of(snap(d1, "_Base", CHANGED))
    local base_setuid = ino_of(snap(d1, "_Base", SETUID))
    code, out, err = config_run(dir, index2, { d1, d2 }, {
        source_map = opts.source_map,
        exclude = opts.exclude,
        dry_run = true,
    })
    expect(code == 0, "dry exit " .. tostring(code) .. " " .. err)
    expect(err == OWNER, "dry stderr [" .. err .. "]")
    expect(out:find("hardlink ", 1, true) ~= nil, "dry missing hardlink\n" .. out)
    expect(out:find(snap(d1, S2, KEEP), 1, true) ~= nil, "dry missing date path\n" .. out)
    expect(lfs.symlinkattributes(d1 .. "/" .. S2) == nil, "dry published")
    expect(ino_of(snap(d1, "_Base", KEEP)) == base_keep, "dry moved keep")
    expect(read_all(snap(d1, "_Base", CHANGED)) == "one\n", "dry changed bytes")
    expect(partials_of(d1)[1] == nil, "dry partial")
    expect(lfs.symlinkattributes(d1 .. "/.casually_backup.lock") == nil, "dry lock")

    local changed_src = tree .. CHANGED
    local keep_src = tree .. KEEP
    local trace
    code, out, err, trace = config_run(dir, index2, { d1, d2 }, opts, true)
    expect_success(code, out, err, "date")
    local run2_changed = open_count(trace, changed_src)
    local run2_keep = open_count(trace, keep_src)
    io.stdout:write("acceptance run2 changed_opens=" .. tostring(run2_changed)
        .. " keep_opens=" .. tostring(run2_keep) .. "\n")
    io.stdout:flush()
    expect(run2_changed == 1, "date opened changed " .. tostring(run2_changed))
    expect(run2_keep == 0, "date opened keep " .. tostring(run2_keep))
    if code ~= 0 then
        return
    end
    for _, dest in ipairs({ d1, d2 }) do
        expect_only(dest, { "_Base", S2 }, dest .. " date names")
        expect(read_all(snap(dest, S2, KEEP)) == "keep\n", dest .. " date keep")
        expect(read_all(snap(dest, S2, CHANGED)) == "changed\n", dest .. " date changed")
        expect(read_all(snap(dest, S2, DOT)) == "dot\n", dest .. " date dot")
        expect(read_all(snap(dest, S2, BANG)) == "bang\n", dest .. " date bang")
        expect(read_all(snap(dest, S2, FF)) == "ff\n", dest .. " date ff")
        expect(read_all(snap(dest, "_Base", CHANGED)) == "one\n", dest .. " base changed rewritten")
        expect(lfs.symlinkattributes(snap(dest, S2, DANGLE)) == nil, dest .. " date still has dangling")
        expect(lfs.symlinkattributes(snap(dest, "_Base", DANGLE)) ~= nil, dest .. " base lost dangling")
        expect(lfs.symlinkattributes(snap(dest, S2, SECRET)) == nil, dest .. " date has secret")
        expect(partials_of(dest)[1] == nil, dest .. " date partial")
        expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, dest .. " date lock")
    end
    local date_keep, date_keep_n = ino_of(snap(d1, S2, KEEP))
    expect(date_keep == base_keep, "unchanged file broke away")
    expect(date_keep_n >= 2, "unchanged nlink " .. tostring(date_keep_n))
    local date_changed = ino_of(snap(d1, S2, CHANGED))
    expect(date_changed ~= nil and date_changed ~= base_changed, "changed file was hardlinked")
    expect(ino_of(snap(d1, "_Base", CHANGED)) == base_changed, "base changed inode moved")
    expect(ino_of(snap(d1, "_Base", SETUID)) == base_setuid, "base setuid inode moved")
    expect(ino_of(snap(d1, S2, KEEP)) ~= ino_of(snap(d2, S2, KEEP)), "date destinations share keep")
    expect(ino_of(snap(d1, S2, CHANGED)) ~= ino_of(snap(d2, S2, CHANGED)),
        "date destinations share changed")

    local index3 = write_listing(dir, S3, later_rows())
    code, out, err, trace = config_run(dir, index3, { d1, d2 }, opts, true)
    expect_success(code, out, err, "third")
    local run3_changed = open_count(trace, changed_src)
    local run3_keep = open_count(trace, keep_src)
    io.stdout:write("acceptance run3 changed_opens=" .. tostring(run3_changed)
        .. " keep_opens=" .. tostring(run3_keep) .. "\n")
    io.stdout:flush()
    expect(run3_changed == 0, "third opened changed " .. tostring(run3_changed))
    expect(run3_keep == 0, "third opened keep " .. tostring(run3_keep))
    if code ~= 0 then
        return
    end
    local third_keep, third_keep_n = ino_of(snap(d1, S3, KEEP))
    local third_changed, third_changed_n = ino_of(snap(d1, S3, CHANGED))
    expect(third_keep == base_keep, "third keep inode")
    expect(third_keep_n >= 3, "third keep nlink " .. tostring(third_keep_n))
    expect(third_changed == date_changed, "third changed inode")
    expect(third_changed_n >= 2, "third changed nlink " .. tostring(third_changed_n))
    expect(read_all(snap(d1, "_Base", CHANGED)) == "one\n", "third base bytes")
    expect(ino_of(snap(d1, "_Base", CHANGED)) == base_changed, "third moved base")
    expect(ino_of(snap(d1, S3, KEEP)) ~= ino_of(snap(d2, S3, KEEP)), "third joined keep")
    expect_only(d1, { "_Base", S2, S3 }, "third names")

    local again_keep = ino_of(snap(d1, S2, KEEP))
    local again_changed = ino_of(snap(d1, S2, CHANGED))
    code, out, err = config_run(dir, index2, { d1, d2 }, opts)
    expect_line(code, out, err, 1, "snapshot exists: " .. d1 .. "/" .. S2, "stamp")
    expect(ino_of(snap(d1, S2, KEEP)) == again_keep, "stamp moved keep")
    expect(ino_of(snap(d1, S2, CHANGED)) == again_changed, "stamp moved changed")
    expect(read_all(snap(d1, "_Base", CHANGED)) == "one\n", "stamp base bytes")
    expect_only(d1, { "_Base", S2, S3 }, "stamp names")
    expect(partials_of(d1)[1] == nil, "stamp partial")
    expect(lfs.symlinkattributes(d1 .. "/.casually_backup.lock") == nil, "stamp lock")
end

local function source_map_case()
    local dir = case_dir("map")
    local tree = dir .. "/mapped"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    write_file(tree .. "/fvl/readme", "mapped\n")
    sh("chmod 755 " .. sh_quote(tree .. "/fvl"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/readme"))
    local index_path = write_listing(dir, S1, {
        row(tree, "/fvl"),
        row(tree, "/fvl/readme"),
    })
    local code, out, err = run_cli({
        "--index", index_path,
        "--dest", dest,
        "--source-map", "/fvl=" .. tree .. "/fvl",
    })
    expect_success(code, out, err, "map")
    expect(read_all(snap(dest, "_Base", "/fvl/readme")) == "mapped\n", "map bytes")
    expect(lfs.symlinkattributes(dest .. "/_Base" .. tree) == nil, "map stored the real prefix")
    expect_only(dest, { "_Base" }, "map names")
end

local function mode_case()
    local dir = case_dir("mode")
    local tree = dir .. "/src"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    write_file(tree .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(tree .. "/fvl"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/readme"))
    local function rows()
        return {
            row(tree, "/fvl"),
            row(tree, "/fvl/readme"),
        }
    end
    local opts = { source_map = { { alias = "/fvl", path = tree .. "/fvl" } } }
    local code, out, err = config_run(dir, write_listing(dir, S1, rows()), { dest }, opts)
    expect_success(code, out, err, "mode base")
    if code ~= 0 then
        return
    end
    local mode_ino = ino_of(snap(dest, "_Base", "/fvl/readme"))
    local mode_mtime = lfs.symlinkattributes(snap(dest, "_Base", "/fvl/readme")).modification
    sh("chmod 755 " .. sh_quote(tree .. "/fvl/readme"))
    code, out, err = config_run(dir, write_listing(dir, S2, rows()), { dest }, opts)
    expect_success(code, out, err, "mode date")
    expect(ino_of(snap(dest, "_Base", "/fvl/readme")) == mode_ino, "mode moved base")
    expect(lfs.symlinkattributes(snap(dest, "_Base", "/fvl/readme")).modification == mode_mtime,
        "mode retimed base")
    expect(read_all(snap(dest, "_Base", "/fvl/readme")) == "hello\n", "mode base bytes")
    expect(stat_mode(snap(dest, "_Base", "/fvl/readme")) == "644", "mode base stat")
    expect(ino_of(snap(dest, S2, "/fvl/readme")) ~= mode_ino, "mode hardlinked")
    expect(stat_mode(snap(dest, S2, "/fvl/readme")) == "755", "mode date stat")
end

local function refuse_case()
    local dir = case_dir("refuse")
    local dest = dir .. "/dest"
    mkdir_p(dest)
    local bad = dir .. "/bad.listing"
    write_file(bad, "not a listing")
    local code, out, err = run_cli({ "--index", bad, "--dest", dest })
    expect_line(code, out, err, 1, "listing is missing a final newline", "bad listing")
    expect_only(dest, {}, "bad listing names")

    local parent = dir .. "/parent"
    local child = parent .. "/child"
    mkdir_p(child)
    local dummy = dir .. "/dummy.listing"
    write_file(dummy, "x\n")
    code, out, err = run_cli({ "--index", dummy, "--dest", parent, "--dest", child })
    expect_line(code, out, err, 1,
        "destinations overlap: " .. parent .. " and " .. child, "nested")
    expect_only(parent, { "child" }, "nested names")

    local slash_index = dir .. "/slash.listing"
    write_file(slash_index, "x\n")
    write_config(dir .. "/slash.json", {
        index = slash_index,
        destinations = { dest },
        exclude = { "/" },
    })
    code, out, err = run_cli({ "--config", dir .. "/slash.json" })
    expect_line(code, out, err, 1, "exclude[1] must not be /", "exclude slash")
    expect_only(dest, {}, "exclude slash names")

    local src = dir .. "/src"
    local inside = src .. "/backup"
    mkdir_p(inside)
    write_file(src .. "/readme", "nest\n")
    sh("chmod 755 " .. sh_quote(src))
    sh("chmod 644 " .. sh_quote(src .. "/readme"))
    local nest_index = write_listing(dir, S1, {
        { abs = src, listing = src, user = 0, group = 0 },
        { abs = src .. "/readme", listing = src .. "/readme", user = 0, group = 0 },
    })
    code, out, err = run_cli({ "--index", nest_index, "--dest", inside })
    expect_line(code, out, err, 1,
        "source and destination nest: " .. src .. " and " .. inside, "nest")
    expect_only(inside, {}, "nest names")
end

local function omit_case()
    local dir = case_dir("omit")
    local tree = dir .. "/src"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    write_file(tree .. "/fvl/keep", "keep\n")
    write_file(tree .. "/fvl/old1", "old1\n")
    write_file(tree .. "/fvl/old2", "old2\n")
    sh("chmod 755 " .. sh_quote(tree .. "/fvl"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/keep"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/old1"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/old2"))
    local function rows(include_old)
        local list = {
            row(tree, "/fvl"),
            row(tree, "/fvl/keep"),
        }
        if include_old then
            list[#list + 1] = row(tree, "/fvl/old1")
            list[#list + 1] = row(tree, "/fvl/old2")
        end
        return list
    end
    local opts = { source_map = { { alias = "/fvl", path = tree .. "/fvl" } } }
    local code, out, err = config_run(dir, write_listing(dir, S1, rows(true)), { dest }, opts)
    expect_success(code, out, err, "omit base")
    if code ~= 0 then
        return
    end
    local keep_ino = ino_of(snap(dest, "_Base", "/fvl/keep"))
    local old_bytes = read_all(snap(dest, "_Base", "/fvl/old1"))
    code, out, err = run_cli({
        "--index", write_listing(dir, S2, rows(false)),
        "--dest", dest,
        "--source-map", "/fvl=" .. tree .. "/fvl",
        "--omit-limit", "1",
    })
    expect_line(code, out, err, 1,
        "too many omissions: " .. dest .. " omitted 2 limit 1 fraction 0.02", "omit")
    expect(lfs.symlinkattributes(dest .. "/" .. S2) == nil, "omit published")
    expect(ino_of(snap(dest, "_Base", "/fvl/keep")) == keep_ino, "omit moved keep")
    expect(read_all(snap(dest, "_Base", "/fvl/old1")) == old_bytes, "omit base bytes")
    expect_only(dest, { "_Base" }, "omit names")
    expect(partials_of(dest)[1] == nil, "omit partial")
end

local function unreadable_case()
    local dir = case_dir("dark")
    local tree = dir .. "/src"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    write_file(tree .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(tree .. "/fvl"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/readme"))
    local function rows()
        return {
            row(tree, "/fvl"),
            row(tree, "/fvl/readme"),
        }
    end
    local opts = { source_map = { { alias = "/fvl", path = tree .. "/fvl" } } }
    local code, out, err = config_run(dir, write_listing(dir, S1, rows()), { dest }, opts)
    expect_success(code, out, err, "dark base")
    if code ~= 0 then
        return
    end
    local dark_base = dest .. "/_Base"
    local dark_ino = ino_of(snap(dest, "_Base", "/fvl/readme"))
    local dark_bytes = read_all(snap(dest, "_Base", "/fvl/readme"))
    sh("chmod 000 " .. sh_quote(dark_base))
    code, out, err = config_run(dir, write_listing(dir, S2, rows()), { dest }, opts)
    sh("chmod 755 " .. sh_quote(dark_base))
    expect_line(code, out, err, 2,
        "cannot read " .. dark_base .. ": cannot open " .. dark_base .. ": Permission denied",
        "dark")
    expect(lfs.symlinkattributes(dest .. "/" .. S2) == nil, "dark published")
    expect(ino_of(snap(dest, "_Base", "/fvl/readme")) == dark_ino, "dark moved base")
    expect(read_all(snap(dest, "_Base", "/fvl/readme")) == dark_bytes, "dark bytes")
    expect_only(dest, { "_Base" }, "dark names")
end

local function size_case()
    local dir = case_dir("size")
    local tree = dir .. "/src"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    write_file(tree .. "/fvl/readme", "hello\n")
    sh("chmod 755 " .. sh_quote(tree .. "/fvl"))
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/readme"))
    local function rows()
        return {
            row(tree, "/fvl"),
            row(tree, "/fvl/readme"),
        }
    end
    local opts = { source_map = { { alias = "/fvl", path = tree .. "/fvl" } } }
    local code, out, err = config_run(dir, write_listing(dir, S1, rows()), { dest }, opts)
    expect_success(code, out, err, "size base")
    if code ~= 0 then
        return
    end
    local size_ino = ino_of(snap(dest, "_Base", "/fvl/readme"))
    -- The listing has to disagree with _Base, or the run hardlinks and never
    -- reads the source. Grow once, record that size, then grow again.
    write_file(tree .. "/fvl/readme", "hello!!\n")
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/readme"))
    local index2 = write_listing(dir, S2, rows())
    write_file(tree .. "/fvl/readme", "hello!!\n!")
    sh("chmod 644 " .. sh_quote(tree .. "/fvl/readme"))
    code, out, err = config_run(dir, index2, { dest }, opts)
    expect_warn(code, out, err, "source is longer than the listing: " .. tree .. "/fvl/readme (skipped)", "size")
    expect(lfs.symlinkattributes(dest .. "/" .. S2) ~= nil, "size published")
    expect(ino_of(snap(dest, "_Base", "/fvl/readme")) == size_ino, "size moved base")
    expect(read_all(snap(dest, "_Base", "/fvl/readme")) == "hello\n", "size base bytes")
    local parts = partials_of(dest)
    expect(#parts == 0, "size partial " .. table.concat(parts, ","))
    expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, "size lock")
end

local function usage_case()
    local dir = case_dir("usage")
    local dest = dir .. "/dest"
    mkdir_p(dest)
    local code, out, err = run_cli({ "--index", dest, "--dest", dest })
    expect_line(code, out, err, 1, "--index is not a regular file", "index directory")
    expect_only(dest, {}, "index directory names")

    code, out, err = run_cli({ "--bogus" })
    expect_line(code, out, err, 1, "unknown argument: --bogus", "unknown flag")

    local cfg = dir .. "/backup.json"
    write_file(cfg, "{}\n")
    code, out, err = run_cli({ "--config", cfg, "--dest", dest })
    expect_line(code, out, err, 1, "use either --config or --index with --dest", "mixed")
    expect_only(dest, {}, "mixed names")
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /mnt/extra/Projects/Casually/.casually-phase7.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end
    expect(real_euid() ~= 0, "phase 7 gate expects a non-root euid")
    if failures > 0 then
        return
    end
    acceptance()
    source_map_case()
    mode_case()
    refuse_case()
    omit_case()
    unreadable_case()
    size_case()
    usage_case()
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
local phase_cmd = sh_quote(root .. "/test/run.sh") .. " backup 6 > "
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
if pcode ~= 0 or phase_text:find("backup phase 6 gate passed", 1, true) == nil then
    io.stderr:write("backup phase 6 did not pass, exit " .. tostring(pcode) .. "\n")
    io.stderr:write(phase_err_text)
    io.stderr:write(phase_text)
    os.exit(1)
end

io.stdout:write("backup phase 7 gate passed\n")
