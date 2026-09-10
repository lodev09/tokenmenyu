# TokeiMenyu

Track Claude and Codex usage limits from your macOS menu bar.

From Japanese 時計 (*tokei*, "clock/watch") and メニュー (*menyū*, "menu") — a watch for your tokens, in the menu bar.

- Menu bar shows current session usage for Claude and Codex
- Provider switch with separate account details and usage limits
- Dropdown with progress bars for session, weekly, and per-model limits
- Live reset countdowns and extra usage credits
- Auto-refreshes every 5 minutes, and on open

## How it works

Claude: Reads your Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`). Fetches usage from `api.anthropic.com/api/oauth/usage`.

Codex: Runs the installed Codex CLI through its [app-server interface](https://learn.chatgpt.com/docs/app-server). Reads account details and usage limits with `account/read` and `account/rateLimits/read`. Codex manages authentication through your existing ChatGPT sign-in.

Each provider refreshes independently. An error from one provider does not prevent updates from the other.

## Requirements

- macOS 14+
- For Claude: [Claude Code](https://claude.com/claude-code) signed in with a Claude subscription
- For Codex: [Codex CLI](https://developers.openai.com/codex/cli/) signed in with ChatGPT through `codex login`. API key usage is not supported.

The app finds Codex CLI through `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`.

## Install

Download the latest app from [GitHub Releases](https://github.com/lodev09/tokeimenyu/releases), or build from source:

```sh
make install   # builds and copies to /Applications
```

Or just run it:

```sh
make run
```

If macOS prompts for keychain access on first launch, click **Always Allow**.

## Disclaimer

Unofficial project with no affiliation with Anthropic or OpenAI. Claude support uses undocumented endpoints that can change. Codex support requires a CLI version with `account/rateLimits/read` support.

## License

[MIT](LICENSE)
