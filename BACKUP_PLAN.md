# casually_backup implementation plan

Living plan for the backup runner. This file is the spec. There is no second document. Phases start at `not started`. Each phase finishes when its gate passes. The listing it reads is the one `casually_index.lua` publishes, under [INDEX_PLAN.md](INDEX_PLAN.md) and [INDEX_SPEC.md](INDEX_SPEC.md).

## Phase status

| Phase | What it delivers | Difficulty | Status |
| --- | --- | --- | --- |
| 1 | Toolchain and `casually_backup.lua` arguments | easy | done |
| 2 | Config load and every rejection rule | medium | done |
| 3 | Listing parser | medium | done |
| 4 | Plan: hardlink or copy against each destination's previous snapshot | hard | done |
| 5 | Apply: one read, per-destination hardlinks, snapshot publish | hard | done |
| 6 | Screen on a terminal | medium | done |
| 7 | Acceptance run | medium | done |

Difficulty is a rough size, not a schedule. Easy is an afternoon of wiring. Medium is a day of edge cases. Hard is the plan and the apply, and the ways they must fail closed.

Status values: `not started`, `in progress`, `blocked`, `done`.

## Work completed

Append a row when a gate passes. Keep the row specific enough that a later session can see what exists.

| Date | Phase | Completed |
| --- | --- | --- |
| 2026-10-08 | 1 | Executable `casually_backup.lua` parses the four command forms. It loads `lfs` 1.9.0, `dkjson` 2.5, and `terminal` 0.1.0. A well-formed command is empty success and does not open the listing. `test/run.sh backup 1` passes. `test/run.sh` with no arguments still runs only the indexer gates. |
| 2026-10-08 | 2 | `load_config` checks a JSON file or an `--index`/`--dest` command. Rejections are class `config`: exit 1, one stderr line, and the destination tree stays unchanged. `--omit-limit` and `--omit-fraction` override the file. A valid config is not applied. `test/run.sh backup 2` passes. `test/run.sh backup 1` still passes. |
| 2026-10-08 | 3 | `parse_listing` reads a finished listing back to records: bang escapes, a target of `-`, UTC mtime, mode bits, and parent records. `listing_stamp` reads `index-YYYYMMDD-HHMM.listing`. A valid listing is not applied. `test/run.sh backup 3` passes. `test/run.sh backup 2` still passes. |
| 2026-10-08 | 4 | `plan` chooses `_Base` or the listing stamp per destination and classifies mkdir, copy, hardlink, symlink, and omit. A missing `_Base` is a full copy and does not hardlink leftover dates. The latest dated snapshot is the hardlink source. An excluded directory is one omission and is not descended. Mass omission, a foreign device, an unreadable previous tree, and a nested source are refused before any snapshot is written. A valid plan is not applied. `test/run.sh backup 4` passes. `test/run.sh backup 3` still passes. |
| 2026-10-08 | 5 | `apply` locks each destination, removes leftover `.partial` directories, copies each changed file once into every destination that needs a new inode, hardlinks the rest to the previous snapshot, sets mode and owner with NUL xargs batches, then renames the partial directory into place. A dry-run prints the plan and changes nothing. A failure releases the locks and does not rename. `test/run.sh backup 5` passes. `test/run.sh backup 4` still passes. |
| 2026-10-08 | 6 | The screen paints one rounded frame only when stdout is a terminal and the run is not a dry-run. It opens after the listing is parsed and before the previous-snapshot scan. The frame holds the status counts, the file lines, and the rates. `q` aborts class apply, writes `casually_backup: aborted`, and does not rename. The pty quit run showed counts `0,1` at `0:00:00`, exit 2, that stderr line, no dated directory, and an unchanged `_Base`. The finished run showed counts `0,1,2,3`, elapsed advancing from `0:00:00` through `0:00:22` while a copy was open, a line settling from the spinner to `C` or `S`, and the copied-byte rate. `warn_on_screen` stayed 0. After restore, stderr was `casually_backup: owner not applied` and then `casually_backup: left named pipe` for the fifo planted in `_Base`. `test/run.sh backup 6` passes. `test/run.sh backup 5` still passes. |
| 2026-10-08 | 5 | Headless apply copies regular files with `workers` processes, default 4, maximum 64. Each process reads one source and writes every destination that needs a new inode. Directories, hardlinks, symlinks, and the metadata batches stay in the parent. `workers` 1, a terminal screen, and the `open_source` / `open_dest` seam stay in the parent. A short source with four workers leaves the partial directory and does not publish. `test/run.sh backup 5` passes. |
| 2026-10-08 | 7 | `test/backup_phase7.lua` runs the entry point against one trusted-folder contract. Two destinations publish `_Base` for a file, a directory, a symlink, a dangling symlink, a dotfile, an excluded path, a bang name, a `0xFF` name, a target of `-`, and a setuid file. Inodes differ across destinations. Stdout is empty, and the non-root run skips chown. The second listing hardlinks the unchanged file, copies the changed file once (`changed_opens=1`, `keep_opens=0`), and leaves the dropped path in `_Base` only. The third listing hardlinks both files and opens neither (`changed_opens=0`, `keep_opens=0`). `--source-map` reads the mapped tree and stores the listing prefix. A dry-run prints `hardlink` and the dated path and changes nothing. A later mode change leaves `_Base` at the old mode. A bad listing, nested destinations, an exclude of `/`, a destination inside the source, and a stamp that already exists exit 1 with one stderr line and publish nothing. Omissions over both thresholds exit 1 and leave `_Base` unchanged. An unreadable `_Base` exits 2 and adds no dated directory. A copy whose source is longer than the listing exits 2, leaves the partial directory, and does not publish. An `--index` directory, an unknown flag, and `--config` mixed with `--dest` exit 1 with empty stdout. `test/run.sh backup 7` passes. `test/run.sh backup 6` still passes. |
| 2026-10-08 | 7 | Re-ran after the worker pool. The dated copy still opened the changed file once and the unchanged file not at all (`changed_opens=1`, `keep_opens=0`). The third run opened neither. `test/run.sh backup 7` passes. |

## Lessons learned

Append a row when a gate fails, a dependency misbehaves, or a decision in this plan turns out to be wrong. Correct the plan in the same edit. Leave the lesson in place.

| Date | Phase | Lesson |
| --- | --- | --- |
| 2026-10-08 |  | The first draft mirrored each destination in place and treated hard links as out of scope. The backup folder is a chain of snapshots. `_Base` is the first full tree. Each later run adds `YYYYMMDD-HHMM`. Unchanged files are hardlinked inside that destination only. History is not rewritten. |
| 2026-10-08 | 2 | The phase 1 gate ran a well-formed `--config` and `--index` command and expected exit 0. Phase 2's `main` opens those paths, so a missing file is exit 1. The phase 1 gate checks `parse_args` for those forms and does not run them. |
| 2026-10-08 | 3 | One local offset does not round-trip both a January mtime and a July mtime on this machine. `os.time` reads the civil fields as local time, and the guess is corrected until `os.date` in UTC matches the original text. |
| 2026-10-08 | 3 | Forcing `isdst` false folds `20260705:180030` and `20260705:190030` onto one epoch on this zone. The correction then sees a zero delta and rejects a real listing mtime. When that delta is zero, the step is taken again with daylight saving left unset. |
| 2026-10-08 | 3 | The parent check kept only the current branch. `/fvl/adm/ceph-csi` sorts before `/fvl/adm/ceph/.dot`, so the branch was popped and the dotfile was rejected even though `ceph` is in the listing. Every directory record stays a parent for the rest of the file. |
| 2026-10-08 | 4 | LuaFileSystem 1.9.0 `permissions` is nine letters and drops setuid, setgid, and sticky. Mode compare uses the type character plus those letters, which is the same text the indexer writes. A change of only those three bits still hardlinks. |
| 2026-10-08 | 5 | Coroutines cannot overlap a blocking `file:read`. They share one C thread and do not yield inside the read. `workers` is a pool of processes. A terminal run stays in the parent because the panel has to tick on that same thread during the read. |
| 2026-10-08 | 6 | The first phase 6 gate run hardlinked a file whose bytes changed from `one` to `two`. Both strings are 4 bytes and both writes landed in the same mtime second, so kind, size, mtime, and mode matched. The match rule stays. The headless fixture steps that file's mtime forward so the second run has to copy. `readansi(0)` returned in the pty, so the poll timeout stays 0. |
| 2026-10-08 | 7 | The first phase 7 size case grew the source after a listing that still matched `_Base`. The run hardlinked and exited 0. A matching kind, size, mtime, and mode does not open the source, so a later edit is invisible. A short or long source is reported only for a copy. The fixture writes a listing that disagrees with `_Base`, then changes the length. |

