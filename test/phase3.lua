-- Phase 3 gate. Run from the repo root: lua test/phase3.lua
-- Formats listing lines. No directory tree.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/phase3.lua")
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

expect(type(api.format_line) == "function", "format_line is exported")

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

expect(os.date("!%Y%m%d:%H%M%S", T_README) == "20261008:143015", "readme epoch")
expect(os.date("!%Y%m%d:%H%M%S", T_DOCS) == "20261008:143016", "docs epoch")
expect(os.date("!%Y%m%d:%H%M%S", T_LINK) == "20261008:090001", "link epoch")

local MODE_644 = tonumber("644", 8)
local MODE_755 = tonumber("755", 8)
local MODE_777 = tonumber("777", 8)
local MODE_4755 = tonumber("4755", 8)
local MODE_2755 = tonumber("2755", 8)
local MODE_4644 = tonumber("4644", 8)
local MODE_1777 = tonumber("1777", 8)
local MODE_1776 = tonumber("1776", 8)
local MODE_IFREG_644 = 0x8000 + MODE_644

local function base(over)
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
    if over then
        for k, v in pairs(over) do
            rec[k] = v
        end
    end
    return rec
end

local function expect_line(over, want, label)
    local text, err = api.format_line(base(over))
    expect(text == want,
        label .. " got " .. string.format("%q", tostring(text)) .. " err " .. tostring(err))
    if text then
        expect(text:find("\n", 1, true) == nil, label .. " contains a newline")
        expect(text:sub(-1) ~= "\n", label .. " has a trailing newline")
    end
    return text
end

local TAB = "\t"

local sample_readme = table.concat({
    "20261008:143015", "andrew:andrew", "-rw-r--r--", "4821", "-", "/fvl/a/docs/readme.txt",
}, TAB)
local sample_docs = table.concat({
    "20261008:143016", "andrew:andrew", "drwxr-xr-x", "6", "-", "/fvl/a/docs",
}, TAB)
local sample_link = table.concat({
    "20261008:090001", "andrew:andrew", "lrwxrwxrwx", "11", "../other/readme", "/fvl/a/docs/link",
}, TAB)
local sample_bang = table.concat({
    "!20261008:090001", "andrew:andrew", "-rw-r--r--", "3", "-", "/fvl/a/odd\\tname",
}, TAB)

expect_line(nil, sample_readme, "sample file")
expect_line({
    path = "/fvl/a/docs",
    kind = "dir",
    permissions = "rwxr-xr-x",
    mode = 0,
    size = 6,
    mtime = T_DOCS,
}, sample_docs, "sample directory")
expect_line({
    path = "/fvl/a/docs/link",
    kind = "link",
    mode = MODE_777,
    size = 11,
    mtime = T_LINK,
    target = "../other/readme",
}, sample_link, "sample symlink")
expect_line({
    path = "/fvl/a/odd\tname",
    kind = "file",
    permissions = "rw-r--r--",
    size = 3,
    mtime = T_LINK,
}, sample_bang, "sample bang tab")

