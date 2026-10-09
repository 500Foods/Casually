# fvl-index

Build a complete, sorted listing of one or more directory trees, with each tree's real prefix rewritten to an alias. The listing is a point-in-time index of names and metadata. It is not a changelog, not a copy of the file contents, and not a Ceph-specific tool. A backup runner consumes the finished file; this program only produces it.

The walker is Lua. One process, `readdir` and `stat` through a C binding such as LuaFileSystem. No per-file fork. Interpreter choice is not the bottleneck; keeping the stitch map, the field rules, and the sort in one script is the point.

## Config

One JSON file, path given as the only argument. No environment variables, no second config.

```json
{
  "roots": [
    { "path": "/mnt/ceph-a", "alias": "/fvl/a" },
    { "path": "/mnt/ceph-b", "alias": "/fvl/b" }
  ],
  "work_dir": "/var/lib/fvl-index",
  "output_dir": "/var/lib/fvl-index",
  "exclude": []
}
```

`roots` is required and non-empty. Each entry:

- `path` is the real directory to walk. It must exist, must be a directory, and is normalized by removing any trailing slash. A `path` of `/` is rejected.
- `alias` is the prefix written into the listing. Normalized the same way, then treated as an absolute path. `/fvl` and `/fvl/` are the same alias. The alias is what a consumer mounts or copies against; it does not have to exist on the machine running the indexer.

`work_dir` is where the temporary file is created. `output_dir` is where the finished listing is renamed to. Both are required, both must already exist, both must be directories. They may be the same directory. Neither may lie inside any `path`: a listing must not become part of the tree it describes.

`exclude` is optional. Each entry is a path prefix in alias form, compared against the remapped path. `/fvl/a/.snap` skips that directory and everything under it. Empty or omitted means exclude nothing. Matching is by whole path component, so `/fvl/a/.snap` does not skip `/fvl/a/.snapshot`.

Reject the config before walking if:

- two `path` values are equal, or one is a prefix of another
- two `alias` values are equal, or one is a prefix of another
- a `path` or `alias` is relative, empty, or contains `.` or `..` as a component
- `work_dir` or `output_dir` is missing, not a directory, or sits inside a root

Overlapping roots would make one file able to appear twice, or make the longer-prefix rule a silent dependency. Fail instead.

## Walk

For each root, walk `path` depth-first or breadth-first; order does not matter because the output is sorted afterward. Do not follow symlinks. Do not cross into a different filesystem (`st_dev` changes); record the mount point as a directory and do not descend. A symlink to another filesystem is still recorded as a symlink.

Include every directory, regular file, and symlink, including dotfiles. Include the root itself, remapped to its alias (`/mnt/ceph-a` becomes `/fvl/a`). Skip anything else (fifo, socket, device, whiteout). Count each skipped inode and print a one-line warning to stderr with the remapped path and the type. Do not fail the run for those.

Do not open file contents. `lstat` only. Symlink metadata comes from the link, not from its target.

Uid and gid are resolved to names on the machine running the indexer. Both ends mount the same trees and use the same directory, so the names match. If a uid or gid has no name, write the decimal number. Do not fail.

## Remapping

Strip the matched `path` prefix and prepend the `alias`. Join with exactly one slash. No trailing slash on any output path, including directories.

`/mnt/ceph-a` with alias `/fvl/a` produces `/fvl/a`. `/mnt/ceph-a/docs/readme` produces `/fvl/a/docs/readme`. The alias is a string prefix, not a chroot: a symlink target is not remapped. Targets are recorded exactly as stored, because a relative target is relative to the link's directory and an absolute target is only meaningful to the consumer.

## Output file

Name: `index-YYYYMMDD-HHMM.listing`, UTC, from the time the walk started. Minute resolution is only in the name. Two runs in the same minute must not clobber: if the name exists, fail rather than overwrite.

Write to `work_dir/index-YYYYMMDD-HHMM.listing.partial`. When the walk and the sort finish, `fsync` the file and rename it into `output_dir`. Same directory or not, rename is the publish step. A consumer must ignore `*.partial`. A crashed run leaves a partial file and no new listing; the next run does not append to it.