## How a phase moves

1. Set that phase to `in progress` before editing code for it.
2. Build only what the phase lists. Leave later behavior unstubbed rather than half-implemented.
3. Run the gate. Fix the phase until the gate passes.
4. Set the phase to `done`, append the work log, and append any lesson.
5. Stop. The following phase starts in a later session, after this plan still matches what was learned.

A blocked phase stays `blocked` with a lesson that says what is missing. No skipping ahead.

## What this program is

`casually_backup.lua` reads one finished listing and adds one snapshot to each destination. A destination is a backup folder. The first run there creates `_Base`, a full tree of the listing. Every later run creates `YYYYMMDD-HHMM` beside it. Open that folder and the tree is the system at that listing. Files that still match the previous snapshot on that same folder are hard links, so the bytes are stored once. A file that changed is a new inode. Directories are always new inodes, because this system does not hardlink directories. Two backup folders never share an inode, even when they sit on the same device.

```text
/backup/disk1/_Base/fvl/a/docs/readme          first full copy
/backup/disk1/20261008-1430/fvl/a/docs/readme  hardlink to the _Base inode, if unchanged
/backup/disk1/20261009-0900/fvl/a/docs/readme  same inode again, or a new file if that day changed
/backup/disk2/_Base/...                        a separate inode on the other backup
```

The listing is the desired tree: names, kinds, sizes, mtimes, modes, owners, and symlink targets. The program reads file bytes only when some destination needs a new inode for that regular file. One read feeds every destination that needs a new copy. A destination that can hardlink does not open the source and does not write the bytes.

The workload from the repo readme is a large tree, indexed where the files live, with the listing copied to the machine that holds the backups. Daily change is a few small files. Comparing a previous snapshot is local. Source bytes move only for new inodes. Records and per-destination scans stay in memory. That is the same bound the indexer accepted. A larger tree becomes a lesson and a plan change.

Language is Lua 5.5. One process. The libraries are the ones the indexer already uses: `lfs`, `dkjson`, and `terminal`. Metadata that `lfs` cannot set goes through GNU `chmod`, GNU `chown`, and GNU `xargs`, with paths on a NUL-delimited stdin. There is no C file in this repo, no `fsync`, and no call to `casually_index.lua`. Nothing in this plan deletes an old snapshot. Removing one by hand is described under Housekeeping. A retention command is a later plan.

## Command line

The program is `casually_backup.lua`. Line 1 is the shebang `#!/usr/bin/env lua`, and the file is executable:

```text
./casually_backup.lua --config <file>
./casually_backup.lua --index <listing> --dest <dir> [--dest <dir>...] [--source-map <alias>=<path>...]
./casually_backup.lua --help
./casually_backup.lua --version
```

`env` finds `lua` on `PATH`. On this machine that is Lua 5.5.1 at `/usr/local/bin/lua`. Lua skips a first line that starts with `#!`. Flag order does not matter. Each flag that takes a value consumes the next argument, and that value must be present and must not itself start with `-`.

`--config <file>` loads the JSON config below. `--dry-run`, `--omit-limit`, and `--omit-fraction` may appear with `--config`. They override the JSON keys of the same meaning. `--index`, `--dest`, and `--source-map` may not appear with `--config`.

`--index` with one or more `--dest` is the flag form. `--source-map` is optional and repeatable on that form only. Each value is `<alias>=<path>`, split on the first `=`. Both sides are absolute paths checked by the phase 2 rules.

`--dry-run` builds the plan, prints it, and changes nothing. It may appear once, on either form.

`--omit-limit <n>` and `--omit-fraction <number>` override the mass-omission stop. `<n>` is a decimal integer `>= 0`. `<number>` is a decimal from 0 to 1 inclusive, such as `0.02`. Each may appear once.

`--help` prints the four forms and a one-line description of each flag to stdout, then exits 0. It does not read a listing and does not create a file.

`--version` prints three lines to stdout and exits 0, before any terminal setup: `casually_backup <version>`, `Lua <version>`, `terminal.lua <version>`. The script version starts at `0.1.0`.

Anything else is a usage error. Exit 1, one stderr line, stdout empty, no file created.

| Arguments | stderr |
| --- | --- |
| none | `casually_backup: missing arguments` |
| unknown flag, or a value that was parsed as a flag | `casually_backup: unknown argument: <token>` |
| a bare word | `casually_backup: unexpected argument: <token>` |
| the same flag twice, except `--dest` and `--source-map` | `casually_backup: repeated argument: <flag>` |
| `--help` or `--version` with anything else | `casually_backup: <flag> does not take other arguments` |
| `--config` together with `--index`, `--dest`, or `--source-map` | `casually_backup: use either --config or --index with --dest` |
| `--config` with no file | `casually_backup: --config requires a file` |
| `--index` without `--dest` | `casually_backup: --index requires --dest` |
| `--dest` without `--index` | `casually_backup: --dest requires --index` |
| `--source-map` without `--index` | `casually_backup: --source-map requires --index` |
| `--source-map` whose value has no `=` | `casually_backup: --source-map requires alias=path` |
| a flag that takes a value, with no value | `casually_backup: <flag> requires a value` |

A missing file, a relative path, or a path that fails the phase 2 checks is also exit 1. Those messages name the path rule. They use the same `casually_backup:` prefix.

## Config

One JSON object. Unknown keys are a config error.

```json
{
  "index": "/var/lib/casually/index-20261008-1430.listing",
  "destinations": ["/backup/disk1", "/backup/disk2"],
  "source_map": [
    { "alias": "/fvl/a", "path": "/mnt/ceph-a" }
  ],
  "exclude": [],
  "omit_limit": 1000,
  "omit_fraction": 0.02
}
```

`index` is the finished listing. It must be absolute. `lstat` must show a regular file. A symlink is rejected. A path whose final component ends in `.partial` is rejected.

`destinations` is required and non-empty. Each entry is a backup folder that already exists. The program creates the folder's snapshots. It does not create the folder. `/` is rejected. Two destinations that are equal, or where one is a path-prefix of the other, are rejected.

`source_map` is optional. Each entry has string `alias` and string `path`. Omitted or empty means every listing path is read from that path. `exclude` is optional. Omitted or empty means nothing is excluded. `omit_limit` defaults to 1000. `omit_fraction` defaults to 0.02.

The flag form builds the same internal config. `--index` sets `index`. Each `--dest` appends one destination. Each `--source-map` appends one map entry. Exclude is empty unless a later phase is given keys, which phase 2 does not invent. The limit flags, when present, set the numbers. When absent, the defaults apply.

## Snapshot names

The stamp is taken once per run and shared by every destination that is adding a dated snapshot.

The listing's final component is matched against `index-YYYYMMDD-HHMM.listing`. A match uses that `YYYYMMDD-HHMM` as the stamp. The indexer's listing name is already UTC, minute resolution, from the walk start, so the folder is the same moment as the listing. A name that does not match uses `os.date("!%Y%m%d-%H%M")` at plan start.

For each destination:

