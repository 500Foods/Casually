-- Phase 1 gate. Run from the repo root: lua test/phase1.lua
-- dofile of casually_index.lua must not enter main.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase1.lua")
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
    expect(code == 1, "exit 1 for: " .. table.concat(args, " ") .. " got " .. tostring(code))
    expect(out == "", "empty stdout for: " .. table.concat(args, " ") .. " got " .. string.format("%q", out))
    expect(err == stderr_line .. "\n",
        "stderr for [" .. table.concat(args, " ") .. "] got " .. string.format("%q", err))
end

local function expect_ok(args, stdout)
    local code, out, err = run(args)
    expect(code == 0, "exit 0 for: " .. table.concat(args, " ") .. " got " .. tostring(code) .. " err " .. err)
    expect(err == "", "quiet stderr for: " .. table.concat(args, " ") .. " got " .. string.format("%q", err))
    if stdout ~= nil then
        expect(out == stdout, "stdout for: " .. table.concat(args, " ") .. " got " .. string.format("%q", out))
    else
        expect(out == "", "empty stdout for: " .. table.concat(args, " ") .. " got " .. string.format("%q", out))
    end
end

expect_error({}, "casually_index: missing arguments")
expect_error({ "--bogus" }, "casually_index: unknown argument: --bogus")
expect_error({ "--config", "--bogus" }, "casually_index: unknown argument: --bogus")
expect_error({ "--source", "--index" }, "casually_index: unknown argument: --index")
expect_error({ "config.json" }, "casually_index: unexpected argument: config.json")
expect_error({ "--config", "a.json", "--config", "b.json" },
    "casually_index: repeated argument: --config")
expect_error({ "--source", "/a", "--source", "/b" },
    "casually_index: repeated argument: --source")
expect_error({ "--help", "extra" },
    "casually_index: --help does not take other arguments")
expect_error({ "--version", "--help" },
    "casually_index: --version does not take other arguments")
expect_error({ "--config", "a.json", "--help" },
    "casually_index: --help does not take other arguments")
expect_error({ "--config", "a.json", "--source", "/root" },
    "casually_index: use either --config or --source with --index")
expect_error({ "--source", "/root", "--index", "/out", "--config", "a.json" },
    "casually_index: use either --config or --source with --index")
expect_error({ "--config" }, "casually_index: --config requires a file")
expect_error({ "--source", "/root" }, "casually_index: --source requires --index")
expect_error({ "--index", "/out" }, "casually_index: --index requires --source")
expect_error({ "--source" }, "casually_index: --source requires a value")
expect_error({ "--index" }, "casually_index: --index requires a value")

local cfg_cmd, cfg_err = api.parse_args({ "--config", "/any/path.json" })
expect(cfg_cmd and cfg_cmd.config == "/any/path.json" and cfg_err == nil,
    "parser accepts --config without opening it")
local src_cmd, src_err = api.parse_args({
    "--index", "/var/lib/out.listing",
    "--source", "/var/lib/root",
})
expect(src_cmd and src_cmd.source == "/var/lib/root"
    and src_cmd.index == "/var/lib/out.listing" and src_err == nil,
    "parser accepts --source and --index without opening them")

local help = api.help_text()
expect(help:find("./casually_index.lua --config <file>", 1, true) ~= nil, "help has --config form")
expect(help:find("./casually_index.lua --source <root> --index <file>", 1, true) ~= nil, "help has --source form")
expect(help:find("./casually_index.lua --help", 1, true) ~= nil, "help has --help form")
expect(help:find("./casually_index.lua --version", 1, true) ~= nil, "help has --version form")
expect(help:find("--config <file>", 1, true) ~= nil, "help describes --config")
expect(help:find("--source <root>", 1, true) ~= nil, "help describes --source")
expect(help:find("--index <file>", 1, true) ~= nil, "help describes --index")
expect_ok({ "--help" }, help)

local version = table.concat(api.version_lines(), "\n") .. "\n"
expect(version == "casually_index 0.1.0\nLua 5.5\nterminal.lua 0.1.0\n",
    "version lines are " .. string.format("%q", version))
expect_ok({ "--version" }, version)

-- Same three lines when stdout is a terminal.
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
    os.execvpe(exe, [exe, "--version"], {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "")})
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
expect(xok == true, "casually_index.lua is executable")

local find_out = os.tmpname()
os.execute("find " .. sh_quote(root) .. " -name '*.c' -print > " .. sh_quote(find_out))
local cfiles = read_file(find_out)
expect(cfiles == "", "repo has no .c file, found " .. cfiles)

if failures > 0 then
    io.stderr:write(failures .. " failure(s)\n")
    os.exit(1)
end
io.stdout:write("phase 1 gate passed\n")
