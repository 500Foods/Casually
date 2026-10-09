-- Phase 1 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 1
-- dofile of casually_backup.lua must not enter main.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase1.lua")
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

local api = dofile(exe)
expect(type(api) == "table", "dofile returned the function table")
expect(type(api.parse_args) == "function", "parse_args is exported")
expect(type(api.main) == "function", "main is exported")
expect(api.VERSION == "0.1.0", "version is 0.1.0")
expect(api.lfs and api.lfs._VERSION and api.lfs._VERSION:find("1.9", 1, true),
    "lfs 1.9 loaded with a clean module path")
expect(type(api.dkjson) == "table" and type(api.dkjson.encode) == "function",
    "dkjson loaded")
expect(api.terminal and api.terminal._VERSION == "0.1.0",
    "terminal 0.1.0 loaded")

local first = assert(io.open(exe, "rb")):read(32)
expect(first:sub(1, 19) == "#!/usr/bin/env lua\n", "shebang is the first line")

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a") or ""
    f:close()
    os.remove(path)
    return s
end

local function run(args)
    local outp = os.tmpname()
    local errp = os.tmpname()
    local cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT " .. sh_quote(exe)
    for i = 1, #args do
        cmd = cmd .. " " .. sh_quote(args[i])
    end
    cmd = cmd .. " > " .. sh_quote(outp) .. " 2> " .. sh_quote(errp)
    local ok, how, code = os.execute(cmd)
    local out = read_file(outp)
    local err = read_file(errp)
    if ok == true then
        code = 0
    elseif how == "exit" then
        code = code or 1
    else
        code = -1
    end
    return code, out, err
end

local function expect_error(args, stderr_line)
    local code, out, err = run(args)
    local shown = table.concat(args, " ")
    if shown == "" then
        shown = "(none)"
    end
    expect(code == 1, "exit 1 for: " .. shown .. " got " .. tostring(code))
    expect(out == "", "empty stdout for: " .. shown .. " got " .. string.format("%q", out))
    expect(err == stderr_line .. "\n",
        "stderr for [" .. shown .. "] got " .. string.format("%q", err))
end

local function expect_ok(args, stdout)
    local code, out, err = run(args)
    local shown = table.concat(args, " ")
    expect(code == 0, "exit 0 for: " .. shown .. " got " .. tostring(code) .. " err " .. err)
    expect(err == "", "quiet stderr for: " .. shown .. " got " .. string.format("%q", err))
    if stdout ~= nil then
        expect(out == stdout, "stdout for: " .. shown .. " got " .. string.format("%q", out))
    else
        expect(out == "", "empty stdout for: " .. shown .. " got " .. string.format("%q", out))
    end
end

local function tool_version(bin)
    local ok = os.execute(bin .. " --version >/dev/null 2>&1")
    expect(ok == true, bin .. " --version exits 0")
end

tool_version("chmod")
tool_version("chown")
tool_version("xargs")

expect_error({}, "casually_backup: missing arguments")
expect_error({ "--bogus" }, "casually_backup: unknown argument: --bogus")
expect_error({ "--config", "--bogus" }, "casually_backup: unknown argument: --bogus")
expect_error({ "config.json" }, "casually_backup: unexpected argument: config.json")
expect_error({ "--config", "a.json", "--config", "b.json" },
    "casually_backup: repeated argument: --config")
expect_error({ "--index", "a.listing", "--index", "b.listing" },
    "casually_backup: repeated argument: --index")
expect_error({ "--dry-run", "--dry-run" },
    "casually_backup: repeated argument: --dry-run")
expect_error({ "--omit-limit", "1", "--omit-limit", "2" },
    "casually_backup: repeated argument: --omit-limit")
expect_error({ "--omit-fraction", "0.1", "--omit-fraction", "0.2" },
    "casually_backup: repeated argument: --omit-fraction")
expect_error({ "--help", "extra" },
    "casually_backup: --help does not take other arguments")
expect_error({ "--version", "--help" },
    "casually_backup: --version does not take other arguments")
expect_error({ "--config", "a.json", "--help" },
    "casually_backup: --help does not take other arguments")
expect_error({ "--dry-run", "--help" },
    "casually_backup: --help does not take other arguments")
expect_error({ "--config", "a.json", "--index", "a.listing" },
    "casually_backup: use either --config or --index with --dest")
expect_error({ "--config", "a.json", "--dest", "/backup" },
    "casually_backup: use either --config or --index with --dest")
expect_error({ "--config", "a.json", "--source-map", "/fvl=/srv/fvl" },
    "casually_backup: use either --config or --index with --dest")
expect_error({ "--config" }, "casually_backup: --config requires a file")
expect_error({ "--index", "a.listing" }, "casually_backup: --index requires --dest")
expect_error({ "--dest", "/backup" }, "casually_backup: --dest requires --index")
expect_error({ "--source-map", "/fvl=/srv/fvl" },
    "casually_backup: --source-map requires --index")
expect_error({ "--source-map", "nopath" },
    "casually_backup: --source-map requires alias=path")
expect_error({ "--index" }, "casually_backup: --index requires a value")
expect_error({ "--dest" }, "casually_backup: --dest requires a value")
expect_error({ "--source-map" }, "casually_backup: --source-map requires a value")
expect_error({ "--omit-limit" }, "casually_backup: --omit-limit requires a value")
expect_error({ "--omit-fraction" }, "casually_backup: --omit-fraction requires a value")
expect_error({ "--workers" }, "casually_backup: --workers requires a value")
expect_error({ "--dry-run" },
    "casually_backup: use either --config or --index with --dest")