- `_Base` missing, or not present: this run's snapshot is `_Base`. There is no previous snapshot. Every file is a new copy. A dated folder is not also created.
- `_Base` exists and is not a real directory: class `plan`, exit 1.
- `_Base` exists and is a real directory: this run's snapshot is the stamp. Previous is the lexicographically latest child whose name is `YYYYMMDD-HHMM`, or `_Base` when no dated child exists. `YYYYMMDD-HHMM` sorts in time order.
- The chosen snapshot name already exists: class `plan`, exit 1, naming the destination and the name. A second run of the same listing does not clobber.

A destination that still needs `_Base` and a destination that already has `_Base` may share one run. The new disk receives a full `_Base`. The old disk receives the dated snapshot. Their inodes stay distinct.

## Layout

```text
casually_backup.lua       the whole program. Line 1 is #!/usr/bin/env lua
test/backup_phaseN.lua    gate for backup phase N. dofile's the script and calls its functions
test/run.sh               index gates as before; `backup` selects the backup gates
```

The script returns a table of its functions and runs `main` only when `arg[0]` names `casually_backup.lua`. A test `dofile`s it and calls those functions.

`test/run.sh` with no arguments, or with one phase number, runs only `test/phaseN.lua`. That is the indexer. `test/run.sh backup` runs every `test/backup_phaseN.lua` that exists. `test/run.sh backup N` runs one backup gate. Backup gates re-run earlier backup gates. They do not re-run the indexer suite, except the phase 1 backup gate, which runs `test/run.sh` with no arguments once and requires those indexer gates to pass.

Functions return data or `nil, err, class` where class is `config`, `plan`, `scan`, or `apply`. `main` maps `config` and `plan` to exit 1, and `scan` and `apply` to exit 2. It writes the single failure line.

## Settled decisions

**Each backup folder is its own hardlink chain.** A hard link is created only between two paths under the same destination: the previous snapshot and the snapshot being built. A file that has never changed since `_Base` keeps one inode, and every later snapshot on that folder holds another name for it. A file that changed on a middle day is a new inode from that day forward. Later unchanged days hardlink to that newer inode, not a second copy of the bytes. Disk 2 gets its own inode even when disk 1 and disk 2 are the same filesystem.

**The previous snapshot is the link source.** The latest `YYYYMMDD-HHMM` is previous when one exists, otherwise `_Base`. Linking only to `_Base` would store a fresh copy, on every later day, of a file that changed once and then sat still. Linking to the latest snapshot stores that day's delta once.

**A hard link shares the whole inode.** Size, bytes, mtime, mode, and owner are one set. The new snapshot hardlinks a regular file only when kind, size, mtime, and mode match the previous file, and owner matches too when this run is applying owner. Any one of those differing means a new copy, so the old snapshot keeps the old mode, owner, and mtime. `chmod` or `chown` on a hard link would change every snapshot that shares the inode, and this program does not do that. Directories are always new. An unchanged directory still gets a new inode whose metadata is set to the listing. Symlink mode and symlink mtime are ignored, as below. An unchanged symlink is a hard link to the previous symlink inode. Linux `link` does not follow the symlink. A changed target is a new symlink.

**Source hard links are not reconstructed.** The listing has no inode identity. Two listing paths are two snapshot entries. If they were one inode on the source, the backup may store them twice.

**The listing is the desired tree for the new snapshot.** One listing per run. There is no previous listing to diff. Each destination is stated from its own previous snapshot, because two backup folders can be a generation apart. A path in the previous snapshot and absent from the listing is omitted from the new snapshot. It is left in place in the old snapshot. The indexer's rule stands: a missing subtree in a published listing means those paths were absent at walk time.

**Alias paths are the source, with an optional remap.** A listing path `/fvl/dir1/file1` is read from `/fvl/dir1/file1`. Under destination `/mnt/backup1` and snapshot `_Base` the file is `/mnt/backup1/_Base/fvl/dir1/file1`. Join the snapshot directory and the absolute listing path with one slash at the boundary. A `source_map` entry rewrites one listing prefix to another absolute prefix before the read, and the snapshot still stores the listing path. Map aliases do not overlap. Symlink targets are copied as stored. They are not remapped.

**The listing is produced elsewhere, with its own config.** On the remote machine the index walks the real tree and writes the alias:

```json
{
  "roots": [
    { "path": "/mnt/fvl", "alias": "/fvl" }
  ],
  "work_dir": "/var/lib/casually",
  "output_dir": "/var/lib/casually",
  "exclude": []
}
```

A file at `/mnt/fvl/dir1/file1` is a listing line whose path is `/fvl/dir1/file1`. That file is copied to the backup machine. The local mount is already `/fvl`, so the backup config names the listing and the backup folder and leaves `source_map` empty:

```json
{
  "index": "/var/lib/casually/index-20261008-0300.listing",
  "destinations": ["/mnt/backup1"],
  "exclude": [],
  "omit_limit": 1000,
  "omit_fraction": 0.02
}
```

The run reads `/fvl/dir1/file1` and publishes `/mnt/backup1/_Base/fvl/dir1/file1`, then `/mnt/backup1/20261008-0300/fvl/dir1/file1` on the next listing. The two JSON files stay separate. The indexer rejects unknown keys, and the backup rejects unknown keys, so one file cannot carry `roots` for the remote and `destinations` for the local machine. The shared contract is the alias text inside the listing. `source_map` is for the day the local mount is not the alias. `{ "alias": "/fvl", "path": "/srv/fvl" }` reads `/srv/fvl/dir1/file1` and still stores `/fvl/dir1/file1` under the snapshot. Mapping the alias back to the remote path `/mnt/fvl` would look for the files in the wrong place on this machine.

**One source read feeds every destination that needs a new inode.** The copy reads a chunk and writes that same chunk to each new file that needs the bytes, then reads the next chunk. Chunk size is `1048576` bytes. A destination that hardlinks does not receive those bytes. There is no spool and no second process per destination.

**Workers are processes.** `workers` is an integer from 1 to 64. Omitted, it is 4. `--workers` overrides the file. Lua coroutines share one thread, and a blocking read does not yield, so the pool is long-lived OS processes, not threads and not one process per file. A headless run with `workers` greater than 1 creates every directory first, then keeps up to that many processes busy. Each process copies one file at a time: it reads the source once and writes every destination that needs a new inode. The parent does hardlinks, symlinks, `chmod`, and `chown`. `workers` 1, a terminal screen, or an `open_source` / `open_dest` test seam copies in the parent, so the panel can tick during a read and `q` can abort it. A worker that reports a short read, a long read, or a write error stops the run. Copies already finished by other workers stay inside the partial directory. The snapshot is not renamed.

**Metadata on new inodes.** `lfs.touch` sets mtime on new regular files and on the new directories. Mode is applied with `chmod` on those same paths. Owner and group are applied with `chown -h` when the effective uid is 0, on new files, new directories, and new symlinks. Hardlinked paths are not passed to `chmod`, `chown`, or `touch`. Names come from one `getent passwd` and one `getent group` on this machine, the same cache shape as the indexer. A listing side that is all digits and is not a known name is that uid or gid. A side that matches a name uses that name's id. An unknown name, when owner is being applied, is class `scan` and exits 2 before any change.

**Owner is best-effort.** The effective uid is the second number on the `Uid:` line of `/proc/self/status`. If it is not 0, the run does not call `chown`, does not compare owner, and writes one stderr warning: `casually_backup: owner not applied`. If that file cannot be read, the run exits 1. A `chown` failure while root is class `apply`. Hardlink matching then ignores owner, so two snapshots owned by the backup user still share an inode.

**Symlinks are not chmod'd and not touched.** On Linux, `chmod` and `utime` follow a symlink and would change the target. `lfs` has no `lchmod` or `lutimes`. Symlink mode in the listing is ignored. Symlink mtime is ignored. A new symlink may be `chown -h`'d. A hardlinked symlink is left alone.

