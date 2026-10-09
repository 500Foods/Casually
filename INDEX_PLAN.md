# casually_index implementation plan

Living plan for [INDEX_SPEC.md](INDEX_SPEC.md). Phases 1 through 7 are done. Each phase finished when its gate passed. Anything the backup runner still needs is a different spec.

## Phase status

| Phase | What it delivers | Difficulty | Status |
| --- | --- | --- | --- |
| 1 | Toolchain and `casually_index.lua` arguments | easy | done |
| 2 | Config load and every rejection rule | medium | done |
| 3 | Listing line formatter | medium | done |
| 4 | Walk, remap, exclude, names | hard | done |
| 5 | Sort, partial file, rename | medium | done |
| 6 | Progress panel on a terminal | medium | done |
| 7 | Spec acceptance run | medium | done |

Difficulty is a rough size, not a schedule. Easy is an afternoon of wiring. Medium is a day of edge cases. Hard is the walk and the ways it must fail closed.

Status values: `not started`, `in progress`, `blocked`, `done`.

## Work completed

Append a row when a gate passes. Keep the row specific enough that a later session can see what exists.

| Date | Phase | Completed |
| --- | --- | --- |
| 2026-10-08 | 1 | Executable `casually_index.lua` parses the four command forms. It loads `lfs` 1.9.0, `dkjson` 2.5, and `terminal` 0.1.0. `test/run.sh 1` passes. |
| 2026-10-08 | 2 | `load_config` checks a JSON file or a `--source`/`--index` pair. Rejections are class `config`: exit 1, one stderr line, and no file left under `work_dir`. `test/run.sh 2` passes. `test/run.sh 1` still passes. |
| 2026-10-08 | 3 | `format_line` writes one listing line with no trailing newline: ten-character mode, UTC mtime, owner fallback, and bang escapes. `test/run.sh 3` passes. `test/run.sh 1` and `test/run.sh 2` still pass. |
| 2026-10-08 | 4 | `walk` returns records and skip warnings. It remaps, excludes before descend, resolves names with one `getent passwd` and one `getent group`, and closes each directory before visiting its names. `main` does not walk or publish yet. `test/run.sh 4` passes. `test/run.sh 1`, `2`, and `3` still pass. |
| 2026-10-08 | 5 | `publish` sorts by the raw remapped path, writes `<listing-name>.<pid>.partial` in `work_dir`, and renames it onto the stamped name or the `--index` path. `main` refuses an existing listing before the walk, prints skip warnings, and does not print the path. `test/run.sh 5` passes. `test/run.sh 1`, `2`, `3`, and `4` still pass. |
| 2026-10-08 | 6 | The progress panel runs only when stdout is a terminal: one red border, title ` casually_index `, an activity strip during the walk, and a determinate bar with a percent during sort and publish. `test/run.sh 6` passes. A pty stand-in, not a person, sent `q` after the file count had moved and the path had changed: exit 2, stderr `casually_index: aborted`, no listing, no partial, and the fifo warning stayed off the screen. The finish run exited 0, published the listing, showed `100%`, and wrote the fifo warning only on stderr after the terminal was restored. The headless CLI tree matches the phase 4 shape with data alias `/data`, because alias `/` overlaps every other absolute alias. `test/run.sh 1`, `2`, `3`, `4`, and `5` still pass. |
| 2026-10-08 | 7 | `test/phase7.lua` is the spec acceptance run. The `--config` golden is built at runtime for the user running the test: two roots, an exclude, a symlink, a dangling symlink, a dotfile, a fifo warning, an empty root as one directory line, a tab name that round-trips on a bang line and sorts ahead of a backslash name, and a raw `0xFF` byte. Stdout is empty, the partial is gone, and a second run in the same minute exits 3 with the listing unchanged. `--source`/`--index` writes the real paths. Bad arguments and rejected configs exit 1 with one stderr line. An unreadable directory exits 2 and leaves no listing. A duplicate remapped path is class `walk` through `M.run`, because a loaded config cannot overlap aliases, and it leaves no partial. A pre-existing stamped name and a pre-existing `--index` file exit 3 without walking. Work and output on `/tmp` and `/mnt/extra` exit 1. An lstat uid missing from the getent cache is written as a decimal. `test/run.sh` 1 through 6 still pass. The phase 6 pty remains the terminal check. |

## Lessons learned

Append a row when a gate fails, a dependency misbehaves, or a decision in this plan turns out to be wrong. Correct the plan in the same edit. Leave the lesson in place.

