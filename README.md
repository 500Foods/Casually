# Casually

This is a pair of Lua scripts used to make backups. The need came from having a remote filesystem that was large and physically far away, and wanting multiple local copies without having to fiddle with rsync or worry about all kinds of other issues. Instead, we build an index at the remote site, copy it over, and use that to build copies locally, retrieving only what has changed. So for a large filesystem with hundreds of thousands of files where only a few small files change daily, this is ideal. Virtually no network traffic except for the changed files. 

The name came from trying to come up with an anagram of LuaSync which is probably already taken and kind of boring.

## Additional Notes
While this project is currently under active development, feel free to give it a try and post any issues you encounter.  Or start a discussion if you would like to help steer the project in a particular direction.  Early days yet, so a good time to have your voice heard.  As the project unfolds, additional resources will be made available, including platform binaries, more documentation, demos, and so on.

## Repository Information 
[![Count Lines of Code](https://github.com/500Foods/Template/actions/workflows/main.yml/badge.svg)](https://github.com/500Foods/Casually/actions/workflows/main.yml)
<!--CLOC-START -->
```cloc
Last updated at 2026-10-08 17:22:47 UTC
-------------------------------------------------------------------------------
Language                     files          blank        comment           code
-------------------------------------------------------------------------------
YAML                             2              8             13             37
Markdown                         1              5              2             24
-------------------------------------------------------------------------------
SUM:                             3             13             15             61
-------------------------------------------------------------------------------
2 Files were skipped (duplicate, binary, or without source code):
  gitattributes: 1
  gitignore: 1
```
<!--CLOC-END-->

## Sponsor / Donate / Support
If you find this work interesting, helpful, or valuable, or that it has saved you time, money, or both, please consider directly supporting these efforts financially via [GitHub Sponsors](https://github.com/sponsors/500Foods) or donating via [Buy Me a Pizza](https://www.buymeacoffee.com/andrewsimard500). Also, check out these other [GitHub Repositories](https://github.com/500Foods?tab=repositories&q=&sort=stargazers) that may interest you.
