# Casually

A pair of Lua 5.5 scripts for efficient remote filesystem backup. The name is an anagram of "LuaSync" — because why settle for predictable names?

Why Lua? No particular reason. Just been using it for a few projects and thought it would make a nice fit for here.

## Overview

When you have a large remote filesystem and need multiple local copies, `rsync` and friends can be slow because they scan over the network. Casually takes a different approach:

1. **`casually_index.lua`** runs on the remote host, walks your directory trees, and writes a flat sorted listing file (paths, mtimes, permissions, sizes, owners).
2. You transfer just the listing file (compressed with `brotli`, it's tiny).
3. **`casually_backup.lua`** reads the listing on your local machine, compares it against existing snapshots, and copies only the files that changed — into as many backup folders as you want.

For a large filesystem with hundreds of thousands of files where only a few small files change daily, this is ideal. Virtually no network traffic except for the changed files.

```
┌─────────────────┐     ┌────────────────┐     ┌─────────────────┐
│  Remote host    │     │  Listing file  │     │ Local backup    │
│                 │     │  (transfer)    │     │ destinations    │
│ casually_index  │────>│  brotli -c     │──>  │                 │
│   walk dirs     │     │  scp/ssh       │     │ casually_backup │
│   write listing │     │                │     │   copy changed  │
└─────────────────┘     └────────────────┘     └─────────────────┘
```

## Quick Start

```bash
# Remote: build a listing of /srv/data
./casually_index.lua --source /srv/data --index /tmp/index.list

# Local: back up to three destinations using that listing
./casually_backup.lua \
    --index /tmp/index.list \
    --dest /backups/primary \
    --dest /backups/secondary \
    --dest /backups/offsite
```

Or use a JSON config file for repeatable, multi-root setups:

```bash
./casually_backup.lua --config /etc/casually/my-backup.json
```

## Documentation

| Document | Description |
|----------|-------------|
| [Index](INSTRUCTIONS-INDEX.md) | How to generate listings: `casually_index.lua` CLI flags, JSON config, listing format, exclude patterns. |
| [Backup](INSTRUCTIONS-BACKUP.md) | How to run backups: `casually_backup.lua` CLI flags, JSON config, source_map remapping, report output, exit codes. |
| [Developers](DEVELOPERS.md) | Developer guide to the Lua source: shared module pattern, listing format, plan/apply/perform pipeline, worker pool, test phases, the `dir.c/dir.c` fix, and Lua idioms. |

## Requirements

- **Lua 5.5**
- LuaRocks packages: `lua-filesystem`, `dkjson`, `terminal`, `lua-system`
- `brotli` (for compressing listings during transfer)

## Additional Notes

While this project is currently under active development, feel free to give it a try and post any issues you encounter. Or start a discussion if you would like to help steer the project in a particular direction. Early days yet, so a good time to have your voice heard. As the project unfolds, additional resources will be made available, including platform binaries, more documentation, demos, and so on.

## Repository Information
[![Count Lines of Code](https://github.com/500Foods/Casually/actions/workflows/main.yml/badge.svg)](https://github.com/500Foods/Casually/actions/workflows/main.yml)
<!--CLOC-START -->
```cloc
Last updated at 2026-10-10 22:19:18 UTC
-------------------------------------------------------------------------------
Language                     files          blank        comment           code
-------------------------------------------------------------------------------
Lua                             16           1035            195          14543
Markdown                         8            541              2           1263
Bourne Shell                     1             11              2             79
YAML                             2              8             13             37
-------------------------------------------------------------------------------
SUM:                            27           1595            212          15922
-------------------------------------------------------------------------------
2 Files were skipped (duplicate, binary, or without source code):
  gitattributes: 1
  gitignore: 1
```
<!--CLOC-END-->

## Sponsor / Donate / Support
If you find this work interesting, helpful, or valuable, or that it has saved you time, money, or both, please consider directly supporting these efforts financially via [GitHub Sponsors](https://github.com/sponsors/500Foods) or donating via [Buy Me a Pizza](https://www.buymeacoffee.com/andrewsimard500). Also, check out these other [GitHub Repositories](https://github.com/500Foods?tab=repositories&q=&sort=stargazers) that may interest you.