| Date | Phase | Lesson |
| --- | --- | --- |
| 2026-10-08 | 1 | `/usr/bin/luarocks` 3.9.2 cannot install a Lua 5.5 rock. It looks for a literal `LUA_VERSION_NUM 505` in `lua.h`, and Lua 5.5.1 computes that macro. `lfs.so` 1.9.0 was compiled into `~/.luarocks/lib/lua/5.5/` and `dkjson` 2.5 was copied to `~/.luarocks/share/lua/5.5/`. The script's path prepend finds both. Neither file lives in this repo. |
| 2026-10-08 | 1 | This Lua 5.5.1 rejects `io.open` modes that contain `x`, so the script cannot create a file with `O_EXCL`. It also rejects `0o` octal literals. Modes use `tonumber(text, 8)` or hex masks. |
| 2026-10-08 | 4 | `lfs.dir` raises `cannot open PATH: Permission denied` instead of returning nil and an error. The walk `pcall`s it. A chmod `000` directory is class `walk`. An excluded path is not stated and not opened, so an unreadable directory under an exclude is not that error. |
| 2026-10-08 | 5 | `os.rename` on Linux replaces an existing file, and `file:flush` only empties the Lua buffer. Clobber protection is the existence check before the walk and again before the rename. A name created in that gap can still be replaced, and a power loss can still drop a flushed listing. Both are accepted. There is no fsync and no C helper. |
| 2026-10-08 | 6 | Alias `/` is a prefix of every other absolute path, so a loaded config cannot pair it with another alias. The phase 4 gate calls `M.walk` directly and can use that alias. The phase 6 headless command uses data alias `/data`. A helper named `pty.py` shadows Python's `pty` module; the stand-in is `panel_pty.py`. |
| 2026-10-08 | 6 | Schemahelper's eighths bar is one cell per eight records. A few thousand records overflow an 80-column row, so the percent was never painted. `progress_eighths` still returns the full cell list. The painter reserves columns for the percent and draws only the cells that fit. `readansi(0)` returned promptly in the pty, so the poll stayed at timeout 0. |

## How a phase moves

1. Set that phase to `in progress` before editing code for it.
2. Build only what the phase lists. Leave later behavior unstubbed rather than half-implemented.
3. Run the gate. Fix the phase until the gate passes.
4. Set the phase to `done`, append the work log, and append any lesson.
5. Stop. The following phase starts in a later session, after this plan still matches what was learned.

A blocked phase stays `blocked` with a lesson that says what is missing. No skipping ahead.

## What this program is

`casually_index.lua` writes one sorted listing of one or more directory trees. Real prefixes are rewritten to aliases. The listing is names and metadata. A backup runner, which this plan does not build, consumes the finished file.

The spec's "only argument is a JSON path" is replaced by the command line below. A bare path is a usage error.

The design point from the repo readme is a remote tree of hundreds of thousands of files, indexed where the files live, then copied as a single file. Records stay in a Lua array for the duration of the run. That is about a hundred megabytes at a few hundred bytes a record. A larger tree becomes a lesson and a plan change, not an external-sort design in these phases.

Language is Lua 5.5. The interpreter on this machine today is Lua 5.5.1 at `/usr/local/bin/lua`. One process. `readdir` and `lstat` go through LuaFileSystem. No per-file fork.

## Command line

The program is `casually_index.lua`. Line 1 is the shebang `#!/usr/bin/env lua`, and the file is executable, so the kernel starts it:

```text
./casually_index.lua --config <file>
./casually_index.lua --source <root> --index <file>
./casually_index.lua --help
./casually_index.lua --version
```

`env` finds `lua` on `PATH`. On this machine that is Lua 5.5.1 at `/usr/local/bin/lua`. Lua skips a first line that starts with `#!`, so the rest of the file is ordinary Lua. Flag order does not matter. Each flag that takes a value consumes the next argument, and that value must be present and must not itself start with `-`.

`--config <file>` loads the JSON config from the spec: `roots`, `work_dir`, `output_dir`, and optional `exclude`. The finished listing is `index-YYYYMMDD-HHMM.listing` in `output_dir`, UTC, from the moment the walk starts.

`--source <root> --index <file>` is the one-root form. It builds the same internal config the JSON loader returns.

- `--source` is the real directory to walk. It follows every `path` rule in phase 2, including absolute, no `.` or `..`, not `/`, and a real directory.
- The alias is the normalized source path. Paths in the listing are the real paths. There is no `--alias` flag.
- `--index` is the finished listing file, not a directory. It must be absolute, with no `.` or `..` component. Its parent must already exist, must be a real directory, and must not sit inside the source. The program does not create the parent. If `--index` is an existing directory, that is a usage error.
- Exclude is empty.
- `work_dir` and `output_dir` are both the parent of `--index`. The partial file is `<index-path>.<pid>.partial`.
- If that listing file already exists, the run exits 3 and leaves it unchanged. This form does not invent a minute-stamped name.

`--help` prints those four `./casually_index.lua` forms and a one-line description of each flag to stdout, then exits 0. It does not read a config and does not create a file.

`--version` prints three lines to stdout and exits 0, before any terminal setup: `casually_index <version>`, `Lua <version>`, `terminal.lua <version>`. The script version starts at `0.1.0`.

