-- Phase 3 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 3
-- parse_listing is the inverse of casually_index.lua format_line.
-- No destination tree. A valid listing is not applied.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase3.lua")
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

local api = dofile(exe)
local index = dofile(index_exe)
expect(type(api.parse_listing) == "function", "parse_listing is exported")
expect(type(api.listing_stamp) == "function", "listing_stamp is exported")
expect(type(index.format_line) == "function", "format_line is exported")

local OCT = function(text)
    return tonumber(text, 8)
end

local function fields(mtime, owner, mode, size, link, path)
    return table.concat({ mtime, owner, mode, tostring(size), link, path }, "\t")
end

local function as_listing(lines)
    return table.concat(lines, "\n") .. "\n"
end

local function dir_line(mtime, path, mode)
    return fields(mtime, "andrew:andrew", mode or "drwxr-xr-x", 0, "-", path)
end

local function file_line(mtime, path, size, mode)
    return fields(mtime, "andrew:andrew", mode or "-rw-r--r--", size or 0, "-", path)
end

local function link_line(mtime, path, target, size, mode)
    return fields(mtime, "andrew:andrew", mode or "lrwxrwxrwx", size, target, path)
end

local function reject(text, reason)
    local parsed, err, class = api.parse_listing(text)
    expect(parsed == nil, reason .. " accepted a listing")
    expect(err == reason, reason .. " got " .. string.format("%q", tostring(err)))
    expect(class == "config", reason .. " class " .. tostring(class))
end

local function accept(text, label)
    local parsed, err, class = api.parse_listing(text)
    if not parsed then
        fail(label .. " rejected: " .. tostring(err) .. " class " .. tostring(class))
        return nil
    end
    expect(err == nil and class == nil, label .. " returned an error with records")
    return parsed
end

local SEC = 1700000000

local function base_record(over)
    local rec = {
        path = "/fvl/a",
        kind = "dir",
        size = 0,
        mtime = SEC,
        user = "andrew",
        group = "andrew",
        mode = OCT("755"),
    }
    if over then
        for key, value in pairs(over) do
            rec[key] = value
        end
    end
    return rec
end