**The snapshot directory is the publish.** The tree is built in `<dest>/<snapshot-name>.<pid>.partial/`. Files are written there under their final relative names. `file:flush()` and `file:close()` run before the snapshot is published. There is no `fsync`. When every record has succeeded, `os.rename` moves that directory to `<dest>/_Base` or `<dest>/<stamp>`. Rename is atomic on the same filesystem, and hard links made inside the partial directory remain valid after the rename. A power loss after the rename can leave a new file whose size and mtime match while the bytes are wrong. A later run can hardlink that inode forward. That window is accepted. A short write, a short read, or a source length that is not the listing size does not rename the snapshot. The previous snapshots stay as they were. The partial directory is left in place.

**Stop at the first apply error.** Later listing records are not added. The snapshot directory is not renamed on any destination. Exit 2. Published history does not change. A hard link or a new file already created inside the partial directory is unpublished debris.

**Omissions are not deletes.** Old snapshots are never removed, and paths inside them are never unlinked. The new snapshot simply lacks the names that left the listing. The mass-omission stop runs before any change. For each destination that has a previous snapshot, if the number of omitted file, directory, and symlink paths is greater than `omit_limit` and greater than `omit_fraction` times the number of desired records, the run exits 1. Nothing is locked or written. The message names the destination, the omission count, the limit, and the fraction. Desired records are the listing records that remain after exclude. Raising the limit or the fraction, in the config or with the flags, is how a real mass removal is snapshotted. The check uses ordinary Lua numbers. The gate's cases sit away from a rounding boundary. A first `_Base` has no previous snapshot, so its omission count is 0.

**Special files in a previous snapshot are warnings.** A fifo, socket, or device is not an omission and is not recreated. Each one is `casually_backup: left <type> <path>`, using the LuaFileSystem mode string. The warning does not change a successful exit. If a special file or a symlink sits where an ancestor directory of the new snapshot must be created, the plan exits 1 before any change and names the path.

**Dry-run prints the plan and does not take the locks.** Stdout is the action list, then one summary line. Paths in the list are the published snapshot paths. Stderr still gets warnings and the one failure line. A mass-omission refusal exits 1 with an empty stdout.

**Stdout on a real run is empty.** The panel uses stdout when it is a terminal. Warnings and the failure line go to stderr after the terminal is restored. `--help` and `--version` are the other stdout exceptions.

**No indexer configuration from the environment.** The script may read `HOME` only to prepend the Lua 5.5 rock paths before `require`. Roots, destinations, and the listing path come from the command or the JSON file.

**Lua 5.5 is a hard check.** If `_VERSION` is not `Lua 5.5`, the script prints `casually_backup: need Lua 5.5` and exits 1 before `require`.

## Housekeeping

The program never removes a published snapshot. Removing one is deleting that date directory while no run holds the destination lock. A retention command is a later plan.

A hard link is another directory name for one inode. The names are peers. Day 7 does not store a pointer to day 6 or to `_Base`. `link` is called with the previous snapshot's path, and the new name refers to that same inode. The bytes stay allocated until the last name is removed.

A file added on day 6 and unchanged after that has names only in `20261006` and the later dates. `_Base` does not have it. Deleting `20261006` leaves the bytes in place through day 7. Deleting every date that still names it frees the bytes.

A file that has never changed has a name in `_Base` and in every date. Deleting dates leaves the bytes for as long as `_Base`, or any kept date, still names them.

A file that changed on day 6 has the old inode in `_Base` and the new inode from day 6 forward. Deleting day 6 leaves the new bytes in the later dates and the old bytes in `_Base`.

Directories are not shared. Each snapshot has its own directory inodes. Removing a date frees those directories entirely. The file bytes that survive are the ones another snapshot still names.

Keep `_Base`. If that directory is missing, the next run treats the backup folder as new: it writes a full `_Base` and does not hardlink to the dates that remain. Deleting the latest date is safe for the following run. Previous becomes the latest dated directory that is still there, or `_Base` when no dated directory remains. Files that existed only in the deleted date are gone.

Each backup folder is cleaned up on its own. Another folder has its own inodes.

## Path rules

The prefix rule is the indexer's rule. Strip every trailing slash, leaving `/` as `/`. A prefix matches only at a boundary. `/backup/disk1` matches `/backup/disk1` and `/backup/disk1/_Base`. It does not match `/backup/disk1b`. `/` is a prefix of every other absolute path.

Normalize `index`, destinations, map aliases, map paths, and excludes by removing every trailing slash when the value is longer than `/`.

Reject empty, relative, or a component that is `.` or `..`. Destination `/` is rejected. Map path `/` is allowed. Map alias `/` is allowed only when it is the only map entry, because `/` is a prefix of every other alias.

The listing file must not sit inside any destination, by the prefix rule. Two destinations must not nest. A map `path` must `lstat` as a real directory. A symlink, including a symlink to a directory, is rejected.

Exclude entries use the same absolute-path rules. They are matched against listing paths. An excluded listing path is not put in the new snapshot. If a previous snapshot contains it, that path counts as an omission. The previous-snapshot scan does not descend into an excluded path. An exclude of `/` is rejected. After exclude, zero desired records is rejected: `exclude covers the listing`.

A previous snapshot's device must equal the destination's device. Hard links cannot cross devices, and a previous tree on another device would force a full copy that looks like a new `_Base`. The plan exits 1 and names the path. The scan does not descend into a directory whose device differs from the previous snapshot's device. A desired path under that mount is class `plan`, exit 1.

## Listing parser

`parse_listing` takes the file bytes and returns an array of records, or `nil, err, "config"`. It does not touch the filesystem. Records are sorted by raw path because the parser rejects a line that is not strictly greater than the previous raw path. Duplicate paths fail that test. A missing final newline fails. Zero records fails.

Each record holds: raw path, kind (`file`, `dir`, `link`), size as an integer, mtime text (`YYYYMMDD:HHMMSS`), mtime as a Unix second, user text, group text, mode text (ten characters), mode bits for `chmod`, and for a link the raw target.

Field split is the indexer's split. Six fields, tab-separated. A line that starts with `!` has the bang glued to the mtime. There is no tab between `!` and the mtime. The bang means the path and the link field use the four escapes: `\\`, `\t`, `\n`, `\r`. Any other backslash on a bang line is a bad line, except the link field that is exactly `\-`.

Link field:

- `-` with kind `file` or `dir` means no target.
- `-` with kind `link` is a bad line.
- `\-` means the target is exactly `-`, on a bang line and on a normal line. That backslash is not an escape.
- A bang line's other target is unescaped with the four escapes. `\\-` is a target whose bytes are `\` and `-`.
- A normal line's target is raw. A `\` in a normal path or target is a bad line.

The mode's first character is `-`, `d`, or `l`, and it must match the kind. The other nine follow `nine_permissions` in `casually_index.lua`: `r`/`-`, `w`/`-`, and `x`/`-`/`s`/`S`/`t`/`T` in the positions that function emits. The parser turns them back into mode bits. Setuid is `0x800`, setgid is `0x400`, sticky is `0x200`. The low nine bits are the `rwx` bits. `S` is setuid or setgid without the execute bit. `T` is sticky without the other execute bit.

Size is a decimal integer. For a symlink it must equal the byte length of the decoded target. Mtime text is fifteen characters, `YYYYMMDD:HHMMSS`, and must survive a round trip through UTC. Convert the six fields to a Unix second, then `os.date("!%Y%m%d:%H%M%S", second)` must equal the original text. `os.time` reads a table as local time. The conversion corrects that guess until the UTC rendering matches. Forcing standard time can fold two summer hours onto one epoch. When that correction is zero and the UTC fields still differ, the same step is taken with daylight saving left unset. The gate checks the round trip, including a January date, a July date, and the two July hours that fold under forced standard time.

Path bytes are raw, including a byte that is not UTF-8. The path must be absolute, with no empty, `.`, or `..` component.