Anything else is a usage error. Exit 1, one stderr line, stdout empty, no file created. The line names the problem:

| Arguments | stderr |
| --- | --- |
| none | `casually_index: missing arguments` |
| unknown flag, or a value that was parsed as a flag | `casually_index: unknown argument: <token>` |
| a bare word, including a bare config path | `casually_index: unexpected argument: <token>` |
| the same flag twice | `casually_index: repeated argument: <flag>` |
| `--help` or `--version` with anything else | `casually_index: <flag> does not take other arguments` |
| `--config` together with `--source` or `--index` | `casually_index: use either --config or --source with --index` |
| `--config` with no file | `casually_index: --config requires a file` |
| `--source` without `--index` | `casually_index: --source requires --index` |
| `--index` without `--source` | `casually_index: --index requires --source` |
| `--source` or `--index` with no value | `casually_index: <flag> requires a value` |

A missing file, a relative path, or a path that fails the phase 2 checks is also exit 1. Those messages name the path rule. They are config errors, reported by the loader, with the same `casually_index:` prefix.

## Layout

The program we write is one file, `casually_index.lua`. It `require`s libraries that are already installed for Lua 5.5: `lfs` (directory walk), `dkjson` (the config file), and `terminal` (the progress panel). Those are not source files in this repo. There is no C file in this repo.

```text
casually_index.lua        the whole program. Line 1 is #!/usr/bin/env lua
test/phaseN.lua           gate for phase N. dofile's the script and calls its functions
test/run.sh               runs one phase gate or all gates that exist
```

The script returns a table of its functions and runs `main` only when `arg[0]` names `casually_index.lua`. A test `dofile`s it and calls those functions, so the gates do not need a second copy of the logic.

Functions return data or `nil, err, class` where class is `config`, `walk`, or `publish`. Usage failures are class `config`. `main` maps those to exit codes 1, 2, and 3. It writes the single failure line. Skip warnings are the other stderr.

## Settled decisions

These are part of the plan. They replace the matching sentences in the spec.

**Bang glued to the mtime.** The spec's example is `!20261008:090001` followed by a tab. The `!` is a prefix on the first field. There is no extra tab between `!` and the mtime. The sentence "bang, then the tab that starts the first field" is read as wording around that example, and the example wins.

**Symlink target that is exactly `-`.** The link field of a non-symlink is `-`. A symlink must keep a link field that is not a bare `-`.