local function round_trip(records, label)
    local lines = {}
    for i = 1, #records do
        local text, err = index.format_line(records[i])
        if not text then
            fail(label .. " format_line " .. i .. ": " .. tostring(err))
            return nil
        end
        lines[i] = text
    end
    local parsed = accept(as_listing(lines), label)
    if not parsed then
        return nil
    end
    expect(#parsed == #records, label .. " record count " .. tostring(#parsed))
    for i = 1, #records do
        local want = records[i]
        local got = parsed[i]
        if not got then
            fail(label .. " missing record " .. i)
        else
            local where = label .. " record " .. i
            expect(got.path == want.path, where .. " path " .. string.format("%q", tostring(got.path)))
            expect(got.kind == want.kind, where .. " kind " .. tostring(got.kind))
            expect(got.size == want.size, where .. " size " .. tostring(got.size))
            expect(got.user == want.user, where .. " user " .. tostring(got.user))
            expect(got.group == want.group, where .. " group " .. tostring(got.group))
            expect(got.target == want.target, where .. " target " .. string.format("%q", tostring(got.target)))
            local mtime_text = os.date("!%Y%m%d:%H%M%S", want.mtime)
            expect(got.mtime_text == mtime_text, where .. " mtime text " .. tostring(got.mtime_text))
            expect(os.date("!%Y%m%d:%H%M%S", got.mtime) == mtime_text,
                where .. " mtime round trip " .. tostring(got.mtime))
            expect(math.type(got.mtime) == "integer", where .. " mtime type " .. tostring(math.type(got.mtime)))
            local mode_field = lines[i]:match("^[^\t]*\t[^\t]*\t([^\t]*)\t")
            expect(got.mode_text == mode_field, where .. " mode text " .. tostring(got.mode_text))
            if want.mode ~= nil then
                expect(got.mode == want.mode, where .. " mode bits " .. tostring(got.mode))
            end
            if want.permissions ~= nil then
                local type_char = ({ file = "-", dir = "d", link = "l" })[want.kind]
                expect(got.mode_text == type_char .. want.permissions,
                    where .. " permissions text " .. tostring(got.mode_text))
            end
        end
    end
    return parsed
end

local function gate()
    reject("", "listing is empty")
    reject("\n", "listing has no records")
    reject(dir_line("20261008:143015", "/fvl/a"), "listing is missing a final newline")
    reject(as_listing({
        dir_line("20261008:143015", "/fvl/a"),
        "",
        dir_line("20261008:143015", "/other"),
    }), "line 2 is empty")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/a") .. "\textra" }),
        "line 1 has 7 fields")
    reject(as_listing({
        dir_line("20261008:143015", "/fvl"),
        file_line("20261008:143015", "/fvl/a", 1) .. "\textra",
    }), "line 2 has 7 fields")
    reject(as_listing({ "20261008:143015\tandrew:andrew\tdrwxr-xr-x\t0\t-" }),
        "line 1 has 5 fields")
    reject(as_listing({ dir_line("20261301:000000", "/fvl/a") }), "line 1 has a bad mtime")
    reject(as_listing({ dir_line("20260230:000000", "/fvl/a") }), "line 1 has a bad mtime")
    reject(as_listing({ dir_line("20261008-143015", "/fvl/a") }), "line 1 has a bad mtime")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/a", "drwxr-xr-q") }),
        "line 1 has a bad mode")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/a", "xrwxr-xr-x") }),
        "line 1 has a bad mode")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/a", "drwxr-xr-xX") }),
        "line 1 has a bad mode")
    reject(as_listing({
        dir_line("20261008:090001", "/fvl/a"),
        link_line("20261008:090001", "/fvl/a/link", "../other/readme", 11),
    }), "line 2 symlink size is not the target length")
    reject(as_listing({
        dir_line("20261008:090001", "/fvl/a"),
        link_line("20261008:090001", "/fvl/a/link", "-", 1),
    }), "line 2 link target is -")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/a\\b") }),
        "line 1 contains a backslash")
    reject(as_listing({
        fields("20261008:143015", "andrew:andrew", "-rw-r--r--", 1, "foo\\bar", "/fvl/a"),
    }), "line 1 contains a backslash")
    reject(as_listing({ "!20261008:143015\tandrew:andrew\tdrwxr-xr-x\t0\t-\t/fvl/\\x" }),
        "line 1 has an unknown escape")
    reject(as_listing({ "!20261008:143015\tandrew:andrew\tlrwxrwxrwx\t1\t\\q\t/fvl/a" }),
        "line 1 has an unknown escape")
    reject(as_listing({ dir_line("20261008:143015", "fvl/a") }),
        "line 1 path must be absolute")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/../a") }),
        "line 1 path contains '.' or '..'")
    reject(as_listing({ dir_line("20261008:143015", "/fvl/./a") }),
        "line 1 path contains '.' or '..'")
    reject(as_listing({ dir_line("20261008:143015", "/fvl//a") }),
        "line 1 path contains an empty component")
    reject(as_listing({
        dir_line("20261008:143015", "/fvl/a"),
        dir_line("20261008:143015", "/fvl/a"),
    }), "line 2 repeats a path")
    reject(as_listing({
        dir_line("20261008:143015", "/fvl/b"),
        dir_line("20261008:143015", "/fvl/a"),
    }), "line 2 is out of order")
    reject(as_listing({
        dir_line("20261008:143015", "/fvl"),
        file_line("20261008:143015", "/fvl/a/readme", 4),
    }), "line 2 parent is missing")
    reject(as_listing({
        dir_line("20261008:143015", "/fvl"),
        dir_line("20261008:143015", "/fvl/a/docs/sub"),
    }), "line 2 parent is missing")
    reject(as_listing({ file_line("20261008:143015", "/fvl/a/readme", 4) }),
        "line 1 root is not a directory")
    reject(42, "listing must be a string")

    local function expect_mtime(text)
        local parsed = accept(as_listing({ dir_line(text, "/fvl/a") }), text)
        if not parsed then
            return
        end
        expect(#parsed == 1, text .. " count")
        expect(parsed[1].path == "/fvl/a" and parsed[1].kind == "dir", text .. " record")
        expect(parsed[1].mtime_text == text, text .. " stored text " .. tostring(parsed[1].mtime_text))
        expect(os.date("!%Y%m%d:%H%M%S", parsed[1].mtime) == text,
            text .. " formats as " .. tostring(os.date("!%Y%m%d:%H%M%S", parsed[1].mtime)))
        expect(math.type(parsed[1].mtime) == "integer", text .. " mtime is an integer")
    end

    expect_mtime("20261008:143015")
    expect_mtime("20260101:000000")
    expect_mtime("20260701:120000")

    local one = accept(as_listing({ dir_line("20261008:143015", "/fvl/a") }), "only /fvl/a")
    if one then
        expect(#one == 1 and one[1].kind == "dir" and one[1].path == "/fvl/a", "only /fvl/a shape")
        expect(one[1].mode == OCT("755"), "dir mode bits " .. tostring(one[1].mode))
        expect(one[1].mode_text == "drwxr-xr-x", "dir mode text")
        expect(one[1].user == "andrew" and one[1].group == "andrew", "owner text")
        expect(one[1].target == nil, "dir has no target")
    end

    local roots = accept(as_listing({
        dir_line("20261008:143015", "/fvl/a"),
        dir_line("20261008:143015", "/other"),
    }), "two roots")
    if roots then
        expect(#roots == 2, "two roots count")
        expect(roots[1].path == "/fvl/a" and roots[2].path == "/other", "two roots stay sorted")
    end

    local slash = accept(as_listing({
        dir_line("20261008:143015", "/", "drwxr-xr-x"),
        file_line("20261008:143015", "/readme", 3),
    }), "root slash")
    if slash then
        expect(slash[1].path == "/" and slash[1].kind == "dir", "slash dir")
        expect(slash[2].path == "/readme" and slash[2].kind == "file" and slash[2].size == 3,
            "child of slash")
    end

    local sample = accept(as_listing({
        dir_line("20261008:143016", "/fvl/a/docs", "drwxr-xr-x"),
        link_line("20261008:090001", "/fvl/a/docs/link", "../other/readme", 15),
        file_line("20261008:143015", "/fvl/a/docs/readme.txt", 4821),
    }), "spec sample")
    if sample then
        expect(#sample == 3, "spec sample count")
        expect(sample[2].kind == "link" and sample[2].target == "../other/readme",
            "spec link target")
        expect(sample[2].size == 15 and sample[2].mode_text == "lrwxrwxrwx", "spec link meta")
        expect(sample[3].kind == "file" and sample[3].size == 4821
            and sample[3].mode_text == "-rw-r--r--", "spec file meta")
        expect(sample[3].mtime_text == "20261008:143015", "spec file mtime")
    end

    local dash = accept(as_listing({
        dir_line("20261008:090001", "/fvl/a"),
        link_line("20261008:090001", "/fvl/a/dash", "\\-", 1),
    }), "escaped dash target")
    if dash then
        expect(dash[2].target == "-", "dash target decodes to -")
        expect(dash[2].size == 1, "dash target length")
    end

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/readme.txt",
            kind = "file",
            size = 4821,
            mode = OCT("644"),
        }),
    }, "plain file")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/odd\tname",
            kind = "file",
            size = 3,
            mode = OCT("644"),
        }),
    }, "tab in the path")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/odd\nname",
            kind = "file",
            size = 3,
            mode = OCT("644"),
        }),
    }, "newline in the path")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/odd\rname",
            kind = "file",
            size = 3,
            mode = OCT("644"),
        }),
    }, "carriage return in the path")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/" .. string.char(0xFF),
            kind = "file",
            size = 1,
            mode = OCT("644"),
        }),
    }, "byte 0xFF in the path")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/dash",
            kind = "link",
            size = 1,
            mode = OCT("777"),
            target = "-",
        }),
    }, "target dash")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/odd\tlink",
            kind = "link",
            size = 1,
            mode = OCT("777"),
            target = "-",
        }),
    }, "target dash on a bang line")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/backslash",
            kind = "link",
            size = 2,
            mode = OCT("777"),
            target = "\\-",
        }),
    }, "target backslash dash")

    round_trip({
        base_record(),
        base_record({
            path = "/fvl/a/setgid",
            kind = "file",
            size = 1,
            mode = OCT("2755"),
        }),
        base_record({
            path = "/fvl/a/setgid-no-exec",
            kind = "file",
            size = 1,
            mode = OCT("2644"),
        }),
        base_record({
            path = "/fvl/a/setuid",
            kind = "file",
            size = 1,
            mode = OCT("4755"),
        }),
        base_record({
            path = "/fvl/a/setuid-no-exec",
            kind = "file",
            size = 1,
            mode = OCT("4644"),
        }),
        base_record({
            path = "/fvl/a/sticky",
            kind = "file",
            size = 1,
            mode = OCT("1755"),
        }),
        base_record({
            path = "/fvl/a/sticky-no-exec",
            kind = "file",
            size = 1,
            mode = OCT("1754"),
        }),
    }, "setuid setgid and sticky")

    round_trip({
        base_record({ permissions = "rwxr-xr-x" }),
        base_record({
            path = "/fvl/a/from-nine",
            kind = "file",
            size = 1,
            permissions = "rw-r--r--",
            mode = OCT("644"),
        }),
    }, "nine-character permissions")

    local nine = accept(as_listing({
        dir_line("20261008:143015", "/fvl/a", "drwxr-xr-x"),
        file_line("20261008:143015", "/fvl/a/from-nine", 1, "-rw-r--r--"),
    }), "permission bits")
    if nine then
        expect(nine[2].mode == OCT("644"), "644 bits " .. tostring(nine[2].mode))
    end

    local function expect_stamp(name, want)
        local got = api.listing_stamp(name)
        expect(got == want, "stamp " .. string.format("%q", tostring(name))
            .. " got " .. string.format("%q", tostring(got)))
    end

    expect_stamp("/var/lib/casually/index-20261008-1430.listing", "20261008-1430")
    expect_stamp("index-20261008-1430.listing", "20261008-1430")
    expect_stamp("index-20260101-0000.listing", "20260101-0000")
    expect_stamp("dir/index-20260701-1200.listing", "20260701-1200")
    expect_stamp("index-20261008-1430.listing.partial", nil)
    expect_stamp("index-20261008-1430.listing/", nil)
    expect_stamp("index-2026108-1430.listing", nil)
    expect_stamp("index-20261008-1430.txt", nil)
    expect_stamp("index-20261008-1430.LISTING", nil)
    expect_stamp("notes.listing", nil)
    expect_stamp("/var/lib/index-20261008-1430.listing/extra", nil)
    expect_stamp("", nil)
    expect_stamp(nil, nil)
end

local ok, err = xpcall(gate, debug.traceback)
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
local phase_cmd = sh_quote(root .. "/test/run.sh") .. " backup 2 > "
    .. sh_quote(phase_out) .. " 2> " .. sh_quote(phase_err)
local pok, phow, pcode = os.execute(phase_cmd)
local function read_all(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a") or ""
    f:close()
    return text
end
local phase_text = read_all(phase_out)
local phase_err_text = read_all(phase_err)
os.remove(phase_out)
os.remove(phase_err)
if pok == true then
    pcode = 0
elseif phow ~= "exit" then
    pcode = -1
end
if pcode ~= 0 or phase_text:find("backup phase 2 gate passed", 1, true) == nil then
    io.stderr:write("backup phase 2 did not pass, exit " .. tostring(pcode) .. "\n")
    io.stderr:write(phase_err_text)
    io.stderr:write(phase_text)
    os.exit(1)
end

io.stdout:write("backup phase 3 gate passed\n")