Parent path is the path with its final component removed. The parent of `/fvl/a` is `/fvl`. The parent of `/` is absent. A record is a root when no other record's path is a strict prefix of it. Every root record must be a directory. Every non-root record must have its parent path present as a `dir` record. A file `/fvl/a/readme` without a `/fvl/a` directory record is a bad listing. A directory `/fvl/a/docs/sub` without `/fvl/a/docs` is a bad listing. A listing whose only record is the directory `/fvl/a` is valid: `/fvl` is not a record, and the snapshot creates that ancestor with umask and the running user, not from listing metadata. The indexer sorts full paths, so a sibling can sit between a directory and a later child: `/fvl/adm/ceph-csi` sorts before `/fvl/adm/ceph/.dot`. That child is valid. The parent directory stays known for the rest of the listing.

## What a snapshot path is

For a listing path P, destination D, and snapshot name S, the published path is D, a slash, S, and P. S is `_Base` or `YYYYMMDD-HHMM`. P starts with `/`.

Ancestors between the snapshot root and the shallowest listing path are created as plain directories. They are not listing records. They get the process umask and the running user. Example: listing `/fvl/a` creates `<snapshot>/fvl` as an ancestor, then `<snapshot>/fvl/a` from the listing.

While the snapshot is unpublished, those paths live under `<dest>/<S>.<pid>.partial` instead of `<dest>/<S>`. The pid is the first field of `/proc/self/stat`. If that file cannot be read, the suffix is `os.time()` and `math.random`.

## Plan

The plan is pure with respect to user data. It may `lstat` and read directories. It does not create, remove, rename, `chmod`, `chown`, hardlink, or copy.

Steps:

1. Parse the listing. Apply exclude. Choose the stamp from the listing name, or from UTC now.
2. Resolve each listing path to a source path through `source_map`.
3. Reject the plan if any resolved source directory is a path-prefix of a destination, or any destination is a path-prefix of a resolved source path, or a resolved source file equals a destination path. The message names both paths. Class `plan`, exit 1.
4. Read the uid file. If root, load `getent`. A `getent` failure is class `scan`, exit 2.
5. For each destination, choose `_Base` or the stamp, as the snapshot-name rules say. A name that already exists is class `plan`, exit 1, before any destination is written.
6. When a previous snapshot exists, walk it with `lfs.dir` and `lfs.symlinkattributes`. Read all names, close the directory, then visit. One directory fd. Do not follow symlinks. Do not descend into an excluded listing path. Do not descend into a different device. Map each walked path back to a listing path by stripping the previous snapshot's directory prefix. An unreadable directory is class `scan`, exit 2. The walk is discarded. An unreadable previous tree must not become a full copy or a hollow snapshot.
7. Classify each desired record against the previous path's `lstat`.
8. Count omissions. Run the mass-omission check.

Classification for a desired record:

| Previous snapshot | Action |
| --- | --- |
| no previous snapshot, or path absent | `mkdir`, `copy`, or `symlink` |
| directory, any metadata | `mkdir`. Directories are never hardlinked |
| file, kind size mtime and mode match, owner matches or owner is skipped | `hardlink` |
| file, anything else differs, including owner when owner is applied | `copy` |
| symlink, target matches | `hardlink` |
| symlink, target differs | `symlink` |
| different kind | the new kind's create action. The old inode stays in the old snapshot |

Mtime compare formats the previous `modification` with `os.date("!%Y%m%d:%H%M%S", whole_seconds)` and compares the text to the listing. Whole seconds truncate toward zero. Mode compare uses the ten-character form: the type character plus LuaFileSystem's nine permission letters. That string omits setuid, setgid, and sticky, so a change of only those bits still hardlinks. Owner compare uses numeric ids after name resolution.

An omission is a file, directory, or symlink in the previous snapshot whose listing path is not desired. The previous snapshot's own root is not an omission. Special files are warnings, not omissions.

The plan returns, per destination, the snapshot name, the previous snapshot path or none, the action lists, the warnings, and the counts. It also returns the distinct source paths that any destination will read.

A file hardlinked on one destination and copied on another produces one `hardlink`, one `copy`, and one source read. A file hardlinked on every destination produces no source read.

## Apply

User data changes only in this phase, and only when the plan returned success and the run is not a dry-run. Published snapshot directories are not modified.

1. Take a lock on every destination. `lfs.lock_dir` on `<dest>/.casually_backup.lock`. Write `<pid>\n` to `owner` inside it. If `lock_dir` fails, read `owner`. A pid whose `/proc/<pid>` is a directory means the lock is live: class `config`, exit 1, `destination locked: <path> (pid N)`. A missing `owner`, or a pid that is not alive, is a stale lock: remove the lock directory and take it again. The gap between `lock_dir` and the `owner` write is accepted. Live locks on two destinations are released if the second lock fails. A pid suffix that is not a live pid cannot be stolen.
2. Remove direct child directories of the destination whose names end in `.partial`. That is a crashed run's unpublished snapshot. Do not walk into `_Base` or a dated snapshot to do this. A failure here is class `apply`, exit 2, and no snapshot is renamed.
3. Create `<dest>/<snapshot-name>.<pid>.partial`. `lstat` each existing component of the destination. A symlink component is class `apply`.
4. Walk the desired records in raw-path order. Parents are before children because a parent path is a byte-order prefix of its child. A sibling may sort between a directory and a later child. That child still has its parent record earlier in the listing.
5. For a directory: mkdir the new directory inside the partial snapshot. Queue mode, owner, and mtime for that new inode.
6. For a regular file: destinations that copy share one source open. `lstat` each source ancestor and the file. A symlink ancestor, or a file that is not a regular file, is class `apply`. Read `min(1048576, remaining)` and require a full buffer. Write that buffer to every new file opened `wb` inside its partial snapshot. After the listing size has been written, one extra `read(1)` must return nil. `flush`, `close`, and `lfs.touch` each new file to the listing mtime. Queue `chmod` and `chown` for those new paths only. Destinations that hardlink call `lfs.link(previous, new)` with two arguments, after the copies for this record have succeeded. A hardlink failure, including a cross-device failure, is class `apply`. A headless run with `workers` greater than 1 does the directory records first, then hands each copied file to a worker process for this step. The parent still hardlinks and still runs the metadata batches. `workers` 1 and a terminal run keep this step in the parent.
7. For a symlink that is new: `lfs.link(target, new, true)`. Queue `chown -h` only. For a symlink that hardlinks: `lfs.link(previous, new)` with two arguments, and do not queue metadata.
8. If any step from 3 through 7 fails, release the locks and exit 2. Do not rename any snapshot directory. Do not continue to the next record. Do not modify `_Base` or an older date.
9. On success so far, run the metadata batches on the queued new inodes. One `xargs -0 chmod <mode> --` per distinct mode, paths on stdin as NUL-terminated bytes. One `xargs -0 chown -h <uid>:<gid> --` per distinct pair, the same way, and only when root. The command text contains only fixed flags and decimal numbers. Paths never enter the shell. A batch failure is class `apply` and does not rename.
10. `lfs.touch` each new directory to the listing mtime. Children already exist, so the directory mtime stays.
11. `os.rename` each partial directory onto `<dest>/_Base` or `<dest>/<stamp>`. A rename failure is class `apply`. Destinations already renamed in this step stay published. The plan refuses name collisions before the build, so a rename failure here is an I/O failure, not a clobber of an older snapshot.
12. Release every lock. `main` releases locks on every exit path that took them. A crash leaves a lock whose pid is dead, and the next run clears it.

`chmod` and `chown` are GNU coreutils. `xargs` is GNU findutils. Phase 1 checks that `chmod --version`, `chown --version`, and `xargs --version` all run. The parent copy does not fork. A headless run with `workers` greater than 1 forks that many long-lived Lua processes for the file copies and no more. `lfs.link` with two arguments is the hard link. `lfs.link` with a true third argument is the new symlink.

