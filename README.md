# wiki-mcp Installer

One-command setup for **wiki-mcp** — an AI agent that can read and edit pages on
[wiki.fosscell.org](https://wiki.fosscell.org) on your behalf, via natural language.

It wires together:
- [opencode](https://opencode.ai) — an agentic CLI (think Claude Code, but model-agnostic)
- [`@professional-wiki/mediawiki-mcp-server`](https://www.npmjs.com/package/@professional-wiki/mediawiki-mcp-server) — an MCP server that exposes MediaWiki's API as tools the agent can call
- Your own wiki bot account, scoped to specific permissions

This repo contains the installers for **Linux** (`install.sh`) and **Windows** (`install.ps1`). The actual agent config, skills, and rules live in [`Wiki-NITC/wiki-mcp`](https://github.com/Wiki-NITC/wiki-mcp), which the script clones for you.

## Quick install

### Linux (Ubuntu 22.04+)
```bash
curl -fsSL https://raw.githubusercontent.com/Wiki-NITC/wiki-mcp-installer/main/install.sh | bash
```

### Windows (PowerShell 5.1+)
```powershell
powershell -c "iwr -useb https://raw.githubusercontent.com/Wiki-NITC/wiki-mcp-installer/main/install.ps1 | iex"
```

Or clone and run locally:
```bash
git clone https://github.com/Wiki-NITC/wiki-mcp-installer.git
cd wiki-mcp-installer
# Linux:
bash install.sh
# Windows:
powershell -ExecutionPolicy Bypass -File install.ps1
```

## Requirements

### Linux
- Ubuntu 22.04+ (tested on 24.04 LTS)
- `sudo` access (for installing system packages)
- An internet connection
- A wiki account on `wiki.fosscell.org` (the script helps you create one if you don't have it — signups are open to `@nitc.ac.in` email addresses)

### Windows
- Windows 10+ / Windows Server 2016+
- PowerShell 5.1+
- An internet connection
- A wiki account on `wiki.fosscell.org`

## What the Linux script does

1. Verifies you're on Ubuntu.
2. Installs `curl`, `jq`, `git`, and `zenity` (zenity is optional — enables GUI dialogs; falls back to plain terminal prompts if unavailable).
3. Installs Node.js 22+ if it's missing or outdated.
4. Installs `opencode`.
5. Clones [`Wiki-NITC/wiki-mcp`](https://github.com/Wiki-NITC/wiki-mcp) into `~/.wiki-mcp` (agent skills, rules, `opencode.json`, `config.json`).
6. Checks whether you have a wiki account and opens the signup page if not.
7. Walks you through creating a **bot password** at `Special:BotPasswords`, saves it to `config.json`, and verifies it actually logs in before continuing.
8. Validates the config file and confirms the MCP server runs.
9. Adds a `wiki-mcp` alias to your shell config (`.bashrc` and/or `.zshrc`).
10. Creates a desktop launcher and app-menu entry.

## What the Windows script does

1. Checks install location — auto-relocates from C:\ to `%USERPROFILE%\wiki-mcp`.
2. Installs Git (winget or direct download).
3. Installs Node.js 22+ (winget or direct download).
4. Installs `opencode` (GitHub release → PATH).
5. Clones `wiki-mcp` into the working directory.
6. Creates `config.json` with wiki.fosscell.org defaults.
7. Checks wiki account and prompts for bot credentials (with API verification).
8. Adds `wiki-mcp` PowerShell function to your profile.
9. Creates desktop + Start Menu shortcuts.
10. Validates the setup.

## Usage

### Linux
After installation, run `wiki-mcp` in a new terminal (or `source ~/.bashrc` / `source ~/.zshrc` first if using the same session), or double-click the **wiki-mcp** desktop icon.

### Windows
After installation, run `wiki-mcp` in a new PowerShell terminal (or restart PowerShell), or double-click the **NITC Wiki MCP** desktop shortcut.

First run downloads opencode's model (~2GB) — this happens once.
- Run `wiki-mcp` in a new terminal (or `source ~/.bashrc` / `source ~/.zshrc` first if using the same session), or
- Double-click the **wiki-mcp** desktop icon / find it in your app launcher.

First run downloads opencode's model (~2GB) — this happens once.

## Bot password permissions

When creating the bot password, tick exactly these grants:

- **Basic rights**
- **Edit existing pages**
- **Create, edit, and move pages**
- **High-volume editing**

`Basic rights` and `High-volume editing` alone are *not* enough to edit — they cover API access and bot-edit flagging, not the actual edit permission. If you also want the agent to upload images/files, additionally tick **Upload new files** and **Upload, replace, and move files**.

You can review or revoke any bot password anytime at [`Special:BotPasswords`](https://wiki.fosscell.org/Special:BotPasswords).

## Security notes

- The bot password is saved in plaintext at `~/.wiki-mcp/config.json`, with permissions locked to `600` (readable only by you) by the installer.
- **Never commit `config.json`** if you fork this repo's companion config repo or back up your home directory publicly.
- A bot password is *not* your main wiki password — if it leaks, revoke it from `Special:BotPasswords` without affecting your main account.
- Changing your main wiki account password invalidates all bot passwords; you'll need to regenerate and re-run credential setup.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Could not log in to wiki` during Step 7 | Bot username must be in the form `YourWikiName@wiki-mcp`, not just your wiki username. Re-check the password too. |
| `opencode install failed` | Run `curl -fsSL https://opencode.ai/install \| bash` manually and check the output. |
| `Node.js installation failed` | NodeSource setup script may be blocked by network/firewall — try `sudo apt install nodejs` directly or check `https://deb.nodesource.com/`. |
| `wiki-mcp` command not found after install | Run `source ~/.bashrc` (or `~/.zshrc`) once, or open a new terminal. |
| MCP server check times out | Harmless — it just means the package wasn't cached yet; it downloads on first real run. |
| `git clone` fails on Windows | Script auto-relocates from C:\ to `%USERPROFILE%\wiki-mcp`. If you're still seeing issues, run from a directory under `%USERPROFILE%`. |
| `winget install` fails on Windows | Falls back to direct download. If both fail, install Git/Node.js manually and re-run. |

## Re-running the installer

Safe to run again — it detects existing installs at each step (Node, opencode, the `~/.wiki-mcp` clone, the shell alias) and skips or updates rather than duplicating.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Related

- [Wiki-NITC/wiki-mcp](https://github.com/Wiki-NITC/wiki-mcp) — the agent config this installer sets up
- [MediaWiki MCP server](https://www.npmjs.com/package/@professional-wiki/mediawiki-mcp-server)
- [opencode](https://opencode.ai)
