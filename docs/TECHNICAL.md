<p align="right"><b>English</b> · <a href="TECHNICAL.ru.md">Русский</a></p>

# clones: technical notes

For users, see the [README](../README.md). Why this mechanism was chosen: [RESEARCH.md](RESEARCH.md) (Russian).

## How it works

A profile is a separate Electron userData folder. clones starts Claude with
`--user-data-dir=<profile folder>`; Claude keeps cookies (sign-in), Local Storage, IndexedDB, cache,
settings and `claude_desktop_config.json` there. `app.asar` is not patched and Anthropic's signature
is not changed.

The `default` profile is plain Claude without flags (`~/Library/Application Support/Claude`).
It can be started, closed and given a launcher, but not removed or renamed.

Each profile consists of three things:

| What | Where | Why |
|---|---|---|
| Data | `~/.clones/<name>/` | userData: sign-in, chats, settings, cache, MCP config; `claude-code/` inside is the profile's Claude Code folder |
| Launcher | `/Applications/Claude <Name>.app` | A tiny bundle with a script calling `clones run <name>`; icon with a colored badge. For the Dock, Spotlight, Raycast |
| Claude.app copy | `~/.clones/.bundles.noindex/<name>/Claude <Name>.app` | So the running profile is called “Claude <Name>” in the Dock and ⌘Tab |

### Claude.app copies

The Dock and ⌘Tab show the name and icon of the bundle a process was started from, so each profile
is started from its own copy of Claude.app.

- The copy is byte-for-byte: `Info.plist`, binaries and resources are unchanged, and the `.app` folder
  name is not part of the signature. The signature and restricted entitlements stay valid and the
  Keychain behaves as with the original. clones runs `codesign --verify` after copying and removes
  the copy on failure.
- On APFS the copy is made with `clonefile`: instant and almost free until the first update.
- The badge icon is applied to the copy with `NSWorkspace.setIcon` and kept only if
  `codesign --verify` still passes.
- `.noindex` in the path keeps copies out of Spotlight.
- Squirrel updates a copy by itself, independently of the original; after an update it takes its own
  ~500 MB. `clones doctor` reports version drift; `clones update` and `clones app <name>` rebuild copies.
- `--no-copy` (on `add` and `app`) starts the profile with the original Claude.app.

### Background guard (`clones agent`)

macOS starts a copy pinned in the Dock (or opened from Finder) **without arguments**, and without
`--user-data-dir` it would run on the `default` data. The guard is the LaunchAgent `dev.clones.agent`
(`~/Library/LaunchAgents/dev.clones.agent.plist`, process `clones agent run`):

- it reacts to `NSWorkspace.didLaunchApplicationNotification` for Claude's bundle id and also polls
  every 2 s just in case;
- it SIGKILLs a profile copy running without `--user-data-dir` (before Electron writes much) and starts
  the profile properly, or focuses it if it is already running;
- it is installed automatically with the first copy; log: `~/Library/Logs/clones-agent.log`.

`clones agent` / `agent status` / `agent install` / `agent uninstall`.

### Processes

Claude's main process is recognized by its executable path (the original or a copy with the same
bundle id); argv is read with `sysctl(KERN_PROCARGS2)` rather than `ps`, so paths with spaces
(“Application Support”) do not merge. The profile is determined by `--user-data-dir` (paths are
compared after resolving symlinks); no flag means `default`.

Claude has no single-instance lock, so two processes on one folder would both start and corrupt the
data. `clones run` first looks for the profile's running process and focuses it (Apple Event “reopen”
plus `NSRunningApplication.activate`); `ls`/`doctor` show `CONFLICT`.

Launching uses `NSWorkspace.openApplication` with `createsNewApplicationInstance` (fallback: `open -n`):
without a new instance LaunchServices would just activate any running Claude with the same bundle id.

Quitting (`kill`) escalates: the “quit” Apple Event (like ⌘Q) → SIGTERM → SIGKILL only with `--force`.

## Commands and flags

