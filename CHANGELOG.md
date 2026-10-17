# Changelog

## v0.1.0

First release.

- **Isolated Claude Desktop profiles.** Each profile has its own sign-in, chats, settings,
  MCP servers and cache in `~/.clones/<name>`: `clones add`, `run`, `login`, `ls`, `kill`, `rm`,
  `rename`, `config`, `dir`.
- **Its own Claude Code.** The Code tab of each profile keeps skills, settings and sessions in
  `~/.clones/<name>/claude-code` (`--no-isolate-claude-code` shares `~/.claude`).
- **Dock icons.** Every profile gets a launcher in /Applications and a Claude.app copy named after it,
  so a running profile shows up as “Claude Work” with its own badge in the Dock and ⌘Tab.
  The first profile also adds “Claude Default” for your regular Claude.
- **Background guard** that makes Dock-pinned profile icons always open the right profile.
- **`clones install` / `clones update`** download and install Claude Desktop with Anthropic signature
  and notarization checks.
- **`clones doctor`** diagnostics.
- English interface, Russian when macOS is set to Russian (`CLONES_LANG` to override).

Download `clones-macos.tar.gz` below (universal: Apple silicon and Intel, macOS 13+) and see the
README for the one-block install.