- The bang flag is decided from the raw path and the raw target. The four special bytes are `\`, tab, newline, and carriage return. A target of `-` does not by itself raise the flag.
- When the target is exactly `-`, the written link field is the two characters `\` and `-`, and that inserted backslash is not passed through the escape table again.
- On any other symlink, a bang line runs the four escapes on both the path and the target. A normal line writes both raw.
- A raw target whose bytes are `\` then `-` takes the bang path and is written `\\-`. After unescaping, those two bytes are the target. The written field `\-` (one backslash) is reserved for the target that is exactly `-`.

**No C of our own.** The script does not `fsync`. `file:flush()` and `file:close()` run before `os.rename`, which pushes the Lua buffer out, and a power loss can still drop the listing. That is accepted. The clobber check is an existence test, not a special rename. See Robustness.

**Names.** LuaFileSystem returns numeric uid and gid. Once per run, before the walk, the process runs `getent passwd` and `getent group` and caches them. That is two processes, not one per file. A uid or gid missing from the cache is written as a decimal. A name that contains a colon, a tab, or a space is dropped and the decimal is written for that side. The other side keeps its name. `getent` uses the same name service the machine uses. `/etc/passwd` alone would miss that service.

**Root must be a real directory.** `lstat` on each `path` must be a directory. A symlink, including a symlink to a directory, is a config error. The walk then never follows a link to enter its tree.

**Stdout.** The listing never goes to stdout. With a terminal on stdout, phase 6 paints the progress panel there and restores the previous screen on the way out. Warnings and the one failure line go to stderr after the terminal is restored. With stdout not a terminal, there is no panel. `M.walk` does not print. `main` writes each skip warning after the run returns, and then the failure line if there is one. `--help` and `--version` are the stdout exceptions, and both exit 0 before any walk.

**Prefix means a path prefix.** Equality, root overlap, alias overlap, exclude, and "directory sits inside a root" all use the same rule. Strip every trailing slash, leaving `/` as `/`, then a prefix matches only at a boundary. `/mnt/ceph-a` matches `/mnt/ceph-a` and `/mnt/ceph-a/docs`. It does not match `/mnt/ceph-ab`. `/` is a prefix of every other absolute path. The same rule makes `/fvl/a/.snap` skip that directory and leave `/fvl/a/.snapshot` in the listing.

**In-memory sort.** The sort key is the raw remapped path, compared with Lua `<`, which is byte order, the same order as `LC_ALL=C`. The path is the last field, names may contain newlines, and bang lines change bytes, so sorting the finished text with `sort(1)` is the wrong tool. `table.sort` the record array, then write.

**Rename is the only publish.** There is no copy fallback. `work_dir` and `output_dir` must be on the same device; a mismatch is exit 1 before the walk, so `os.rename` is not asked to cross filesystems. The publish step is `flush`, `close`, then `os.rename`.

**Excluded directories are not opened.** A prefix match skips that directory, writes no record for it, and does not descend. An unreadable directory under an exclude is not a walk error.

**Mount points are recorded and not opened.** Each root remembers the `dev` from its own `lstat`. A directory whose `dev` differs is written as a directory and not descended. A symlink is always written as a symlink, including when its target is on another filesystem, because the walk never stats the target.

**Signals and the panel.** Schemahelper sets `disable_sigint` because it is an interactive tool and a raw terminal must be restored. The indexer copies that while the panel is up. `q` or Ctrl-C (`\3` from `readansi`) leaves `main`, `initwrap` restores the terminal, and the process exits 2 without renaming. Headless runs leave SIGINT alone.

**No indexer configuration from the environment.** `casually_index.lua` may read `HOME` only to prepend the Lua 5.5 rock paths before `require`. It does not read the environment for roots, aliases, or the output path. There is no shell wrapper in front of the script.

## Robustness

These rules are in force. They keep a finished listing from looking complete when it is wrong, and they keep a long walk from failing only at the last step.

**An exclude must not drop a whole root.** If an exclude equals an alias, or an exclude is a path-prefix of an alias, reject the config. That listing would tell the consumer the tree disappeared. An exclude under an alias, such as `/fvl/a/.snap`, still skips only that subtree. An exclude of `/` matches every alias and is rejected.

**Directory identity stops bind-mount loops.** The spec's `st_dev` check still records a foreign mount and does not descend. A bind mount of the same filesystem has the same device, so the walk also remembers `(dev, ino)` for every directory it has descended into, including the root. A later directory with a remembered pair is recorded and not descended. Hard-linked files are two names and both are kept. Only directories are tracked.

**One directory fd.** The walk reads all names from a directory, closes that directory, then visits the names. A deep tree holds one directory fd.

**Checks before the walk.** After the config is valid and the listing path is known:

- `work_dir` and `output_dir` are on the same device, and each is writable. A failure here is exit 1. The writability probe creates and removes `.casually_index.probe.<pid>` in that directory. One probe covers both when they are the same directory.
- The finished listing path does not already exist. A failure here is exit 3, and the walk does not start. This is the clobber check. There is no non-replacing rename syscall behind it.
- The same existence test runs again immediately before `os.rename`. If the name has appeared, exit 3, leave the partial, and do not rename. `os.rename` on Linux would otherwise replace the file. A name created in the gap between that test and the rename can still be replaced. That gap is accepted.

**Partial names are unique to the process.** The partial is `<listing-name>.<pid>.partial` in `work_dir`. For `--index`, that is `<output_path>.<pid>.partial`. Two runs do not share a temp file. A crash leaves that partial. The next run does not append to it and does not delete another process's partial. Consumers ignore names ending in `.partial`. The pid is the first field of `/proc/self/stat`. If that file cannot be read, the suffix is `os.time()` and `math.random`.

**The write either finishes or does not publish.** Sort, then refuse the run if two records have the same remapped path (exit 2, no partial). Write the partial from scratch, and treat a short write or a full disk as exit 3 with the partial left in place and no rename. Then `file:flush()`, `file:close()`, the existence test, and `os.rename`.

**Bytes in the listing stay raw.** A filename byte that is not UTF-8 is copied unchanged. The panel drops a tab to four spaces, removes ANSI CSI sequences, and drops every remaining byte below 32, including newline, plus DEL, so one row stays one row. Schemahelper's `display_text` keeps newline; this panel does not. Stderr stays one physical line by writing tab, newline, and carriage return inside a path as the two-character sequences `\t`, `\n`, and `\r`.

**Dangling symlinks are records. A failed `readlink` is a walk error.** `lstat` of a dangling symlink is `link`, and the stored target is the link text. If reading the target fails, the walk aborts and nothing is published.

**Alias `/` joins with one slash.** The root record is `/`. A child `docs` is `/docs`.

**Lua 5.5 is a hard check.** If `_VERSION` is not `Lua 5.5`, the script prints `casually_index: need Lua 5.5` and exits 1 before `require`.

## Shared behavior

Failure stderr is one line, `casually_index: <reason>`, and a non-zero exit. No stack trace on the console. Tab, newline, and carriage return inside a path are written as `\t`, `\n`, and `\r` so the line stays one physical line. Success writes nothing to stdout. Skip warnings, one per inode, are `casually_index: skipped <type> <remapped-path>`. The type is the LuaFileSystem mode string (`named pipe`, `socket`, `char device`, `block device`, `other`). Whiteouts arrive as one of those and use the same warning. `.` and `..` from `readdir` are ignored with no warning and no record.

Exit codes stay the spec's: 0 published, 1 config, 2 walk or an operator abort during the walk, 3 the output name exists or the rename failed.

The partial file is created only after the walk has returned every record and the duplicate-path check has passed. A walk error therefore leaves no new partial from this run. A crash during the write leaves `<listing-name>.<pid>.partial` and no new listing. The next run uses its own pid and appends nothing.

## Phase 1 — Toolchain and entry point

**Difficulty:** easy. **Depends on:** nothing.

Prove the runtime the later phases use, and land an executable `casually_index.lua` whose first line is `#!/usr/bin/env lua`. The gates call `./casually_index.lua`. The first check after the shebang is `_VERSION == "Lua 5.5"`; any other value prints `casually_index: need Lua 5.5` and exits 1 before `require`. Argument parsing is a function in that same file. Phase 1's `main` treated a well-formed `--config` or `--source`/`--index` command as empty success and did not open the file. Phase 2 replaced that path: `main` loads the config, and a missing file or a rejected path exits 1. Phase 1 does not walk, format, or publish.

