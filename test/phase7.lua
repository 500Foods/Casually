-- Phase 7 gate. Run from the repo root: lua test/phase7.lua
-- Spec acceptance: exit codes, one runtime golden listing, no checked-in names.
-- The terminal check stays the phase 6 pty. This gate does not open a screen.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase7.lua")
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

os.setlocale("C")

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

expect(type(api.main) == "function", "main is exported")
expect(type(api.run) == "function", "run is exported")
expect(type(api.load_config) == "function", "load_config is exported")
expect(type(api.format_line) == "function", "format_line is exported")

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
    local ok, how, code = os.execute(cmd)
    if ok ~= true then
        error("command failed (" .. tostring(how) .. " " .. tostring(code) .. "): " .. cmd)
    end
end

local function capture(cmd)
    local handle = assert(io.popen(cmd, "r"))
    local text = handle:read("a") or ""
    handle:close()
    return (text:gsub("%s+$", ""))
end

local function write_file(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text or "")
    handle:close()
end

local function read_file(path)
    local handle = assert(io.open(path, "rb"))
    local text = handle:read("a") or ""
    handle:close()
    return text
end

local function mkdir(path)
    local ok, err = api.lfs.mkdir(path)
    if not ok then
        error("mkdir " .. path .. ": " .. tostring(err))
    end
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

