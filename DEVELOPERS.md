# Developer Notes

This document explains the Lua code in `casually_backup.lua` and `casually_index.lua`, the testing approach, notable issues that have come up, and guidance for developers who are not Lua experts.

## Overview

`casually_index.lua` and `casually_backup.lua` are standalone Lua 5.5 programs. The indexer walks directory trees and writes a flat, sorted listing file. The backup runner reads that listing and creates one snapshot directory per destination, hardlinking unchanged files to the previous snapshot and copying changed ones. They share the same LuaRocks dependencies and nearly the same boilerplate shape.

## Dependencies and toolchain

Both scripts require:

- **Lua 5.5** (the version check at line 9 of each script prints `casually_backup: need Lua 5.5` or `casually_index: need Lua 5.5` and exits 1 if `_VERSION` does not match).
- `lua-filesystem` (loaded as `lfs`) — directory iteration, `symlinkattributes`, `link`, `touch`.
- `dkjson` — JSON encoding/decoding for config files.
- `terminal` — terminal control for the progress screen (backup phase 6).
- `lua-system` — used as `system` in tests for `monotime` and `isatty`; the backup script uses it for the screen and process timing.

Lua paths are prepended before `require` so that the scripts find `/usr/local/share/lua/5.5/` and `$HOME/.luarocks/share/lua/5.5/`. This is done in a `do` block early in each file (lines 24-41) that builds `path` and `cpath` arrays and joins them with semicolons. The `prepend` function (lines 14-22) puts the project paths ahead of the defaults so the right library versions load even if the caller's environment has different `LUA_PATH`/`LUA_CPATH`.

Tests run with `env -u LUA_PATH -u LUA_CPATH -u LUA_INIT lua` to ensure the scripts' own path setup is exercised, not a leftover environment.

## Shared module pattern

Both scripts follow the same structure:

1. **Shebang** (line 1): `#!/usr/bin/env lua`, and the file is executable.
2. **Version check**: `if _VERSION ~= "Lua 5.5" then ... os.exit(1) end`
3. **Path setup**: the `prepend` + `do` block that configures `package.path` and `package.cpath`.
4. **Load libraries**: `load_library("lfs")`, `load_library("dkjson")`, `load_library("terminal")` — each uses `pcall(require, ...)` so a failure exits 1 with a clear message rather than throwing.
5. **Export table `M`**: functions are added as `M.something = function(...)` or `function M.something(...)` so tests can `dofile` the file and call them directly.
6. **`invoked_as_script` guard** (lines 4446-4456 of backup, 1724-1732 of index): checks whether `arg[0]` matches the script name. If so, calls `M.main(arg)` and `os.exit(code)`. Otherwise just `return M`. This is what lets a test do `local api = dofile(exe)` and then call `api.plan(...)` without triggering `main`.

Key exported functions:

| Backup (`casually_backup.lua`) | Index (`casually_index.lua`) |
|---|---|
| `M.parse_args(argv)` | `M.parse_args(argv)` |
| `M.load_config(cmd, fs)` | `M.load_config(cmd, fs)` |
| `M.parse_listing(text)` (line 1193) | `M.format_line(record)` (line 674) |
| `M.plan(config, fs, screen)` (line 2482) | `M.walk(config, fs, progress)` (line 932) |
| `M.apply(config, fs, plan, screen)` (line 3588) | `M.publish(records, config, stamp, seam, progress)` (line 1162) |
| `M.perform(config, opts, fs, out, err_out, screen)` (line 4300) | `M.run(config, fs, clock, seam, progress)` (line 1286) |
| `M.main(argv)` | `M.main(argv)` |
| `M.copy_worker()` (line 3228) | |
| `M.format_elapsed`, `M.format_bytes`, `M.middle_clip` | |

The `fs` parameter in plan/apply/run functions is a filesystem abstraction table. In production it wraps real `lfs` and `io.open` calls. In tests, it is a seam that can stub `lstat`, `dir`, `open_source`, `open_dest`, `chmod`, `chown`, `getent`, and `pid` to simulate permission errors, device mismatches, dead pids, and short reads.

## Listing line format

The listing is plain text, one record per line, tab-separated:

```
{mtime}\t{user}:{group}\t{mode}\t{size}\t{link}\t{path}
```

- **mtime** — `YYYYMMDD:HHMMSS` in UTC (15 chars, second resolution).
- **user:group** — resolved names from `getent passwd`/`getent group`, or decimal ids if unresolved or if the name contains a colon, tab, or space.
- **mode** — 10 characters: type char (`-` file, `d` dir, `l` link) + 9 permission characters. Setuid/setgid/sticky bits appear as `s`/`S`/`t`/`T` overlays.
- **size** — byte count for regular files. For symlinks, the byte length of the target string.
- **link** — symlink target, or `-` for non-links. A target of exactly `-` is written as `\-` to disambiguate.
- **path** — the alias-remapped absolute path.