Starting point on this machine, checked 2026-10-08:

- `lua -v` is Lua 5.5.1.
- `luarocks` is `/usr/bin/luarocks`.
- `terminal` 0.1.0 and `luasystem` 0.7.1 are installed for Lua 5.5 under `~/.luarocks`.
- Plain `lua` does not see them. `schemahelper.sh` runs `eval "$(luarocks --lua-version=5.5 path --bin)"` and then appends `/usr/local/share/lua/5.5` and `/usr/local/lib/lua/5.5`. `casually_index.lua` prepends those `/usr/local` locations and `$HOME/.luarocks/share/lua/5.5` plus `$HOME/.luarocks/lib/lua/5.5` and `lib64` before any `require`. The gate invokes the script with a clean `LUA_PATH` and `LUA_CPATH`.
- `luafilesystem` 1.9.0 for Lua 5.5 is `~/.luarocks/lib/lua/5.5/lfs.so`. The 5.4 system `lfs.so` stays unused. `/usr/bin/luarocks` 3.9.2 cannot build it; see the lesson log. A later install needs LuaRocks 3.13 or newer, which understands the Lua 5.5 header.
- `dkjson` 2.5, pure Lua, is `~/.luarocks/share/lua/5.5/dkjson.lua`. It is not vendored into this repo.

**Gate.** `test/run.sh 1` runs `./casually_index.lua` and checks that it sees Lua 5.5 and can `require` `lfs`, `terminal`, and `dkjson` with a clean module path. The repo contains no `.c` file. The file mode is executable and byte 1 of the file is the shebang. `--version` prints three lines and exits 0 with stdout a terminal and with stdout a pipe. `--help` prints the four `./casually_index.lua` forms and exits 0. Every row in the usage-error table exits 1 with that stderr line and empty stdout, including a bare JSON path. A well-formed `--config /any/path.json` is accepted by `parse_args`. The phase 1 gate does not run that command, because `main` now opens the file. A direct `dofile` from the test does not run `main`. Update the status table and the work log.

## Phase 2 — Config

**Difficulty:** medium. **Depends on:** phase 1.

The config function turns a parsed command into a checked config. `--config` reads that JSON file. `--source` with `--index` synthesizes one root, as the command-line section describes, and sets `output_path` to the `--index` file. Parse failures, permission errors, and every rejection below are class `config`. The stamped listing name is chosen later, at walk start, and only when `output_path` is absent.

Accept the spec's object and ignore unknown keys only after this plan is changed to say so. Until then, unknown keys are a config error, so a typo cannot silently drop a root.

Checks, in an order the failure line can name:

- The file parses as a JSON object.
- `roots` is a non-empty array. Each entry has string `path` and string `alias`.
- Normalize `path` and `alias` by removing every trailing slash when the value is longer than `/`. `///mnt/ceph-a///` becomes `/mnt/ceph-a`.
- Reject empty, relative, or a value whose components include `.` or `..`. `path` of `/` is rejected. `alias` of `/` is allowed. After normalization both are absolute.
- `path` must `lstat` as a real directory.
- `work_dir` and `output_dir` are present, `lstat` as real directories, and already exist. The program creates neither. Their `dev` values must match. Each must be writable by the probe file in the robustness section. Either directory may be `/`.
- Neither directory sits inside any root, by the path-prefix rule. The root sitting inside the work directory is allowed. The listing must stay out of the tree it describes.
- No two paths, and no two aliases, are equal or a path-prefix of each other.
- `exclude` omitted or empty means exclude nothing. Each entry is normalized like an alias and must be absolute, with no `.` or `..` component. Entries are not required to exist. An entry that equals an alias, or that is a path-prefix of an alias, is rejected. An entry under an alias is kept.

