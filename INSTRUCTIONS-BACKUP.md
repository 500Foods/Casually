# Casually Backup Instructions

`casually_backup.lua` reads a finished listing (produced by `casually_index.lua`) and makes one snapshot directory per destination. It only copies files that are new or changed, based on the listing's mtime and CRC32 hash.

## Requirements

- **Lua 5.5**
- LuaRocks packages: `lua-filesystem`, `dkjson`, `terminal`, `lua-system`
- Read access to the source paths referenced by the listing and `source_map`
- Write access to every destination directory

## Command Line

```
./casually_backup.lua --config <file>
./casually_backup.lua --index <listing> --dest <dir> [--dest <dir>...] [--source-map <alias>=<path>...]
./casually_backup.lua --help
./casually_backup.lua --version
```

| Flag | Description |
|------|-------------|
| `--config <file>` | JSON file with the listing, destinations, and optional limits. |
| `--index <listing>` | Finished listing to read. Requires `--dest`. |
| `--dest <dir>` | Backup folder. Repeat for another folder. Requires `--index`. |
| `--source-map <alias>=<path>` | Read one listing prefix from another directory. Requires `--index`. |
| `--dry-run` | Print the plan and change nothing. |
| `--omit-limit <n>` | Refuse a snapshot that drops more than *n* paths. Default `1000`. |
| `--omit-fraction <number>` | Refuse a snapshot that drops more than this fraction. Default `0.02`. |
| `--workers <n>` | Copy files with *n* processes. Default `4`. Range `1`–`64`. |
| `--report <email>` | Print a backup summary to stderr after running. |
| `--report-dir <dir>` | Write detailed report lines to `<dir>/<stamp>.log` instead of stderr. |
| `--help` | Show help and exit. |
| `--version` | Show script, Lua, and terminal.lua versions. |

You must use either `--config <file>` or `--index <listing> --dest <dir> ...` on the command line. The two modes are mutually exclusive.

## JSON Config File

When you use `--config <file>`, the config is a JSON object:

```json
{
  "index": "/var/lib/casually/festival/index-20261009-0314.listing",
  "destinations": [
    "/run/media/asimard/BigA/Backups/Casually-fvl",
    "/run/media/asimard/BigB/Backups/Casually-fvl",
    "/run/media/asimard/Offline Backup/Backups/Casually-fvl"
  ],
  "source_map": [
    { "alias": "/fvl/fst", "path": "/mnt/fvl/fst" },
    { "alias": "/fvl/slw", "path": "/mnt/fvl/slw" }
  ],
  "exclude": [
    "/fvl/slw/tmp/*",
    "/fvl/fst/cache/*"
  ],
  "omit_limit": 1000,
  "omit_fraction": 0.02,
  "workers": 4,
  "report": "andrew@500foods.com",
  "report_dir": "/var/lib/casually/festival/reports"
}
```

### Config Keys

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `index` | Yes | string | Path to the finished listing file. |
| `destinations` | Yes | array of strings | Backup folder paths. Each must be a real, existing directory. |
| `source_map` | No | array of objects | Remap listing aliases to local paths. Each entry has `alias` (the prefix in the listing) and `path` (the local directory to read from). |
| `exclude` | No | array of strings | Glob-style patterns; paths matching these are skipped during backup. |
| `omit_limit` | No | integer | Refuse to publish a snapshot if more than this many paths would be dropped. Default `1000`. |
| `omit_fraction` | No | number | Refuse to publish a snapshot if dropping more than this fraction of tracked paths. Default `0.02`. |
| `workers` | No | integer | Number of copy worker processes. Default `4`, range `1`–`64`. |
| `report` | No | string | Email address. When set, a summary is printed to stderr after a successful run. |
| `report_dir` | No | string | Directory for detailed report logs. A file named `<stamp>.log` is written here. |

### Multiple Destinations

