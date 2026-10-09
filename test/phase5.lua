-- Phase 5 gate. Run from the repo root: lua test/phase5.lua
-- Sorts a fixture record array and publishes it. No progress panel.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase5.lua")
    if here == "test" then
        return "."
    end
    if here:match("/test$") then
        return here:gsub("/test$", "")
    end
    return "."
end

local root = repo_root()
local exe = root .. "/casually_index.lua"
local api = dofile(exe)

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

expect(type(api.publish) == "function", "publish is exported")
expect(type(api.run) == "function", "run is exported")

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
    local ok, how, code = os.execute(cmd)
    if ok ~= true then
        error("command failed (" .. tostring(how) .. " " .. tostring(code) .. "): " .. cmd)
    end
end

local function utc_epoch(y, mo, d, h, mi, s)
    local guess = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
    local shown = os.date("!*t", guess)
    local shown_local = os.time({
        year = shown.year, month = shown.month, day = shown.day,
        hour = shown.hour, min = shown.min, sec = shown.sec,
    })
    return guess + os.difftime(guess, shown_local)
end

local T_README = utc_epoch(2026, 10, 8, 14, 30, 15)
local T_DOCS = utc_epoch(2026, 10, 8, 14, 30, 16)
local T_LINK = utc_epoch(2026, 10, 8, 9, 0, 1)
local STAMP = utc_epoch(2026, 10, 8, 14, 30, 0)

expect(os.date("!%Y%m%d-%H%M", STAMP) == "20261008-1430", "stamp minute")

local MODE_644 = tonumber("644", 8)
local MODE_777 = tonumber("777", 8)
local TAB = "\t"

local function sample(over)
    local rec = {
        path = "/fvl/a/docs/readme.txt",
        kind = "file",
        mode = MODE_644,
        size = 4821,
        mtime = T_README,
        user = "andrew",
        group = "andrew",
        uid = 1000,
        gid = 1000,
    }
    for k, v in pairs(over) do
        rec[k] = v
    end
    return rec
end

local docs_rec = sample({
    path = "/fvl/a/docs",
    kind = "dir",
    permissions = "rwxr-xr-x",
    mode = 0,
    size = 6,
    mtime = T_DOCS,
})
local link_rec = sample({
    path = "/fvl/a/docs/link",
    kind = "link",
    mode = MODE_777,
    size = 11,
    mtime = T_LINK,
    target = "../other/readme",
})
local readme_rec = sample({})
local bang_rec = sample({
    path = "/fvl/a/odd\tname",
    permissions = "rw-r--r--",
    size = 3,
    mtime = T_LINK,
})

local function line_of(rec, label)
    local text, err = api.format_line(rec)
    expect(text ~= nil, label .. " format failed: " .. tostring(err))
    return text
end

local sample_docs = line_of(docs_rec, "docs")
local sample_link = line_of(link_rec, "link")
local sample_readme = line_of(readme_rec, "readme")
local sample_bang = line_of(bang_rec, "bang")

local golden = table.concat({
    sample_docs, sample_link, sample_readme, sample_bang,
}, "\n") .. "\n"

expect(sample_bang:sub(1, 1) == "!", "bang sample is a bang line")
expect(golden:sub(-1) == "\n", "golden ends with a newline")
expect(golden:sub(-2) ~= "\n\n", "golden does not end with a blank line")

local function fixture_records()
    -- Not path order. Publish must sort by the raw path.
    return { bang_rec, readme_rec, link_rec, docs_rec }
end

local function self_pid()
    local f = assert(io.open("/proc/self/stat", "rb"))
    local n = f:read("*n")
    f:close()
    if not n then
        error("no pid in /proc/self/stat")
    end
    return tostring(n)
end

local PID = self_pid()