The returned config carries normalized strings, the exclude list, `work_dir`, and `output_dir`. The flag form also sets `output_path` to the `--index` file. The JSON form leaves `output_path` unset. This phase does not walk a tree past the `lstat` of each root and of the work and output directories.

**Gate.** `test/run.sh 2` builds temp directories and runs one JSON config per rejection plus one valid config with two roots, a shared work and output directory, and an exclude of a subtree. Each rejection exits 1, names the reason on one stderr line, and creates no file under `work_dir`. Rejections include multiple trailing slashes that still normalize on the valid case, an exclude equal to an alias, an exclude that is a path-prefix of an alias, an exclude of `/`, a `work_dir` chmod `555`, and a fake filesystem seam whose work and output devices differ. The chmod is restored by the test cleanup. An exclude under an alias is accepted. The valid config is accepted by the loader. A second run returns the same normalized paths. The flag form gets the same path checks: relative `--source`, relative `--index`, missing source, source of `/`, `--index` whose parent is inside the source, and `--index` that is an existing directory. One valid `--source`/`--index` pair returns one root whose alias equals the source, an empty exclude, and `output_path` set to the given file. An accepted config is checked through the loader. The phase 2 gate does not run the entry point on that config, because main walks and publishes. The probe file is gone after a successful load. The loader still accepts an existing regular `--index` file; the clobber check is phase 5, exit 3.

## Phase 3 — Line format

**Difficulty:** medium. **Depends on:** phase 1. Independent of the walk.

The format function is pure Lua. Input is a record table: remapped path, kind (`file`, `dir`, `link`), mode bits enough to render the ten-character mode, size, mtime in whole seconds, user string, group string, and for a link the raw target. Output is one line without the trailing newline. The caller writes the newline.

Mode, first character: `-` file, `d` directory, `l` symlink. The other nine come from LuaFileSystem's `permissions` string when the caller has one. The formatter also accepts the numeric mode and applies `s`/`S`, `t`/`T` itself, so tests do not need a filesystem. The ten characters match `ls -l` for the cases in the spec: `-rw-r--r--`, `drwxr-xr-x`, `lrwxrwxrwx`, plus one setuid and one sticky case.

mtime is `os.date("!%Y%m%d:%H%M%S", seconds)`. Fifteen characters, second resolution, UTC. Fractional input is truncated toward zero before formatting.

user and group are already resolved or already decimals. The formatter replaces a side that contains a colon, a tab, or a space with the decimal the record also carries.

Size is the integer `st_size`. For a symlink the caller passes the link length. The formatter does not measure the target.

Escaping and the `-` target follow the decision above. Fields are tab-separated and the path is last. Path bytes are copied unchanged, including a byte that is not a UTF-8 sequence.