If the path or target contains tab, backslash, newline, carriage return, or a leading space, the line is prefixed with `!` and both path and target are backslash-escaped. The `!` prefix is a flag, not a field — the line is still one record. See `KIND_CHAR` (line 568 of index) and `SPECIAL_BYTE` (line 574) for the character tables, and `escape_field` (line 590) for the escaping logic.

`M.format_line(record)` (line 674 of `casually_index.lua`) builds one line from a record table. It validates each field and returns `nil, err` on a problem. The backup side has a parallel parser, `M.parse_listing(text)` (line 1193 of `casually_backup.lua`), that reads the lines back into records.

## Backup pipeline: plan, apply, perform

`M.perform` (line 4300) is the top-level orchestrator. It:

1. Calls `M.plan` to build a snapshot plan.
2. If `--dry-run`, prints the plan text and returns 0.
3. Calls `M.apply` to execute the plan (copy, hardlink, symlink, mkdir, chmod/chown, rename).
4. On success, writes the report summary if `--report` was given.

### `M.plan` (line 2482)

For each destination, determines the snapshot name (`_Base` if none exists, or the stamp from the listing name) and classifies each listing entry against the previous snapshot:

- **copy** — new file, or a file whose kind, size, mtime, or mode differs (or owner differs when chown is active).
- **hardlink** — file matches the previous snapshot on all those fields; a hard link is created to the previous inode instead of copying.
- **symlink** — symlink target differs from the previous snapshot.
- **mkdir** — new or renamed directory.
- **omit** — a path in the previous snapshot but not in the listing, under the omit threshold.

It refuses the whole run (before any snapshot is written) if:

- Too many omissions (over `omit_limit` and `omit_fraction`).
- The previous snapshot is on a different filesystem device.
- `_Base` is unreadable or not a directory.
- The source and destination paths nest (destination inside source).
- The stamp directory already exists.

The plan is serialized as human-readable text and stored in `plan.text` for dry-run output.

### `M.apply` (line 3588)

1. Acquires a per-destination lock (directory `.casually_backup.lock`), clearing stale locks whose pid is dead.
2. Removes leftover `.partial` directories.
3. Copies each file that needs a new inode — one source read feeds every destination that needs a copy.
4. Hardlinks unchanged files to the previous snapshot within the same destination.
5. Creates directories, symlinks, applies `chmod` and `chown` via batched `xargs -0` calls.
6. Renames the partial directory to `_Base` or the stamp via `os.rename` (atomic on the same filesystem).

If any step fails, the locks are released and the partial is left in place (the rename does not happen). The previous snapshots are untouched.

### Worker pool for concurrent copies

When running headless (stdout is not a tty, or `--dry-run`), file copies are parallelized across `workers` processes (default 4, max 64). Each worker is a forked `lua casually_backup.lua --copy-worker` process (see `M.copy_worker` at line 3228). The parent sends copy jobs over a pipe using a length-prefixed frame protocol (`write_frame`/`read_frame`), and each worker replies with `ok`, `skip <reason>`, or `fail <reason>`.

When `workers` is 1, or when stdout is a terminal, copies stay in the parent process so the progress screen can render during the read.

## Index walk and publish

`M.walk` (line 932 of `casually_index.lua`) traverses each root depth-first. It uses `lfs.symlinkattributes` (never `stat` — follows the symlink rule). It records the filesystem device of the root and refuses to descend into a different device (mount point), noting the mount as a directory record. Inode identity is tracked with `inode_key` (line 776), which combines `dev` and `ino` as `dev:ino` to avoid false matches across devices.

`M.publish` (line 1162) sorts the records by remapped path (byte order, like `LC_ALL=C`), rejects duplicates, writes to a `.partial` file, flushes, closes, and renames into `output_dir`. The listing name is `index-YYYYMMDD-HHMM.listing` derived from the walk start time in UTC.

## Progress screen (backup phase 6 only)

The screen is painted through the `terminal` library. It runs only when stdout is a terminal and the run is not a dry-run. `terminal.initwrap` sets up the alternate screen and raw mode. `q` aborts the run with exit 2 and `casually_backup: aborted`, leaving no snapshot behind.

The screen shows: a rounded border, the title `casually_backup`, an activity spinner during the scan, and a progress bar with elapsed time and copy rate during the apply phase. Warnings are held until the terminal is restored, then printed on stderr.

## Testing approach

Tests live in `test/`. Index gates are `test/phaseN.lua` (phases 1-7). Backup gates are `test/backup_phaseN.lua` (phases 1-7).

`test/run.sh` dispatches:

- `test/run.sh` or `test/run.sh N` — runs `test/phaseN.lua`.
- `test/run.sh backup` — runs all `test/backup_phase*.lua`.
- `test/run.sh backup N` — runs one backup gate.

Each backup phase gate re-runs earlier backup gates (phase 5 runs phase 4, etc.) to ensure no regressions. Phase 4 onward can be run individually.

Tests `dofile` the script and call exported functions directly — they never spawn the script as a subprocess (except phase 6 which runs the CLI under a pty, and phase 7 which runs the real entry point). The `fs` seam lets tests inject fake filesystems, fake `getent` output, dead pids, and short reads.