## Dry-run stdout

One action per line. Kinds in this order: `mkdir`, `copy`, `hardlink`, `symlink`, `omit`. Within a kind, lines sort by the published path, byte order.

```text
mkdir /backup/disk1/20261009-0900/fvl
hardlink /backup/disk1/_Base/fvl/a/docs/readme /backup/disk1/20261009-0900/fvl/a/docs/readme
copy /mnt/ceph-a/docs/new /backup/disk1/20261009-0900/fvl/a/docs/new
symlink /backup/disk1/20261009-0900/fvl/a/docs/link
omit /backup/disk1/_Base/fvl/a/old
plan copy=1 mkdir=1 hardlink=1 symlink=1 omit=1 skip=0 read=1
```

`hardlink` prints the previous path, then the published path. `copy` prints the resolved source path, then the published path. `read` is the number of distinct source files the apply would open. `skip` stays 0 in this model: an unchanged file is a `hardlink`, and an unchanged directory is still a `mkdir`. Ancestor mkdirs are `mkdir` lines. The summary is the last line.

## Screen

Same terminal stack as the indexer. `require("terminal")`, `require("terminal.ui.panel.screen")`, and `require("terminal.ui.panel")`. `t.initwrap` uses `displaybackup = true`, `filehandle = io.stdout`, `skip_width_detection = true`, `disable_sigint = true`, and `autotermrestore = true`, only when `system.isatty(io.stdout)` is true and the run is not a dry-run. The screen is up before the previous-snapshot scan, as soon as the listing has been parsed. Headless runs and dry-runs do not paint.

One frame, the shape of a single rounded table. Glyphs come from `t.draw.box_fmt.rounded`: `╭`, `╮`, `╰`, `╯`, `─`, `│`. The two rules that separate status, files, and rates use `├`, `─`, and `┤`, and those junctions sit on the side borders. A panel border title is centered and cannot sit in the corner, so the paint draws the frame itself and the name is not a border title.

```text
╭──────────────────────────────────────────────────────────────────────────╮
│ 12840 files   410 done   12430 left   0:01:07            Casually Backup │
│ /mnt/backup1   20261008-0300                                             │
├──────────────────────────────────────────────────────────────────────────┤
│ D /mnt/backup1/20261008-0300/fvl/dir1                                    │
│ S /mnt/backup1/20261008-0300/fvl/dir1/file1                              │
│ / /mnt/backup1/20261008-0300/.../dir1/file2                              │
├──────────────────────────────────────────────────────────────────────────┤
│ files 410   copied 12   6.1 files/s                                      │
│ seen 1.2 GiB   copied 48.0 MiB   812 KiB/s                               │
╰──────────────────────────────────────────────────────────────────────────╯
```

Colors are attributes the `terminal.text` stack already understands. `brightness = "bright"` is the bright form of a base color.

| What | Attribute |
| --- | --- |
| Frame and rules | `{ fg = "cyan" }` |
| `Casually Backup` | `{ fg = "white", brightness = "bright" }` |
| Count labels | `{ fg = "white" }` |
| Count numbers | `{ fg = "white", brightness = "bright" }` |
| Elapsed time | `{ fg = "yellow", brightness = "bright" }` |
| Destination path | `{ fg = "white" }` |
| Snapshot name | `{ fg = "cyan", brightness = "bright" }` |
| `C` and the copied-byte number | `{ fg = "green", brightness = "bright" }` |
| `S` | `{ fg = "cyan" }` |
| `L` | `{ fg = "magenta", brightness = "bright" }` |
| `D` | `{ fg = "blue", brightness = "bright" }` |
| Spinner | `{ fg = "yellow", brightness = "bright" }` |
| File path | `{ fg = "white" }` |
| Rate labels | `{ fg = "white" }` |
| Other rate numbers | `{ fg = "white", brightness = "bright" }` |

**Status**, two inner lines. The first line holds the counts and the elapsed time on the left, and the words `Casually Backup` flush with the right edge. A narrow terminal drops characters from the left of that line before it drops the name. The counts read `12840 files   410 done   12430 left   0:01:07`. The total is the number of desired records in the listing. It is known as soon as the listing is parsed. Finished records start at 0. The second line names the destination and the snapshot being built. Before apply, the second line says `scanning`. Elapsed time is `hours:minutes:seconds` from `system.monotime` at screen open. Hours are unpadded and may grow past two digits. Minutes and seconds are two digits.

The clock is redrawn when one second has passed since the last status paint. The copy loop checks that between chunks, and so does every finished record. A `file:read` that has not returned holds the clock. One process cannot paint during a blocked read. A hung mount freezes the elapsed time until the read returns or fails.

**Files**, the remaining rows. One line per desired record per destination, added when that record starts and rewritten when it finishes. The line is a one-character marker, a space, and the published path. The marker settles to:

| Marker | Record |
| --- | --- |
| `C` | bytes were copied |
| `S` | hard link to the existing inode, file or symlink |
| `L` | new symlink |
| `D` | directory |

While the record is open, the marker cycles `|`, `/`, `-`, `\` on the same one-second tick as the clock. Ancestor directories that are not listing records do not get a line. The list is the new snapshot being built from the listing. A path that is absent from the listing is not a line, and the screen has no removal count. Older snapshots keep those names.

The list keeps only as many lines as the rows between the two rules. A resize recomputes that height. Older lines are dropped. There is no scroll-back. The open line is the last line and is replaced in place until the record finishes.

A path is clipped in the middle to the inner width minus the marker and the space. The clip keeps the head and the tail, with `...` between them, and gives the head the extra column when the remainder is odd. A path that fits is padded with spaces so the row paints clean. Width is display columns. Valid UTF-8 uses `utf8swidth`. Any other byte is one column. A tab, a newline, a carriage return, and DEL are drawn as `?`.

**Rates**, two inner lines. Counts are for this run, across every destination:

```text
files 410   copied 12   6.1 files/s
seen 1.2 GiB   copied 48.0 MiB   812 KiB/s
```

`files` is finished records. `copied` on that line is records whose marker is `C`. `files/s` is finished records divided by elapsed seconds. `seen` is the sum of the sizes of finished records, hard links included. `copied` on the second line is bytes read from the source. `bytes/s` is those copied bytes divided by elapsed seconds. Elapsed time below one second draws the rates as `0`. Units are `B`, `KiB`, `MiB`, `GiB`, `TiB`, 1024 at a step. Values from 10 upward are integers. Values below 10 and at least one unit step show one decimal.

On each paint, `screen:check_resize(true)` and `t.input.readansi(0)`. `q` or Ctrl-C aborts with class `apply`. No snapshot directory is renamed, locks are released, and stderr is `casually_backup: aborted`. If `readansi(0)` blocks, that is a lesson and the poll becomes a 1ms timeout.

## Robustness

These rules keep a published date from looking complete when it is short, and they keep history intact when this run fails.

**Checks before the first user-data change.** Listing parsed, stamp chosen, excludes applied, parents present, source and destination trees do not nest, previous snapshot chosen, device checked, scan finished, omission check passed, snapshot name free, writability probed. The probe creates and removes `.casually_backup.probe.<pid>` in each destination. A destination that is not writable is exit 1. The probe is gone afterward.

**History is immutable.** Apply creates files only inside the partial directory. It hardlinks from the previous snapshot. It does not open an older snapshot for writing. `chmod`, `chown`, and `touch` receive only paths inside the partial directory.

**Do not follow a symlink to build a path.** Source ancestors of a file being copied are `lstat`ed. A symlink stops the apply. The new snapshot is built from mkdir and link calls on paths the plan already checked, not by writing through a directory symlink. A previous snapshot that contains a directory symlink is not descended.

**The previous scan is fail-closed.** An error while reading it aborts before an omission count is trusted and before a full copy starts.

**A snapshot is published whole or not at all.** The partial directory is renamed only after every record, the metadata batches, and the directory mtimes. A copy whose source grew or shrank since the listing is not published. A record that still matches the previous snapshot is hardlinked and does not open the source. There are no retries. A crash leaves `<snapshot-name>.<pid>.partial` and the previous snapshots. The next run, after it holds the lock, removes direct child directories ending in `.partial` and appends nothing to them.

**Two backup folders do not share inodes.** The hardlink source and the hardlink target are both under one destination. The gate checks that two destinations on one filesystem still have different inode numbers for the same unchanged file.

**Bytes stay raw.** A filename byte that is not UTF-8 is copied unchanged into the snapshot name and into the dry-run line. Stderr writes tab, newline, and carriage return inside a path as `\t`, `\n`, and `\r`.

**Two runs may write different destinations.** They may not write the same one. The lock is per destination. There is no time-based stale lock. A long copy keeps its lock.

**ACLs, xattrs, and holes are out of scope.** A new copy is a byte stream, so a hole is filled. The hard link preserves whatever the previous inode already stored, including a hole that was in that inode, because it is the same inode.

## Shared behavior

Failure stderr is one line, `casually_backup: <reason>`, and a non-zero exit. No stack trace on the console. Success of a real run writes nothing to stdout. Warnings are the owner line and the `left` lines.

| Code | Reason |
| --- | --- |
| 0 | Every destination has its new snapshot renamed into place. Specials in an older snapshot may have been warned about |
| 1 | Usage, config, a plan refusal, a live lock, a snapshot name that already exists, or the mass-omission stop. No snapshot was published |
| 2 | The previous scan failed, or apply failed, or the operator aborted. No snapshot directory from this run was renamed. A partial directory may remain |

There is no exit 3. A snapshot name that already exists is exit 1, before the build.

## Phase 1 — Toolchain and entry point

**Difficulty:** easy. **Depends on:** nothing.

Prove the runtime, and land an executable `casually_backup.lua` whose first line is `#!/usr/bin/env lua`. The first check after the shebang is `_VERSION == "Lua 5.5"`. Any other value prints `casually_backup: need Lua 5.5` and exits 1 before `require`. The script prepends the same `/usr/local` and `$HOME/.luarocks` paths the indexer prepends, before `require`. It loads `lfs`, `dkjson`, and `terminal`.