local function write_file(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a") or ""
    f:close()
    return text
end

local function exists(path)
    return api.lfs.symlinkattributes(path) ~= nil
end

local function mkdir(path)
    sh("mkdir -p " .. sh_quote(path))
end

local function names_of(dir)
    local names = {}
    for name in api.lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function partials_in(dir)
    local found = {}
    for _, name in ipairs(names_of(dir)) do
        if name:match("%.partial$") then
            found[#found + 1] = name
        end
    end
    return found
end

local function recording_open(bucket)
    return function(path)
        bucket[#bucket + 1] = path
        return io.open(path, "wb")
    end
end

local function config_for(work, output, output_path)
    return {
        work_dir = work,
        output_dir = output,
        output_path = output_path,
        roots = {},
        exclude = {},
    }
end

local base

local function cleanup()
    if not base then
        return
    end
    os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
    os.execute("rm -rf " .. sh_quote(base))
end

local function publish_golden(cfg, label)
    local opened = {}
    local records = fixture_records()
    local before = {}
    for i = 1, #records do
        before[i] = records[i].path
    end
    local path, err, class = api.publish(records, cfg, STAMP, {
        open = recording_open(opened),
    })
    expect(path ~= nil, label .. " publish failed: " .. tostring(err) .. " class " .. tostring(class))
    if not path then
        return nil
    end
    expect(class == nil, label .. " class " .. tostring(class))
    expect(#opened == 1, label .. " opened " .. tostring(#opened) .. " files")
    local partial = opened[1]
    expect(partial:find("." .. PID .. ".partial", 1, true) ~= nil,
        label .. " partial name " .. tostring(partial))
    expect(not exists(partial), label .. " left the partial " .. tostring(partial))
    expect(read_file(path) == golden, label .. " listing bytes differ")
    expect(read_file(path):sub(-1) == "\n", label .. " missing final newline")
    for i = 1, #records do
        expect(records[i].path == before[i], label .. " reordered the caller's array")
    end
    return path, partial
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /tmp/casually-phase5.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end

    local same = base .. "/same"
    local split_work = base .. "/split-work"
    local split_out = base .. "/split-out"
    local flagged = base .. "/flagged"
    mkdir(same)
    mkdir(split_work)
    mkdir(split_out)
    mkdir(flagged)

    local same_dev = api.lfs.attributes(split_work)
    local out_dev = api.lfs.attributes(split_out)
    expect(same_dev and out_dev and same_dev.dev == out_dev.dev,
        "work_dir and output_dir are not on the same device")

    local foreign = same .. "/index-20261008-1430.listing." .. (PID == "0" and "1" or "0") .. ".partial"
    write_file(foreign, "foreign\n")

    local stamped = "index-20261008-1430.listing"
    local same_path, same_partial = publish_golden(config_for(same, same, nil), "same directory")
    expect(same_path == same .. "/" .. stamped, "same directory listing path " .. tostring(same_path))
    expect(same_partial == same .. "/" .. stamped .. "." .. PID .. ".partial",
        "same directory partial " .. tostring(same_partial))
    expect(read_file(foreign) == "foreign\n", "deleted another process's partial")
    local leftover = partials_in(same)
    expect(#leftover == 1 and leftover[1] == foreign:match("([^/]+)$"),
        "same directory partials " .. table.concat(leftover, ","))

    local kept = read_file(same_path)
    local again, again_err, again_class = api.publish(fixture_records(), config_for(same, same, nil), STAMP, {
        open = function(path)
            fail("second publish opened " .. path)
            return io.open(path, "wb")
        end,
    })
    expect(again == nil, "second publish returned a path")
    expect(again_class == "publish", "second publish class " .. tostring(again_class))
    expect(again_err == "listing exists " .. same_path, "second publish reason " .. tostring(again_err))
    expect(read_file(same_path) == kept, "second publish changed the listing")
    expect(#names_of(same) == 2, "second publish added a listing")

    local split_path, split_partial = publish_golden(
        config_for(split_work, split_out, nil), "two directories")
    expect(split_path == split_out .. "/" .. stamped, "split listing path " .. tostring(split_path))
    expect(split_partial == split_work .. "/" .. stamped .. "." .. PID .. ".partial",
        "split partial " .. tostring(split_partial))
    expect(#partials_in(split_work) == 0, "split work_dir kept a partial")
    expect(#partials_in(split_out) == 0, "split output_dir has a partial")
    expect(#names_of(split_out) == 1, "split output count")

    local explicit = flagged .. "/out.listing"
    local flag_path, flag_partial = publish_golden(config_for(flagged, flagged, explicit), "output_path")
    expect(flag_path == explicit, "output_path listing " .. tostring(flag_path))
    expect(flag_partial == explicit .. "." .. PID .. ".partial",
        "output_path partial " .. tostring(flag_partial))

    local tab_rec = sample({ path = "/b\t", size = 1, mtime = T_LINK })
    local slash_rec = sample({ path = "/b\\t", size = 1, mtime = T_LINK })
    local raw_dir = base .. "/raw-order"
    mkdir(raw_dir)
    local raw_opened = {}
    local raw_path, raw_err, raw_class = api.publish({ slash_rec, tab_rec }, config_for(raw_dir, raw_dir, nil), STAMP, {
        open = recording_open(raw_opened),
    })
    expect(raw_path ~= nil, "raw order publish failed: " .. tostring(raw_err) .. " " .. tostring(raw_class))
    if raw_path then
        local tab_line = line_of(tab_rec, "raw tab")
        local slash_line = line_of(slash_rec, "raw slash")
        expect(read_file(raw_path) == tab_line .. "\n" .. slash_line .. "\n",
            "tab byte does not sort before the escaped backslash")
        expect(not exists(raw_opened[1]), "raw order left a partial")
    end

    local dup_dir = base .. "/dup"
    mkdir(dup_dir)
    local dup_opened = {}
    local dup_path, dup_err, dup_class = api.publish({
        sample({ path = "/fvl/a/docs", size = 1 }),
        sample({ path = "/other", size = 2 }),
        sample({ path = "/fvl/a/docs", size = 3 }),
    }, config_for(dup_dir, dup_dir, dup_dir .. "/dup.listing"), STAMP, {
        open = recording_open(dup_opened),
    })
    expect(dup_path == nil, "duplicate returned a path")
    expect(dup_class == "walk", "duplicate class " .. tostring(dup_class))
    expect(dup_err == "duplicate path /fvl/a/docs", "duplicate reason " .. tostring(dup_err))
    expect(#dup_opened == 0, "duplicate opened a partial")
    expect(#names_of(dup_dir) == 0, "duplicate left a file")
    expect(not exists(dup_dir .. "/dup.listing"), "duplicate created the listing")

    local crash_dir = base .. "/crash"
    mkdir(crash_dir)
    local crash_listing = crash_dir .. "/crash.listing"
    local crash_partial
    local crash_path, crash_err, crash_class = api.publish(fixture_records(), config_for(crash_dir, crash_dir, crash_listing), STAMP, {
        open = function(path)
            crash_partial = path
            local real = assert(io.open(path, "wb"))
            local writes = 0
            return {
                write = function(_, data)
                    writes = writes + 1
                    if writes >= 2 then
                        real:close()
                        return nil, "closed"
                    end
                    return real:write(data)
                end,
                flush = function()
                    return real:flush()
                end,
                close = function()
                    return real:close()
                end,
            }
        end,
        rename = function()
            fail("crash seam renamed")
            return nil, "renamed"
        end,
    })
    expect(crash_path == nil, "crash seam returned a path")
    expect(crash_class == "publish", "crash class " .. tostring(crash_class))
    expect(tostring(crash_err):find("closed", 1, true) ~= nil, "crash reason " .. tostring(crash_err))
    expect(not exists(crash_listing), "crash seam created the listing")
    expect(crash_partial ~= nil and exists(crash_partial), "crash seam removed the partial")
    if crash_partial and exists(crash_partial) then
        expect(read_file(crash_partial) == sample_docs .. "\n", "crash partial bytes")
        expect(crash_partial:find("." .. PID .. ".partial", 1, true) ~= nil, "crash partial name")
    end

    local appear_dir = base .. "/appear"
    mkdir(appear_dir)
    local appear_listing = appear_dir .. "/appear.listing"
    local previous = "previous-bytes\n"
    local appear_partial
    local renamed = false
    local checks = 0
    local appear_path, appear_err, appear_class = api.publish(
        fixture_records(),
        config_for(appear_dir, appear_dir, appear_listing),
        STAMP,
        {
            open = function(path)
                appear_partial = path
                return io.open(path, "wb")
            end,
            exists = function(path)
                checks = checks + 1
                if checks == 1 then
                    return false
                end
                write_file(appear_listing, previous)
                return true
            end,
            rename = function(from, to)
                renamed = true
                return os.rename(from, to)
            end,
        }
    )
    expect(appear_path == nil, "late listing returned a path")
    expect(appear_class == "publish", "late listing class " .. tostring(appear_class))
    expect(appear_err == "listing exists " .. appear_listing, "late listing reason " .. tostring(appear_err))
    expect(not renamed, "late listing renamed over the previous bytes")
    expect(read_file(appear_listing) == previous, "late listing changed the previous bytes")
    expect(appear_partial ~= nil and exists(appear_partial), "late listing removed the partial")

    local link_dir = base .. "/symlink"
    mkdir(link_dir)
    local link_listing = link_dir .. "/link.listing"
    sh("ln -s /missing " .. sh_quote(link_listing))
    local link_opened = {}
    local link_path, link_err, link_class = api.publish(
        fixture_records(),
        config_for(link_dir, link_dir, link_listing),
        STAMP,
        { open = recording_open(link_opened) }
    )
    expect(link_path == nil, "symlink listing returned a path")
    expect(link_class == "publish", "symlink listing class " .. tostring(link_class))
    expect(link_err == "listing exists " .. link_listing, "symlink listing reason " .. tostring(link_err))
    expect(#link_opened == 0, "symlink listing opened a partial")
    local link_attr = api.lfs.symlinkattributes(link_listing)
    expect(link_attr and link_attr.mode == "link", "symlink listing was replaced")

    local rename_dir = base .. "/rename-fail"
    mkdir(rename_dir)
    local rename_listing = rename_dir .. "/rename.listing"
    local rename_partial
    local rename_path, rename_err, rename_class = api.publish(
        fixture_records(),
        config_for(rename_dir, rename_dir, rename_listing),
        STAMP,
        {
            open = function(path)
                rename_partial = path
                return io.open(path, "wb")
            end,
            rename = function()
                return nil, "cross-device link"
            end,
        }
    )
    expect(rename_path == nil, "rename failure returned a path")
    expect(rename_class == "publish", "rename failure class " .. tostring(rename_class))
    expect(rename_err == "cannot rename " .. tostring(rename_partial) .. " to " .. rename_listing .. ": cross-device link",
        "rename failure reason " .. tostring(rename_err))
    expect(not exists(rename_listing), "rename failure created the listing")
    expect(rename_partial ~= nil and read_file(rename_partial) == golden, "rename failure partial bytes")

    local called = false
    local run_cfg = {
        work_dir = same,
        output_dir = same,
        output_path = same .. "/pre-walk.listing",
        roots = { { path = "/walker-should-not-run", alias = "/x" } },
        exclude = {},
    }
    write_file(run_cfg.output_path, "already\n")
    local run_path, run_err, run_class = api.run(run_cfg, {
        lstat = function()
            called = true
            return nil, "walker was called"
        end,
        dir = function()
            called = true
            return nil, "walker was called"
        end,
    }, STAMP)
    expect(not called, "pre-walk check called the walker")
    expect(run_path == nil, "pre-walk check returned a path")
    expect(run_class == "publish", "pre-walk class " .. tostring(run_class))
    expect(run_err == "listing exists " .. run_cfg.output_path, "pre-walk reason " .. tostring(run_err))
    expect(read_file(run_cfg.output_path) == "already\n", "pre-walk changed the listing")
    expect(#partials_in(same) == 1, "pre-walk created a partial")

    local function capture_main(argv)
        local out, err_buf = {}, {}
        local saved_out, saved_err = io.stdout, io.stderr
        io.stdout = {
            write = function(_, data)
                out[#out + 1] = data
                return true
            end,
        }
        io.stderr = {
            write = function(_, data)
                err_buf[#err_buf + 1] = data
                return true
            end,
        }
        local ok, code = xpcall(function()
            return api.main(argv)
        end, debug.traceback)
        io.stdout = saved_out
        io.stderr = saved_err
        if not ok then
            error(code)
        end
        return code, table.concat(out), table.concat(err_buf)
    end

    local main_root = base .. "/main-root"
    local main_out = base .. "/main-out"
    mkdir(main_root)
    mkdir(main_out)
    write_file(main_root .. "/hello.txt", "hello\n")
    local main_cfg = base .. "/main.json"
    write_file(main_cfg, string.format([[{
  "roots": [{"path": %q, "alias": "/tree"}],
  "work_dir": %q,
  "output_dir": %q
}
]], main_root, main_out, main_out))

    local minute = os.date("!%Y%m%d-%H%M")
    local clobber = main_out .. "/index-" .. minute .. ".listing"
    write_file(clobber, "KEEP\n")
    local code, out, err = capture_main({ "--config", main_cfg })
    if os.date("!%Y%m%d-%H%M") ~= minute then
        for _, name in ipairs(names_of(main_out)) do
            if name:match("^index%-") or name:match("%.partial$") then
                os.remove(main_out .. "/" .. name)
            end
        end
        minute = os.date("!%Y%m%d-%H%M")
        clobber = main_out .. "/index-" .. minute .. ".listing"
        write_file(clobber, "KEEP\n")
        code, out, err = capture_main({ "--config", main_cfg })
    end
    expect(os.date("!%Y%m%d-%H%M") == minute, "stamp minute changed during main")
    expect(code == 3, "main clobber exit " .. tostring(code) .. " err " .. err)
    expect(out == "", "main clobber stdout " .. string.format("%q", out))
    expect(err == "casually_index: listing exists " .. clobber .. "\n",
        "main clobber stderr " .. string.format("%q", err))
    expect(read_file(clobber) == "KEEP\n", "main clobber changed the listing")
    expect(#partials_in(main_out) == 0, "main clobber left a partial")

    os.remove(clobber)
    code, out, err = capture_main({ "--config", main_cfg })
    expect(code == 0, "main publish exit " .. tostring(code) .. " err " .. err)
    expect(out == "", "main publish stdout " .. string.format("%q", out))
    expect(err == "", "main publish stderr " .. string.format("%q", err))
    local produced = {}
    for _, name in ipairs(names_of(main_out)) do
        if name:match("^index%-%d%d%d%d%d%d%d%d%-%d%d%d%d%.listing$") then
            produced[#produced + 1] = name
        end
    end
    expect(#produced == 1, "main stamped names " .. table.concat(produced, ","))
    expect(#partials_in(main_out) == 0, "main publish left a partial")
    if produced[1] then
        local body = read_file(main_out .. "/" .. produced[1])
        expect(body:sub(-1) == "\n", "main listing missing final newline")
        local paths = {}
        for line in body:gmatch("([^\n]*)\n") do
            paths[#paths + 1] = line:match(".*\t(.*)")
        end
        expect(#paths == 2, "main listing lines " .. tostring(#paths))
        expect(paths[1] == "/tree", "main root path " .. tostring(paths[1]))
        expect(paths[2] == "/tree/hello.txt", "main file path " .. tostring(paths[2]))
    end

    local cli_root = base .. "/cli-root"
    local cli_out = base .. "/cli-out"
    mkdir(cli_root)
    mkdir(cli_out)
    write_file(cli_root .. "/file.txt", "hello\n")
    sh("mkfifo " .. sh_quote(cli_root .. "/pipe"))
    local cli_index = cli_out .. "/list.listing"

    local function run_cli(args)
        local outp = os.tmpname()
        local errp = os.tmpname()
        local cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT LC_ALL=C " .. sh_quote(exe)
        for i = 1, #args do
            cmd = cmd .. " " .. sh_quote(args[i])
        end
        cmd = cmd .. " > " .. sh_quote(outp) .. " 2> " .. sh_quote(errp)
        local ok, how, status = os.execute(cmd)
        local out_f = assert(io.open(outp, "rb"))
        local got_out = out_f:read("a") or ""
        out_f:close()
        os.remove(outp)
        local err_f = assert(io.open(errp, "rb"))
        local got_err = err_f:read("a") or ""
        err_f:close()
        os.remove(errp)
        if ok == true then
            status = 0
        elseif how == "exit" then
            status = status or 1
        else
            status = -1
        end
        return status, got_out, got_err
    end

    local cli_args = { "--source", cli_root, "--index", cli_index }
    code, out, err = run_cli(cli_args)
    local warn = "casually_index: skipped named pipe " .. cli_root .. "/pipe\n"
    expect(code == 0, "cli exit " .. tostring(code) .. " err " .. err)
    expect(out == "", "cli stdout " .. string.format("%q", out))
    expect(err == warn, "cli stderr " .. string.format("%q", err))
    expect(exists(cli_index), "cli did not publish")
    if exists(cli_index) then
        local body = read_file(cli_index)
        expect(body:sub(-1) == "\n", "cli listing missing final newline")
        expect(body:find(cli_root .. "/file.txt", 1, true) ~= nil, "cli listing omitted the file")
        expect(body:find(cli_root .. "/pipe", 1, true) == nil, "cli listing included the fifo")
    end
    expect(#partials_in(cli_out) == 0, "cli left a partial")

    local cli_bytes = read_file(cli_index)
    code, out, err = run_cli(cli_args)
    expect(code == 3, "cli second exit " .. tostring(code) .. " err " .. err)
    expect(out == "", "cli second stdout " .. string.format("%q", out))
    expect(err == "casually_index: listing exists " .. cli_index .. "\n",
        "cli second stderr " .. string.format("%q", err))
    expect(read_file(cli_index) == cli_bytes, "cli second run changed the listing")
    expect(#names_of(cli_out) == 1, "cli second run added a file")
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
io.stdout:write("phase 5 gate passed\n")