local cfg = api.parse_args({ "--config", "/any/backup.json" })
expect(cfg and cfg.config == "/any/backup.json" and cfg.dry_run == false
    and cfg.omit_limit == nil and cfg.omit_fraction == nil,
    "parser accepts --config without opening it")

local both = api.parse_args({
    "--dest", "/backup/disk2",
    "--index", "/var/lib/index-20261008-0300.listing",
    "--dest", "/backup/disk1",
    "--source-map", "/fvl=/srv/fvl",
    "--source-map", "/other=/mnt/other",
    "--dry-run",
    "--omit-limit", "50",
    "--omit-fraction", "0.02",
})
expect(both and both.index == "/var/lib/index-20261008-0300.listing",
    "parser keeps --index")
expect(both and both.destinations[1] == "/backup/disk2"
    and both.destinations[2] == "/backup/disk1",
    "repeated --dest keeps order")
expect(both and both.source_map[1].alias == "/fvl"
    and both.source_map[1].path == "/srv/fvl"
    and both.source_map[2].alias == "/other"
    and both.source_map[2].path == "/mnt/other",
    "repeated --source-map splits on the first equals")
expect(both and both.dry_run == true
    and both.omit_limit == "50" and both.omit_fraction == "0.02"
    and both.workers == nil,
    "flag form accepts dry-run and omission overrides")

local with_workers = api.parse_args({
    "--config", "/any/backup.json",
    "--workers", "4",
})
expect(with_workers and with_workers.workers == "4" and with_workers.config == "/any/backup.json",
    "parser keeps --workers")

local with_config = api.parse_args({
    "--omit-fraction", "0.5",
    "--config", "/any/backup.json",
    "--dry-run",
    "--omit-limit", "9",
})
expect(with_config and with_config.config == "/any/backup.json"
    and with_config.dry_run == true
    and with_config.omit_limit == "9"
    and with_config.omit_fraction == "0.5"
    and with_config.index == nil,
    "--config accepts dry-run and omission overrides")

local help = api.help_text()
expect(help:find("./casually_backup.lua --config <file>", 1, true) ~= nil,
    "help has --config form")
expect(help:find("./casually_backup.lua --index <listing> --dest <dir>", 1, true) ~= nil,
    "help has --index form")
expect(help:find("./casually_backup.lua --help", 1, true) ~= nil, "help has --help form")
expect(help:find("./casually_backup.lua --version", 1, true) ~= nil, "help has --version form")
expect(help:find("--dest <dir>", 1, true) ~= nil, "help describes --dest")
expect(help:find("--source-map <alias>=<path>", 1, true) ~= nil, "help describes --source-map")
expect(help:find("--dry-run", 1, true) ~= nil, "help describes --dry-run")
expect(help:find("--omit-limit <n>", 1, true) ~= nil, "help describes --omit-limit")
expect(help:find("--omit-fraction <number>", 1, true) ~= nil, "help describes --omit-fraction")
expect(help:find("--workers <n>", 1, true) ~= nil, "help describes --workers")
expect_ok({ "--help" }, help)

local version = table.concat(api.version_lines(), "\n") .. "\n"
expect(version == "casually_backup 0.1.0\nLua 5.5\nterminal.lua 0.1.0\n",
    "version lines are " .. string.format("%q", version))
expect_ok({ "--version" }, version)

local py = os.tmpname() .. ".py"
local pyf = assert(io.open(py, "w"))
pyf:write([[
import os, pty, sys
exe = sys.argv[1]
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.close(slave)
    env = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "")}
    os.execvpe(exe, [exe, "--version"], env)
os.close(slave)
data = b""
while True:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
os.close(master)
_, status = os.waitpid(pid, 0)
rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
sys.stdout.buffer.write(data)
sys.exit(rc)
]])
pyf:close()
local tty_out = os.tmpname()
local tty_cmd = "env -u LUA_PATH -u LUA_CPATH -u LUA_INIT python3 "
    .. sh_quote(py) .. " " .. sh_quote(exe) .. " > " .. sh_quote(tty_out)
local tok, thow, tcode = os.execute(tty_cmd)
local tty_text = read_file(tty_out):gsub("\r\n", "\n")
os.remove(py)
if tok == true then
    tcode = 0
elseif thow ~= "exit" then
    tcode = -1
end
expect(tcode == 0, "tty --version exit " .. tostring(tcode))
expect(tty_text == version, "tty --version text " .. string.format("%q", tty_text))

local xok = os.execute("test -x " .. sh_quote(exe))
expect(xok == true, "casually_backup.lua is executable")

local index_out = os.tmpname()
local index_err = os.tmpname()
local index_cmd = sh_quote(root .. "/test/run.sh")
    .. " > " .. sh_quote(index_out) .. " 2> " .. sh_quote(index_err)
local iok, ihow, icode = os.execute(index_cmd)
local index_text = read_file(index_out)
local index_err_text = read_file(index_err)
if iok == true then
    icode = 0
elseif ihow ~= "exit" then
    icode = -1
end
expect(icode == 0, "indexer gates still pass, exit " .. tostring(icode)
    .. " " .. index_err_text)
expect(index_text:find("phase 1 gate passed", 1, true) ~= nil,
    "indexer phase 1 ran")
expect(index_text:find("phase 7 gate passed", 1, true) ~= nil,
    "indexer phase 7 ran")
expect(index_text:find("backup_phase", 1, true) == nil,
    "indexer run did not enter a backup gate")

if failures > 0 then
    io.stderr:write(failures .. " failure(s)\n")
    os.exit(1)
end
io.stdout:write("backup phase 1 gate passed\n")