| Command | Description |
|---|---|
| `add <name> [--color <hex>] [--icon <path>] [--title <s>] [--clone-mcp-from <p>] [--no-isolate-claude-code] [--no-app] [--no-copy]` | Profile, launcher and Claude copy. `--clone-mcp-from` copies only `mcpServers`. By default the profile gets its own `CLAUDE_CONFIG_DIR` (`<profile>/claude-code`) for the Code tab; `--no-isolate-claude-code` shares `~/.claude`. Names: Latin letters, digits, `-`, `_`, `.`; up to 32 characters |
| `ls [--json] [--no-size]` | Status, PID, size, MCP server count, launcher. `--json` adds `bundleCopy`, `bundleVersion`, `unmanaged`. Colors only in a terminal; `NO_COLOR` turns them off |
| `run <name>` | Start a profile or bring its window forward |
| `login <name> [-y] [--no-restore]` | Quit the other instances, start this one alone, restart the others after Enter |
| `kill <name> \| --all [--force] [--timeout s]` | Quit (waits 15 s by default) |
| `rm <name> [-f]` | Remove the profile, its data, launcher and copy; without `-f` asks first and refuses a running profile |
| `rename <old> <new>` | Rename; launcher and copy are rebuilt |
| `dir <name>` | The profile's data folder |
| `config <name> [--path]` | `claude_desktop_config.json` in `$VISUAL`/`$EDITOR` (otherwise TextEdit), then a JSON check |
| `app <name> \| --all [--color] [--icon] [--title] [--no-copy] [--remove] [-f]` | (Re)build the launcher and copy. `--all` covers `default` only if it already has a launcher. `--remove` removes the launcher and copy but keeps the profile |
| `install [-f] [--dir <path>]`, alias `update` | Download and install/update Claude Desktop (see below) |
| `agent [status\|install\|uninstall]` | Background copy guard |
| `doctor` | Diagnostics |
| `completion zsh\|bash\|fish` | Shell completion (profile names included) |

### `clones install`