Each destination gets its own snapshot subdirectory. The same set of changed files is copied to every destination independently. `bytes added` in the report is the unique bytes (total copy bytes divided by destination count).

### Source Map

The listing contains paths prefixed with aliases like `/fvl/fst` and `/fvl/slw`. On the backup machine these may not be mounted at those locations. `source_map` tells the backup script where to find each alias:

```json
{
  "source_map": [
    { "alias": "/fvl/fst", "path": "/mnt/fvl/fst" },
    { "alias": "/fvl/slw", "path": "/mnt/fvl/slw" }
  ]
}
```

### Exclude Patterns

Exclude uses the same glob-style patterns as the listing. Patterns match path prefixes — a pattern `/fvl/slw/tmp/*` excludes any path under `/fvl/slw/tmp/`.

## How It Works

1. **Parse the listing.** Each line is either a regular file entry or a verification entry (prefixed with `!`).
2. **Compare against existing snapshot.** If a destination already has a snapshot with the same stamp, it is skipped. Otherwise the listing is diffed against the most recent prior snapshot.
3. **Plan copies.** Files listed as new or changed (different mtime or CRC32 mismatch) are queued for copy. Files with changed mtime are always re-copied in full — there is no block-level dedup.
4. **Copy files.** Up to `workers` processes copy files concurrently into each destination's snapshot directory.
5. **Publish snapshot.** The new snapshot is moved into place and the `current` symlink is updated atomically.

### Listing Line Format

Each non-verification line in the listing is tab-separated:

```
{mtime}    {user}:{group}    {perms}    {size}    {link}    {path}
```

- **mtime** — `YYYYMMDD:HHMMSS` (UTC), or `!` + CRC32 hash when hash verification is requested.
- **user:group** — owner and group names (or numeric IDs).
- **perms** — 10-character string: type character (`-` for file, `d` for dir, `l` for link) followed by 9 permission characters (e.g. `rwxr-xr-x`).
- **size** — file size in bytes.
- **link** — symlink target, or `-` for non-links.
- **path** — the file path relative to the listing root alias.

Lines whose first field starts with `!` trigger CRC32 hash verification on the backup side. If the hash does not match, the file is scheduled for copy.

## Report Output

When `--report` and/or `--report-dir` are used, a summary is printed:

```
=== casually_backup report ===
stamp:            20261009-0314
elapsed:          0:02:26
files added:      3012
bytes added:      253 MiB
files tracked:    603487
bytes tracked:    93 GiB
destinations:     3
warnings:         230
details log:    /var/lib/casually/festival/reports/20261009-0314.log
230 warnings in 2 groups:
  read error: 226 instances
    - cannot read /mnt/fvl/slw/tnt/t-500nodes: 226 instances
  size mismatch: 4 instances
    - source is longer than the listing: /mnt/fvl/slw/tnt/t-500nodes: 3 instances
    - source is shorter than the listing: /mnt/fvl/slw/tnt/t-500nodes: 1 instances
=== end report ===
```

Warnings are grouped by type and by the first 6 path segments of the affected file, so related errors are easy to spot. Common warning types:

- **read error** — the source file could not be read (permissions, I/O error, missing mount).
- **size mismatch** — the source file size differs from what the listing recorded.
- **skipped source** — the source path does not exist.

## Bash Wrapper Example

In production, a bash script fetches the listing over SSH, builds the config JSON, and invokes the backup:

```bash
# Fetch the latest listing from the remote host
ssh root@vpn 'cat /root/festival-*.listing.brotli' | brotli -d -c > "$local_listing"

# Build config JSON and run the backup
HOME=/home/asimard "$lua" "$prog" --config "$cfg" \
    --report "$report_to" --report-dir "$report_dir"

# Point symlinks at the new snapshot
ln -sfn "$stamp" "$dest/current"
```

See `festival-backup.sh` for the full production wrapper.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `1` | Failure (config error, I/O error, etc.), or snapshot already exists. |