Phase 1's `main` treats a well-formed command as empty success and does not open the listing. Phase 2 replaces that path.

**Gate.** `test/run.sh backup 1` checks Lua 5.5, the three `require`s, the shebang, and the executable bit, with `LUA_PATH`, `LUA_CPATH`, and `LUA_INIT` unset. `chmod --version`, `chown --version`, and `xargs --version` each exit 0. `--version` prints three lines and exits 0 on a terminal and on a pipe. `--help` prints the four forms and exits 0. Every row in the usage table exits 1 with that stderr line and empty stdout. Repeated `--dest` and repeated `--source-map` are accepted by `parse_args`. `--dry-run`, `--omit-limit`, and `--omit-fraction` are accepted on both forms. The gate does not run a well-formed command: `main` opens the config and checks the paths. A direct `dofile` does not run `main`. `test/run.sh` with no arguments still runs the indexer gates and does not run `test/backup_phase1.lua` as an indexer phase. Update the status table and the work log.

## Phase 2 — Config

**Difficulty:** medium. **Depends on:** phase 1.

The loader turns a parsed command into a checked config. Parse failures and every rejection below are class `config`. This phase does not parse listing bytes and does not walk a destination past an `lstat` of the destination itself. It does not look inside `_Base`.

Checks, in an order the failure line can name:

- The JSON file parses as an object. Unknown keys fail.
- `index` is a string and passes the path rules. `lstat` is a regular file. The final component does not end in `.partial`.
- `destinations` is a non-empty array of strings. Each passes the path rules, is not `/`, and `lstat`s as a real directory. Each is writable by the probe. The probe is gone after the check.
- No destination is equal to another or a path-prefix of another. The listing path is not inside any destination.
- `source_map` omitted, empty, or an array of `{alias, path}`. Both strings pass the path rules. Map path `lstat`s as a real directory. Map aliases do not overlap. Alias `/` only as the sole entry.
- `exclude` omitted, empty, or an array of absolute prefixes. `/` is rejected. Excludes are not required to exist.
- `omit_limit` omitted or an integer `>= 0`. `omit_fraction` omitted or a number from 0 through 1. The flags override the file when both are present.
- `workers` omitted or an integer from 1 through 64. Omitted means 4. `--workers` overrides the file.
- The flag form gets the same path checks: relative `--index`, relative `--dest`, missing directory, destination `/`, nested destinations, `--index` inside a destination, `--source-map` without `=`, a map path that is a symlink.

The returned config carries normalized strings, the map, the exclude list, and the two omission numbers.

**Gate.** `test/run.sh backup 2` builds temp directories and runs one JSON config per rejection plus one valid config with two destinations, a map, an exclude, and the default omission numbers. Each rejection exits 1, names the reason on one stderr line, and leaves the destination tree unchanged. Rejections include a destination chmod `555` (restored by cleanup), a symlink used as a destination, a listing path that ends in `.partial`, nested destinations, and an unknown JSON key. One valid `--index`/`--dest`/`--dest` command returns two destinations and an empty map. `--omit-limit 50` overrides the JSON. The phase 2 gate does not run the entry point on a valid config, because later phases will apply. `test/run.sh backup 1` still passes.

## Phase 3 — Listing parser

**Difficulty:** medium. **Depends on:** phase 1. Independent of the destinations.

`parse_listing` is pure Lua. The gate builds lines with `casually_index.lua`'s `format_line` by `dofile`, then parses them back. The decoded path, kind, size, mtime text, mode text, owner text, and target equal the record that was formatted. That includes a target of `-`, a target whose bytes are `\` and `-`, a tab in the path, a newline in the path, and a path containing the byte `0xFF`.

