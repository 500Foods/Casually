-- Phase 4 gate. Run from the repo root: lua test/phase4.lua
-- Walks a temp tree and a fake filesystem. Does not publish.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase4.lua")
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

expect(type(api.walk) == "function", "walk is exported")

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
    local text = (handle:read("a") or ""):gsub("%s+$", "")
    local ok = handle:close()
    if ok ~= true then
        error("command failed: " .. cmd)
    end
    return text
end

local function shown_name(name, id)
    if name == "" or name:find("[: \t]") then
        return tostring(id)
    end
    return name
end

local expect_user = shown_name(capture("id -un"), tonumber(capture("id -u")))
local expect_group = shown_name(capture("id -gn"), tonumber(capture("id -g")))
local expect_uid = tonumber(capture("id -u"))
local expect_gid = tonumber(capture("id -g"))

local base

local function cleanup()
    if not base then
        return
    end
    os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
    os.execute("rm -rf " .. sh_quote(base))
end

local function index_records(result, label)
    local map = {}
    if type(result) ~= "table" or type(result.records) ~= "table" then
        fail(label .. " missing records")
        return map
    end
    for i = 1, #result.records do
        local rec = result.records[i]
        if type(rec) ~= "table" or type(rec.path) ~= "string" then
            fail(label .. " bad record " .. i)
        elseif map[rec.path] then
            fail(label .. " duplicate path " .. rec.path)
        else
            map[rec.path] = rec
        end
    end
    return map
end

local function last_field(line)
    return line:match(".*\t(.*)")
end

local function mode_char(kind)
    if kind == "file" then
        return "-"
    end
    if kind == "dir" then
        return "d"
    end
    if kind == "link" then
        return "l"
    end
    return nil
end

