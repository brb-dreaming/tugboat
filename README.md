<p align="center">
  <img src="assets/logo.png" width="260" alt="Tugboat">
</p>

# Tugboat

A macOS menubar app that tells you, in English, what every listening port on your
machine actually is.

`lsof -iTCP -sTCP:LISTEN` will tell you that pid 942 is holding port 44960. It
won't tell you that's Logitech's mouse daemon and you shouldn't kill it, or that
the thing on 3000 is the branch you were reviewing on Tuesday and you can.
Tugboat asks a model that question once per server, caches the answer, and shows
you the result grouped by what things belong to.

## What it does

- **Scans** every listening TCP port every 4 seconds (`lsof`), with pid, command,
  argv, cwd, memory, CPU, uptime and live connection count.
- **Describes** each one in a sentence you can act on, and says whether it's safe
  to kill. Cached to disk per port fingerprint, so you pay for it once.
- **Groups** related ports together in a second pass — five ports out of one
  monorepo become one card, because a per-port view can't see that.
- **Acts**: open in browser, re-ask what something is, or quit it. Every
  destructive action asks twice.

Two wordings, switchable live: **simple** (for anyone) and **technical**
(for you). Two surfaces: **glass** (Liquid Glass, macOS 26+) and **tinted**.

The menubar icon is a tugboat on the water. The sea gets choppier the more CPU
the listening processes are using between them, so a glance tells you something
woke up before you've opened anything.

## Build

No Xcode project — one file, one compiler invocation.

```sh
./build.sh     # swiftc -O -o Tugboat Tugboat.swift
./Tugboat
```

Requires macOS 26+ for the glass surface (it falls back to the tinted one below
that), and the `claude` CLI on your PATH for descriptions. Without the CLI
everything still works; rows fall back to what the process itself says it is.

### Headless

A running SwiftUI app can't be screenshotted from a shell, so the two things
worth verifying have their own entry points:

```sh
./Tugboat --scan --describe --group    # print what the menubar would show
./Tugboat --icon /tmp/boat             # dump menubar icon frames to PNG at 8x
```

`--simple` / `--technical` override the saved wording for one run.

## Notes

- Descriptions are cached at `~/.claude/ports-cache-v2.json`, keyed by a
  fingerprint of the process rather than the port, so a dev server that comes
  back on a different port is still recognised.
- Model calls run with `--strict-mcp-config --no-session-persistence`: one
  answer, no MCP servers booted, no transcript per description. A default
  `claude -p` is a whole interactive session in miniature, and one per port
  makes a menubar utility the heaviest thing on the machine.
- Sonnet first, Haiku if Sonnet is unreachable, and the row says which answered.
- Nothing is ever killed without a second click.