Further rejections, each `nil, err, "config"`: no trailing newline, empty file, seven fields, a bad mtime, a bad mode character, a symlink size that is not the target length, a bare `-` target on a link, a normal line containing `\`, an unknown bang escape, a relative path, a `..` component, a duplicate path, a path that sorts earlier than the previous path, a file whose parent directory record is missing, a non-root directory whose parent directory record is missing, a directory whose parent record is a file, and a root record that is not a directory. One directory record `/fvl/a` and nothing else is accepted. A directory, a sibling that sorts between that directory and a later child, and that child are accepted.

The mtime round trip covers `20261008:143015`, `20260101:000000`, `20260701:120000`, `20260705:180030`, and `20260705:180036`. Each parsed second formats back to that text with `os.date` in UTC.

A helper exposed to later gates takes a listing filename and returns the stamp `YYYYMMDD-HHMM`, or nil when the final component is not `index-YYYYMMDD-HHMM.listing`.

**Gate.** `test/run.sh backup 3` is the cases above. No destination tree. `test/run.sh backup 1` and `backup 2` still pass.

## Phase 4 — Plan

**Difficulty:** hard. **Depends on:** phases 2 and 3.

`plan(config)` returns the per-destination snapshot names, action lists, warnings, and counts, or `nil, err, class`. It does not create or remove user files. The test seam `plan(config, fs)` supplies a fake filesystem for the mount, the unreadable directory, and the foreign-device previous snapshot, and an euid so the owner branch does not depend on the user running the gate. euid 0 compares owner. Any other euid skips owner and records the single owner warning. The real filesystem is LuaFileSystem.

**Gate.** `test/run.sh backup 4` builds a temp source tree and a listing from `format_line` plus real `lstat` data, and two destination folders. The listing filename `index-20261008-1430.listing` produces stamp `20261008-1430`.

| Case | Result |
| --- | --- |
| empty dest, a file and its parent dir | snapshot `_Base`, `mkdir` and `copy`, `read=1`, `omit=0` |
| `_Base` present and matching, on one dest only | that dest snapshots `20261008-1430` with `hardlink` and `read=0`. The empty dest still snapshots `_Base` with `copy` and the shared `read=1` |
| `_Base` matching on size and mtime, mode different | `copy`, not `hardlink` |
| symlink target matches | `hardlink`, source file not read |
| symlink target differs | `symlink` |
| file present in `_Base`, absent from the listing, under the limit | `omit`, and the action is not a delete |
| omissions over the limit and over the fraction | class `plan`, exit 1 |
| omissions over the limit and under the fraction | plan allowed |
| stamp directory already present | class `plan`, exit 1, tree unchanged |
| fifo inside `_Base` | warning `left`, not an omission |
| exclude covering a listing directory | no create for that subtree. Paths under it in the previous snapshot are omissions and are not descended |
| destination nested under a resolved source directory | class `plan` |
| source map prefix | `copy` prints the mapped source and the snapshot path under the listing prefix |
| unreadable `_Base` | class `scan`, no actions |
| previous snapshot on a different device | class `plan` |
| exclude that removes every record | class `plan`, `exclude covers the listing` |

The omission numbers in the gate are concrete: 3 desired records, limit 1, fraction 0.02, 2 omissions, refused; the same with fraction 0.9, allowed because 2 is not greater than 0.9 times 3. `test/run.sh backup 1`, `2`, and `3` still pass.

## Phase 5 — Apply

**Difficulty:** hard. **Depends on:** phase 4.

`apply` performs the plan. A seam wraps source `open`/`read` so the gate can count reads and inject a short file. Another seam fails a write on the second destination only.

**Gate.** `test/run.sh backup 5`. Listings use `index-20261008-1430.listing` and then `index-20261009-0900.listing`.

- Empty destinations create `_Base` only. Two destinations receive the same new file from one source open. Inode numbers differ across the destinations. Bytes, UTC mtime, and mode match. A partial directory is not left behind.
- A second run, with one file unchanged and one file changed, creates `20261009-0900`. The unchanged file has the same inode as `_Base` and `nlink >= 2`. The changed file has a new inode. `_Base`'s changed file keeps its old inode, bytes, and mtime. The source is opened once, for the changed file only. A third run whose listing matches the second run hardlinks the changed file to the `20261009-0900` inode, and the unchanged file still shares the `_Base` inode. The third run opens no source file.
- Two destinations on one filesystem still have different inodes for the unchanged file.
- A mode-only change is a new inode. `_Base` keeps the old mode.
- A zero-byte file is copied, then hardlinked on the next run.
- A symlink, including a dangling one and a target of `-`, is created with that exact target. The next run hardlinks it: the new path is still a symlink, with the same inode, and the target file's mode is unchanged.
- A name containing a tab is created from a bang line.
- A path omitted under the limit is absent from the dated snapshot and still present in `_Base`.
- Source longer or shorter than the listing: exit 2, the dated directory is absent, `_Base` is unchanged, the partial directory remains.
- Write error on the second destination: neither snapshot is renamed, exit 2.
- Omission refusal: exit 1, no dated directory, `_Base` unchanged, no lock left behind.
- Stamp already present: exit 1, no partial directory left behind.
- Dry-run: stdout matches the action list and the `plan` line, no snapshot created, no lock directory left.
- A live lock: exit 1, destination unchanged.
- A stale lock whose pid is dead: the run proceeds.
- A leftover `<name>.<pid>.partial` directory is removed and is not published.
- Non-root seam: stderr has `owner not applied`, `chown` is not called, and a later run still hardlinks.
- Root seam, or a fake chown that records its arguments: the uid and gid are the resolved numbers, the command is `chown -h`, and the paths are inside the partial directory. An owner-only change is a new inode. The old snapshot's owner is unchanged.
- `chmod` is invoked via the NUL batch on new inodes only. A path containing a space and a path containing a newline both arrive intact. The mode bits of a setuid file match. A hardlinked file is not in the batch.
- `q` is phase 6. This gate does not require a terminal.

`test/run.sh backup 1` through `4` still pass.

## Phase 6 — Screen

**Difficulty:** medium. **Depends on:** phase 5.

The panel is an observer. Headless apply already works. This phase adds the paint and the abort.

**Gate.** `test/run.sh backup 6` runs headless against a tree shaped like the phase 5 fixture. Stdout is empty, `_Base` matches, and a dated snapshot hardlinks the unchanged file. A newline in a warned path is one physical stderr line. A Lua test checks middle-clip on a short path, a long path, and a path containing a tab, and checks the unit labels for 512 B, 1536 B, and 10 KiB. The elapsed formatter turns 67 seconds into `0:01:07`. The terminal half is a pty. The operator note recorded in the work log must show the status counts moving, the elapsed seconds advancing while a copy is open, a line settling from the spinner to `C` or `S`, `q` leaving the dated directory unpublished and leaving `_Base` unchanged, exit 2, stderr `casually_backup: aborted`, and a finished run whose rates lines show the copied-byte total. The `left` warning is on stderr after restore. If `readansi(0)` blocks, record the lesson and use a 1ms timeout. `test/run.sh backup 1` through `5` still pass.

## Phase 7 — Acceptance

**Difficulty:** medium. **Depends on:** phases 1 through 6.

No new behavior. One fixture covers the contract a backup folder can be trusted for, and the exit codes.

`test/run.sh backup 7` creates a source tree, builds listings with the indexer's `format_line` and real metadata, and runs the entry point. The first listing is named `index-20261008-1430.listing`. The second is `index-20261009-0900.listing`.

| Case | Exit | Result |
| --- | --- | --- |
| Two destinations, a file, a directory, a symlink, a dangling symlink, a dotfile, an exclude, a bang name | 0 | Each destination has `_Base` and no dated folder. Inodes differ across destinations. Stdout empty |
| Second listing, one file unchanged, one file changed, one path dropped under the limit | 0 | `20261009-0900` shows the full remaining tree. Unchanged file shares the `_Base` inode. Changed file is new. Dropped path remains in `_Base` and is absent from the date. Source opened once |
| Third listing identical to the second | 0 | New date hardlinks both files. Source is not opened |
| `--source-map` | 0 | Bytes read from the mapped tree. Snapshot paths still use the listing prefix |
| `--dry-run` on a second snapshot | 0 | Action list includes `hardlink` and the published date path. Trees unchanged |
| Bad listing, nested destinations, exclude of `/`, destination inside the source, stamp already present | 1 | No snapshot published, one stderr line |
| Omissions over both thresholds | 1 | `_Base` unchanged, dated directory absent |
| Unreadable `_Base` | 2 | No dated directory |
| Source size changed after the listing | 2 | `_Base` unchanged, dated directory absent, partial directory remains |
| `--index` path already a directory, unknown flag, `--config` mixed with `--dest` | 1 | The usage or config line, stdout empty |

Plus: a filename containing `0xFF` is created, a target of `-` round-trips, mode `drwxr-xr-x` and a setuid file match `lfs` inside `_Base`, a later mode change does not alter `_Base`, and a non-root seam skips `chown`. The phase 6 pty remains the terminal check.

When this gate passes, set phase 7 to `done` and stop.

## Coverage

| Rule | Phase |
| --- | --- |
| Command forms, help, version, usage errors, Lua 5.5, libraries, GNU metadata tools | 1 |
| Config, destinations, source map, exclude, omission numbers, probes | 2 |
| Listing parse, bang escapes, `\-`, mtime round trip, parent records, stamp helper | 3 |
| `_Base` or dated snapshot, previous snapshot, hardlink or copy, mass-omission stop | 4 |
| One source read, per-destination hardlinks, partial directory, rename publish, locks, dry-run | 5 |
| Screen and abort | 6 |
| Exit codes 0, 1, 2, history left intact, two folders do not share inodes | 7 |