- Version list: `https://downloads.claude.ai/releases/darwin/universal/RELEASES.json` (the same source
  as Homebrew's `claude` cask). Only `https` archive links on `claude.ai`/`anthropic.com` are accepted.
- The archive is downloaded with `curl` and unpacked with `ditto`.
- Before installing: `codesign --verify --deep --strict`, Team ID `Q6L2SF6YDW` and bundle id
  `com.anthropic.claudefordesktop` in the signature, `spctl --assess` (notarization). Any failure aborts.
- The previous Claude.app is put back if the replacement fails.
- All instances must be closed. Afterwards the copies of closed profiles are rebuilt; if the latest
  version is already installed, only outdated copies are rebuilt.

## Files

| Path | What |
|---|---|
| `~/.clones/<name>/` | the profile's userData |
| `~/.clones/<name>/claude-code/` | the profile's Claude Code folder (`CLAUDE_CONFIG_DIR`) |
| `~/.clones/.bundles.noindex/<name>/` | Claude.app copy |
| `~/.clones/.icons/` | copies of `--icon` pictures |
| `~/.clones/.config.json` | metadata: color, icon, launcher name, profile `env`, `claudeApp` |
| `/Applications/Claude <Name>.app` | launchers (bundle id `dev.clones.launcher.<name>`, `ClonesProfile` key in Info.plist). Old launchers in `~/Applications` are found and moved too |
| `~/Library/LaunchAgents/dev.clones.agent.plist`, `~/Library/Logs/clones-agent.log` | copy guard |

Dot names never clash with profiles, since a profile name must start with a letter or digit.
Early development builds kept data in `~/Library/Application Support/clones` and metadata in `~/.config/clones`;
the first run with no Claude instance open moves everything to `~/.clones` and fixes the paths
in the metadata (`LayoutMigration`). While an instance is open it keeps using the old place and says so.

Environment variables: `CLONES_CLAUDE_APP` (path to Claude.app), `CLONES_HOME` (instead of `~/.clones`),
`CLONES_APPS_DIR` (where launchers go), `CLONES_DEFAULT_USER_DATA`, `CLONES_LANG` (`en`/`ru`).
A profile's `env` field in `config.json` is passed to the Claude process (that is how the Claude Code isolation works). The terminal `claude` CLI is not affected: run it with `CLAUDE_CONFIG_DIR="<profile>/claude-code" claude` to use a profile's folder.

## Limitations

- **`claude://`.** All instances share one bundle id, so macOS hands a deep link to any of them.
  Regular and SSO sign-in go through `ASWebAuthenticationSession` and come back to the right process;
  Google sign-in, email links, MCP connector OAuth and “Open in app” go through `claude://`.
  If a sign-in link lands in another instance, that instance shows a sign-in code and the profile you
  wanted stays signed out. Hence `clones login`.
- **Not isolated:** `~/Library/Logs/Claude`; `~/.claude` for plain Claude, the terminal CLI and profiles made with `--no-isolate-claude-code`;
  `~/Documents/Claude` and `~/Claude Projects` (Cowork/Code); the Keychain key “Claude Safe Storage”
  (shared, safe); `com.anthropic.claudefordesktop.plist`.
- **Claude in Chrome.** With userData outside the standard place Claude itself disables local pairing
  (`userData relocated`); it works only in `default`.
- **An auto-update applied from a profile** restarts the app without flags; the guard sends a restarted
  copy back to its profile, while the original Claude.app opens as `default`.
- **One account, one profile:** the device hardware key is tied to the account.
- **Opening Claude.app directly** while profiles run activates an arbitrary running instance.
  That is why the first `clones add` also creates “Claude Default” (launcher and copy for `default`);
  `clones app default --remove` removes it, and later `add`/`app --all` do not bring it back.
- Claude reads the MCP config at startup: restart the profile after `clones config`.

## Development

```
Sources/ClonesCore/   profiles, processes (sysctl), launching (NSWorkspace), launchers and icons,
                      Claude.app copies, the guard, Claude installation, localization
Sources/clones/       CLI commands (swift-argument-parser)
Tests/                unit tests
scripts/e2e.sh        end-to-end scenario; scripts/fake-claude is a Claude.app stub
scripts/render-terminal.py   renders the README terminal pictures
.github/workflows/    ci.yml (macOS + Linux), release.yml (tag v* → universal binary in a GitHub release)
Formula/clones.rb     Homebrew formula (fill in url/sha256 after a release)
```

```sh
make build          # release build for the current architecture
make universal      # arm64 + x86_64 (needs Xcode)
make install        # ~/.local/bin; PREFIX=/usr/local for /usr/local/bin
make uninstall
make test           # unit tests (XCTest may be missing with Command Line Tools only)
make e2e            # end-to-end scenario on the Claude stub
CLONES_E2E_REAL=1 make e2e   # the same on the real /Applications/Claude.app
```

`e2e.sh` works in a temporary folder (`CLONES_*_DIR`). It creates profiles, starts `default`, `work`
and `test` at once, checks with `ps`/`lsof` that these are three processes with three different
userData folders, and checks MCP config isolation, `kill`, `rm`, `app`, `rename`, copies, the guard
and `doctor`. The stub (`scripts/fake-claude/fake-claude.c`) treats `--user-data-dir` like Electron
and, without the flag, writes into the sandbox rather than the real `~/Library/Application Support/Claude`.
With `CLONES_E2E_REAL=1` your plain Claude is started and closed at the end.

UI language: English, or Russian when the system language is Russian (`Locale.preferredLanguages`;
on Linux `LC_ALL`/`LC_MESSAGES`/`LANG`). Override with `CLONES_LANG=en|ru`. Strings are written as
`tr("English", "Русский")` pairs (`Sources/ClonesCore/L10n.swift`).

The core also builds on Linux: macOS-specific code is behind `#if os(macOS)` so tests and e2e run
without a Mac. CI (`.github/workflows/ci.yml`, on pull requests and manual runs): macOS (universal build, tests, e2e) and Linux. Releases are tested by `release.yml` itself.

### Releases

Bump `Clones.version` in `Sources/clones/Clones.swift`, add a section to `CHANGELOG.md`, then
`git tag v0.2.0 && git push origin v0.2.0`. `release.yml` checks that the tag matches the version,
runs the tests and the e2e scenario on macOS, builds a universal binary (ad-hoc signed) and publishes
`clones-macos.tar.gz` with its SHA-256 to a GitHub release.

### Manual checklist

- [ ] `clones doctor`: Claude.app found, no ✗, the guard is running.
- [ ] `clones add work && clones add test`: “Claude Work” and “Claude Test” with badges in /Applications; Spotlight finds them.
- [ ] `clones login work`, `clones login test`: different accounts; after Enter the other profiles come back.
- [ ] `clones run default`, `run work`, `run test`: each window has its own account and chats; the Dock shows “Claude Work”, “Claude Test”.
- [ ] `clones ls`: three `running`, different PIDs, no `CONFLICT`.
- [ ] `clones config work` + restart: the MCP server exists only in `work`.
- [ ] Close the `work` windows (⌘W), then `clones run work`: a window appears in the same process.
- [ ] Pin a running profile in the Dock, quit it, click it: after a short flicker the right profile opens and the guard log has an entry.
- [ ] `clones kill --all`, then `clones run work`: still signed in.
- [ ] After a Claude update: `clones update`; profiles open and stay signed in.
- [ ] `clones rm test`: asks for confirmation; data, launcher and copy are removed.
