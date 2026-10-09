-- Phase 6 gate. Run from the repo root: lua test/phase6.lua
-- Headless listing, warning lines, eighths cells, and the panel stripper.
-- A pty stands in for the interactive terminal: q aborts, a full run finishes.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase6.lua")
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

expect(type(api.display_text) == "function", "display_text is exported")
expect(type(api.progress_eighths) == "function", "progress_eighths is exported")

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
    local ok, how, code = os.execute(cmd)
    if ok ~= true then
        error("command failed (" .. tostring(how) .. " " .. tostring(code) .. "): " .. cmd)
    end
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

local base

local function cleanup()
    if not base then
        return
    end
    os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
    os.execute("rm -rf " .. sh_quote(base))
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

local function json_config(text, path)
    write_file(path, text)
    return path
end

local function listing_bytes(records)
    local copy = {}
    for i = 1, #records do
        copy[i] = records[i]
    end
    table.sort(copy, function(a, b)
        return a.path < b.path
    end)
    local lines = {}
    for i = 1, #copy do
        local text, err = api.format_line(copy[i])
        if not text then
            error("format " .. tostring(copy[i].path) .. ": " .. tostring(err))
        end
        lines[i] = text .. "\n"
    end
    return table.concat(lines)
end

local function check_strip_and_bar()
    local esc = string.char(27)
    local raw = "a\tb\nc" .. esc .. "[31;1mZ" .. esc .. "[0md\r"
    local shown = api.display_text(raw)
    expect(shown == "a    bcZd", "display text " .. string.format("%q", shown))
    expect(shown:find("\n", 1, true) == nil, "display text kept a newline")
    expect(shown:find("\t", 1, true) == nil, "display text kept a tab")
    expect(shown:find(esc, 1, true) == nil, "display text kept an escape")
    local raw_byte = "x" .. string.char(255) .. "y"
    expect(api.display_text(raw_byte) == raw_byte, "display text changed a non-control byte")

    local function cells_of(current, total)
        local cells, pct = api.progress_eighths(current, total)
        local chars = {}
        for i = 1, #cells do
            chars[i] = cells[i].ch
            expect(cells[i].attr and cells[i].attr.bg == 236,
                "eighths background " .. tostring(cells[i].attr and cells[i].attr.bg))
        end
        return table.concat(chars), pct
    end

    local zero, zero_pct = cells_of(0, 8)
    expect(zero == " ", "zero bar " .. string.format("%q", zero))
    expect(zero_pct == 0, "zero percent " .. tostring(zero_pct))
    local half, half_pct = cells_of(4, 8)
    expect(half == utf8.char(0x258C), "half bar " .. string.format("%q", half))
    expect(half_pct == 50, "half percent " .. tostring(half_pct))
    local full, full_pct = cells_of(8, 8)
    expect(full == utf8.char(0x2588), "full bar " .. string.format("%q", full))
    expect(full_pct == 100, "full percent " .. tostring(full_pct))
    local empty, empty_pct = cells_of(0, 0)
    expect(empty == "", "empty total drew " .. string.format("%q", empty))
    expect(empty_pct == 0, "empty percent " .. tostring(empty_pct))
end