expect(#sample_readme:match("^[^\t]+") == 15, "mtime is 15 characters")
expect(sample_bang:sub(1, 16) == "!20261008:090001", "bang is glued to the mtime")
expect(sample_bang:sub(17, 17) == "\t", "tab follows the banged mtime")

local function raw_line(over)
    return api.format_line(base(over))
end

local same, same_err = raw_line({ mtime = T_README + 0.9 })
local next_sec = raw_line({ mtime = T_README + 1 })
local prev_sec = raw_line({ mtime = T_README - 0.1 })
expect(same == sample_readme, "fraction 0.9 truncates toward zero, got " .. string.format("%q", tostring(same)) .. " " .. tostring(same_err))
expect(next_sec ~= nil and next_sec ~= sample_readme, "next second differs")
expect(next_sec and next_sec:find("^20261008:143016\t", 1) == 1, "next second is 143016")
expect(prev_sec and prev_sec:find("^20261008:143014\t", 1) == 1,
    "fraction below an integer truncates toward zero, got " .. string.format("%q", tostring(prev_sec)))

local neg, neg_err = raw_line({ mtime = -1.2 })
local neg_trunc = os.date("!%Y%m%d:%H%M%S", -1)
local neg_floor = os.date("!%Y%m%d:%H%M%S", -2)
expect(neg ~= nil and neg:sub(1, 15) == neg_trunc,
    "negative fraction truncates toward zero, got " .. string.format("%q", tostring(neg)) .. " " .. tostring(neg_err))
expect(neg_trunc ~= neg_floor, "negative fixtures differ")
expect(neg and #neg:match("^[^\t]+") == 15, "negative mtime width")

expect_line({
    user = "an:drew",
    uid = 1001,
}, table.concat({
    "20261008:143015", "1001:andrew", "-rw-r--r--", "4821", "-", "/fvl/a/docs/readme.txt",
}, TAB), "colon in the user becomes the uid")

expect_line({
    group = "an drew",
    gid = 42,
}, table.concat({
    "20261008:143015", "andrew:42", "-rw-r--r--", "4821", "-", "/fvl/a/docs/readme.txt",
}, TAB), "space in the group becomes the gid")

expect_line({
    user = "an\tdrew",
    uid = 7,
    group = "an:drew",
    gid = 8,
}, table.concat({
    "20261008:143015", "7:8", "-rw-r--r--", "4821", "-", "/fvl/a/docs/readme.txt",
}, TAB), "tab and colon each fall back on their own side")

local missing_user, missing_err = api.format_line({
    path = "/fvl/a/docs/readme.txt",
    kind = "file",
    mode = MODE_644,
    size = 1,
    mtime = T_README,
    user = "a:b",
    group = "andrew",
    gid = 1000,
})
expect(missing_user == nil and missing_err == "user is required",
    "bad user without an id got " .. tostring(missing_err))

expect_line({
    path = "/fvl/a/docs/dash",
    kind = "link",
    mode = MODE_777,
    size = 1,
    target = "-",
}, table.concat({
    "20261008:143015", "andrew:andrew", "lrwxrwxrwx", "1", "\\-", "/fvl/a/docs/dash",
}, TAB), "target dash on a clean path")

expect_line({
    path = "/fvl/a/odd\tname",
    kind = "link",
    mode = MODE_777,
    size = 1,
    mtime = T_LINK,
    target = "-",
}, table.concat({
    "!20261008:090001", "andrew:andrew", "lrwxrwxrwx", "1", "\\-", "/fvl/a/odd\\tname",
}, TAB), "target dash is not re-escaped on a bang line")

expect_line({
    path = "/fvl/a/docs/link",
    kind = "link",
    mode = MODE_777,
    size = 2,
    target = "\\-",
}, table.concat({
    "!20261008:143015", "andrew:andrew", "lrwxrwxrwx", "2", "\\\\-", "/fvl/a/docs/link",
}, TAB), "target backslash-dash")

expect_line({
    path = "/fvl/a/odd\nname",
    kind = "link",
    mode = MODE_777,
    size = 3,
    target = "a\tb",
}, table.concat({
    "!20261008:143015", "andrew:andrew", "lrwxrwxrwx", "3", "a\\tb", "/fvl/a/odd\\nname",
}, TAB), "newline in the path escapes both fields")

expect_line({
    path = "/fvl/a/odd\\name",
    kind = "file",
    size = 1,
}, table.concat({
    "!20261008:143015", "andrew:andrew", "-rw-r--r--", "1", "-", "/fvl/a/odd\\\\name",
}, TAB), "backslash in the path")

expect_line({
    path = "/fvl/a/odd\rname",
    kind = "file",
    size = 1,
}, table.concat({
    "!20261008:143015", "andrew:andrew", "-rw-r--r--", "1", "-", "/fvl/a/odd\\rname",
}, TAB), "carriage return in the path")

local ff_path = "/fvl/a/odd" .. string.char(0xFF) .. "name"
local ff_line = expect_line({
    path = ff_path,
    size = 4,
}, table.concat({
    "20261008:143015", "andrew:andrew", "-rw-r--r--", "4", "-", ff_path,
}, TAB), "byte 0xFF is copied unchanged")
expect(ff_line and ff_line:sub(1, 1) ~= "!", "byte 0xFF does not raise the bang flag")
expect(ff_line and ff_line:find(string.char(0xFF), 1, true) ~= nil, "byte 0xFF is present")

local ff_bang_path = "/fvl/a/" .. string.char(0xFF) .. "\tname"
local ff_bang = expect_line({
    path = ff_bang_path,
    size = 4,
}, table.concat({
    "!20261008:143015", "andrew:andrew", "-rw-r--r--", "4", "-",
    "/fvl/a/" .. string.char(0xFF) .. "\\tname",
}, TAB), "byte 0xFF survives a bang escape")
expect(ff_bang and ff_bang:find(string.char(0xFF), 1, true) ~= nil, "bang line keeps byte 0xFF")

expect_line({
    kind = "file",
    mode = MODE_4755,
}, table.concat({
    "20261008:143015", "andrew:andrew", "-rwsr-xr-x", "4821", "-", "/fvl/a/docs/readme.txt",
}, TAB), "setuid")

expect_line({
    kind = "dir",
    path = "/fvl/a/docs",
    mode = MODE_2755,
    size = 6,
}, table.concat({
    "20261008:143015", "andrew:andrew", "drwxr-sr-x", "6", "-", "/fvl/a/docs",
}, TAB), "setgid")

expect_line({
    kind = "file",
    mode = MODE_4644,
}, table.concat({
    "20261008:143015", "andrew:andrew", "-rwSr--r--", "4821", "-", "/fvl/a/docs/readme.txt",
}, TAB), "setuid without execute")

expect_line({
    kind = "dir",
    path = "/tmp/sticky",
    mode = MODE_1777,
    size = 40,
}, table.concat({
    "20261008:143015", "andrew:andrew", "drwxrwxrwt", "40", "-", "/tmp/sticky",
}, TAB), "sticky")

expect_line({
    kind = "dir",
    path = "/tmp/sticky",
    mode = MODE_1776,
    size = 40,
}, table.concat({
    "20261008:143015", "andrew:andrew", "drwxrwxrwT", "40", "-", "/tmp/sticky",
}, TAB), "sticky without execute")

expect_line({
    mode = MODE_IFREG_644,
}, sample_readme, "file-type bits are ignored")

expect_line({
    path = "/fvl/a/docs/link",
    kind = "link",
    mode = MODE_777,
    size = 0,
    target = "../other/readme",
}, table.concat({
    "20261008:143015", "andrew:andrew", "lrwxrwxrwx", "0", "../other/readme", "/fvl/a/docs/link",
}, TAB), "size is the caller's integer, not the target length")

expect_line({
    target = "../ignored",
}, sample_readme, "a non-symlink link field stays a dash")

local bad_perm, bad_perm_err = raw_line({ permissions = "rw" })
expect(bad_perm == nil and bad_perm_err == "permissions must be 9 characters",
    "short permissions got " .. tostring(bad_perm_err))

local no_target, no_target_err = raw_line({ kind = "link", mode = MODE_777, target = nil })
expect(no_target == nil and no_target_err == "link target is required",
    "missing target got " .. tostring(no_target_err))

if failures > 0 then
    io.stderr:write(failures .. " failure(s)\n")
    os.exit(1)
end
io.stdout:write("phase 3 gate passed\n")