local function assert_formatted(rec, label)
    local line, err = api.format_line(rec)
    expect(line ~= nil, label .. " format failed: " .. tostring(err))
    if not line then
        return nil
    end
    expect(line:find("\n", 1, true) == nil, label .. " formatted line has a newline")
    local want = mode_char(rec.kind)
    expect(line:match("^[!%d]") ~= nil, label .. " line does not start with mtime or bang")
    local body = line
    if line:sub(1, 1) == "!" then
        body = line:sub(2)
    end
    local mode = body:match("^[^\t]+\t[^\t]+\t([^\t]+)")
    expect(mode ~= nil and mode:sub(1, 1) == want,
        label .. " mode " .. tostring(mode) .. " for kind " .. tostring(rec.kind))
    return line
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /tmp/casually-phase4.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end

    local tree = base .. "/tree"
    local empty = base .. "/empty"
    local locked_root = base .. "/locked-root"
    local function mkdir(path)
        local ok, err = api.lfs.mkdir(path)
        if not ok then
            error("mkdir " .. path .. ": " .. tostring(err))
        end
    end
    local function write_file(path, text)
        local handle = assert(io.open(path, "wb"))
        handle:write(text or "x")
        handle:close()
    end

    mkdir(tree)
    mkdir(empty)
    mkdir(locked_root)
    mkdir(tree .. "/docs")
    mkdir(tree .. "/skip")
    mkdir(locked_root .. "/locked")
    write_file(tree .. "/docs/readme.txt", "hello")
    write_file(tree .. "/.hidden", "dot")
    write_file(tree .. "/my file", "sp")
    write_file(tree .. "/my\tfile", "tab")
    write_file(tree .. "/hard-a", "same")
    write_file(tree .. "/skip/secret.txt", "nope")
    write_file(locked_root .. "/locked/hidden.txt", "secret")
    assert(api.lfs.link("docs/readme.txt", tree .. "/link-file", true))
    assert(api.lfs.link("docs", tree .. "/link-dir", true))
    assert(api.lfs.link("missing-target", tree .. "/link-missing", true))
    assert(api.lfs.link(tree .. "/hard-a", tree .. "/hard-b"))
    sh("mkfifo " .. sh_quote(tree .. "/pipe"))
    assert(api.lfs.link(tree .. "/pipe", tree .. "/pipe-link"))

    local result, err, class = api.walk({
        roots = {
            { path = empty, alias = "/vacant" },
            { path = tree, alias = "/" },
        },
        exclude = { "/skip" },
    })
    expect(result ~= nil, "walk failed: " .. tostring(err) .. " class " .. tostring(class))
    expect(class == nil, "success class " .. tostring(class))
    local got = index_records(result, "tree")
    local want = {
        "/vacant",
        "/",
        "/docs",
        "/docs/readme.txt",
        "/.hidden",
        "/link-file",
        "/link-dir",
        "/link-missing",
        "/my file",
        "/my\tfile",
        "/hard-a",
        "/hard-b",
    }
    expect(result and #result.records == #want,
        "record count " .. tostring(result and #result.records))
    for i = 1, #want do
        expect(got[want[i]] ~= nil, "missing record " .. want[i])
    end
    expect(got["/skip"] == nil, "excluded directory was recorded")
    expect(got["/skip/secret.txt"] == nil, "excluded file was recorded")
    expect(got["/pipe"] == nil and got["/pipe-link"] == nil, "fifo was recorded")

    local function kind(path, expect_kind)
        local rec = got[path]
        if rec then
            expect(rec.kind == expect_kind, path .. " kind " .. tostring(rec.kind))
        end
        return rec
    end

    kind("/vacant", "dir")
    kind("/", "dir")
    kind("/docs", "dir")
    local readme = kind("/docs/readme.txt", "file")
    kind("/.hidden", "file")
    local link_file = kind("/link-file", "link")
    local link_dir = kind("/link-dir", "link")
    local link_miss = kind("/link-missing", "link")
    local spaced = kind("/my file", "file")
    local tabbed = kind("/my\tfile", "file")
    local hard_a = kind("/hard-a", "file")
    local hard_b = kind("/hard-b", "file")

    if link_file then
        expect(link_file.target == "docs/readme.txt", "file link target " .. tostring(link_file.target))
        expect(link_file.size == #"docs/readme.txt", "symlink size is the target length")
    end
    if link_dir then
        expect(link_dir.target == "docs", "dir link target " .. tostring(link_dir.target))
    end
    if link_miss then
        expect(link_miss.target == "missing-target", "dangling target " .. tostring(link_miss.target))
    end
    if hard_a and hard_b then
        expect(hard_a.ino == hard_b.ino and hard_a.dev == hard_b.dev,
            "hard-linked files are both kept")
    end
    if readme then
        expect(readme.size == 5, "readme size " .. tostring(readme.size))
    end

    for path, rec in pairs(got) do
        expect(rec.user == expect_user, path .. " user " .. tostring(rec.user))
        expect(rec.group == expect_group, path .. " group " .. tostring(rec.group))
        expect(rec.uid == expect_uid, path .. " uid " .. tostring(rec.uid))
        expect(rec.gid == expect_gid, path .. " gid " .. tostring(rec.gid))
        expect(type(rec.permissions) == "string" and #rec.permissions == 9,
            path .. " permissions " .. tostring(rec.permissions))
        local dotted = false
        for part in path:gmatch("[^/]+") do
            if part == "." or part == ".." then
                dotted = true
            end
        end
        expect(not dotted, "dot entry recorded " .. path)
        assert_formatted(rec, path)
    end

    local space_line = spaced and api.format_line(spaced)
    expect(space_line and space_line:sub(1, 1) ~= "!", "space in a path raises bang")
    expect(space_line and last_field(space_line) == "/my file", "space path was rewritten")

    local tab_line = tabbed and api.format_line(tabbed)
    expect(tab_line and tab_line:sub(1, 1) == "!", "tab path is not a bang line")
    expect(tab_line and last_field(tab_line) == "/my\\tfile",
        "tab path field " .. string.format("%q", tostring(tab_line and last_field(tab_line))))

    expect(result and #result.warnings == 1, "warning count " .. tostring(result and #result.warnings))
    local warning = result and result.warnings[1]
    if warning then
        expect(warning.type == "named pipe", "skip type " .. tostring(warning.type))
        expect(warning.path == "/pipe" or warning.path == "/pipe-link",
            "skip path " .. tostring(warning.path))
        expect(warning.path:find("\n", 1, true) == nil, "warning path has a newline")
    end

    local locked_dir = locked_root .. "/locked"
    sh("chmod 000 " .. sh_quote(locked_dir))
    local locked_ok, locked_err = xpcall(function()
        local denied, why, why_class = api.walk({
            roots = { { path = locked_root, alias = "/locked" } },
            exclude = {},
        })
        expect(denied == nil, "chmod 000 walk returned records")
        expect(why_class == "walk", "chmod 000 class " .. tostring(why_class) .. " err " .. tostring(why))
        expect(type(why) == "string" and why:find("Permission denied", 1, true) ~= nil,
            "chmod 000 reason " .. tostring(why))
    end, debug.traceback)
    sh("chmod 755 " .. sh_quote(locked_dir))
    if not locked_ok then
        error(locked_err, 0)
    end

    local function node(mode, dev, ino, extra)
        local attr = {
            mode = mode,
            dev = dev,
            ino = ino,
            uid = 0,
            gid = 0,
            size = extra and extra.size or 0,
            modification = 0,
            permissions = extra and extra.permissions or "rwxr-xr-x",
        }
        if extra and extra.target ~= nil then
            attr.target = extra.target
        end
        return attr
    end

    local function fake_walk(nodes, roots, rules)
        local open = 0
        local max_open = 0
        local lstat_while_open = 0
        local opened = {}
        local stated = {}
        local fs = {
            lstat = function(path)
                if open ~= 0 then
                    lstat_while_open = lstat_while_open + 1
                end
                stated[path] = (stated[path] or 0) + 1
                local item = nodes[path]
                if not item then
                    return nil, "absent"
                end
                return item.attr
            end,
            dir = function(path)
                opened[path] = (opened[path] or 0) + 1
                open = open + 1
                if open > max_open then
                    max_open = open
                end
                local item = nodes[path]
                if not item then
                    open = open - 1
                    return nil, "cannot open " .. path
                end
                local names = item.children or {}
                local index = 0
                local closed = false
                local function iter()
                    if closed then
                        error("closed directory")
                    end
                    index = index + 1
                    return names[index]
                end
                local obj = {}
                function obj:close()
                    if not closed then
                        closed = true
                        open = open - 1
                    end
                end
                return iter, obj
            end,
        }
        local walked, why, why_class = api.walk({
            roots = roots,
            exclude = rules or {},
        }, fs)
        return walked, why, why_class, {
            max_open = max_open,
            open = open,
            lstat_while_open = lstat_while_open,
            opened = opened,
            stated = stated,
        }
    end

    local virt = "/virt/root"
    local nodes = {
        [virt] = {
            attr = node("directory", 1, 1),
            children = { "mnt", "loop", "ok", "note.txt" },
        },
        [virt .. "/mnt"] = {
            attr = node("directory", 2, 9),
            children = { "secret" },
        },
        [virt .. "/mnt/secret"] = { attr = node("file", 2, 10) },
        [virt .. "/loop"] = {
            attr = node("directory", 1, 1),
            children = { "hidden" },
        },
        [virt .. "/loop/hidden"] = { attr = node("file", 1, 12) },
        [virt .. "/ok"] = {
            attr = node("directory", 1, 4),
            children = { "child.txt" },
        },
        [virt .. "/ok/child.txt"] = {
            attr = node("file", 1, 5, { size = 3, permissions = "rw-r--r--" }),
        },
        [virt .. "/note.txt"] = {
            attr = node("file", 1, 3, { size = 1, permissions = "rw-r--r--" }),
        },
    }
    local fake, fake_err, fake_class, stats = fake_walk(nodes, {
        { path = virt, alias = "/v" },
    })
    expect(fake ~= nil, "fake walk failed: " .. tostring(fake_err) .. " " .. tostring(fake_class))
    local fmap = index_records(fake, "fake")
    local fake_want = { "/v", "/v/mnt", "/v/loop", "/v/ok", "/v/ok/child.txt", "/v/note.txt" }
    expect(fake and #fake.records == #fake_want, "fake record count " .. tostring(fake and #fake.records))
    for i = 1, #fake_want do
        expect(fmap[fake_want[i]] ~= nil, "fake missing " .. fake_want[i])
    end
    expect(fmap["/v/mnt/secret"] == nil, "foreign mount child was recorded")
    expect(fmap["/v/loop/hidden"] == nil, "repeated inode child was recorded")
    if fmap["/v/mnt"] then
        expect(fmap["/v/mnt"].kind == "dir", "mount point kind")
    end
    if fmap["/v/loop"] then
        expect(fmap["/v/loop"].kind == "dir", "repeated directory kind")
    end
    expect(stats.opened[virt .. "/mnt"] == nil, "foreign mount was opened")
    expect(stats.opened[virt .. "/loop"] == nil, "repeated inode was opened")
    expect(stats.opened[virt] == 1, "root directory open count " .. tostring(stats.opened[virt]))
    expect(stats.opened[virt .. "/ok"] == 1, "nested directory was not opened once")
    expect(stats.stated[virt .. "/mnt/secret"] == nil, "foreign child was stat'd")
    expect(stats.stated[virt .. "/loop/hidden"] == nil, "loop child was stat'd")
    expect(stats.max_open <= 1, "open directories " .. tostring(stats.max_open))
    expect(stats.open == 0, "directory left open")
    expect(stats.lstat_while_open == 0, "lstat while a directory was open " .. tostring(stats.lstat_while_open))
    if fmap["/v/note.txt"] then
        expect(fmap["/v/note.txt"].user == "root", "fake uid 0 user " .. tostring(fmap["/v/note.txt"].user))
        expect(fmap["/v/note.txt"].group == "root", "fake gid 0 group " .. tostring(fmap["/v/note.txt"].group))
        assert_formatted(fmap["/v/note.txt"], "/v/note.txt")
    end

    local bad_root = "/virt/bad"
    local bad_nodes = {
        [bad_root] = {
            attr = node("directory", 1, 1),
            children = { "broken" },
        },
        [bad_root .. "/broken"] = { attr = node("link", 1, 2) },
    }
    local bad, bad_err, bad_class, bad_stats = fake_walk(bad_nodes, {
        { path = bad_root, alias = "/b" },
    })
    expect(bad == nil, "broken target returned records")
    expect(bad_class == "walk", "broken target class " .. tostring(bad_class))
    expect(bad_err == "cannot read target /b/broken", "broken target reason " .. tostring(bad_err))
    expect(bad_stats.max_open <= 1, "broken target open count " .. tostring(bad_stats.max_open))
    expect(bad_stats.lstat_while_open == 0, "broken target lstat while open")
    expect(bad_stats.open == 0, "broken target left a directory open")
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
io.stdout:write("phase 4 gate passed\n")
