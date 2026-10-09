-- Phase 4 gate for casually_backup. Run from the repo root:
--   test/run.sh backup 4
-- plan classifies each destination. It does not create or remove user files.
-- A successful plan is not applied.

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function repo_root()
    local here = dirname(arg[0] or "test/backup_phase4.lua")
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
expect(type(api.plan) == "function", "plan is exported")
expect(type(index.format_line) == "function", "format_line is exported")

local base

local function cleanup()
    if base then
        os.execute("chmod -R u+rwx " .. sh_quote(base) .. " >/dev/null 2>&1")
        os.execute("rm -rf " .. sh_quote(base))
    end
end

local function real_dir(path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then
        return nil, iter
    end
    return iter, dir_obj
end

local function real_lstat(path)
    return lfs.symlinkattributes(path)
end

local function user_fs(extra)
    extra = extra or {}
    if extra.euid == nil then
        extra.euid = 1000
    end
    extra.lstat = extra.lstat or real_lstat
    extra.dir = extra.dir or real_dir
    return extra
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

local function line_for(abs, listing)
    local attr = assert(lfs.symlinkattributes(abs), abs)
    local kind = assert(kind_of(attr.mode), attr.mode)
    local rec = {
        path = listing,
        kind = kind,
        size = math.tointeger(attr.size),
        mtime = attr.modification,
        user = attr.uid,
        group = attr.gid,
        permissions = attr.permissions,
    }
    if kind == "link" then
        rec.target = attr.target
        rec.size = #attr.target
    end
    local line, err = index.format_line(rec)
    if not line then
        error(err or "format_line")
    end
    return line
end

local function write_listing(dir, rows)
    table.sort(rows, function(a, b)
        return a.listing < b.listing
    end)
    local lines = {}
    for i = 1, #rows do
        lines[i] = line_for(rows[i].abs, rows[i].listing)
    end
    local path = dir .. "/index-20261008-1430.listing"
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    return path
end

local function config_for(index_path, dests, opts)
    opts = opts or {}
    return {
        index = index_path,
        destinations = dests,
        source_map = opts.source_map or {},
        exclude = opts.exclude or {},
        omit_limit = opts.omit_limit ~= nil and opts.omit_limit or 1000,
        omit_fraction = opts.omit_fraction ~= nil and opts.omit_fraction or 0.02,
    }
end

local function published(dest, snap, listing)
    return dest .. "/" .. snap .. listing
end

local function find_listing(dest_plan, kind, listing)
    local list = dest_plan.actions[kind]
    if not list then
        return nil
    end
    for i = 1, #list do
        if list[i].listing == listing then
            return list[i]
        end
    end
    return nil
end

local function warning_count(plan, text)
    local n = 0
    for i = 1, #plan.warnings do
        if plan.warnings[i] == text then
            n = n + 1
        end
    end
    return n
end

local function tree_text(dir)
    local handle = io.popen("find " .. sh_quote(dir) .. " -printf '%P\\t%y\\n' | sort")
    local text = handle:read("a") or ""
    handle:close()
    return text
end

local function refuse(cfg, fs, reason, class)
    local plan, err, got = api.plan(cfg, fs)
    expect(plan == nil, reason .. " returned a plan")
    expect(err == reason, reason .. " got " .. string.format("%q", tostring(err)))
    expect(got == class, reason .. " class " .. tostring(got))
    return err
end

local function place_copy(src, dst)
    mkdir_p(dirname(dst))
    sh("cp -a " .. sh_quote(src) .. " " .. sh_quote(dst))
end

local seq = 0

local function case_dir(name)
    seq = seq + 1
    local path = base .. "/" .. string.format("%02d-%s", seq, name)
    mkdir_p(path)
    return path
end

local function gate()
    local tmp = os.tmpname()
    os.remove(tmp)
    base = tmp
    mkdir_p(base)

    -- empty dest, a file and its parent dir
    local empty = case_dir("empty")
    local src = empty .. "/src"
    local dest = empty .. "/dest"
    mkdir_p(dest)
    write_file(src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(src .. "/fvl/readme"))
    sh("chmod 755 " .. sh_quote(src .. "/fvl"))
    local index_path = write_listing(empty, {
        { abs = src .. "/fvl", listing = "/fvl" },
        { abs = src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local cfg = config_for(index_path, { dest }, {
        source_map = { { alias = "/fvl", path = src .. "/fvl" } },
    })
    local plan, err, class = api.plan(cfg, user_fs())
    expect(plan ~= nil, "empty dest plan " .. tostring(err) .. " " .. tostring(class))
    if plan then
        expect(plan.stamp == "20261008-1430", "stamp " .. tostring(plan.stamp))
        expect(#plan.destinations == 1, "one destination")
        local one = plan.destinations[1]
        expect(one.snapshot == "_Base", "empty snapshot " .. tostring(one.snapshot))
        expect(one.previous == nil, "empty previous")
        expect(one.counts.omit == 0, "empty omit " .. tostring(one.counts.omit))
        expect(one.counts.read == 1, "empty read " .. tostring(one.counts.read))
        expect(plan.counts.read == 1, "empty shared read " .. tostring(plan.counts.read))
        expect(find_listing(one, "mkdir", "/fvl") ~= nil, "empty mkdir")
        local copy = find_listing(one, "copy", "/fvl/readme")
        expect(copy ~= nil, "empty copy")
        if copy then
            expect(copy.source == src .. "/fvl/readme", "empty source " .. tostring(copy.source))
            expect(copy.path == published(dest, "_Base", "/fvl/readme"), "empty published " .. tostring(copy.path))
        end
        expect(one.actions.hardlink ~= nil and #one.actions.hardlink == 0, "empty hardlink")
        expect(one.actions.omit ~= nil and #one.actions.omit == 0, "empty omit list")
        expect(one.actions.delete == nil and one.actions.unlink == nil, "empty has a delete action")
        expect(warning_count(plan, "casually_backup: owner not applied") == 1, "owner warning")
        expect(tree_text(dest) == "\t" .. "d" .. "\n" or tree_text(dest):find("_Base", 1, true) == nil,
            "empty dest was written")
        expect(lfs.symlinkattributes(dest .. "/_Base") == nil, "empty dest gained _Base")
    end

    -- _Base matching on one dest, empty on the other. Shared read is 1.
    local split = case_dir("split")
    local split_src = split .. "/src"
    local filled = split .. "/filled"
    local bare = split .. "/bare"
    mkdir_p(bare)
    write_file(split_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(split_src .. "/fvl/readme"))
    place_copy(split_src .. "/fvl", filled .. "/_Base/fvl")
    local split_index = write_listing(split, {
        { abs = split_src .. "/fvl", listing = "/fvl" },
        { abs = split_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local split_plan, split_err = api.plan(config_for(split_index, { filled, bare }, {
        source_map = { { alias = "/fvl", path = split_src .. "/fvl" } },
    }), user_fs())
    expect(split_plan ~= nil, "split plan " .. tostring(split_err))
    if split_plan then
        local old = split_plan.destinations[1]
        local new = split_plan.destinations[2]
        expect(old.snapshot == "20261008-1430", "filled snapshot " .. tostring(old.snapshot))
        expect(old.previous == filled .. "/_Base", "filled previous")
        expect(old.counts.read == 0, "filled read " .. tostring(old.counts.read))
        expect(find_listing(old, "hardlink", "/fvl/readme") ~= nil, "filled hardlink")
        expect(#old.actions.copy == 0, "filled copy")
        local link = find_listing(old, "hardlink", "/fvl/readme")
        if link then
            expect(link.previous == filled .. "/_Base/fvl/readme", "link source " .. tostring(link.previous))
            expect(link.path == published(filled, "20261008-1430", "/fvl/readme"), "link dest")
        end
        expect(new.snapshot == "_Base", "bare snapshot " .. tostring(new.snapshot))
        expect(new.counts.read == 1, "bare read")
        expect(find_listing(new, "copy", "/fvl/readme") ~= nil, "bare copy")
        expect(split_plan.counts.hardlink == 1, "shared hardlink " .. tostring(split_plan.counts.hardlink))
        expect(split_plan.counts.copy == 1, "shared copy " .. tostring(split_plan.counts.copy))
        expect(split_plan.counts.read == 1, "shared read " .. tostring(split_plan.counts.read))
        expect(split_plan.reads[1] == split_src .. "/fvl/readme", "shared source")
        expect(#split_plan.reads == 1, "one source read")
    end

    -- both destinations hardlink: no source read
    local both = case_dir("both")
    local both_src = both .. "/src"
    local both_a = both .. "/a"
    local both_b = both .. "/b"
    write_file(both_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(both_src .. "/fvl/readme"))
    place_copy(both_src .. "/fvl", both_a .. "/_Base/fvl")
    place_copy(both_src .. "/fvl", both_b .. "/_Base/fvl")
    local both_index = write_listing(both, {
        { abs = both_src .. "/fvl", listing = "/fvl" },
        { abs = both_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local both_plan, both_err = api.plan(config_for(both_index, { both_a, both_b }, {
        source_map = { { alias = "/fvl", path = both_src .. "/fvl" } },
    }), user_fs())
    expect(both_plan ~= nil, "both plan " .. tostring(both_err))
    if both_plan then
        expect(both_plan.counts.read == 0, "both read " .. tostring(both_plan.counts.read))
        expect(both_plan.counts.hardlink == 2, "both hardlink " .. tostring(both_plan.counts.hardlink))
        expect(both_plan.counts.copy == 0, "both copy")
        expect(#both_plan.reads == 0, "both reads list")
    end

    -- latest dated snapshot is the link source, not _Base
    local chain = case_dir("chain")
    local chain_src = chain .. "/src"
    local chain_dest = chain .. "/dest"
    write_file(chain_src .. "/fvl/readme", "new-bytes\n")
    sh("chmod 644 " .. sh_quote(chain_src .. "/fvl/readme"))
    write_file(chain_dest .. "/_Base/fvl/readme", "old-bytes\n")
    place_copy(chain_src .. "/fvl", chain_dest .. "/20261007-1200/fvl")
    local chain_index = write_listing(chain, {
        { abs = chain_src .. "/fvl", listing = "/fvl" },
        { abs = chain_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local chain_plan, chain_err = api.plan(config_for(chain_index, { chain_dest }, {
        source_map = { { alias = "/fvl", path = chain_src .. "/fvl" } },
    }), user_fs())
    expect(chain_plan ~= nil, "chain plan " .. tostring(chain_err))
    if chain_plan then
        local one = chain_plan.destinations[1]
        expect(one.previous == chain_dest .. "/20261007-1200", "chain previous " .. tostring(one.previous))
        expect(one.snapshot == "20261008-1430", "chain snapshot")
        local link = find_listing(one, "hardlink", "/fvl/readme")
        expect(link ~= nil, "chain hardlink")
        if link then
            expect(link.previous == chain_dest .. "/20261007-1200/fvl/readme",
                "chain link " .. tostring(link.previous))
        end
        expect(chain_plan.counts.read == 0, "chain read")
    end

    -- missing _Base ignores leftover dates
    local orphan = case_dir("orphan")
    local orphan_src = orphan .. "/src"
    local orphan_dest = orphan .. "/dest"
    write_file(orphan_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(orphan_src .. "/fvl/readme"))
    place_copy(orphan_src .. "/fvl", orphan_dest .. "/20261007-1200/fvl")
    local orphan_index = write_listing(orphan, {
        { abs = orphan_src .. "/fvl", listing = "/fvl" },
        { abs = orphan_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local orphan_plan, orphan_err = api.plan(config_for(orphan_index, { orphan_dest }, {
        source_map = { { alias = "/fvl", path = orphan_src .. "/fvl" } },
    }), user_fs())
    expect(orphan_plan ~= nil, "orphan plan " .. tostring(orphan_err))
    if orphan_plan then
        local one = orphan_plan.destinations[1]
        expect(one.snapshot == "_Base", "orphan snapshot " .. tostring(one.snapshot))
        expect(one.previous == nil, "orphan previous")
        expect(find_listing(one, "copy", "/fvl/readme") ~= nil, "orphan copy")
        expect(#one.actions.hardlink == 0, "orphan hardlink")
        expect(one.counts.omit == 0, "orphan omit")
        expect(orphan_plan.counts.read == 1, "orphan read")
    end

    -- size and mtime match, mode differs: copy
    local mode = case_dir("mode")
    local mode_src = mode .. "/src"
    local mode_dest = mode .. "/dest"
    write_file(mode_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(mode_src .. "/fvl/readme"))
    place_copy(mode_src .. "/fvl", mode_dest .. "/_Base/fvl")
    sh("chmod 700 " .. sh_quote(mode_dest .. "/_Base/fvl/readme"))
    local src_attr = lfs.symlinkattributes(mode_src .. "/fvl/readme")
    lfs.touch(mode_dest .. "/_Base/fvl/readme", src_attr.modification, src_attr.modification)
    local mode_index = write_listing(mode, {
        { abs = mode_src .. "/fvl", listing = "/fvl" },
        { abs = mode_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local mode_plan, mode_err = api.plan(config_for(mode_index, { mode_dest }, {
        source_map = { { alias = "/fvl", path = mode_src .. "/fvl" } },
    }), user_fs())
    expect(mode_plan ~= nil, "mode plan " .. tostring(mode_err))
    if mode_plan then
        local one = mode_plan.destinations[1]
        expect(find_listing(one, "copy", "/fvl/readme") ~= nil, "mode copy")
        expect(#one.actions.hardlink == 0, "mode hardlink")
        expect(one.counts.read == 1, "mode read")
    end

    -- symlink target matches: hardlink, and the symlink is not a source read
    local same_link = case_dir("same-link")
    local same_src = same_link .. "/src"
    local same_dest = same_link .. "/dest"
    mkdir_p(same_src .. "/fvl")
    sh("ln -s target " .. sh_quote(same_src .. "/fvl/link"))
    place_copy(same_src .. "/fvl", same_dest .. "/_Base/fvl")
    local same_index = write_listing(same_link, {
        { abs = same_src .. "/fvl", listing = "/fvl" },
        { abs = same_src .. "/fvl/link", listing = "/fvl/link" },
    })
    local same_plan, same_err = api.plan(config_for(same_index, { same_dest }, {
        source_map = { { alias = "/fvl", path = same_src .. "/fvl" } },
    }), user_fs())
    expect(same_plan ~= nil, "same link plan " .. tostring(same_err))
    if same_plan then
        local one = same_plan.destinations[1]
        local link = find_listing(one, "hardlink", "/fvl/link")
        expect(link ~= nil, "same link hardlink")
        expect(#one.actions.symlink == 0, "same link create")
        expect(same_plan.counts.read == 0, "same link read " .. tostring(same_plan.counts.read))
        if link then
            expect(link.previous == same_dest .. "/_Base/fvl/link", "same link previous")
        end
    end

    -- symlink target differs
    local diff_link = case_dir("diff-link")
    local diff_src = diff_link .. "/src"
    local diff_dest = diff_link .. "/dest"
    mkdir_p(diff_src .. "/fvl")
    mkdir_p(diff_dest .. "/_Base/fvl")
    sh("ln -s target " .. sh_quote(diff_src .. "/fvl/link"))
    sh("ln -s other " .. sh_quote(diff_dest .. "/_Base/fvl/link"))
    local diff_index = write_listing(diff_link, {
        { abs = diff_src .. "/fvl", listing = "/fvl" },
        { abs = diff_src .. "/fvl/link", listing = "/fvl/link" },
    })
    local diff_plan, diff_err = api.plan(config_for(diff_index, { diff_dest }, {
        source_map = { { alias = "/fvl", path = diff_src .. "/fvl" } },
    }), user_fs())
    expect(diff_plan ~= nil, "diff link plan " .. tostring(diff_err))
    if diff_plan then
        local one = diff_plan.destinations[1]
        local link = find_listing(one, "symlink", "/fvl/link")
        expect(link ~= nil, "diff link symlink")
        expect(#one.actions.hardlink == 0, "diff link hardlink")
        expect(diff_plan.counts.read == 0, "diff link read")
        if link then
            expect(link.target == "target", "diff link target " .. tostring(link.target))
            expect(link.path == published(diff_dest, "20261008-1430", "/fvl/link"), "diff link path")
        end
    end

    -- one extra file under the limit is an omit, not a delete
    local kept = case_dir("omit-under")
    local kept_src = kept .. "/src"
    local kept_dest = kept .. "/dest"
    write_file(kept_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(kept_src .. "/fvl/readme"))
    place_copy(kept_src .. "/fvl", kept_dest .. "/_Base/fvl")
    write_file(kept_dest .. "/_Base/fvl/old", "gone\n")
    local kept_index = write_listing(kept, {
        { abs = kept_src .. "/fvl", listing = "/fvl" },
        { abs = kept_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local kept_plan, kept_err = api.plan(config_for(kept_index, { kept_dest }, {
        source_map = { { alias = "/fvl", path = kept_src .. "/fvl" } },
    }), user_fs())
    expect(kept_plan ~= nil, "omit under plan " .. tostring(kept_err))
    if kept_plan then
        local one = kept_plan.destinations[1]
        expect(one.counts.omit == 1, "omit under count " .. tostring(one.counts.omit))
        expect(#one.actions.omit == 1, "omit under list")
        if one.actions.omit[1] then
            expect(one.actions.omit[1].path == kept_dest .. "/_Base/fvl/old",
                "omit path " .. tostring(one.actions.omit[1].path))
            expect(one.actions.omit[1].listing == "/fvl/old", "omit listing")
        end
        expect(one.actions.delete == nil and one.actions.unlink == nil, "omit is a delete")
        expect(kept_plan.text:find("\ndelete ", 1, true) == nil, "omit text delete")
        expect(kept_plan.text:find("omit " .. kept_dest .. "/_Base/fvl/old\n", 1, true) ~= nil,
            "omit line missing\n" .. kept_plan.text)
        expect(kept_plan.text:find("skip=0", 1, true) ~= nil, "skip stays 0")
        expect(lfs.symlinkattributes(kept_dest .. "/_Base/fvl/old") ~= nil, "omit removed the file")
    end

    -- 3 desired, limit 1, fraction 0.02, 2 omissions: refused.
    -- fraction 0.9: 2 is not greater than 0.9 * 3, allowed.
    local mass = case_dir("mass")
    local mass_src = mass .. "/src"
    local mass_dest = mass .. "/dest"
    write_file(mass_src .. "/fvl/a/keep", "keep\n")
    sh("chmod 644 " .. sh_quote(mass_src .. "/fvl/a/keep"))
    place_copy(mass_src .. "/fvl", mass_dest .. "/_Base/fvl")
    write_file(mass_dest .. "/_Base/fvl/a/old1", "one\n")
    write_file(mass_dest .. "/_Base/fvl/a/old2", "two\n")
    local mass_index = write_listing(mass, {
        { abs = mass_src .. "/fvl", listing = "/fvl" },
        { abs = mass_src .. "/fvl/a", listing = "/fvl/a" },
        { abs = mass_src .. "/fvl/a/keep", listing = "/fvl/a/keep" },
    })
    local mass_map = { { alias = "/fvl", path = mass_src .. "/fvl" } }
    local refused = config_for(mass_index, { mass_dest }, {
        source_map = mass_map,
        omit_limit = 1,
        omit_fraction = 0.02,
    })
    local before = tree_text(mass_dest)
    refuse(refused, user_fs(),
        "too many omissions: " .. mass_dest .. " omitted 2 limit 1 fraction 0.02",
        "plan")
    expect(tree_text(mass_dest) == before, "mass refusal changed the tree")
    expect(lfs.symlinkattributes(mass_dest .. "/20261008-1430") == nil, "mass refusal published")

    local allowed, allowed_err = api.plan(config_for(mass_index, { mass_dest }, {
        source_map = mass_map,
        omit_limit = 1,
        omit_fraction = 0.9,
    }), user_fs())
    expect(allowed ~= nil, "fraction allow " .. tostring(allowed_err))
    if allowed then
        expect(allowed.destinations[1].counts.omit == 2, "fraction omit "
            .. tostring(allowed.destinations[1].counts.omit))
        expect(allowed.desired == 3, "fraction desired " .. tostring(allowed.desired))
    end

    -- stamp directory already present
    local clash = case_dir("clash")
    local clash_src = clash .. "/src"
    local clash_dest = clash .. "/dest"
    write_file(clash_src .. "/fvl/readme", "hello\n")
    place_copy(clash_src .. "/fvl", clash_dest .. "/_Base/fvl")
    mkdir_p(clash_dest .. "/20261008-1430/fvl")
    local clash_index = write_listing(clash, {
        { abs = clash_src .. "/fvl", listing = "/fvl" },
        { abs = clash_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local clash_before = tree_text(clash_dest)
    refuse(config_for(clash_index, { clash_dest }, {
        source_map = { { alias = "/fvl", path = clash_src .. "/fvl" } },
    }), user_fs(), "snapshot exists: " .. clash_dest .. "/20261008-1430", "plan")
    expect(tree_text(clash_dest) == clash_before, "clash changed the tree")

    -- fifo is a left warning, not an omission
    local pipe = case_dir("fifo")
    local pipe_src = pipe .. "/src"
    local pipe_dest = pipe .. "/dest"
    write_file(pipe_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(pipe_src .. "/fvl/readme"))
    place_copy(pipe_src .. "/fvl", pipe_dest .. "/_Base/fvl")
    sh("mkfifo " .. sh_quote(pipe_dest .. "/_Base/fvl/queue"))
    local pipe_index = write_listing(pipe, {
        { abs = pipe_src .. "/fvl", listing = "/fvl" },
        { abs = pipe_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local pipe_plan, pipe_err = api.plan(config_for(pipe_index, { pipe_dest }, {
        source_map = { { alias = "/fvl", path = pipe_src .. "/fvl" } },
    }), user_fs())
    expect(pipe_plan ~= nil, "fifo plan " .. tostring(pipe_err))
    if pipe_plan then
        local one = pipe_plan.destinations[1]
        expect(one.counts.omit == 0, "fifo counted as omit " .. tostring(one.counts.omit))
        local left = "casually_backup: left named pipe " .. pipe_dest .. "/_Base/fvl/queue"
        expect(warning_count(pipe_plan, left) == 1, "fifo warning missing\n"
            .. table.concat(pipe_plan.warnings, "\n"))
        expect(pipe_plan.text:find("queue", 1, true) == nil, "fifo appeared in the plan text")
    end

    -- exclude covers a listing directory: no create, children are not walked
    local skip = case_dir("exclude")
    local skip_src = skip .. "/src"
    local skip_dest = skip .. "/dest"
    write_file(skip_src .. "/fvl/keep/file", "keep\n")
    write_file(skip_src .. "/fvl/skip/secret", "secret\n")
    place_copy(skip_src .. "/fvl", skip_dest .. "/_Base/fvl")
    write_file(skip_dest .. "/_Base/fvl/skip/deep/x", "hidden\n")
    sh("chmod 000 " .. sh_quote(skip_dest .. "/_Base/fvl/skip"))
    local skip_index = write_listing(skip, {
        { abs = skip_src .. "/fvl", listing = "/fvl" },
        { abs = skip_src .. "/fvl/keep", listing = "/fvl/keep" },
        { abs = skip_src .. "/fvl/keep/file", listing = "/fvl/keep/file" },
        { abs = skip_src .. "/fvl/skip", listing = "/fvl/skip" },
        { abs = skip_src .. "/fvl/skip/secret", listing = "/fvl/skip/secret" },
    })
    local skip_plan, skip_err, skip_class = api.plan(config_for(skip_index, { skip_dest }, {
        source_map = { { alias = "/fvl", path = skip_src .. "/fvl" } },
        exclude = { "/fvl/skip" },
    }), user_fs())
    expect(skip_plan ~= nil, "exclude plan " .. tostring(skip_err) .. " " .. tostring(skip_class))
    if skip_plan then
        local one = skip_plan.destinations[1]
        expect(skip_plan.desired == 3, "exclude desired " .. tostring(skip_plan.desired))
        expect(find_listing(one, "hardlink", "/fvl/keep/file") ~= nil, "exclude kept the file")
        expect(find_listing(one, "mkdir", "/fvl/skip") == nil, "exclude mkdir skip")
        expect(find_listing(one, "copy", "/fvl/skip/secret") == nil, "exclude copied secret")
        expect(one.counts.omit == 1, "exclude omit " .. tostring(one.counts.omit))
        if one.actions.omit[1] then
            expect(one.actions.omit[1].listing == "/fvl/skip",
                "exclude omit path " .. tostring(one.actions.omit[1].listing))
        end
        for _, kind in ipairs({ "mkdir", "copy", "hardlink", "symlink" }) do
            for i = 1, #one.actions[kind] do
                local path = one.actions[kind][i].path
                expect(path:find("/skip", 1, true) == nil, "exclude created " .. path)
            end
        end
    end
    sh("chmod 755 " .. sh_quote(skip_dest .. "/_Base/fvl/skip"))

    -- destination nested under a resolved source directory
    local nest = case_dir("nest")
    local nest_src = nest .. "/src"
    local nest_dest = nest_src .. "/fvl/backup"
    write_file(nest_src .. "/fvl/readme", "hello\n")
    mkdir_p(nest_dest)
    local nest_index = write_listing(nest, {
        { abs = nest_src .. "/fvl", listing = nest_src .. "/fvl" },
        { abs = nest_src .. "/fvl/readme", listing = nest_src .. "/fvl/readme" },
    })
    local nest_err = refuse(config_for(nest_index, { nest_dest }), user_fs(),
        "source and destination nest: " .. nest_src .. "/fvl and " .. nest_dest, "plan")
    expect(type(nest_err) == "string", "nest message")

    -- source map prefix: copy prints the mapped source and the listing path
    local mapped = case_dir("map")
    local map_src = mapped .. "/src"
    local map_dest = mapped .. "/dest"
    mkdir_p(map_dest)
    write_file(map_src .. "/a/readme", "mapped\n")
    sh("chmod 644 " .. sh_quote(map_src .. "/a/readme"))
    local map_index = write_listing(mapped, {
        { abs = map_src, listing = "/fvl" },
        { abs = map_src .. "/a", listing = "/fvl/a" },
        { abs = map_src .. "/a/readme", listing = "/fvl/a/readme" },
    })
    local map_plan, map_err = api.plan(config_for(map_index, { map_dest }, {
        source_map = { { alias = "/fvl", path = map_src } },
    }), user_fs())
    expect(map_plan ~= nil, "map plan " .. tostring(map_err))
    if map_plan then
        local copy = find_listing(map_plan.destinations[1], "copy", "/fvl/a/readme")
        expect(copy ~= nil, "map copy")
        if copy then
            expect(copy.source == map_src .. "/a/readme", "map source " .. tostring(copy.source))
            expect(copy.path == published(map_dest, "_Base", "/fvl/a/readme"),
                "map published " .. tostring(copy.path))
        end
        local copy_line = "copy " .. map_src .. "/a/readme "
            .. published(map_dest, "_Base", "/fvl/a/readme")
        expect(map_plan.text:find(copy_line, 1, true) ~= nil, "map line missing\n" .. map_plan.text)
        expect(map_plan.destinations[1].snapshot == "_Base", "map snapshot")
    end

    -- unreadable _Base is class scan and returns no actions
    local dark = case_dir("dark")
    local dark_src = dark .. "/src"
    local dark_dest = dark .. "/dest"
    write_file(dark_src .. "/fvl/readme", "hello\n")
    mkdir_p(dark_dest .. "/_Base/fvl")
    local dark_index = write_listing(dark, {
        { abs = dark_src .. "/fvl", listing = "/fvl" },
        { abs = dark_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local dark_base = dark_dest .. "/_Base"
    local dark_fs = user_fs({
        dir = function(path)
            if path == dark_base then
                return nil, "Permission denied"
            end
            return real_dir(path)
        end,
    })
    local dark_plan, dark_err, dark_class = api.plan(config_for(dark_index, { dark_dest }, {
        source_map = { { alias = "/fvl", path = dark_src .. "/fvl" } },
    }), dark_fs)
    expect(dark_plan == nil, "dark returned a plan")
    expect(dark_class == "scan", "dark class " .. tostring(dark_class))
    expect(dark_err == "cannot read " .. dark_base .. ": Permission denied",
        "dark err " .. tostring(dark_err))
    expect(lfs.symlinkattributes(dark_dest .. "/20261008-1430") == nil, "dark published")

    -- previous snapshot on a different device
    local other = case_dir("device")
    local other_src = other .. "/src"
    local other_dest = other .. "/dest"
    write_file(other_src .. "/fvl/readme", "hello\n")
    place_copy(other_src .. "/fvl", other_dest .. "/_Base/fvl")
    local other_index = write_listing(other, {
        { abs = other_src .. "/fvl", listing = "/fvl" },
        { abs = other_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    local other_base = other_dest .. "/_Base"
    local other_fs = user_fs({
        lstat = function(path)
            local attr, lerr = real_lstat(path)
            if path == other_base and attr then
                local copy = {}
                for k, v in pairs(attr) do
                    copy[k] = v
                end
                copy.dev = (attr.dev or 0) + 1000
                return copy
            end
            return attr, lerr
        end,
    })
    local other_plan, other_err, other_class = api.plan(config_for(other_index, { other_dest }, {
        source_map = { { alias = "/fvl", path = other_src .. "/fvl" } },
    }), other_fs)
    expect(other_plan == nil, "device returned a plan")
    expect(other_class == "plan", "device class " .. tostring(other_class))
    expect(other_err == "previous snapshot is on another device: " .. other_base,
        "device err " .. tostring(other_err))

    -- a desired path under a foreign-device directory
    local mount = case_dir("mount")
    local mount_src = mount .. "/src"
    local mount_dest = mount .. "/dest"
    write_file(mount_src .. "/fvl/mnt/file", "inside\n")
    place_copy(mount_src .. "/fvl", mount_dest .. "/_Base/fvl")
    local mount_index = write_listing(mount, {
        { abs = mount_src .. "/fvl", listing = "/fvl" },
        { abs = mount_src .. "/fvl/mnt", listing = "/fvl/mnt" },
        { abs = mount_src .. "/fvl/mnt/file", listing = "/fvl/mnt/file" },
    })
    local mount_point = mount_dest .. "/_Base/fvl/mnt"
    local mount_fs = user_fs({
        lstat = function(path)
            local attr, lerr = real_lstat(path)
            if path == mount_point and attr then
                local copy = {}
                for k, v in pairs(attr) do
                    copy[k] = v
                end
                copy.dev = (attr.dev or 0) + 1000
                return copy
            end
            return attr, lerr
        end,
        dir = function(path)
            if path == mount_point then
                return nil, "descended into the mount"
            end
            return real_dir(path)
        end,
    })
    local mount_plan, mount_err, mount_class = api.plan(config_for(mount_index, { mount_dest }, {
        source_map = { { alias = "/fvl", path = mount_src .. "/fvl" } },
    }), mount_fs)
    expect(mount_plan == nil, "mount returned a plan")
    expect(mount_class == "plan", "mount class " .. tostring(mount_class) .. " " .. tostring(mount_err))
    expect(mount_err == "path is on another device: /fvl/mnt/file",
        "mount err " .. tostring(mount_err))

    -- A symlink at a parent that is not a listing record blocks the ancestor.
    local above = case_dir("ancestor-above")
    local above_src = above .. "/src"
    local above_dest = above .. "/dest"
    write_file(above_src .. "/fvl/a/readme", "hello\n")
    mkdir_p(above_dest .. "/_Base")
    sh("ln -s elsewhere " .. sh_quote(above_dest .. "/_Base/fvl"))
    local above_index = write_listing(above, {
        { abs = above_src .. "/fvl/a", listing = "/fvl/a" },
        { abs = above_src .. "/fvl/a/readme", listing = "/fvl/a/readme" },
    })
    refuse(config_for(above_index, { above_dest }, {
        source_map = { { alias = "/fvl", path = above_src .. "/fvl" } },
    }), user_fs(),
        "ancestor is not a directory: " .. above_dest .. "/_Base/fvl", "plan")

    -- exclude that removes every record
    local cover = case_dir("cover")
    local cover_src = cover .. "/src"
    local cover_dest = cover .. "/dest"
    mkdir_p(cover_dest)
    write_file(cover_src .. "/fvl/readme", "hello\n")
    local cover_index = write_listing(cover, {
        { abs = cover_src .. "/fvl", listing = "/fvl" },
        { abs = cover_src .. "/fvl/readme", listing = "/fvl/readme" },
    })
    refuse(config_for(cover_index, { cover_dest }, {
        source_map = { { alias = "/fvl", path = cover_src .. "/fvl" } },
        exclude = { "/fvl" },
    }), user_fs(), "exclude covers the listing", "plan")

    -- euid 0 compares owner. A different id is a copy. The same id hardlinks.
    -- A non-root euid hardlinks without comparing owner.
    local owned = case_dir("owner")
    local owned_src = owned .. "/src"
    local owned_dest = owned .. "/dest"
    write_file(owned_src .. "/fvl/readme", "hello\n")
    sh("chmod 644 " .. sh_quote(owned_src .. "/fvl/readme"))
    place_copy(owned_src .. "/fvl", owned_dest .. "/_Base/fvl")
    local owned_attr = lfs.symlinkattributes(owned_src .. "/fvl/readme")
    local owned_uid = math.tointeger(owned_attr.uid)
    local owned_gid = math.tointeger(owned_attr.gid)
    local function owned_listing(name, user, group)
        local dir_attr = lfs.symlinkattributes(owned_src .. "/fvl")
        local file_attr = lfs.symlinkattributes(owned_src .. "/fvl/readme")
        local function one(attr, listing, kind)
            local rec = {
                path = listing,
                kind = kind,
                size = math.tointeger(attr.size),
                mtime = attr.modification,
                user = user,
                group = group,
                permissions = attr.permissions,
            }
            return assert(index.format_line(rec))
        end
        local path = owned .. "/" .. name
        local f = assert(io.open(path, "wb"))
        f:write(one(dir_attr, "/fvl", "dir") .. "\n")
        f:write(one(file_attr, "/fvl/readme", "file") .. "\n")
        f:close()
        return path
    end
    local function owned_getent(database)
        if database == "passwd" then
            return "owner:x:" .. owned_uid .. ":" .. owned_gid .. ":\n"
        end
        if database == "group" then
            return "owner:x:" .. owned_gid .. ":\n"
        end
        return nil, "cannot read " .. database .. " names"
    end
    local match_index = owned_listing("index-20261008-1430.listing", "owner", "owner")
    local match_plan, match_err = api.plan(config_for(match_index, { owned_dest }, {
        source_map = { { alias = "/fvl", path = owned_src .. "/fvl" } },
    }), user_fs({ euid = 0, getent = owned_getent }))
    expect(match_plan ~= nil, "owner match plan " .. tostring(match_err))
    if match_plan then
        expect(warning_count(match_plan, "casually_backup: owner not applied") == 0, "root warned")
        expect(find_listing(match_plan.destinations[1], "hardlink", "/fvl/readme") ~= nil,
            "owner match hardlink")
        expect(match_plan.counts.read == 0, "owner match read")
    end

    local other_id = owned_uid == 2 and 3 or 2
    local mismatch_index = owned_listing(
        "index-20261008-1500.listing", tostring(other_id), tostring(other_id))
    local mismatch_plan, mismatch_err = api.plan(config_for(mismatch_index, { owned_dest }, {
        source_map = { { alias = "/fvl", path = owned_src .. "/fvl" } },
    }), user_fs({ euid = 0, getent = owned_getent }))
    expect(mismatch_plan ~= nil, "owner mismatch plan " .. tostring(mismatch_err))
    if mismatch_plan then
        expect(find_listing(mismatch_plan.destinations[1], "copy", "/fvl/readme") ~= nil,
            "owner mismatch copy")
        expect(#mismatch_plan.destinations[1].actions.hardlink == 0, "owner mismatch hardlink")
    end

    local skipped_plan, skipped_err = api.plan(config_for(mismatch_index, { owned_dest }, {
        source_map = { { alias = "/fvl", path = owned_src .. "/fvl" } },
    }), user_fs({ euid = 1000, getent = function()
        return nil, "getent failed"
    end }))
    expect(skipped_plan ~= nil, "owner skip plan " .. tostring(skipped_err))
    if skipped_plan then
        expect(warning_count(skipped_plan, "casually_backup: owner not applied") == 1, "skip warning")
        expect(find_listing(skipped_plan.destinations[1], "hardlink", "/fvl/readme") ~= nil,
            "owner skip hardlink")
    end

    local unknown_plan, unknown_err, unknown_class = api.plan(
        config_for(owned_listing("index-20261008-1600.listing", "nosuch", "owner"), { owned_dest }, {
            source_map = { { alias = "/fvl", path = owned_src .. "/fvl" } },
        }), user_fs({ euid = 0, getent = owned_getent }))
    expect(unknown_plan == nil, "unknown user returned a plan")
    expect(unknown_class == "scan", "unknown user class " .. tostring(unknown_class))
    expect(unknown_err == "unknown user nosuch", "unknown user err " .. tostring(unknown_err))

    local broken_plan, broken_err, broken_class = api.plan(config_for(match_index, { owned_dest }, {
        source_map = { { alias = "/fvl", path = owned_src .. "/fvl" } },
    }), user_fs({ euid = 0, getent = function()
        return nil, "getent failed"
    end }))
    expect(broken_plan == nil, "getent failure returned a plan")
    expect(broken_class == "scan", "getent class " .. tostring(broken_class))
    expect(broken_err == "getent failed", "getent err " .. tostring(broken_err))

    -- the blocked listing above is unused on purpose: /fvl as a record is a mkdir
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
local phase_cmd = sh_quote(root .. "/test/run.sh") .. " backup 3 > "
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
if pcode ~= 0 or phase_text:find("backup phase 3 gate passed", 1, true) == nil then
    io.stderr:write("backup phase 3 did not pass, exit " .. tostring(pcode) .. "\n")
    io.stderr:write(phase_err_text)
    io.stderr:write(phase_text)
    os.exit(1)
end

io.stdout:write("backup phase 4 gate passed\n")