The listing is the full tree, not a delta against a previous listing. One line per inode-name. No header, no footer, no comments. UTF-8. Final line ends with a newline.

Sorted by remapped pathname, byte order, as `LC_ALL=C` sort would do it. `readdir` order is not name order and must not be relied on. Sort after the walk, in Lua or by feeding the partial file through `sort`.

## Line format

Seven fields, tab-separated. The path is last so that a space in a name is not a separator.

```text
mtime  user:group  mode  size  link  path
```

| Field | Meaning |
| --- | --- |
| mtime | Modification time, UTC, `YYYYMMDD:HHMMSS`. Second resolution. Fixed width, 15 characters. |
| user:group | Names, or decimal ids if unresolved. One field. Neither side may contain a colon, a tab, or a space; if a name does, substitute the decimal id. |
| mode | Ten characters, `ls -l` style. First character is the type. |
| size | `st_size` in bytes, decimal, no separators. For a symlink this is the length of the target string. For a directory it is whatever the filesystem reports and is not content. |
| link | `-` if this is not a symlink. Otherwise the target text, exactly as stored, escaped with the rules below. |
| path | Remapped path, escaped with the same rules. |

Mode, first character: `-` regular file, `d` directory, `l` symlink. The next nine are `rwxrwxrwx` with the usual overlays: `s` or `S` for setuid/setgid, `t` or `T` for sticky. Examples: `-rw-r--r--`, `drwxr-xr-x`, `lrwxrwxrwx`.

A symlink is unambiguous because the mode starts with `l` and the link field is not `-`. The backup runner recreates it with the link field and does not read a target through `/fvl`. A symlink whose target text is exactly `-` is written as `\-`, so a dash always means "not a symlink".

mtime is the change signal, paired with size and, for symlinks, the target. Second resolution is intentional. Two writes in the same second with the same size are one version as far as this index is concerned. Do not emit fractional seconds.

### Escaping

Paths and link targets are written raw when they contain none of tab, newline, carriage return, or backslash. If either field contains one of those, escape both fields and prefix the whole line with `!` (bang, then the tab that starts the first field). A consumer that does not understand `!` must reject the line, not truncate at the tab.

| Byte | Written |
| --- | --- |
| `\` | `\\` |
| tab | `\t` |
| newline | `\n` |
| carriage return | `\r` |

No other escapes. Spaces, quotes, and non-ASCII UTF-8 are written raw. A `!` line is still one record; the bang is a flag, not a field.

```text
20261008:143015	andrew:andrew	-rw-r--r--	4821	-	/fvl/a/docs/readme.txt
20261008:143016	andrew:andrew	drwxr-xr-x	6	-	/fvl/a/docs
20261008:090001	andrew:andrew	lrwxrwxrwx	11	../other/readme	/fvl/a/docs/link
!20261008:090001	andrew:andrew	-rw-r--r--	3	-	/fvl/a/odd\tname
```

## Stderr

Quiet on success. Warnings for skipped inode types, one per inode. On failure, one line to stderr and a non-zero exit. Do not write a partial listing's name to stdout. Stdout is unused; the listing is the file named by the config.

## Exit codes

| Code | Reason |
| --- | --- |
| 0 | Listing renamed into place |
| 1 | Bad config, or a root/alias/output check failed |
| 2 | Walk failed (unreadable directory, vanished root, I/O) |
| 3 | Output name already exists, or the rename failed |

A walk error is fatal. Do not publish a partial tree as if it were complete: a missing subtree looks like a mass delete to the consumer.

## What the consumer may assume

- Every path from the previous listing that is absent here was not present at walk time.
- Every path here was present at `lstat` time, which is sometime between walk start and walk end, not a single instant.
- The file is sorted by path, byte order.
- The alias prefixes are the paths to copy against. The indexer does not check that they exist on the consumer.
- User and group names came from the indexer's directory. Mode is the ten-character form above, not octal.
- A line starting with `!` uses the escapes above. No other line does.

The index and the bytes read later are not one snapshot. A file can change or disappear between the `lstat` and a later copy. That race belongs to the consumer.