local function check_abort(dir)
    mkdir(dir)
    write_file(dir .. "/one.txt", "x")
    local listing = dir .. "/out.listing"
    local ticks = 0
    local phased = false
    local progress = {
        tick = function()
            ticks = ticks + 1
            return nil, "aborted", "walk"
        end,
        phase = function()
            phased = true
            return true
        end,
    }
    local path, err, class = api.run({
        work_dir = dir,
        output_dir = dir,
        output_path = listing,
        roots = { { path = dir, alias = "/a" } },
        exclude = {},
    }, nil, 0, nil, progress)
    expect(path == nil, "abort published")
    expect(class == "walk", "abort class " .. tostring(class))
    expect(err == "aborted", "abort reason " .. tostring(err))
    expect(ticks == 1, "abort ticks " .. tostring(ticks))
    expect(not phased, "abort reached sort or publish")
    expect(api.lfs.symlinkattributes(listing) == nil, "abort created a listing")
    expect(#partials_in(dir) == 0, "abort created a partial")
end

local function check_headless(tree, empty, out, cfg_path)
    mkdir(tree)
    mkdir(empty)
    mkdir(out)
    mkdir(tree .. "/docs")
    mkdir(tree .. "/skip")
    write_file(tree .. "/docs/readme.txt", "hello")
    write_file(tree .. "/.hidden", "dot")
    write_file(tree .. "/my file", "sp")
    write_file(tree .. "/my\tfile", "tab")
    write_file(tree .. "/hard-a", "same")
    write_file(tree .. "/skip/secret.txt", "nope")
    assert(api.lfs.link("docs/readme.txt", tree .. "/link-file", true))
    assert(api.lfs.link("docs", tree .. "/link-dir", true))
    assert(api.lfs.link("missing-target", tree .. "/link-missing", true))
    assert(api.lfs.link(tree .. "/hard-a", tree .. "/hard-b"))
    sh("mkfifo " .. sh_quote(tree .. "/pipe"))
    assert(api.lfs.link(tree .. "/pipe", tree .. "/pipe-link"))

    -- Alias "/" is a prefix of every other alias, so the loader rejects the
    -- phase 4 walk's pair. The tree is the same; the data root alias is /data.
    local cfg = {
        roots = {
            { path = empty, alias = "/vacant" },
            { path = tree, alias = "/data" },
        },
        exclude = { "/data/skip" },
        work_dir = out,
        output_dir = out,
    }
    json_config(string.format([[{
  "roots": [
    {"path": %q, "alias": "/vacant"},
    {"path": %q, "alias": "/data"}
  ],
  "exclude": ["/data/skip"],
  "work_dir": %q,
  "output_dir": %q
}
]], empty, tree, out, out), cfg_path)

    local walked, werr, wclass = api.walk(cfg)
    expect(walked ~= nil, "fixture walk " .. tostring(werr) .. " " .. tostring(wclass))
    if not walked then
        return
    end
    local want = listing_bytes(walked.records)
    local code, out_text, err_text = run_cli({ "--config", cfg_path })
    expect(code == 0, "headless exit " .. tostring(code) .. " err " .. err_text)
    expect(out_text == "", "headless stdout " .. string.format("%q", out_text))
    local pipe_warn = err_text == "casually_index: skipped named pipe /data/pipe\n"
        or err_text == "casually_index: skipped named pipe /data/pipe-link\n"
    expect(pipe_warn, "fifo warning " .. string.format("%q", err_text))
    expect(err_text:find("\n") == #err_text, "fifo warning is more than one physical line")
    local produced = {}
    for _, name in ipairs(names_of(out)) do
        if name:match("^index%-%d%d%d%d%d%d%d%d%-%d%d%d%d%.listing$") then
            produced[#produced + 1] = name
        end
    end
    expect(#produced == 1, "stamped listings " .. table.concat(produced, ","))
    expect(#partials_in(out) == 0, "headless left a partial")
    if produced[1] then
        local got = read_file(out .. "/" .. produced[1])
        expect(got == want, "listing does not match the sorted walk")
        expect(got:sub(-1) == "\n", "listing missing final newline")
        expect(got:find("/data/skip", 1, true) == nil, "listing included an excluded path")
        expect(got:find("/pipe", 1, true) == nil, "listing included the fifo")
    end
end

local function check_newline_warning(dir, out)
    mkdir(dir)
    mkdir(out)
    write_file(dir .. "/hello.txt", "hi")
    local fifo = dir .. "/odd\nname"
    sh("python3 -c 'import os,sys; os.mkfifo(sys.argv[1])' " .. sh_quote(fifo))
    local index = out .. "/nl.listing"
    local code, out_text, err_text = run_cli({ "--source", dir, "--index", index })
    -- The alias is the source path, so the remapped name still contains the newline.
    local warn = "casually_index: skipped named pipe " .. dir .. "/odd\\nname\n"
    expect(code == 0, "newline exit " .. tostring(code) .. " err " .. err_text)
    expect(out_text == "", "newline stdout " .. string.format("%q", out_text))
    expect(err_text == warn, "newline warning " .. string.format("%q", err_text) .. " want " .. string.format("%q", warn))
    local newlines = 0
    for _ in err_text:gmatch("\n") do
        newlines = newlines + 1
    end
    expect(newlines == 1, "newline warning physical lines " .. tostring(newlines))
    expect(err_text:find("\\n", 1, true) ~= nil, "newline warning did not escape the path")
    if api.lfs.symlinkattributes(index) then
        local body = read_file(index)
        expect(body:find("\nname", 1, true) == nil, "listing embedded the newline name")
        expect(body:sub(-1) == "\n", "newline fixture listing missing final newline")
    end
end

local PTY_PY = [=[
import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time
exe, source, index, mode = sys.argv[1:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
err_r, err_w = os.pipe()
env = os.environ.copy()
for key in ("LUA_PATH", "LUA_CPATH", "LUA_INIT"):
    env.pop(key, None)
env["LC_ALL"] = "C"
proc = subprocess.Popen(
    [exe, "--source", source, "--index", index],
    stdin=slave, stdout=slave, stderr=err_w, env=env, close_fds=True,
)
os.close(slave)
os.close(err_w)
buf = b""
err = b""
sent = False
timed_out = False
start = time.time()
limit = 30 if mode == "quit" else 90

def drain(timeout):
    global buf, err
    ready, _, _ = select.select([master, err_r], [], [], timeout)
    for fd in ready:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            continue
        if fd == master:
            buf += chunk
        else:
            err += chunk

while True:
    if proc.poll() is not None:
        drain(0)
        break
    if time.time() - start > limit:
        timed_out = True
        proc.kill()
        drain(0.2)
        break
    drain(0.1)
    if mode == "quit" and not sent:
        plain_now = re.sub(br"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", buf)
        nums = []
        for item in re.findall(br"files (\d+)", plain_now):
            if item not in nums:
                nums.append(item)
        if len(nums) >= 3:
            os.write(master, b"q")
            sent = True

code = proc.wait()
text = buf.decode("utf-8", "replace")
plain = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
err_text = err.decode("utf-8", "replace")
counts = []
for item in re.findall(r"files (\d+)", plain):
    if item not in counts:
        counts.append(item)
paths = []
for item in re.findall(r"d\d\d/n\d\d\d\d", plain):
    if item not in paths:
        paths.append(item)
def bit(flag):
    return "1" if flag else "0"
sys.stdout.write("\n".join([
    "code=" + str(code),
    "timeout=" + bit(timed_out),
    "sent=" + bit(sent),
    "title=" + bit("casually_index" in text),
    "walk=" + bit("walk" in plain),
    "publish=" + bit("publish" in plain),
    "percent=" + bit("100%" in plain),
    "counts=" + ",".join(counts[:12]),
    "paths=" + str(len(paths)),
    "warn_on_screen=" + bit("casually_index: skipped" in text),
    "stderr=" + err_text.replace("\n", "\\n"),
]) + "\n")
]=]

local function pty_run(source, index, mode)
    local script = base .. "/panel_pty.py"
    write_file(script, PTY_PY)
    local outp = os.tmpname()
    local errp = os.tmpname()
    local cmd = "python3 " .. sh_quote(script) .. " " .. sh_quote(exe)
        .. " " .. sh_quote(source) .. " " .. sh_quote(index) .. " " .. sh_quote(mode)
        .. " > " .. sh_quote(outp) .. " 2> " .. sh_quote(errp)
    local ok, how, status = os.execute(cmd)
    local report = read_file(outp)
    local py_err = read_file(errp)
    os.remove(outp)
    os.remove(errp)
    if ok ~= true then
        fail("pty " .. mode .. " failed (" .. tostring(how) .. " " .. tostring(status) .. ") " .. py_err)
        return nil
    end
    local fields = {}
    for line in report:gmatch("[^\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then
            fields[key] = value
        end
    end
    return fields, py_err
end

local function build_many(dir)
    mkdir(dir)
    for d = 0, 39 do
        local sub = dir .. string.format("/d%02d", d)
        mkdir(sub)
        for n = 0, 99 do
            write_file(sub .. string.format("/n%04d", d * 100 + n), "x")
        end
    end
    sh("mkfifo " .. sh_quote(dir .. "/pipe"))
end

local function check_panel(dir, out)
    mkdir(out)
    build_many(dir)
    local quit_index = out .. "/quit.listing"
    local quit = pty_run(dir, quit_index, "quit")
    if quit then
        expect(quit.timeout == "0", "q run timed out")
        expect(quit.sent == "1", "q was not sent, counts=" .. tostring(quit.counts))
        expect(quit.code == "2", "q exit " .. tostring(quit.code) .. " stderr " .. tostring(quit.stderr))
        expect(quit.title == "1", "panel title missing")
        expect(quit.walk == "1", "panel did not show walk")
        expect(tonumber(quit.paths) and tonumber(quit.paths) >= 2,
            "panel path did not change (" .. tostring(quit.paths) .. ")")
        local count_n = 0
        for _ in tostring(quit.counts):gmatch("%d+") do
            count_n = count_n + 1
        end
        expect(count_n >= 2, "panel counts did not move (" .. tostring(quit.counts) .. ")")
        expect(api.lfs.symlinkattributes(quit_index) == nil, "q left a listing")
        expect(#partials_in(out) == 0, "q left a partial")
        expect(quit.stderr == "casually_index: aborted\\n", "q stderr " .. tostring(quit.stderr))
        expect(quit.warn_on_screen == "0", "q wrote a warning into the panel")
    end

    local done_index = out .. "/done.listing"
    local done = pty_run(dir, done_index, "finish")
    if done then
        expect(done.timeout == "0", "finish run timed out")
        expect(done.code == "0", "finish exit " .. tostring(done.code) .. " stderr " .. tostring(done.stderr))
        expect(done.title == "1", "finish panel title missing")
        expect(done.walk == "1" and done.publish == "1",
            "finish phases walk=" .. tostring(done.walk) .. " publish=" .. tostring(done.publish))
        expect(done.percent == "1", "finish bar did not reach 100%")
        expect(done.warn_on_screen == "0", "finish wrote a warning into the panel")
        local want_warn = "casually_index: skipped named pipe " .. dir .. "/pipe\\n"
        expect(done.stderr == want_warn, "finish stderr " .. tostring(done.stderr))
        expect(api.lfs.symlinkattributes(done_index) ~= nil, "finish did not publish")
        expect(#partials_in(out) == 0, "finish left a partial")
        if api.lfs.symlinkattributes(done_index) then
            local body = read_file(done_index)
            expect(body:sub(-1) == "\n", "finish listing missing final newline")
            expect(body:find("/pipe", 1, true) == nil, "finish listing included the fifo")
        end
    end
    return quit, done
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /tmp/casually-phase6.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end

    check_strip_and_bar()
    check_abort(base .. "/abort")
    check_headless(base .. "/tree", base .. "/empty", base .. "/out", base .. "/cfg.json")
    check_newline_warning(base .. "/nl-root", base .. "/nl-out")
    check_panel(base .. "/many", base .. "/panel-out")
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
io.stdout:write("phase 6 gate passed\n")
