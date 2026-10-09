-- Phase 6 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 6
-- The screen paints only when stdout is a terminal and the run is not a dry-run.
-- q aborts class apply and does not rename a snapshot.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase6.lua")
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
local system = require("system")

expect(type(api.format_elapsed) == "function", "format_elapsed is exported")
expect(type(api.format_bytes) == "function", "format_bytes is exported")
expect(type(api.middle_clip) == "function", "middle_clip is exported")
expect(type(api.open_screen) == "function", "open_screen is exported")
expect(type(index.format_line) == "function", "format_line is exported")

local S1 = "20261008-1430"
local S2 = "20261009-0900"
local OWNER = "casually_backup: owner not applied\n"

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

local function ino_of(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then
        return nil
    end
    return attr.ino
end

local function partial_count(dir)
    local n = 0
    for name in lfs.dir(dir) do
        if name:sub(-8) == ".partial" then
            n = n + 1
        end
    end
    return n
end

local function check_pure()
    expect(api.format_elapsed(67) == "0:01:07",
        "elapsed 67 is " .. tostring(api.format_elapsed(67)))
    expect(api.format_bytes(512) == "512 B",
        "512 B is " .. tostring(api.format_bytes(512)))
    expect(api.format_bytes(1536) == "1536 B",
        "1536 B is " .. tostring(api.format_bytes(1536)))
    expect(api.format_bytes(10240) == "10 KiB",
        "10 KiB is " .. tostring(api.format_bytes(10240)))

    local short = api.middle_clip("/fvl/keep", 12)
    expect(short == "/fvl/keep   ", "short clip [" .. short .. "]")
    expect(not short:find("\t"), "short clip has a tab")

    -- Width 10 leaves 7 columns besides "...". 7 is odd, so the head gets 4.
    local long = api.middle_clip("ABCDEFGHIJKLMNOP", 10)
    expect(long == "ABCD...NOP", "long clip [" .. long .. "]")

    local tabbed = api.middle_clip("a\tb", 8)
    expect(tabbed == "a?b     ", "tab clip [" .. tabbed .. "]")
    expect(tabbed:find("\t", 1, true) == nil, "tab clip kept a tab")
end

local function check_headless()
    local dir = base .. "/small"
    local src = dir .. "/src"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    write_file(src .. "/fvl/keep", "keep\n")
    write_file(src .. "/fvl/changed", "one\n")
    sh("chmod 755 " .. sh_quote(src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(src .. "/fvl/keep"))
    sh("chmod 644 " .. sh_quote(src .. "/fvl/changed"))
    local map = "/fvl=" .. src .. "/fvl"
    local index1 = write_listing(dir, S1, {
        { abs = src .. "/fvl", listing = "/fvl" },
        { abs = src .. "/fvl/changed", listing = "/fvl/changed" },
        { abs = src .. "/fvl/keep", listing = "/fvl/keep" },
    })
    local argv = { "--index", index1, "--dest", dest, "--source-map", map }
    local code, out, err = run_cli(argv)
    expect(code == 0, "headless base exit " .. tostring(code) .. " " .. err)
    expect(out == "", "headless base stdout [" .. out .. "]")
    expect(err == OWNER, "headless base stderr [" .. err .. "]")
    expect(read_all(dest .. "/_Base/fvl/keep") == "keep\n", "headless _Base keep")
    expect(read_all(dest .. "/_Base/fvl/changed") == "one\n", "headless _Base changed")
    expect(partial_count(dest) == 0, "headless base left a partial")
    expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, "headless base left a lock")

    local fifo = dest .. "/_Base/fvl/odd\nname"
    sh("python3 -c 'import os,sys; os.mkfifo(sys.argv[1])' " .. sh_quote(fifo))
    write_file(src .. "/fvl/changed", "two\n")
    -- "one\n" and "two\n" are the same length. A matching mtime second
    -- hardlinks, which hides the byte change. Step the mtime forward.
    local bumped = os.time() + 120
    assert(lfs.touch(src .. "/fvl/changed", bumped, bumped))
    local index2 = write_listing(dir, S2, {
        { abs = src .. "/fvl", listing = "/fvl" },
        { abs = src .. "/fvl/changed", listing = "/fvl/changed" },
        { abs = src .. "/fvl/keep", listing = "/fvl/keep" },
    })
    argv[2] = index2
    code, out, err = run_cli(argv)
    expect(code == 0, "headless date exit " .. tostring(code) .. " " .. err)
    expect(out == "", "headless date stdout [" .. out .. "]")
    local newlines = 0
    for _ in err:gmatch("\n") do
        newlines = newlines + 1
    end
    expect(newlines == 2, "newline warning physical lines " .. tostring(newlines) .. " [" .. err .. "]")
    expect(err:find("odd\\nname", 1, true) ~= nil, "newline warning did not escape the path [" .. err .. "]")
    expect(err:find("odd\nname", 1, true) == nil, "newline warning split the path")
    expect(err:sub(1, #OWNER) == OWNER, "headless date missing owner warning [" .. err .. "]")
    local keep_old = lfs.symlinkattributes(dest .. "/_Base/fvl/keep")
    local keep_new = lfs.symlinkattributes(dest .. "/" .. S2 .. "/fvl/keep")
    expect(keep_old ~= nil and keep_new ~= nil and keep_old.ino == keep_new.ino,
        "dated snapshot did not hardlink the unchanged file")
    expect(keep_new ~= nil and keep_new.nlink >= 2, "unchanged nlink")
    expect(read_all(dest .. "/" .. S2 .. "/fvl/changed") == "two\n", "dated changed bytes")
    expect(read_all(dest .. "/_Base/fvl/changed") == "one\n", "headless _Base changed was rewritten")
    local changed_old = ino_of(dest .. "/_Base/fvl/changed")
    local changed_new = ino_of(dest .. "/" .. S2 .. "/fvl/changed")
    expect(changed_old ~= nil and changed_new ~= nil and changed_old ~= changed_new,
        "changed file was hardlinked")
    expect(partial_count(dest) == 0, "headless date left a partial")
    expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, "headless date left a lock")
end

local PTY_PY = [=[
import os, pty, re, select, struct, subprocess, sys, termios, time, fcntl
exe, index_path, dest, source_map, mode, byte_label = sys.argv[1:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
err_r, err_w = os.pipe()
env = os.environ.copy()
for key in ("LUA_PATH", "LUA_CPATH", "LUA_INIT"):
    env.pop(key, None)
env["LC_ALL"] = "C"
proc = subprocess.Popen(
    [exe, "--index", index_path, "--dest", dest, "--source-map", source_map],
    stdin=slave, stdout=slave, stderr=err_w, env=env, close_fds=True,
)
os.close(slave)
os.close(err_w)
buf = b""
err = b""
sent = False
timed_out = False
start = time.time()
limit = 60 if mode == "quit" else 180

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
        drain(0.2)
        break
    if time.time() - start > limit:
        timed_out = True
        proc.kill()
        drain(0.2)
        break
    drain(0.1)
    if mode == "quit" and not sent:
        plain_now = re.sub(br"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", buf)
        if re.search(br"[|/\\-] \S*big\.bin", plain_now):
            try:
                os.write(master, b"q")
                sent = True
            except OSError:
                pass

code = proc.wait()
text = buf.decode("utf-8", "replace")
plain = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
err_text = err.decode("utf-8", "replace")
counts = []
for item in re.findall(r"(\d+) done", plain):
    if not counts or counts[-1] != item:
        counts.append(item)
elapseds = []
for item in re.findall(r"\d+:\d\d:\d\d", plain):
    if not elapseds or elapseds[-1] != item:
        elapseds.append(item)
last = None
spin_elapsed = []
settled = False
pat = re.compile(r"(\d+:\d\d:\d\d)|([|/\\-]) (\S*big\.bin)|([CS]) (\S*big\.bin)")
for match in pat.finditer(plain):
    if match.group(1):
        last = match.group(1)
    elif match.group(2):
        spin_elapsed.append(last or "")
    elif match.group(4):
        settled = True
distinct_spin = []
for item in spin_elapsed:
    if item and (not distinct_spin or distinct_spin[-1] != item):
        distinct_spin.append(item)
def bit(flag):
    return "1" if flag else "0"
sys.stdout.write("\n".join([
    "code=" + str(code),
    "timeout=" + bit(timed_out),
    "sent=" + bit(sent),
    "title=" + bit("Casually Backup" in text),
    "rounded=" + bit("\u256d" in text),
    "scanning=" + bit("scanning" in plain),
    "counts=" + ",".join(counts),
    "elapsed=" + ",".join(elapseds),
    "elapsed_open=" + bit(len(distinct_spin) >= 2),
    "settled=" + bit(settled),
    "rate=" + bit(("copied " + byte_label) in plain),
    "warn_on_screen=" + bit("casually_backup:" in text),
    "stderr=" + err_text.replace("\n", "\\n"),
]) + "\n")
]=]

local function pty_run(index_path, dest, source_map, mode, byte_label)
    local script = base .. "/panel_pty.py"
    write_file(script, PTY_PY)
    local outp = os.tmpname()
    local errp = os.tmpname()
    local cmd = "python3 " .. sh_quote(script)
        .. " " .. sh_quote(exe)
        .. " " .. sh_quote(index_path)
        .. " " .. sh_quote(dest)
        .. " " .. sh_quote(source_map)
        .. " " .. sh_quote(mode)
        .. " " .. sh_quote(byte_label)
        .. " > " .. sh_quote(outp) .. " 2> " .. sh_quote(errp)
    local ok, how, status = os.execute(cmd)
    local report = read_all(outp) or ""
    local py_err = read_all(errp) or ""
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
    return fields
end

local function free_bytes(path)
    local pipe = io.popen("df -B1 -P " .. sh_quote(path))
    local text = pipe:read("a") or ""
    pipe:close()
    local avail
    for line in text:gmatch("[^\n]+") do
        avail = line:match("^%S+%s+%d+%s+%d+%s+(%d+)")
    end
    return tonumber(avail) or 0
end

local function probe_rate(dir)
    local src = dir .. "/probe-in"
    local dst = dir .. "/probe-out"
    sh("dd if=/dev/zero of=" .. sh_quote(src) .. " bs=1048576 count=64 status=none")
    local t0 = system.monotime()
    local input = assert(io.open(src, "rb"))
    local output = assert(io.open(dst, "wb"))
    local n = 0
    while true do
        local buf = input:read(1048576)
        if not buf then
            break
        end
        output:write(buf)
        n = n + #buf
    end
    input:close()
    output:close()
    local dt = system.monotime() - t0
    os.remove(src)
    os.remove(dst)
    if dt < 0.001 then
        dt = 0.001
    end
    return n / dt
end

local function check_panel()
    local dir = base .. "/panel"
    local src = dir .. "/src"
    local dest = dir .. "/dest"
    mkdir_p(dest)
    mkdir_p(src .. "/fvl")
    local rate = probe_rate(dir)
    local chunks = math.ceil(rate * 2.2 / 1048576)
    if chunks < 32 then
        chunks = 32
    end
    local budget = math.floor((free_bytes(dir) - 2 * 1024 * 1024 * 1024) / (4 * 1048576))
    if budget < 32 then
        error("not enough free space for the screen copy")
    end
    if chunks > budget then
        chunks = budget
    end
    if chunks > 12288 then
        chunks = 12288
    end
    io.stdout:write(string.format(
        "screen copy chunks=%d rate=%.0fMiB/s\n", chunks, rate / 1048576))
    sh("dd if=/dev/zero of=" .. sh_quote(src .. "/fvl/big.bin")
        .. " bs=1048576 count=" .. tostring(chunks) .. " status=none")
    write_file(src .. "/fvl/keep", "keep\n")
    sh("chmod 755 " .. sh_quote(src .. "/fvl"))
    sh("chmod 644 " .. sh_quote(src .. "/fvl/big.bin"))
    sh("chmod 644 " .. sh_quote(src .. "/fvl/keep"))
    local map = "/fvl=" .. src .. "/fvl"
    local index1 = write_listing(dir, S1, {
        { abs = src .. "/fvl", listing = "/fvl" },
        { abs = src .. "/fvl/big.bin", listing = "/fvl/big.bin" },
        { abs = src .. "/fvl/keep", listing = "/fvl/keep" },
    })
    local code, out, err = run_cli({
        "--index", index1, "--dest", dest, "--source-map", map,
    })
    expect(code == 0, "panel base exit " .. tostring(code) .. " " .. err)
    expect(out == "", "panel base stdout")
    expect(err == OWNER, "panel base stderr [" .. err .. "]")
    local big_size = lfs.symlinkattributes(src .. "/fvl/big.bin").size
    local label = api.format_bytes(big_size)
    sh("mkfifo " .. sh_quote(dest .. "/_Base/fvl/pipe"))
    local base_big = ino_of(dest .. "/_Base/fvl/big.bin")
    local base_keep = ino_of(dest .. "/_Base/fvl/keep")
    local base_big_size = lfs.symlinkattributes(dest .. "/_Base/fvl/big.bin").size
    sh("touch " .. sh_quote(src .. "/fvl/big.bin"))
    local index2 = write_listing(dir, S2, {
        { abs = src .. "/fvl", listing = "/fvl" },
        { abs = src .. "/fvl/big.bin", listing = "/fvl/big.bin" },
        { abs = src .. "/fvl/keep", listing = "/fvl/keep" },
    })

    local quit = pty_run(index2, dest, map, "quit", label)
    if quit then
        io.stdout:write("screen quit code=" .. tostring(quit.code)
            .. " sent=" .. tostring(quit.sent)
            .. " counts=" .. tostring(quit.counts)
            .. " elapsed=" .. tostring(quit.elapsed)
            .. " settled=" .. tostring(quit.settled)
            .. " stderr=" .. tostring(quit.stderr) .. "\n")
        expect(quit.timeout == "0", "q run timed out")
        expect(quit.sent == "1", "q was not sent counts=" .. tostring(quit.counts))
        expect(quit.code == "2", "q exit " .. tostring(quit.code) .. " stderr " .. tostring(quit.stderr))
        expect(quit.stderr == "casually_backup: aborted\\n", "q stderr " .. tostring(quit.stderr))
        expect(quit.title == "1", "q panel title missing")
        expect(quit.rounded == "1", "q frame missing")
        expect(quit.scanning == "1", "q did not show scanning")
        expect(quit.warn_on_screen == "0", "q wrote a warning into the panel")
        local count_n = 0
        for _ in tostring(quit.counts):gmatch("%d+") do
            count_n = count_n + 1
        end
        expect(count_n >= 2, "q counts did not move (" .. tostring(quit.counts) .. ")")
    end
    expect(lfs.symlinkattributes(dest .. "/" .. S2) == nil, "q published the dated snapshot")
    expect(ino_of(dest .. "/_Base/fvl/big.bin") == base_big, "q changed the _Base payload inode")
    expect(ino_of(dest .. "/_Base/fvl/keep") == base_keep, "q changed the _Base keep inode")
    expect(lfs.symlinkattributes(dest .. "/_Base/fvl/big.bin").size == base_big_size,
        "q changed the _Base payload size")
    expect(read_all(dest .. "/_Base/fvl/keep") == "keep\n", "q changed _Base keep bytes")
    expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, "q left the lock")

    local done = pty_run(index2, dest, map, "finish", label)
    if done then
        io.stdout:write("screen finish code=" .. tostring(done.code)
            .. " counts=" .. tostring(done.counts)
            .. " elapsed=" .. tostring(done.elapsed)
            .. " elapsed_open=" .. tostring(done.elapsed_open)
            .. " settled=" .. tostring(done.settled)
            .. " rate=" .. tostring(done.rate)
            .. " warn_on_screen=" .. tostring(done.warn_on_screen)
            .. " stderr=" .. tostring(done.stderr) .. "\n")
        expect(done.timeout == "0", "finish run timed out")
        expect(done.code == "0", "finish exit " .. tostring(done.code) .. " stderr " .. tostring(done.stderr))
        expect(done.title == "1", "finish panel title missing")
        expect(done.rounded == "1", "finish frame missing")
        expect(done.scanning == "1", "finish did not show scanning")
        expect(done.elapsed_open == "1",
            "elapsed did not advance during the open copy (" .. tostring(done.elapsed) .. ")")
        expect(done.settled == "1", "line did not settle to C or S")
        expect(done.rate == "1", "rates did not show copied " .. label)
        expect(done.warn_on_screen == "0", "finish wrote the left warning into the panel")
        local want_err = "casually_backup: owner not applied\\ncasually_backup: left named pipe "
            .. dest .. "/_Base/fvl/pipe\\n"
        expect(done.stderr == want_err, "finish stderr " .. tostring(done.stderr))
        local count_n = 0
        for _ in tostring(done.counts):gmatch("%d+") do
            count_n = count_n + 1
        end
        expect(count_n >= 2, "finish counts did not move (" .. tostring(done.counts) .. ")")
    end
    local dated = dest .. "/" .. S2
    expect(lfs.symlinkattributes(dated) ~= nil, "finish did not publish the dated snapshot")
    local keep_old = lfs.symlinkattributes(dest .. "/_Base/fvl/keep")
    local keep_new = lfs.symlinkattributes(dated .. "/fvl/keep")
    expect(keep_old ~= nil and keep_new ~= nil and keep_old.ino == keep_new.ino,
        "finish did not hardlink the unchanged file")
    expect(keep_new ~= nil and keep_new.nlink >= 2, "finish unchanged nlink")
    local big_old = ino_of(dest .. "/_Base/fvl/big.bin")
    local big_new = ino_of(dated .. "/fvl/big.bin")
    expect(big_old == base_big, "finish rewrote _Base payload")
    expect(big_new ~= nil and big_new ~= big_old, "finish hardlinked the changed payload")
    expect(lfs.symlinkattributes(dated .. "/fvl/big.bin").size == base_big_size,
        "finish payload size")
    expect(partial_count(dest) == 0, "finish left a partial")
    expect(lfs.symlinkattributes(dest .. "/.casually_backup.lock") == nil, "finish left a lock")
end

local function gate()
    local pipe = assert(io.popen("mktemp -d /mnt/extra/Projects/Casually/.casually-phase6.XXXXXX", "r"))
    base = pipe:read("*l")
    pipe:close()
    if not base or base == "" or base:sub(1, 1) ~= "/" then
        error("mktemp failed")
    end
    check_pure()
    if failures > 0 then
        return
    end
    check_headless()
    if failures > 0 then
        return
    end
    check_panel()
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
local phase_cmd = sh_quote(root .. "/test/run.sh") .. " backup 5 > "
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
if pcode ~= 0 or phase_text:find("backup phase 5 gate passed", 1, true) == nil then
    io.stderr:write("backup phase 5 did not pass, exit " .. tostring(pcode) .. "\n")
    io.stderr:write(phase_err_text)
    io.stderr:write(phase_text)
    os.exit(1)
end

io.stdout:write("backup phase 6 gate passed\n")