local function stamped_in(dir)
    local found = {}
    for _, name in ipairs(names_of(dir)) do
        if name:match("^index%-%d%d%d%d%d%d%d%d%-%d%d%d%d%.listing$") then
            found[#found + 1] = name
        end
    end
    return found
end

local function minute_now()
    return os.date("!%Y%m%d-%H%M")
end

local user_name = capture("id -un")
local group_name = capture("id -gn")
local user_id = tonumber(capture("id -u"))
local group_id = tonumber(capture("id -g"))
local MTIME_TEXT = "20261008:143015"
local UNKNOWN_UID = 2147483000

local base
local extras = {}

local function track(path)
    extras[#extras + 1] = path
    return path
end

local function cleanup()
    if base then
        os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
        os.execute("rm -rf " .. sh_quote(base))
    end
    for i = 1, #extras do
        os.execute("chmod -R u+rwx " .. sh_quote(extras[i]) .. " >/dev/null 2>&1")
        os.execute("rm -rf " .. sh_quote(extras[i]))
    end
end

local function run_cli(args)
    local outp = os.tmpname()
    local errp = os.tmpname()
    local cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT LC_ALL=C " .. sh_quote(exe)
    for i = 1, #args do
        cmd = cmd .. " " .. sh_quote(args[i])
    end
    cmd = cmd .. " > " .. sh_quote(outp) .. " 2> " .. sh_quote(errp)
    local ok, how, status = os.execute(cmd)
    local out_text = read_file(outp)
    local err_text = read_file(errp)
    os.remove(outp)
    os.remove(errp)
    if ok == true then
        status = 0
    elseif how == "exit" then
        status = status or 1
    else
        status = -1
    end
    return status, out_text, err_text
end

local function encode_config(doc)
    return assert(api.dkjson.encode(doc))
end

local function write_config(path, doc)
    write_file(path, encode_config(doc))
    return path
end

local function physical_lines(text)
    local count = 0
    for _ in tostring(text):gmatch("\n") do
        count = count + 1
    end
    return count
end

local function expect_exit(label, code, out_text, err_text, want, reason)
    expect(code == want, label .. " exit " .. tostring(code) .. " err " .. err_text)
    expect(out_text == "", label .. " stdout " .. string.format("%q", out_text))
    expect(err_text == "casually_index: " .. reason .. "\n",
        label .. " stderr " .. string.format("%q", err_text))
    expect(physical_lines(err_text) == 1, label .. " stderr lines " .. tostring(physical_lines(err_text)))
end

local function expect_clean(label, work, output)
    expect(#partials_in(work) == 0, label .. " left a partial")
    expect(#stamped_in(output) == 0, label .. " wrote a listing")
    local work_names = table.concat(names_of(work), "\n")
    local out_names = table.concat(names_of(output), "\n")
    expect(not work_names:find(".casually_index.probe.", 1, true), label .. " left a work probe")
    expect(not out_names:find(".casually_index.probe.", 1, true), label .. " left an output probe")
end

local function fresh_pair(dir)
    local tree = dir .. "/tree"
    local work = dir .. "/work"
    local output = dir .. "/output"
    mkdir(dir)
    mkdir(tree)
    mkdir(work)
    mkdir(output)
    return tree, work, output
end

local function lock_child(tree)
    local locked = tree .. "/locked"
    mkdir(locked)
    sh("chmod 000 " .. sh_quote(locked))
    return locked
end

local function touch(path)
    sh("TZ=UTC touch -h -d " .. sh_quote("2026-10-08 14:30:15") .. " -- " .. sh_quote(path))
end

local function owner_side(name, id)
    if type(name) == "string" and name ~= "" and name:find("[: \t]") == nil then
        return name
    end
    return string.format("%d", id)
end

local expect_owner = owner_side(user_name, user_id) .. ":" .. owner_side(group_name, group_id)

local function unescape_field(text)
    local parts = {}
    local i = 1
    while i <= #text do
        if text:sub(i, i) == "\\" then
            local nxt = text:sub(i + 1, i + 1)
            if nxt == "\\" then
                parts[#parts + 1] = "\\"
            elseif nxt == "t" then
                parts[#parts + 1] = "\t"
            elseif nxt == "n" then
                parts[#parts + 1] = "\n"
            elseif nxt == "r" then
                parts[#parts + 1] = "\r"
            else
                return nil
            end
            i = i + 2
        else
            parts[#parts + 1] = text:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(parts)
end

local function fields_of(line)
    local bang = false
    local body = line
    if line:sub(1, 1) == "!" then
        bang = true
        body = line:sub(2)
    end
    local mtime, owner, mode, size, link, path = body:match(
        "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    return bang, mtime, owner, mode, size, link, path
end

local function raw_fields(line)
    local bang, mtime, owner, mode, size, link, path = fields_of(line)
    if bang then
        link = unescape_field(link)
        path = unescape_field(path)
    end
    return {
        bang = bang,
        mtime = mtime,
        owner = owner,
        mode = mode,
        size = size,
        link = link,
        path = path,
    }
end

local function listing_lines(body)
    local lines = {}
    for line in body:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

local function record_from(abs, mapped)
    local attr = api.lfs.symlinkattributes(abs)
    if not attr then
        error("lstat " .. abs)
    end
    local kind
    if attr.mode == "file" then
        kind = "file"
    elseif attr.mode == "directory" then
        kind = "dir"
    elseif attr.mode == "link" then
        kind = "link"
    else
        error("unexpected mode " .. tostring(attr.mode) .. " for " .. abs)
    end
    local whole = math.modf(attr.modification)
    local rec = {
        path = mapped,
        kind = kind,
        size = math.tointeger(attr.size),
        mtime = whole,
        uid = user_id,
        gid = group_id,
        user = user_name,
        group = group_name,
        permissions = attr.permissions,
    }
    if kind == "link" then
        rec.target = attr.target
    end
    return rec
end

local function golden_from(items)
    local records = {}
    for i = 1, #items do
        records[i] = record_from(items[i].abs, items[i].path)
    end
    table.sort(records, function(a, b)
        return a.path < b.path
    end)
    local lines = {}
    for i = 1, #records do
        local text, err = api.format_line(records[i])
        if not text then
            error("format " .. tostring(records[i].path) .. ": " .. tostring(err))
        end
        lines[i] = text .. "\n"
    end
    return table.concat(lines), records
end

local function check_usage()
    local cases = {
        { { "bare.json" }, "unexpected argument: bare.json" },
        { { "--config", "a.json", "--source", "/tmp" }, "use either --config or --source with --index" },
        { { "--config", "a.json", "--index", "/tmp/out.listing" }, "use either --config or --source with --index" },
        { { "--source", "/tmp" }, "--source requires --index" },
        { { "--nope" }, "unknown argument: --nope" },
    }
    for i = 1, #cases do
        local code, out_text, err_text = run_cli(cases[i][1])
        expect_exit("usage " .. table.concat(cases[i][1], " "), code, out_text, err_text, 1, cases[i][2])
    end
end

local function check_config_rejections()
    local dir = base .. "/reject"
    local tree, work, output = fresh_pair(dir)
    lock_child(tree)
    mkdir(tree .. "/inner")
    local other = dir .. "/other"
    mkdir(other)
    local cfg_path = dir .. "/cfg.json"

    local function reject(doc, reason, label)
        write_config(cfg_path, doc)
        local code, out_text, err_text = run_cli({ "--config", cfg_path })
        expect_exit(label, code, out_text, err_text, 1, reason)
        expect_clean(label, work, output)
    end

    write_file(cfg_path, "not json")
    local code, out_text, err_text = run_cli({ "--config", cfg_path })
    expect_exit("bad json", code, out_text, err_text, 1,
        "config is not valid JSON: no valid JSON value at line 1, column 1")
    expect_clean("bad json", work, output)

    reject({
        work_dir = work,
        output_dir = output,
    }, "roots is required", "missing roots key")

    reject({
        roots = { { path = dir .. "/no-such-root", alias = "/fvl/a" } },
        work_dir = work,
        output_dir = output,
    }, "roots[1].path does not exist", "missing root")

    reject({
        roots = {
            { path = tree, alias = "/fvl/a" },
            { path = other, alias = "/fvl/a/child" },
        },
        work_dir = work,
        output_dir = output,
    }, "aliases overlap: /fvl/a and /fvl/a/child", "overlapping aliases")

    reject({
        roots = { { path = tree, alias = "/fvl/a" } },
        work_dir = tree .. "/inner",
        output_dir = output,
    }, "work_dir sits inside root " .. tree, "work dir inside a root")

    reject({
        roots = { { path = "/", alias = "/fvl/a" } },
        work_dir = work,
        output_dir = output,
    }, "roots[1].path must not be /", "path of /")

    reject({
        roots = { { path = tree, alias = "/fvl/a" } },
        work_dir = work,
        output_dir = output,
        exclude = { "/fvl/a" },
    }, "exclude[1] covers alias /fvl/a", "exclude covers an alias")
end

local function check_devices()
    local dir = base .. "/device"
    local tree, work = fresh_pair(dir)
    -- fresh_pair also makes an output on the same device. The real output is elsewhere.
    lock_child(tree)
    local other = track(capture("mktemp -d /mnt/extra/casually-phase7-dev.XXXXXX"))
    expect(other ~= "" and other:sub(1, 1) == "/", "cross-device temp dir " .. tostring(other))
    local tmp_dev = capture("stat -c %d " .. sh_quote(work))
    local out_dev = capture("stat -c %d " .. sh_quote(other))
    expect(tmp_dev ~= out_dev, "work and output landed on one device")
    local cfg = write_config(dir .. "/cfg.json", {
        roots = { { path = tree, alias = "/fvl/a" } },
        work_dir = work,
        output_dir = other,
    })
    local code, out_text, err_text = run_cli({ "--config", cfg })
    expect_exit("different devices", code, out_text, err_text, 1,
        "work_dir and output_dir are on different filesystems")
    expect_clean("different devices", work, other)
end

local function check_unreadable()
    local dir = base .. "/unreadable"
    local tree, work, output = fresh_pair(dir)
    local locked = lock_child(tree)
    local cfg = write_config(dir .. "/cfg.json", {
        roots = { { path = tree, alias = "/fvl/a" } },
        work_dir = work,
        output_dir = output,
    })
    local code, out_text, err_text = run_cli({ "--config", cfg })
    expect_exit("unreadable directory", code, out_text, err_text, 2,
        "cannot open " .. locked .. ": Permission denied")
    expect_clean("unreadable directory", work, output)
end

local function fake_fs(nodes)
    return {
        lstat = function(path)
            local item = nodes[path]
            if not item then
                return nil, "absent"
            end
            return item.attr
        end,
        dir = function(path)
            local item = nodes[path]
            if not item then
                return nil, "cannot open " .. path
            end
            local names = item.children or {}
            local index = 0
            local function iter()
                index = index + 1
                return names[index]
            end
            return iter, { close = function() end }
        end,
    }
end

local function node(mode, ino, extra)
    extra = extra or {}
    return {
        mode = mode,
        dev = 1,
        ino = ino,
        uid = extra.uid or 0,
        gid = extra.gid or 0,
        size = extra.size or 0,
        modification = extra.mtime or 0,
        permissions = extra.permissions or "rwxr-xr-x",
        target = extra.target,
    }
end

local function check_duplicate()
    -- A loaded config cannot contain two aliases that remap to one path.
    -- main calls run, and run still refuses the duplicate before it opens a partial.
    local dir = base .. "/duplicate"
    local work = dir .. "/work"
    local output = dir .. "/output"
    mkdir(dir)
    mkdir(work)
    mkdir(output)
    local virt = "/virt/dup"
    local nodes = {
        [virt] = {
            attr = node("directory", 1),
            children = { "same.txt", "same.txt" },
        },
        [virt .. "/same.txt"] = {
            attr = node("file", 2, { size = 1, permissions = "rw-r--r--" }),
        },
    }
    local cfg = {
        roots = { { path = virt, alias = "/fvl/dup" } },
        exclude = {},
        work_dir = work,
        output_dir = output,
    }
    local path, err, class = api.run(cfg, fake_fs(nodes), 1760000000)
    expect(path == nil, "duplicate returned a path")
    expect(class == "walk", "duplicate class " .. tostring(class))
    expect(err == "duplicate path /fvl/dup/same.txt", "duplicate reason " .. tostring(err))
    expect(#names_of(work) == 0, "duplicate left a partial")
    expect(#names_of(output) == 0, "duplicate wrote a listing")
end

local function getent_name(database, id)
    local handle = io.popen("getent " .. database .. " " .. tostring(id))
    if not handle then
        return nil
    end
    local line = handle:read("*l")
    handle:close()
    if not line then
        return nil
    end
    local name = line:match("^([^:]*)")
    if not name or name == "" or name:find("[: \t]") then
        return nil
    end
    return name
end

local function check_unknown_uid()
    local dir = base .. "/unknown"
    local work = dir .. "/work"
    local output = dir .. "/output"
    mkdir(dir)
    mkdir(work)
    mkdir(output)
    expect(getent_name("passwd", UNKNOWN_UID) == nil, "unknown uid already has a name")
    local group = getent_name("group", 0) or "0"
    local virt = "/virt/names"
    local nodes = {
        [virt] = {
            attr = node("directory", 1, { uid = 0, gid = 0 }),
            children = { "ghost" },
        },
        [virt .. "/ghost"] = {
            attr = node("file", 2, {
                uid = UNKNOWN_UID,
                gid = 0,
                size = 4,
                permissions = "rw-r--r--",
                mtime = 1760000000,
            }),
        },
    }
    local cfg = {
        roots = { { path = virt, alias = "/fvl/a" } },
        exclude = {},
        work_dir = work,
        output_dir = output,
    }
    local fs = fake_fs(nodes)
    local path, err, class = api.run(cfg, fs, 1760000000)
    expect(path ~= nil, "unknown uid publish failed: " .. tostring(err) .. " " .. tostring(class))
    if not path then
        return
    end
    local body = read_file(path)
    expect(#partials_in(work) == 0, "unknown uid left a partial")
    expect(body:sub(-1) == "\n", "unknown uid listing missing a final newline")
    local lines = listing_lines(body)
    expect(#lines == 2, "unknown uid line count " .. tostring(#lines))
    local ghost
    local previous
    for i = 1, #lines do
        local parsed = raw_fields(lines[i])
        expect(#parsed.mode == 10, "unknown uid mode " .. tostring(parsed.mode))
        expect(parsed.path == "/fvl/a" or parsed.path:sub(1, 7) == "/fvl/a/",
            "unknown uid alias " .. tostring(parsed.path))
        if previous then
            expect(previous < parsed.path, "unknown uid sort")
        end
        previous = parsed.path
        if parsed.path == "/fvl/a/ghost" then
            ghost = parsed
        end
    end
    expect(ghost ~= nil, "unknown uid file missing")
    if ghost then
        expect(ghost.owner == tostring(UNKNOWN_UID) .. ":" .. group,
            "unknown uid owner " .. tostring(ghost.owner))
        expect(ghost.mode == "-rw-r--r--", "unknown uid mode bytes " .. tostring(ghost.mode))
        expect(not ghost.bang, "unknown uid raised bang")
    end
end

local function preseeded_stamp(label, args_of, listing_of)
    local rolled = false
    for _ = 1, 2 do
        local dir = base .. "/" .. label
        os.execute("chmod -R u+rwx " .. sh_quote(dir) .. " >/dev/null 2>&1")
        os.execute("rm -rf " .. sh_quote(dir))
        local tree, work, output = fresh_pair(dir)
        lock_child(tree)
        local stamp = minute_now()
        local listing = listing_of(output, stamp)
        write_file(listing, "KEEP\n")
        local code, out_text, err_text = run_cli(args_of(tree, work, output, listing))
        if minute_now() ~= stamp then
            rolled = true
        else
            expect_exit(label, code, out_text, err_text, 3, "listing exists " .. listing)
            expect(read_file(listing) == "KEEP\n", label .. " changed the listing")
            expect(#partials_in(work) == 0, label .. " left a partial in work")
            expect(#partials_in(output) == 0, label .. " left a partial in output")
            expect(code == 3, label .. " walked an unreadable tree")
            return
        end
    end
    if rolled then
        fail(label .. " crossed a UTC minute twice")
    end
end

local function check_existing_outputs()
    preseeded_stamp("stamped-exists", function(tree, work, output)
        local cfg = write_config(base .. "/stamped-exists/cfg.json", {
            roots = { { path = tree, alias = "/fvl/a" } },
            work_dir = work,
            output_dir = output,
        })
        return { "--config", cfg }
    end, function(output, stamp)
        return output .. "/index-" .. stamp .. ".listing"
    end)

    preseeded_stamp("index-exists", function(tree, _, _, listing)
        return { "--source", tree, "--index", listing }
    end, function(output)
        return output .. "/tree.listing"
    end)
end

local function check_source()
    local dir = base .. "/source"
    local tree, _, output = fresh_pair(dir)
    local hello = tree .. "/hello.txt"
    write_file(hello, "hi")
    touch(tree)
    touch(hello)
    local index = output .. "/tree.listing"
    local code, out_text, err_text = run_cli({ "--source", tree, "--index", index })
    expect(code == 0, "source exit " .. tostring(code) .. " err " .. err_text)
    expect(out_text == "", "source stdout " .. string.format("%q", out_text))
    expect(err_text == "", "source stderr " .. string.format("%q", err_text))
    expect(#partials_in(output) == 0, "source left a partial")
    local body = read_file(index)
    local golden = golden_from({
        { abs = tree, path = tree },
        { abs = hello, path = hello },
    })
    expect(body == golden, "source listing bytes differ")
    expect(body:find(tree .. "/hello.txt", 1, true) ~= nil, "source listing omitted the real path")
    expect(body:sub(-1) == "\n", "source listing missing a final newline")
    local lines = listing_lines(body)
    expect(#lines == 2, "source line count " .. tostring(#lines))
    for i = 1, #lines do
        local parsed = raw_fields(lines[i])
        expect(#parsed.mode == 10, "source mode " .. tostring(parsed.mode))
        expect(parsed.path == tree or parsed.path:sub(1, #tree + 1) == tree .. "/",
            "source alias is not the real path " .. tostring(parsed.path))
    end
end

local function happy_once()
    local dir = base .. "/happy"
    os.execute("rm -rf " .. sh_quote(dir))
    local empty = dir .. "/empty"
    local data = dir .. "/data"
    local work = dir .. "/work"
    local output = dir .. "/output"
    mkdir(dir)
    mkdir(empty)
    mkdir(data)
    mkdir(data .. "/docs")
    mkdir(data .. "/skip")
    mkdir(work)
    mkdir(output)
    local readme = data .. "/docs/readme.txt"
    local hidden = data .. "/.hidden"
    local tabbed = data .. "/b\t"
    local slashed = data .. "/b\\t"
    local ff = data .. "/ff" .. string.char(255)
    local link = data .. "/docs/link"
    local dangling = data .. "/docs/dangling"
    write_file(readme, "hello")
    write_file(hidden, "dot")
    write_file(tabbed, "tab")
    write_file(slashed, "bs")
    write_file(ff, "ff")
    write_file(data .. "/skip/secret.txt", "nope")
    assert(api.lfs.link("../other/readme", link, true))
    assert(api.lfs.link("missing-target", dangling, true))
    sh("mkfifo " .. sh_quote(data .. "/pipe"))
    local touched = {
        empty, data, data .. "/docs", data .. "/skip",
        readme, hidden, tabbed, slashed, ff, link, dangling,
        data .. "/skip/secret.txt",
    }
    for i = 1, #touched do
        touch(touched[i])
    end
    local cfg = write_config(dir .. "/cfg.json", {
        roots = {
            { path = empty, alias = "/vacant" },
            { path = data, alias = "/fvl/a" },
        },
        work_dir = work,
        output_dir = output,
        exclude = { "/fvl/a/skip" },
    })
    local stamp = minute_now()
    local code, out_text, err_text = run_cli({ "--config", cfg })
    if minute_now() ~= stamp then
        return "rolled"
    end
    local listing = output .. "/index-" .. stamp .. ".listing"
    expect(code == 0, "happy exit " .. tostring(code) .. " err " .. err_text)
    expect(out_text == "", "happy stdout " .. string.format("%q", out_text))
    expect(err_text == "casually_index: skipped named pipe /fvl/a/pipe\n",
        "happy stderr " .. string.format("%q", err_text))
    expect(physical_lines(err_text) == 1, "happy warning lines")
    expect(#partials_in(work) == 0, "happy left a partial")
    local produced = stamped_in(output)
    expect(#produced == 1 and produced[1] == "index-" .. stamp .. ".listing",
        "happy listing names " .. table.concat(produced, ","))
    if code ~= 0 or not api.lfs.symlinkattributes(listing) then
        return "fail"
    end
    local body = read_file(listing)
    local items = {
        { abs = empty, path = "/vacant" },
        { abs = data, path = "/fvl/a" },
        { abs = hidden, path = "/fvl/a/.hidden" },
        { abs = tabbed, path = "/fvl/a/b\t" },
        { abs = slashed, path = "/fvl/a/b\\t" },
        { abs = data .. "/docs", path = "/fvl/a/docs" },
        { abs = dangling, path = "/fvl/a/docs/dangling" },
        { abs = link, path = "/fvl/a/docs/link" },
        { abs = readme, path = "/fvl/a/docs/readme.txt" },
        { abs = ff, path = "/fvl/a/ff" .. string.char(255) },
    }
    local golden, records = golden_from(items)
    expect(body == golden, "happy listing bytes differ")
    expect(body:sub(-1) == "\n", "happy listing missing a final newline")
    expect(body:sub(-2, -2) ~= "\n", "happy listing ends with a blank line")
    expect(body:find("/fvl/a/skip", 1, true) == nil, "happy listing included the exclude")
    expect(body:find("secret", 1, true) == nil, "happy listing included the excluded file")
    expect(body:find("/pipe", 1, true) == nil, "happy listing included the fifo")
    expect(body:find(string.char(255), 1, true) ~= nil, "happy listing dropped byte 0xFF")

    local lines = listing_lines(body)
    expect(#lines == #items, "happy line count " .. tostring(#lines))
    local vacant = 0
    local previous
    local saw_tab, saw_slash
    local tab_at, slash_at
    for i = 1, #lines do
        local parsed = raw_fields(lines[i])
        expect(parsed.path ~= nil, "happy line did not round-trip " .. lines[i])
        expect(parsed.mtime == MTIME_TEXT and #parsed.mtime == 15,
            "happy mtime " .. tostring(parsed.mtime))
        expect(parsed.owner == expect_owner, "happy owner " .. tostring(parsed.owner))
        expect(type(parsed.mode) == "string" and #parsed.mode == 10
            and parsed.mode:match("^[-dl][rwxstST%-]+$") ~= nil
            and #parsed.mode:match("^[-dl](.*)$") == 9,
            "happy mode " .. tostring(parsed.mode))
        expect(parsed.size ~= nil and parsed.size:match("^%d+$") ~= nil,
            "happy size " .. tostring(parsed.size))
        expect(parsed.path == "/vacant" or parsed.path == "/fvl/a" or parsed.path:sub(1, 7) == "/fvl/a/",
            "happy alias " .. tostring(parsed.path))
        if parsed.path == "/vacant" then
            vacant = vacant + 1
            expect(parsed.mode:sub(1, 1) == "d", "empty root is not a directory line")
        end
        expect(parsed.path == nil or parsed.path:sub(1, 9) ~= "/vacant/", "empty root has a child")
        if previous and parsed.path then
            expect(previous < parsed.path, "happy sort " .. previous .. " then " .. parsed.path)
        end
        previous = parsed.path
        if parsed.path == "/fvl/a/b\t" then
            saw_tab = parsed
            tab_at = i
            expect(parsed.bang, "tab path is not a bang line")
            expect(fields_of(lines[i]) == true, "tab bang flag")
        end
        if parsed.path == "/fvl/a/b\\t" then
            saw_slash = parsed
            slash_at = i
            expect(parsed.bang, "backslash path is not a bang line")
        end
        if parsed.path == "/fvl/a/docs/link" then
            expect(parsed.link == "../other/readme", "link target " .. tostring(parsed.link))
            expect(parsed.mode:sub(1, 1) == "l", "link mode " .. tostring(parsed.mode))
            expect(not parsed.bang, "plain symlink raised bang")
        end
        if parsed.path == "/fvl/a/docs/dangling" then
            expect(parsed.link == "missing-target", "dangling target " .. tostring(parsed.link))
        end
        if parsed.path == "/fvl/a/ff" .. string.char(255) then
            expect(not parsed.bang, "byte 0xFF raised bang")
            expect(lines[i]:find(string.char(255), 1, true) ~= nil, "0xFF line dropped the byte")
        end
        if parsed.path == "/fvl/a/.hidden" then
            expect(not parsed.bang, "dotfile raised bang")
        end
    end
    expect(vacant == 1, "empty root lines " .. tostring(vacant))
    expect(saw_tab ~= nil, "tab path missing")
    expect(saw_slash ~= nil, "backslash path missing")
    if tab_at and slash_at then
        expect(tab_at < slash_at, "tab path sorted by the escaped text")
    end
    if saw_tab then
        local _, _, _, _, _, link_field, path_field = fields_of(lines[tab_at])
        expect(unescape_field(path_field) == "/fvl/a/b\t", "tab round-trip " .. tostring(path_field))
        expect(link_field == "-", "tab link field " .. tostring(link_field))
    end
    if records then
        expect(#records == #items, "golden record count")
    end

    local again, again_out, again_err = run_cli({ "--config", cfg })
    if minute_now() ~= stamp then
        return "rolled"
    end
    expect_exit("same stamp", again, again_out, again_err, 3, "listing exists " .. listing)
    expect(read_file(listing) == body, "same stamp changed the listing")
    expect(#stamped_in(output) == 1, "same stamp added a listing")
    expect(#partials_in(work) == 0, "same stamp left a partial")
    return "ok"
end

local function check_happy()
    for _ = 1, 2 do
        local status = happy_once()
        if status == "ok" or status == "fail" then
            return
        end
    end
    fail("happy path crossed a UTC minute twice")
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /tmp/casually-phase7.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end
    check_usage()
    check_config_rejections()
    check_devices()
    check_unreadable()
    check_duplicate()
    check_unknown_uid()
    check_existing_outputs()
    check_source()
    check_happy()
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
io.stdout:write("phase 7 gate passed\n")