**Gate.** `test/run.sh 3` matches the four sample lines in the spec, with the sample mtimes, owners, and sizes fixed as inputs. Further cases: name with a colon falls back to the id on that side only; target `-` on a clean path; target `-` when the path contains a tab; target whose bytes are `\` and `-`; newline in a path forces a bang and escapes both fields; a backslash in the path; a path containing the byte `0xFF` is copied unchanged and does not by itself raise the bang flag; setuid and sticky modes; mtime format is fixed width. No fixture touches a directory tree.

## Phase 4 — Walk

**Difficulty:** hard. **Depends on:** phases 2 and 3. Formatting is used only by the gate's assertions, not by the walker. The walker returns records.

The walk function uses `lfs.dir` and `lfs.symlinkattributes`. The walk reads every name from the open directory, closes it, then visits those names. The test seam `walk(config, fs)` counts how many directories the fake filesystem has open at once, and the real `fs` is LuaFileSystem. For every entry except `.` and `..`:

- `lstat` failure is a walk error. The returned array is discarded by the entry point.
- Kind `file`, `directory`, or `link` is kept. Anything else increments the skip count and appends a warning record. The entry point prints warnings. This phase's test reads them from the return value.
- A directory whose `dev` differs from the root's `dev` is kept and not descended.
- A directory whose `(dev, ino)` was already descended into, including the root, is kept and not descended.
- A symlink is kept with `target` taken from `symlinkattributes`. The target string is stored as returned, including when the target does not exist. It is not rewritten to an alias and not resolved. A failure to read the target is a walk error.
- File contents are never opened.
- The root directory itself is a record for that root, remapped to the alias, with no trailing slash. An empty root produces that one record.

Remap strips the matched root `path` and prepends the `alias`, with exactly one slash at the join. The root record's path is the alias. When the alias is `/`, the root record is `/` and a child `docs` is `/docs`.

Exclude is tested against the remapped path with the path-prefix rule, before descend. A match drops the record and, for a directory, does not open it.

Names are resolved by a function in the same file, once at the start of the walk. A `getent` failure is a walk error. A single unresolved id is a decimal, not an error.

**Gate.** `test/run.sh 4` builds a temp tree: an empty root, a nested directory, a regular file, a dotfile, a symlink to a file, a symlink to a directory, a dangling symlink, a fifo, a name containing a space, and a name containing a tab. Two roots, one of them with alias `/`. One exclude that covers a directory which itself contains a file. Assert the record set, the remapped paths, the symlink targets, the skip warning, and that the excluded file is absent. The empty root contributes one directory record. A second tree with a directory chmod `000` under an included path expects class `walk` and no success result. Restore permissions in the test's cleanup. The fake filesystem seam covers three cases: a directory with a different `dev` and no children recorded, a directory whose `(dev, ino)` repeats an ancestor and is not descended, and a symlink whose target read fails as class `walk`. During the fake descent the seam's open-directory count stays at most one.

## Phase 5 — Sort and publish

**Difficulty:** medium. **Depends on:** phases 3 and 4.

The publish function takes the record array, the config, and the walk-start timestamp. The stamp is captured before the walk, and the listing path is checked before the walk starts. If it exists, `main` returns class `publish` and does not walk.

When `output_path` is set, that path is the listing. When it is absent, the listing is `output_dir/index-YYYYMMDD-HHMM.listing` in UTC. The partial is always `<listing-name>.<pid>.partial` in `work_dir`.

- If the listing path exists, return class `publish` and create nothing.
- Sort records by raw remapped path. Two equal paths return class `walk` and create no partial.
- Write the partial from scratch. Each formatted line ends with `\n`, including the last. A short write or a full disk returns class `publish`, leaves the partial, and does not rename.
- `file:flush()`, then `file:close()`.
- Test the listing path again. If it now exists, return class `publish`, leave the partial, and do not rename.
- `os.rename` the partial onto the listing path. A rename error is class `publish`. The partial is left in place when the rename does not happen.
- Return the final path. `main` does not print it.

The four sample paths in the spec are format samples. Their sorted order is `/fvl/a/docs`, then `/fvl/a/docs/link`, then `/fvl/a/docs/readme.txt`, then the tab name. The bang line sorts by the raw path, so the tab byte is the key, not the two characters `\` and `t`.

**Gate.** `test/run.sh 5` publishes a fixture record array both ways: a stamped name under `output_dir`, and an explicit `output_path` from a `--index` config. Each file matches a golden listing, including sort order and a final newline. The partial name contains the pid and is gone after success. A second publish of the same path exits as class `publish`, leaves the first listing byte-for-byte, and adds no second listing. An existence check before the walk, with the listing already present, does not call the walker. If the listing appears after the walk and before rename, the publish function does not rename and the previous bytes stay. Two records with the same remapped path return class `walk` and leave no partial. A crash seam closes the writer halfway. That run's partial remains, and the final name is absent. `work_dir` and `output_dir` as the same directory, and as two directories on the same device, both pass for the stamped form.

## Phase 6 — Progress panel

**Difficulty:** medium. **Depends on:** phases 4 and 5. The walk and the publisher already run headless. This phase adds an observer.

Use the same terminal stack as schemahelper (`/mnt/extra/Projects/Philement/elements/001-hydrogen/hydrogen/extras/schematool/schemahelper.lua` and `lua/schemahelper_const.lua`, `lua/schemahelper_screens.lua`, `lua/schemahelper_invoke.lua`):

- `require("terminal")`, `require("terminal.ui.panel.screen")`, `require("terminal.ui.panel")`.
- One `Panel` as the screen body. Border `t.draw.box_fmt.single`, border attribute `{ fg = "red", brightness = "bright" }`, title ` casually_index `, title attribute `{ fg = "yellow", brightness = "bright" }`.
- `t.initwrap(main, { displaybackup = true, filehandle = io.stdout, skip_width_detection = true, disable_sigint = true, autotermrestore = true })`, and only when `system.isatty(io.stdout)` is true.
- Attribute colors copied from schemahelper's subset: yellow title, bright green values, bright cyan secondary, dim white for the current path, bright red for skip lines, bar background `236`.
- Eighths characters `▏ ▎ ▍ ▌ ▋ ▊ ▉ █` with that background, the same construction as `progress_eighths` in `schemahelper_invoke.lua`.
- Paint with `t.cursor.position.set`, `t.text.push_seq` / `pop_seq`, and `t.text.width` for truncation. Schemahelper's painters already work this way.
- The path shown in the panel is stripped before paint: a tab becomes four spaces, ANSI CSI sequences are removed, and every remaining byte below 32, including newline, plus DEL, is dropped so one panel row stays one row. Listing bytes are not stripped.

The panel shows the phase word (`walk`, `sort`, `publish`), the alias being walked, the current remapped path truncated to the inner width, and four counts: directories, files, symlinks, skipped. Under that, the last skip lines that fit.

During the walk the total is unknown, so the bar is an activity strip of fixed width that advances one eighth-step on each redraw. During sort and publish the total is the record count, and the bar is a real fraction with a percent, using the schemahelper cell math. That function returns one cell per eight records. The painter reserves columns for the percent and draws only as many cells as fit on the row.

The walker calls `progress:tick(record)` and the publisher calls `progress:phase(name, current, total)`. The observer is `nil` when stdout is not a terminal, and the callers tolerate that. Redraw at most every 100ms, using `system.gettime`, and at least every 200 records, whichever comes first. On each redraw, `screen:check_resize(true)` and `t.input.readansi(0)`. `q` or Ctrl-C aborts with class `walk` before publish. Skip warnings collected during a panel run are written to stderr after `initwrap` returns, so they do not tear the frame. Headless runs write each warning from `main` after `M.run` returns. `M.walk` itself stays quiet.

This phase does not add a splash, a mouse, a picker, or a second screen.

**Gate.** `test/run.sh 6` runs the indexer headless against a tree shaped like the phase 4 fixture. The data alias is `/data`, not `/`, because alias `/` overlaps every other absolute alias and the loader rejects that pair. Stdout is empty, stderr contains the fifo warning as one physical line, and the listing matches phase 5's rules. A fixture path containing a newline produces a one-line warning with `\n` in the text. A Lua test builds the eighths cells for 0, half, and full and checks the characters, with no terminal. Another test runs a path containing a tab, a newline, and an ANSI sequence through the panel stripper and checks the display text. The terminal half is a pty on a tree of at least a few thousand files, recorded in the work log: the counts move, the path changes, `q` leaves no listing, and a completed run shows `100%`, prints the skip warning on stderr after restore, and leaves the indexer's own stdout empty. If `readansi(0)` blocks, that is a lesson and the poll becomes a 1ms timeout.

## Phase 7 — Spec acceptance

**Difficulty:** medium. **Depends on:** phases 1 through 6.

No new behavior. One fixture script covers the contract a consumer relies on, and the entry point's exit codes.

`test/run.sh 7` creates a temp tree and a valid config and asserts:

| Case | Exit | Listing |
| --- | --- | --- |
| `--config` happy path, two roots, exclude, symlink, dangling symlink, dotfile, fifo, empty root | 0 | Golden file, sorted, final newline, this run's partial gone, stdout empty. The empty root is one line |
| `--source`/`--index` happy path, one root, alias equals the source | 0 | Listing at the given path, real paths, partial gone |
| Bad JSON, missing root, overlapping aliases, work dir inside a root, `path` of `/`, exclude that covers an alias, work and output on different devices | 1 | No listing, one stderr line, no walk |
| Bad arguments: bare path, mixed forms, `--source` alone, unknown flag | 1 | The usage line from the command-line table, stdout empty |
| Unreadable included directory | 2 | No listing renamed into place, no new partial |
| Two records with the same remapped path | 2 | No partial |
| Stamped output name already present | 3 | Previous listing unchanged, walker not called |
| `--index` path already present | 3 | Previous listing unchanged, walker not called |
| Same stamp after a successful `--config` run | 3 | Previous listing unchanged |

Plus the consumer assumptions checked on the golden file: byte-order sort, alias prefixes, ten-character modes, decimal fallback for a forced unknown uid (test seam on the name cache), bang line round-trip for a tab in a name, a symlink target copied exactly, and a filename containing the byte `0xFF` copied unchanged. Fixture mtimes come from `touch`. The expected owner and group come from the user running the test. The golden bytes are built at runtime. A checked-in golden file does not contain a person's username.

The manual note from phase 6 stays the terminal check. Phase 7 does not require a second visual pass unless phase 6's panel code changed.

When this gate passes, set phase 7 to `done` and stop. Anything the backup runner still needs is a different spec.

## Spec coverage

| Spec rule | Phase |
| --- | --- |
| `--config` file, or one root via `--source` and `--index`. `--help` and `--version`. Usage errors. No env config | 1, 2 |
| Root, alias, work dir, output dir, exclude validation. Same device. Writable. Exclude cannot cover an alias | 2 |
| Overlap and path-prefix rejection. Every trailing slash stripped. Alias `/` joins with one slash | 2, 4 |
| Walk, symlink policy, dangling symlink, mount policy, `(dev, ino)` loop stop, one directory fd, skip types | 4 |
| Remap, exclude, include the root, empty root, dotfiles, raw non-UTF-8 bytes | 3, 4 |
| uid and gid names | 4 |
| Line format, mode, mtime, escaping, bang | 3 |
| Sort by raw path, byte order. Duplicate path publishes nothing | 5 |
| Unique partial, flush, rename. Listing name checked before the walk and again before rename. No fsync | 5 |
| Lua 5.5 required before `require` | 1 |
| Stderr warnings, one failure line, stdout unused | 6, 7 |
| Exit codes 0, 1, 2, 3 | 7 |
| Progress display | 6 |
