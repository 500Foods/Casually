-- Phase 2 gate. Run from the repo root: lua test/phase2.lua
-- Loads casually_index.lua and checks config acceptance and every rejection.
-- A rejection exits 1, names the reason on one stderr line, and leaves the
-- work directory unchanged. The device mismatch uses the lstat seam.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase2.lua")
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
local work, output, locked, nested, outdir, nest_work
local root_a, root_b, root_ab, index_dir, plain, link_root, link_work

local function cleanup()
    if not base then
        return
    end
    os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
    os.execute("rm -rf " .. sh_quote(base))
end

local function jq(s)
    return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function root_obj(path, alias, extra)
    local body = '"path":' .. jq(path) .. ',"alias":' .. jq(alias)
    if extra then
        body = body .. "," .. extra
    end
    return "{" .. body .. "}"
end

local function document(opts)
    local parts = {}
    if opts.roots ~= nil then
        parts[#parts + 1] = '"roots":' .. opts.roots
    end
    if opts.work ~= nil then
        parts[#parts + 1] = '"work_dir":' .. jq(opts.work)
    end
    if opts.output ~= nil then
        parts[#parts + 1] = '"output_dir":' .. jq(opts.output)
    end
    if opts.exclude ~= nil then
        parts[#parts + 1] = '"exclude":' .. opts.exclude
    end
    if opts.extra then
        parts[#parts + 1] = opts.extra
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function arr(items)
    local parts = {}
    for i = 1, #items do
        parts[i] = jq(items[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function slashy(path)
    -- ///tmp/.../name/// collapses to /tmp/.../name
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

local function take_stable()
    stable = {
        work = entries(work),
        output = entries(output),
        locked = entries(locked),
        nested = entries(nested),
        outdir = entries(outdir),
        nest_work = entries(nest_work),
        listing = read_all(output .. "/already.listing"),
    }
end

local function expect_stable(label)
    expect(entries(work) == stable.work, label .. " changed work_dir: " .. entries(work))
    expect(entries(output) == stable.output, label .. " changed output_dir: " .. entries(output))
    expect(entries(locked) == stable.locked, label .. " changed locked: " .. entries(locked))
    expect(entries(nested) == stable.nested, label .. " changed nested: " .. entries(nested))
    expect(entries(outdir) == stable.outdir, label .. " changed outdir: " .. entries(outdir))
    expect(entries(nest_work) == stable.nest_work, label .. " changed nest-work: " .. entries(nest_work))
    expect(read_all(output .. "/already.listing") == stable.listing, label .. " changed existing listing")
    expect(not entries(work):find(".casually_index.probe.", 1, true), label .. " left a probe in work_dir")
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
    expect(err == "casually_index: " .. reason .. "\n",
        "stderr for " .. reason .. " got " .. string.format("%q", err))
    local cfg, merr, class = api.load_config({ config = path })
    reject_module(cfg, merr, class, reason, reason)
    expect_stable(reason)
end

local function reject_flags(source, index, reason)
    local code, out, err = run({ "--source", source, "--index", index })
    expect(code == 1, "exit 1 for " .. reason .. " got " .. tostring(code) .. " err " .. err)
    expect(out == "", "stdout for " .. reason .. " got " .. string.format("%q", out))
    expect(err == "casually_index: " .. reason .. "\n",
        "stderr for " .. reason .. " got " .. string.format("%q", err))
    local cfg, merr, class = api.load_config({ source = source, index = index })
    reject_module(cfg, merr, class, reason, reason)
    expect_stable(reason)
end

local function expect_shape(cfg, want, label)
    if type(cfg) ~= "table" then
        fail(label .. " did not return a config (" .. tostring(cfg) .. ")")
        return
    end
    expect(cfg.work_dir == want.work_dir, label .. " work_dir " .. tostring(cfg.work_dir))
    expect(cfg.output_dir == want.output_dir, label .. " output_dir " .. tostring(cfg.output_dir))
    expect(cfg.output_path == want.output_path, label .. " output_path " .. tostring(cfg.output_path))
    expect(#cfg.roots == #want.roots, label .. " root count " .. tostring(cfg.roots and #cfg.roots))
    for i = 1, #want.roots do
        local got = cfg.roots[i]
        if type(got) ~= "table" then
            fail(label .. " missing root " .. i)
        else
            expect(got.path == want.roots[i].path, label .. " root path " .. i .. " " .. tostring(got.path))
            expect(got.alias == want.roots[i].alias, label .. " root alias " .. i .. " " .. tostring(got.alias))
            expect(keys_of(got) == "alias,path", label .. " root keys " .. keys_of(got))
        end
    end
    expect(#cfg.exclude == #want.exclude, label .. " exclude count " .. tostring(#cfg.exclude))
    for i = 1, #want.exclude do
        expect(cfg.exclude[i] == want.exclude[i], label .. " exclude " .. i .. " " .. tostring(cfg.exclude[i]))
    end
    local want_keys = want.output_path and "exclude,output_dir,output_path,roots,work_dir"
        or "exclude,output_dir,roots,work_dir"
    expect(keys_of(cfg) == want_keys, label .. " keys " .. keys_of(cfg))
end

local function configs_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.work_dir ~= b.work_dir or a.output_dir ~= b.output_dir or a.output_path ~= b.output_path then
        return false
    end
    if #a.roots ~= #b.roots or #a.exclude ~= #b.exclude then
        return false
    end
    for i = 1, #a.roots do
        if a.roots[i].path ~= b.roots[i].path or a.roots[i].alias ~= b.roots[i].alias then
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

local function with_mode(dir, mode, fn)
    sh("chmod " .. mode .. " " .. sh_quote(dir))
    local ok, err = xpcall(fn, debug.traceback)
    sh("chmod 755 " .. sh_quote(dir))
    if not ok then
        error(err, 0)
    end
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /tmp/casually-phase2.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end

    root_a = base .. "/root-a"
    root_b = base .. "/root-b"
    root_ab = base .. "/root-ab"
    work = base .. "/work"
    output = base .. "/output"
    locked = base .. "/locked"
    index_dir = base .. "/index-dir"
    plain = base .. "/plain"
    link_root = base .. "/link-root"
    link_work = base .. "/link-work"
    nested = root_a .. "/nested"
    outdir = root_a .. "/outdir"
    nest_work = base .. "/nest-work"

    local function mkdir(path)
        local ok, err = api.lfs.mkdir(path)
        if not ok then
            error("mkdir " .. path .. ": " .. tostring(err))
        end
    end

    mkdir(root_a)
    mkdir(nested)
    mkdir(outdir)
    mkdir(root_b)
    mkdir(root_ab)
    mkdir(work)
    mkdir(output)
    mkdir(locked)
    mkdir(index_dir)
    mkdir(nest_work)
    mkdir(nest_work .. "/root-inside")
    assert(api.lfs.link(root_a, link_root, true))
    assert(api.lfs.link(work, link_work, true))
    assert(api.lfs.link(index_dir, output .. "/link-index", true))
    local plain_f = assert(io.open(plain, "wb"))
    plain_f:write("x")
    plain_f:close()
    local listing_f = assert(io.open(output .. "/already.listing", "wb"))
    listing_f:write("keep-me\n")
    listing_f:close()
    take_stable()
    expect(stable.work == "", "work starts empty")
    expect(stable.listing == "keep-me\n", "listing fixture")

    local two_roots = "[" .. root_obj(root_a, "/fvl/a") .. "," .. root_obj(root_b, "/fvl/b") .. "]"
    local one_root = "[" .. root_obj(root_a, "/fvl/a") .. "]"

    reject_config("not json", "config is not valid JSON: no valid JSON value at line 1, column 1")
    reject_config("", "config is not valid JSON: no valid JSON value (reached the end)")
    reject_config("{}\n[]", "config is not valid JSON: trailing data")
    reject_config("[1]", "config is not a JSON object")
    reject_config("null", "config is not a JSON object")
    reject_config("true", "config is not a JSON object")
    reject_config('"x"', "config is not a JSON object")
    reject_config("{}", "roots is required")
    reject_config('{"roots":null}', "roots is required")
    reject_config('{"roots":{}}', "roots must be an array")
    reject_config('{"roots":[]}', "roots is empty")
    reject_config('{"roots":["nope"]}', "roots[1] must be an object")
    reject_config(
        document({
            roots = "[" .. root_obj(root_a, "/fvl/a", '"a_key":1,"z_key":2') .. "]",
            work = work,
            output = work,
        }),
        "roots[1] unknown key: a_key")
    reject_config('{"roots":[{"alias":"/fvl/a"}]}', "roots[1].path is required")
    reject_config('{"roots":[{"path":1,"alias":"/fvl/a"}]}', "roots[1].path must be a string")
    reject_config('{"roots":[{"path":"","alias":"/fvl/a"}]}', "roots[1].path is empty")
    reject_config('{"roots":[{"path":"relative","alias":"/fvl/a"}]}', "roots[1].path must be absolute")
    reject_config('{"roots":[{"path":"/tmp/../x","alias":"/fvl/a"}]}', "roots[1].path contains '.' or '..'")
    reject_config('{"roots":[{"path":"/tmp/./x","alias":"/fvl/a"}]}', "roots[1].path contains '.' or '..'")
    reject_config('{"roots":[{"path":"/","alias":"/fvl/a"}]}', "roots[1].path must not be /")
    reject_config('{"roots":[{"path":"///","alias":"/fvl/a"}]}', "roots[1].path must not be /")
    reject_config(
        document({ roots = "[" .. root_obj(base .. "/missing", "/fvl/a") .. "]" }),
        "roots[1].path does not exist")
    reject_config(
        document({ roots = "[" .. root_obj(plain, "/fvl/a") .. "]" }),
        "roots[1].path is not a directory")
    reject_config(
        document({ roots = "[" .. root_obj(link_root, "/fvl/a") .. "]" }),
        "roots[1].path is not a real directory")
    reject_config(
        document({ roots = '[{"path":' .. jq(root_a) .. '}]' }),
        "roots[1].alias is required")
    reject_config(
        document({ roots = "[" .. root_obj(root_a, "") .. "]" }),
        "roots[1].alias is empty")
    reject_config(
        document({ roots = "[" .. root_obj(root_a, "fvl/a") .. "]" }),
        "roots[1].alias must be absolute")
    reject_config(
        document({ roots = "[" .. root_obj(root_a, "/fvl/../a") .. "]" }),
        "roots[1].alias contains '.' or '..'")
    reject_config(
        document({
            roots = "[" .. root_obj(slashy(root_a), "/fvl/a") .. "," .. root_obj(nested, "/fvl/nested") .. "]",
            work = work,
            output = work,
        }),
        "roots overlap: " .. root_a .. " and " .. nested)
    reject_config(
        document({
            roots = "[" .. root_obj(root_a .. "/", "/one") .. "," .. root_obj(root_a .. "///", "/two") .. "]",
            work = work,
            output = work,
        }),
        "roots overlap: " .. root_a .. " and " .. root_a)
    reject_config(
        document({
            roots = "[" .. root_obj(root_a, "/fvl/a") .. "," .. root_obj(root_b, "/fvl/a/child") .. "]",
            work = work,
            output = work,
        }),
        "aliases overlap: /fvl/a and /fvl/a/child")
    reject_config(
        document({
            roots = "[" .. root_obj(root_a, "/fvl/a") .. "," .. root_obj(root_b, "/fvl/a/") .. "]",
            work = work,
            output = work,
        }),
        "aliases overlap: /fvl/a and /fvl/a")
    reject_config(
        document({
            roots = "[" .. root_obj(root_a, "/") .. "," .. root_obj(root_b, "/fvl/b") .. "]",
            work = work,
            output = work,
        }),
        "aliases overlap: / and /fvl/b")
    reject_config(
        document({ roots = two_roots, output = work }),
        "work_dir is required")
    reject_config(
        document({ roots = two_roots, work = work }),
        "output_dir is required")
    reject_config(
        document({ roots = one_root, work = "relative", output = work }),
        "work_dir must be absolute")
    reject_config(
        document({ roots = one_root, work = base .. "/no-work", output = work }),
        "work_dir does not exist")
    reject_config(
        document({ roots = one_root, work = plain, output = work }),
        "work_dir is not a directory")
    reject_config(
        document({ roots = one_root, work = link_work, output = work }),
        "work_dir is not a real directory")
    reject_config(
        document({ roots = one_root, work = work, output = base .. "/no-out" }),
        "output_dir does not exist")
    reject_config(
        document({ roots = one_root, work = work, output = plain }),
        "output_dir is not a directory")
    reject_config(
        document({ roots = one_root, work = root_a, output = work }),
        "work_dir sits inside root " .. root_a)
    reject_config(
        document({ roots = one_root, work = nested, output = work }),
        "work_dir sits inside root " .. root_a)
    reject_config(
        document({ roots = one_root, work = work, output = nested }),
        "output_dir sits inside root " .. root_a)
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = "null" }),
        "exclude must be an array")
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = "{}" }),
        "exclude must be an array")
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = "[1]" }),
        "exclude[1] must be a string")
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = '[""]' }),
        "exclude[1] is empty")
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = '["relative"]' }),
        "exclude[1] must be absolute")
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = '["/fvl/../a"]' }),
        "exclude[1] contains '.' or '..'")
    reject_config(
        document({ roots = one_root, work = work, output = work, exclude = arr({ "/fvl/a/" }) }),
        "exclude[1] covers alias /fvl/a")
    reject_config(
        document({ roots = two_roots, work = work, output = work, exclude = arr({ "/fvl/" }) }),
        "exclude[1] covers alias /fvl/a")
    reject_config(
        document({ roots = two_roots, work = work, output = work, exclude = arr({ "/" }) }),
        "exclude[1] covers alias /fvl/a")
    reject_config(
        document({
            roots = "[" .. root_obj(root_a, "/tree/a/.snapshot") .. "]",
            work = work,
            output = work,
            exclude = arr({ "/tree/a" }),
        }),
        "exclude[1] covers alias /tree/a/.snapshot")
    reject_config(
        '{"a_extra":true,"z_extra":true}',
        "unknown config key: a_extra")

    local missing = base .. "/no-such-config.json"
    local code, out, err = run({ "--config", missing })
    local missing_reason = "cannot read config " .. missing .. ": " .. missing .. ": No such file or directory"
    expect(code == 1, "missing config exit " .. tostring(code))
    expect(out == "", "missing config stdout")
    expect(err == "casually_index: " .. missing_reason .. "\n",
        "missing config stderr " .. string.format("%q", err))
    local mcfg, merr, mclass = api.load_config({ config = missing })
    reject_module(mcfg, merr, mclass, missing_reason, "missing config")
    expect_stable("missing config")

    local denied = write_cfg("{")
    with_mode(denied, "000", function()
        local reason = "cannot read config " .. denied .. ": " .. denied .. ": Permission denied"
        local dcode, dout, derr = run({ "--config", denied })
        expect(dcode == 1, "unreadable config exit " .. tostring(dcode) .. " " .. derr)
        expect(dout == "", "unreadable config stdout")
        expect(derr == "casually_index: " .. reason .. "\n",
            "unreadable config stderr " .. string.format("%q", derr))
        local dcfg, derr_m, dclass = api.load_config({ config = denied })
        reject_module(dcfg, derr_m, dclass, reason, "unreadable config")
    end)
    expect_stable("unreadable config")

    with_mode(locked, "555", function()
        reject_config(
            document({ roots = one_root, work = locked, output = locked }),
            "work_dir is not writable")
        reject_config(
            document({ roots = one_root, work = work, output = locked }),
            "output_dir is not writable")
    end)

    local device_text = document({
        roots = one_root,
        work = work,
        output = output,
    })
    local device_path = write_cfg(device_text)
    local dcfg, derr, dclass = api.load_config({ config = device_path }, {
        lstat = function(path)
            local attr, lerr = api.lfs.symlinkattributes(path)
            if not attr then
                return nil, lerr
            end
            if path == output then
                local copy = {}
                for key, value in pairs(attr) do
                    copy[key] = value
                end
                copy.dev = attr.dev + 1
                return copy
            end
            return attr
        end,
    })
    reject_module(dcfg, derr, dclass, "work_dir and output_dir are on different filesystems", "device seam")
    expect_stable("device seam")

    -- work_dir "/" is a real directory. A device mismatch after normalize proves
    -- the syntax check let "/" through and did not probe.
    local slash_path = write_cfg(document({
        roots = '[{"path":"/virt/root","alias":"/alias"}]',
        work = "///",
        output = "/virt/out",
    }))
    local scfg, serr, sclass = api.load_config({ config = slash_path }, {
        lstat = function(path)
            local dev = { ["/virt/root"] = 1, ["/"] = 1, ["/virt/out"] = 2 }
            if not dev[path] then
                return nil, "absent"
            end
            return { mode = "directory", dev = dev[path], ino = 1 }
        end,
    })
    reject_module(scfg, serr, sclass,
        "work_dir and output_dir are on different filesystems", "work_dir /")
    expect_stable("work_dir /")

    local valid_text = document({
        roots = "[" .. root_obj(slashy(root_a), "/fvl/a///") .. "," .. root_obj(root_b, "/fvl/b") .. "]",
        work = slashy(work),
        output = work .. "///",
        exclude = arr({ "/fvl/a/nested///" }),
    })
    accept_config(valid_text, {
        work_dir = work,
        output_dir = work,
        output_path = nil,
        roots = {
            { path = root_a, alias = "/fvl/a" },
            { path = root_b, alias = "/fvl/b" },
        },
        exclude = { "/fvl/a/nested" },
    }, "valid two-root config")

    accept_config(document({
        roots = two_roots,
        work = work,
        output = output,
        exclude = "[]",
    }), {
        work_dir = work,
        output_dir = output,
        output_path = nil,
        roots = {
            { path = root_a, alias = "/fvl/a" },
            { path = root_b, alias = "/fvl/b" },
        },
        exclude = {},
    }, "distinct work and output on one device")

    accept_config(document({
        roots = "[" .. root_obj(root_a, "/n/a") .. "," .. root_obj(root_ab, "/n/ab") .. "]",
        work = work,
        output = work,
    }), {
        work_dir = work,
        output_dir = work,
        output_path = nil,
        roots = {
            { path = root_a, alias = "/n/a" },
            { path = root_ab, alias = "/n/ab" },
        },
        exclude = {},
    }, "root-a does not overlap root-ab")

    accept_config(document({
        roots = "[" .. root_obj(root_ab, "/n/ab") .. "]",
        work = work,
        output = work,
        exclude = arr({ "/n/a" }),
    }), {
        work_dir = work,
        output_dir = work,
        output_path = nil,
        roots = { { path = root_ab, alias = "/n/ab" } },
        exclude = { "/n/a" },
    }, "exclude /n/a does not cover alias /n/ab")

    accept_config(document({
        roots = "[" .. root_obj(root_a, "/tree/a/.snapshot") .. "]",
        work = work,
        output = work,
        exclude = arr({ "/tree/a/.snap" }),
    }), {
        work_dir = work,
        output_dir = work,
        output_path = nil,
        roots = { { path = root_a, alias = "/tree/a/.snapshot" } },
        exclude = { "/tree/a/.snap" },
    }, "exclude stops at a path-component boundary")

    accept_config(document({
        roots = "[" .. root_obj(root_a, "///") .. "]",
        work = work,
        output = work,
        exclude = arr({ "/docs" }),
    }), {
        work_dir = work,
        output_dir = work,
        output_path = nil,
        roots = { { path = root_a, alias = "/" } },
        exclude = { "/docs" },
    }, "alias / with an exclude under it")

    accept_config(document({
        roots = "[" .. root_obj(nest_work .. "/root-inside", "/inside") .. "]",
        work = nest_work,
        output = nest_work,
    }), {
        work_dir = nest_work,
        output_dir = nest_work,
        output_path = nil,
        roots = { { path = nest_work .. "/root-inside", alias = "/inside" } },
        exclude = {},
    }, "root inside the work directory is allowed")

    reject_flags("relative", work .. "/out.listing", "--source must be absolute")
    reject_flags("", work .. "/out.listing", "--source is empty")
    reject_flags(root_a .. "/../root-a", work .. "/out.listing", "--source contains '.' or '..'")
    reject_flags(base .. "/missing-root", work .. "/out.listing", "--source does not exist")
    reject_flags(plain, work .. "/out.listing", "--source is not a directory")
    reject_flags(link_root, work .. "/out.listing", "--source is not a real directory")
    reject_flags("/", work .. "/out.listing", "--source must not be /")
    reject_flags("///", work .. "/out.listing", "--source must not be /")
    reject_flags(root_a, "out.listing", "--index must be absolute")
    reject_flags(root_a, "", "--index is empty")
    reject_flags(root_a, work .. "/../out.listing", "--index contains '.' or '..'")
    reject_flags(root_a, "/", "--index is a directory")
    reject_flags(root_a, index_dir, "--index is a directory")
    reject_flags(root_a, root_a .. "/outdir/list.listing", "--index parent sits inside the source")
    reject_flags(root_a, base .. "/missing-parent/out.listing", "--index parent does not exist")
    reject_flags(root_a, plain .. "/out.listing", "--index parent is not a directory")
    reject_flags(root_a, link_work .. "/out.listing", "--index parent is not a real directory")

    local flag_source = slashy(root_a)
    local flag_index = work .. "//out.listing"
    local flag, ferr, fclass = api.load_config({ source = flag_source, index = flag_index })
    if not flag then
        fail("flag form rejected: " .. tostring(ferr) .. " class " .. tostring(fclass))
    else
        expect_shape(flag, {
            work_dir = work,
            output_dir = work,
            output_path = work .. "/out.listing",
            roots = { { path = root_a, alias = root_a } },
            exclude = {},
        }, "flag form")
        local flag2 = api.load_config({ source = flag_source, index = flag_index })
        expect(configs_equal(flag, flag2), "flag form second run differs")
    end
    expect_stable("flag form")

    local existing, eerr, eclass = api.load_config({
        source = root_a,
        index = output .. "/already.listing",
    })
    if not existing then
        fail("existing listing rejected: " .. tostring(eerr) .. " class " .. tostring(eclass))
    else
        expect(existing.output_path == output .. "/already.listing", "existing output_path")
        expect(existing.work_dir == output and existing.output_dir == output, "existing parent dirs")
    end
    expect_stable("existing listing")

    local linked, lerr, lclass = api.load_config({
        source = root_a,
        index = output .. "/link-index",
    })
    if not linked then
        fail("symlink index rejected: " .. tostring(lerr) .. " class " .. tostring(lclass))
    else
        expect(linked.output_path == output .. "/link-index", "symlink index path")
    end
    expect_stable("symlink index")

    local none, nerr, nclass = api.load_config(nil)
    reject_module(none, nerr, nclass, "missing arguments", "nil command")
    local empty, empty_err, empty_class = api.load_config({})
    reject_module(empty, empty_err, empty_class, "missing arguments", "empty command")

    local probe = io.popen("find " .. sh_quote(base) .. " -name '.casually_index.probe.*' -print")
    local probes = probe:read("a") or ""
    probe:close()
    expect(probes == "", "probe files left behind: " .. probes)
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
io.stdout:write("phase 2 gate passed\n")