### Test phase breakdown

**Index:**

| Phase | Tests |
|---|---|
| 1 | `--version`, `--help`, no C file, shebang, basic `parse_args` |
| 2 | Config load, all rejection rules, path normalization |
| 3 | `format_line` output, escaping, bang lines, mode bits, owner name resolution |
| 4 | Walk: symlinks, devices, excludes, ancestor records, duplicate paths |
| 5 | Publish: sort, clobber check, crash seam, same-directory work/output |
| 6 | Progress screen under a pty: title, spinner, rate, `q` abort |
| 7 | Acceptance: full walk and publish of a fixture tree |

**Backup:**

| Phase | Tests |
|---|---|
| 1 | Arguments, library loading |
| 2 | Config load, all rejection rules |
| 3 | `parse_listing`, stamp extraction, mtime round-trip |
| 4 | `plan`: hardlink/copy/mkdir decisions, omissions, device check, nesting |
| 5 | `apply`: copy, hardlink chain, workers, dry-run, lock handling, mode changes, short/long source |
| 6 | Terminal screen, `q` abort, progress rendering |
| 7 | End-to-end CLI acceptance: `_Base`, dated snapshots, hardlinks, excludes, CLI flags |

## Notable issue: the `dir.c/dir.c` bug

A directory whose basename matches the file inside it (e.g., `fvl/scripts/dir.c/dir.c`) confused the source-file checker in `check_source_file` (lines 2918-2950 of `casually_backup.lua`).

### The bug

`check_source_file` walks a path component by component, `lstat`-ing each prefix, to verify the source is a real file and not a symlink or directory. It used `path:match("([^/]+)$")` to extract the final component and then compared each iterated part against that final string to decide whether to treat it as the leaf (must be a file) or an intermediate (must be a directory):

```lua
local final = path:match("([^/]+)$")
for part in path:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    if part ~= final and cache and cache[acc] then
        -- lstat'd this directory already
    else
        local attr = lfs.symlinkattributes(acc)
        ...
        if part == final then
            -- this should be a regular file
        end
    end
end
```

When a directory and its contained file share the same basename (like `dir.c/dir.c`), `part ~= final` is `false` for the directory component, so the checker skipped the directory check and treated the directory as if it were the file. This caused the worker to try reading a directory as a file, or to skip the directory entirely and fail on the inner file.

### The fix (commit `d561bf1`)

Replace the name-based comparison with a position-based one. Instead of extracting `final` and comparing names, track the component index and compare against the total count:

```lua
local parts = {}
for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
end
local n = #parts
for i = 1, n do
    local part = parts[i]
    acc = acc .. "/" .. part
    if i < n and cache and cache[acc] then
        -- lstat'd this directory already
    else
        local attr = lfs.symlinkattributes(acc)
        ...
        if i == n then
            -- this should be a regular file
        end
    end
end
```

The test case in `test/backup_phase5.lua` (line 1386) creates `dir.c/dir.c` with content `content\n` and verifies the inner file is copied correctly and the directory keeps its mode. The lesson: **never compare path component names when position is what you actually mean.**

## Running tests

From the repo root:

```bash
# Run all index gates
test/run.sh

# Run all backup gates
test/run.sh backup

# Run a single gate
test/run.sh backup 4
```

A passing gate prints `backup phase N gate passed` or `phase N gate passed`.

## Lua idioms used in this codebase

- **No semicolons or `then` placement tricks.** Standard `if x then` on one line is fine; the style uses lowercase `true`/`false` and explicit `nil` for absence.
- **`pcall` for fallible calls.** Filesystem and shell operations are wrapped in `pcall` and return `nil, err, class` so the caller can map the class to an exit code.
- **String building with `table.concat`.** Repeated `..` concatenation works but `table.concat` is used for lists.
- **NUL-delimited stdin for shell commands.** `chmod` and `chown` batches use `xargs -0` so paths with spaces or newlines are safe. Paths never enter the shell unquoted — `sh_quote` (in tests) and `one_line` (in scripts) handle escaping for stderr output.
- **LuaFileSystem `symlinkattributes` vs `attributes`.** Always `symlinkattributes` — it returns link metadata, not the target's. This is the symlink rule.
- **`math.tointeger`** is used before arithmetic on `lfs` attributes, because `attr.dev` and `attr.ino` are integers but `attr.size` can be a string on some platforms.

## File layout reference

```
casually_backup.lua            the backup runner (single file, ~4500 lines)
casually_index.lua             the indexer (single file, ~1736 lines)
INDEX_SPEC.md                  index listing format spec
INDEX_PLAN.md                  index implementation plan and log
BACKUP_PLAN.md                 backup implementation plan and log
INSTRUCTIONS-INDEX.md          index usage guide
INSTRUCTIONS-BACKUP.md         backup usage guide
test/run.sh                    test runner
test/phaseN.lua                index gate N
test/backup_phaseN.lua         backup gate N
```
