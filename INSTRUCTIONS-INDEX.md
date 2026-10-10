# Casually Index Instructions

`casually_index.lua` walks one or more directory trees and writes a flat, sorted listing file. This listing is then copied to the backup side, where `casually_backup.lua` reads it to decide which files need copying.

## Requirements

- **Lua 5.5**
- LuaRocks packages: `lua-filesystem`, `dkjson`, `terminal`, `lua-system`
- Read (and in some cases execute) access to all root directories being walked

## Command Line

```
./casually_index.lua --config <file>
./casually_index.lua --source <root> --index <file>
./casually_index.lua --help
./casually_index.lua --version
```

| Flag | Description |
|------|-------------|
| `--config <file>` | JSON file with roots, work_dir, output_dir, and optional exclude. |
| `--source <root>` | Directory to walk. Requires `--index`. |
| `--index <file>` | Listing file to write. Requires `--source`. |
| `--help` | Show help and exit. |
| `--version` | Show script, Lua, and terminal.lua versions. |

You must use either `--config <file>` or `--source <root> --index <file>`. The two modes are mutually exclusive.

When using the flags form (`--source` / `--index`), `work_dir` is the parent of the index file and `output_dir` is also the parent, so no extra config is needed.

## JSON Config File

```json
{
  "roots": [
    { "path": "/srv/data/fst", "alias": "/fvl/fst" },
    { "path": "/srv/data/slw", "alias": "/fvl/slw" }
  ],
  "work_dir": "/var/lib/casually/festival",
  "output_dir": "/var/lib/casually/festival/listings",
  "exclude": [
    "/fvl/slw/tmp/*",
    "/fvl/fst/cache/*"
  ],
  "output_path": "/root/festival-20261009-0314.listing"
}
```

### Config Keys

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `roots` | Yes | array of objects | Directories to walk. Each entry has `path` (absolute filesystem path) and `alias` (the path prefix used in the listing). |
| `work_dir` | Yes | string | Working directory for partial files. Must be on the same filesystem as `output_dir`. |
| `output_dir` | Yes | string | Directory for the final listing file. Must be writable. |
| `exclude` | No | array of strings | Glob-style path patterns to skip during the walk. Patterns are matched against the alias-prefixed path. |
| `output_path` | No | string | Explicit output path for the listing. When omitted, the listing is named `index-<YYYYMMDD-HHMM>.listing` in `output_dir`. |

### Multiple Roots

Each root is walked and all records are merged into a single sorted listing. The `alias` is the prefix that appears at the start of each path in the listing. On the backup side, `source_map` in `casually_backup.lua` maps these aliases back to local paths.

### Output Path

By default, the listing file is named `index-<stamp>.listing` where `<stamp>` is derived from the current time (`YYYYMMDD-HHMM`). If `output_path` is set, that path is used verbatim and no timestamp is appended.

## How It Works

1. **Walk roots.** Each directory tree is traversed depth-first. Files, directories, and symlinks are recorded.
2. **Resolve owners.** Numeric UIDs and GIDs are resolved to name strings via `getent passwd` and `getent group`.
3. **Remap paths.** Full filesystem paths are rewritten to use the root's alias prefix (e.g. `/srv/data/fst/photos/img.jpg` becomes `/fvl/fst/photos/img.jpg`).
4. **Sort.** All records are sorted by remapped path.
5. **Write listing.** The sorted records are written as a flat text file, one entry per line, then renamed into place atomically.

### Listing Line Format

Each line is tab-separated:

```
{mtime}	{user}:{group}	{perms}	{size}	{link}	{path}
```

For example:

```
20261009:031422	photos:photos	-rw-r--r--	1024	-	/fvl/fst/photos/img.jpg
20261009:031422	root:wheel	drwxr-xr-x	4096	-	/fvl/fst/photos
20261009:031422	www-data:www-data	lrwxr-xr-x	7	../secret	/fvl/fst/link
```

Field details:

| Field | Description |
|-------|-------------|
| **mtime** | `YYYYMMDD:HHMMSS` in UTC. If the path or symlink target contains a tab, backslash, newline, carriage return, or leading space, the line is prefixed with `!`. |
| **user:group** | Owner and group names. Falls back to numeric IDs if names cannot be resolved. |
| **perms** | 10-character permission string: type char (`-` file, `d` dir, `l` link) + 9 rwx characters. Supports setuid/setgid/sticky bits (shown as `s`/`S`/`t`/`T` in the appropriate position). |
| **size** | File size in bytes for regular files. For directories and links, the size from `lfs` attributes is used. |
| **link** | Symlink target path, or `-` for non-links. Targets containing special characters are backslash-escaped. |
| **path** | The alias-remapped absolute path. Paths with special characters are escaped. |

### Special Character Escaping

When a path or symlink target contains a tab (`\t`), backslash (`\`), newline (`\n`), carriage return (`\r`), or leading space, the listing line is prefixed with `!`. The affected fields are backslash-escaped so the line can be parsed unambiguously. The backup side (`casually_backup.lua`) detects the `!` prefix and unescapes the fields automatically.

Lines without special characters are written verbatim with no `!` prefix.

### Exclude Patterns

Exclude uses prefix matching — a pattern `/fvl/slw/tmp/*` excludes any path under `/fvl/slw/tmp/`. The `work_dir` and `output_dir` must not sit inside any root, and the roots must not overlap (one root cannot be a parent of another).

## Bash Wrapper Example

```bash
# Walk directories and build a listing
HOME=/home/asimard "$lua" "/mnt/extra/Projects/Casually/casually_index.lua" \
    --config /etc/Casually/festival-index.json

# The listing is written to output_dir/index-YYYYMMDD-HHMM.listing
# Compress and transfer it to the backup site
brotli -c "$listing" | ssh root@vpn "cat > /root/festival-$(date -u +%Y%m%d-%H%M).listing.brotli"
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `1` | Failure (config error, walk error, I/O error, etc.). |
