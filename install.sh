#!/usr/bin/env bash
# install.sh — One-command setup for wiki-mcp (Ubuntu)
#
# Usage: bash testinstaller.sh
#
# What it does:
#   1. Installs prerequisites (curl, jq, Node.js 22+)
#   2. Installs opencode
#   3. Creates ~/.wiki-mcp/ with opencode.json + config.json
#   4. Prompts for bot credentials (opens browser to BotPasswords page)
#   5. Validates the setup
#   6. Adds a `wiki-mcp` alias to ~/.bashrc

set -uo pipefail

# ── Colours ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }

# Detect if GUI dialogs are available (re-checked after apt install)
USE_GUI=false
_detect_gui() { command -v zenity &>/dev/null && USE_GUI=true; }
_detect_gui

# ── Header ───────────────────────────────────────────────────────────────
clear
echo "=============================================="
echo "  wiki-mcp Installer for Ubuntu"
echo "=============================================="
echo ""

# ── Step 1: OS check ────────────────────────────────────────────────────
echo "--- Step 1: OS check ---"
if [ "$(uname -s)" != "Linux" ] || [ ! -f /etc/os-release ] || ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  fail "This script is designed for Ubuntu."
  info "Detected: $(uname -s) $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
  exit 1
fi
OS_VER="$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
pass "$OS_VER"
echo ""

# ── Step 2: Install system packages ─────────────────────────────────────
echo "--- Step 2: Installing system packages ---"
sudo apt update -qq || true
APT_OK=true
sudo apt install -y -qq curl jq git zenity || APT_OK=false
if ! $APT_OK; then
  warn "zenity install failed. Retrying without zenity..."
  sudo apt install -y -qq curl jq git || {
    fail "Could not install required packages. Check your internet and sudo access."
    exit 1
  }
  pass "curl, jq, git installed"
else
  pass "curl, jq, git, zenity installed"
  _detect_gui
fi
echo ""

# ── Step 3: Install Node.js 22+ ─────────────────────────────────────────
echo "--- Step 3: Node.js ---"
HAS_NODE=false
# Check both `node` and `nodejs` (Ubuntu sometimes has nodejs without node symlink)
NODE_CMD=""
for cmd in node nodejs; do
  if command -v "$cmd" &>/dev/null; then
    NODE_CMD="$cmd"
    break
  fi
done
if [ -n "$NODE_CMD" ]; then
  NODE_VER="$($NODE_CMD -v 2>/dev/null)"
  NODE_MAJOR="$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)"
  if [ "$NODE_MAJOR" -ge 22 ]; then
    pass "Node $NODE_VER already installed"
    HAS_NODE=true
  else
    warn "Node $NODE_VER is too old. Upgrading..."
  fi
fi

if [ "$HAS_NODE" != true ]; then
  info "Installing Node.js 22.x from NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - || \
    warn "NodeSource script failed — may fall back to distro package"
  sudo apt install -y -qq nodejs
  NODE_CMD="$(command -v node || command -v nodejs || true)"
  if [ -z "$NODE_CMD" ]; then
    fail "Node.js installation failed — binary not found"
    exit 1
  fi
  NODE_VER="$($NODE_CMD -v)"
  NODE_MAJOR="$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)"
  if [ "$NODE_MAJOR" -lt 22 ]; then
    fail "Node $NODE_VER is too old (need 22+). Try adding NodeSource manually: https://deb.nodesource.com/"
    exit 1
  fi
  pass "Node $NODE_VER installed"
fi
echo ""

# ── Step 4: Install opencode ────────────────────────────────────────────
echo "--- Step 4: opencode ---"
HAS_OPENCODE=false
# Check common locations for opencode
for path in "$(command -v opencode 2>/dev/null)" "$HOME/.opencode/bin/opencode" "/usr/local/bin/opencode"; do
  if [ -x "$path" ]; then
    OPENCODE_BIN="$path"
    HAS_OPENCODE=true
    break
  fi
done

if $HAS_OPENCODE; then
  pass "opencode already installed at $OPENCODE_BIN"
else
  info "Installing opencode via official installer..."
  curl -fsSL https://opencode.ai/install | bash
  # Find it after install
  for path in "$HOME/.opencode/bin/opencode" "/usr/local/bin/opencode"; do
    if [ -x "$path" ]; then
      OPENCODE_BIN="$path"
      break
    fi
  done
  if [ -z "${OPENCODE_BIN:-}" ]; then
    fail "opencode install failed — try manually: curl -fsSL https://opencode.ai/install | bash"
    exit 1
  fi
  pass "opencode installed at $OPENCODE_BIN"
fi
echo ""

# ── Step 5: Clone from GitHub ───────────────────────────────────────────
echo "--- Step 5: Downloading wiki-mcp from GitHub ---"
INSTALL_DIR="$HOME/.wiki-mcp"
REPO_URL="https://github.com/Wiki-NITC/wiki-mcp.git"

if [ -d "$INSTALL_DIR/.git" ]; then
  warn "$INSTALL_DIR already exists — pulling latest changes..."
  git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || warn "Could not update (keeping existing)"
elif [ -d "$INSTALL_DIR" ]; then
  warn "$INSTALL_DIR exists but is not a git repo — replacing..."
  BACKUP="/tmp/wiki-mcp-config-$$.json"
  [ -f "$INSTALL_DIR/config.json" ] && cp "$INSTALL_DIR/config.json" "$BACKUP"
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
  [ -f "$BACKUP" ] && mv "$BACKUP" "$INSTALL_DIR/config.json" && pass "Restored previous config.json"
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

if [ -d "$INSTALL_DIR/.git" ]; then
  pass "Cloned repo — includes .agents/skills/, rules/, scripts/, Agents.md"
else
  fail "Clone failed — check internet or permissions"
  exit 1
fi

# config.json (base, credentials filled in step 7)
if [ ! -f "$INSTALL_DIR/config.json" ]; then
  if [ -f "$INSTALL_DIR/config.example.json" ]; then
    cp "$INSTALL_DIR/config.example.json" "$INSTALL_DIR/config.json"
    pass "config.json created from config.example.json"
  else
    cat > "$INSTALL_DIR/config.json" << 'ENDCONF'
{
  "defaultWiki": "wiki.fosscell.org",
  "wikis": {
    "wiki.fosscell.org": {
      "sitename": "WIKI FOSSCELL NITC",
      "server": "https://wiki.fosscell.org",
      "articlepath": "",
      "scriptpath": "",
      "username": null,
      "password": null,
      "private": false
    }
  }
}
ENDCONF
    pass "config.json created (default)"
  fi
else
  pass "config.json already exists — kept as-is"
fi
echo ""

# ── Step 6: Wiki account check ──────────────────────────────────────────
echo "--- Step 6: Wiki account ---"
echo ""
echo "  Checking wiki.fosscell.org..."
echo ""

WIKI_URL="https://wiki.fosscell.org"
API_URL="$WIKI_URL/api.php"
if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$API_URL?action=query&meta=siteinfo&format=json" | grep -q "200"; then
  pass "Wiki is online"
else
  warn "Cannot reach wiki.fosscell.org — check your internet"
  echo ""
fi

echo ""
echo "  You need a wiki account to use this tool."
echo "  (It's free — anyone with @nitc.ac.in email can sign up.)"
echo ""

HAS_ACCOUNT=false
if $USE_GUI; then
  zenity --question --title="wiki-mcp Setup" \
    --text="Do you already have an account on wiki.fosscell.org?" \
    --ok-label="Yes, I have one" \
    --cancel-label="No, I need to sign up" \
    --width=400 2>/dev/null
  ZENITY_RC=$?
  if [ "$ZENITY_RC" -eq 0 ]; then
    HAS_ACCOUNT=true
  fi
else
  read -r -p "  Do you already have a wiki account? [Y/n] " ans
  if [[ ! "$ans" =~ ^[Nn] ]]; then
    HAS_ACCOUNT=true
  fi
fi

if ! $HAS_ACCOUNT; then
  echo ""
  info "Opening registration page..."
  xdg-open "$WIKI_URL/index.php?title=Special:CreateAccount" 2>/dev/null || true
  
  if $USE_GUI; then
    zenity --info --title="wiki-mcp Setup" \
      --text="Complete the sign-up on the wiki.\n\nUse your @nitc.ac.in email.\n\nClick 'Ready' once you have created your account." \
      --ok-label="Ready" --width=400 2>/dev/null || true
  else
    read -r -p "  Press Enter after you've created your account..."
  fi
fi

# ── Step 7: Bot password setup ──────────────────────────────────────────
echo ""
echo "--- Step 7: Bot password ---"
echo ""
echo "  Now create a bot password so the AI can log in."
echo ""
echo "  👉 A browser window will open to:"
echo "     https://wiki.fosscell.org/Special:BotPasswords"
echo ""
echo "  Steps in the browser:"
echo "    1. Log in (if not already)"
echo "    2. Name it:  wiki-mcp"
echo "    3. Tick: Basic rights + Edit existing pages + Create, edit, and move pages + High-volume editing"
echo "    4. Click 'Create'"
echo "    5. Copy the generated password"
if $USE_GUI; then
  zenity --info --title="wiki-mcp Setup" \
    --text="A browser will open to create a bot password.\n\n1. Log in to the wiki\n2. Name it: wiki-mcp\n3. Tick: Basic rights + Edit existing pages + Create, edit, and move pages + High-volume editing\n4. Click Create\n5. Copy the generated credentials" \
    --ok-label="Ready" --width=400 2>/dev/null || true
else
  read -r -p "  Press Enter to open the browser and continue..."
fi

xdg-open "https://wiki.fosscell.org/Special:BotPasswords" 2>/dev/null || \
  warn "Could not open browser. Open this URL manually: https://wiki.fosscell.org/Special:BotPasswords"

if $USE_GUI; then
  CREDS=$(zenity --forms --title="wiki-mcp Setup" \
    --text="Paste the credentials from the wiki" \
    --add-entry="Bot username (e.g. YourName@wiki-mcp)" \
    --add-password="Bot password" \
    --width=400 2>/dev/null || true)
  BOT_USER=$(echo "$CREDS" | cut -d'|' -f1)
  BOT_PASS=$(echo "$CREDS" | cut -d'|' -f2)
else
  echo ""
  read -r -p "  Bot username (e.g. YourName@wiki-mcp): " BOT_USER
  read -r -s -p "  Bot password (paste here): " BOT_PASS
  echo ""
fi

if [ -z "$BOT_USER" ] || [ -z "$BOT_PASS" ]; then
  warn "Empty input. Skipping credential setup."
  info "You can edit ~/.wiki-mcp/config.json later."
else
  jq --arg user "$BOT_USER" --arg pass "$BOT_PASS" \
    '.wikis["wiki.fosscell.org"].username = $user | .wikis["wiki.fosscell.org"].password = $pass' \
    "$INSTALL_DIR/config.json" > "$INSTALL_DIR/config.tmp" && mv "$INSTALL_DIR/config.tmp" "$INSTALL_DIR/config.json"
  chmod 600 "$INSTALL_DIR/config.json"
  pass "Credentials saved to config.json"

  # Validate credentials against wiki API (two-step login with session cookie)
  info "Verifying credentials..."
  COOKIE_JAR="/tmp/wiki-mcp-cookie-$$.txt"
  LOGIN_TOKEN=$(curl -s -c "$COOKIE_JAR" \
    --data "action=query&meta=tokens&type=login&format=json" "$API_URL" | \
    jq -r '.query.tokens.logintoken' 2>/dev/null || echo "")
  if [ -n "$LOGIN_TOKEN" ] && [ "$LOGIN_TOKEN" != "null" ]; then
    LOGIN_RESULT=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      --data-urlencode "lgname=$BOT_USER" \
      --data-urlencode "lgpassword=$BOT_PASS" \
      --data "action=login&format=json&lgtoken=$LOGIN_TOKEN" \
      "$API_URL")
    LOGIN_STATUS=$(echo "$LOGIN_RESULT" | jq -r '.login.result' 2>/dev/null || echo "")
    if [ "$LOGIN_STATUS" = "Success" ]; then
      pass "Wiki credentials verified"
    else
      warn "Could not log in to wiki — check your bot username/password in config.json"
    fi
  else
    warn "Could not obtain login token — skipping credential verification"
  fi
  rm -f "$COOKIE_JAR"
fi
echo ""

# ── Step 8: Validate ────────────────────────────────────────────────────
echo "--- Step 8: Validation ---"
echo ""

# Test config JSON
if ! jq empty "$INSTALL_DIR/config.json" 2>/dev/null; then
  fail "config.json has invalid JSON"
  exit 1
fi
pass "config.json is valid JSON"

# Test connectivity
if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$API_URL?action=query&meta=siteinfo&format=json" | grep -q "200"; then
  pass "Wiki API reachable"
else
  warn "Wiki API not reachable (check your internet)"
fi

# Test Node/npx (with 30s timeout — first download can be slow)
info "Checking MCP server (this may take a moment)..."
MCP_VER="$(timeout 60 npx --yes @professional-wiki/mediawiki-mcp-server@latest --version 2>/dev/null || echo '?')"
if [ "$MCP_VER" != "?" ]; then
  pass "MCP server ready (${MCP_VER})"
else
  warn "MCP server check timed out — it'll download on first run."
  info "This is normal — it'll work when you run 'wiki-mcp'."
fi
echo ""

# ── Step 9: Add alias ──────────────────────────────────────────────────
echo "--- Step 9: Adding wiki-mcp terminal command ---"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
ALIAS_LINE="alias wiki-mcp='(cd \"$INSTALL_DIR\" && exec \"$OPENCODE_BIN\")'"

ALIAS_INSTALLED=false
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ ! -f "$rc" ] && continue
  if grep -q "alias wiki-mcp=" "$rc" 2>/dev/null; then
    sed -i '/^alias wiki-mcp=/d' "$rc"
  fi
  { echo ""; echo "# wiki-mcp"; echo "$ALIAS_LINE"; } >> "$rc"
  pass "Updated alias in $(basename "$rc")"
  ALIAS_INSTALLED=true
done

if ! $ALIAS_INSTALLED; then
  # Fallback: create .bashrc if neither exists
  { echo ""; echo "# wiki-mcp"; echo "$ALIAS_LINE"; } >> "$HOME/.bashrc"
  pass "Created ~/.bashrc with wiki-mcp alias"
fi
info "To use 'wiki-mcp' in this terminal, run: source ~/.bashrc"
echo ""

# ── Step 10: Desktop shortcut ──────────────────────────────────────────
echo "--- Step 10: Desktop shortcut ---"

# Create icon
ICON_DIR="$HOME/.local/share/icons/hicolor/128x128/apps"
mkdir -p "$ICON_DIR"

# Simple SVG icon: blue circle with "W" letter
cat > "$ICON_DIR/wiki-mcp.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <circle cx="64" cy="64" r="60" fill="#2E86C1"/>
  <text x="64" y="80" text-anchor="middle" font-size="64" font-family="Ubuntu, sans-serif" fill="white" font-weight="bold">W</text>
</svg>
EOF

# Create .desktop file
DESKTOP_FILE="$HOME/.local/share/applications/wiki-mcp.desktop"
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=wiki-mcp
Comment=NITC Wiki AI Assistant
Exec=bash -c 'cd $INSTALL_DIR && exec $OPENCODE_BIN'
Path=$INSTALL_DIR
Icon=wiki-mcp
Terminal=true
Categories=Utility;Development;
StartupNotify=true
EOF

chmod +x "$DESKTOP_FILE"

# Also place on desktop (use XDG standard path)
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [ -d "$DESKTOP_DIR" ]; then
  cp "$DESKTOP_FILE" "$DESKTOP_DIR/wiki-mcp.desktop"
  chmod +x "$DESKTOP_DIR/wiki-mcp.desktop"
  # Mark launcher as trusted in GNOME (if gio is available)
  if command -v gio &>/dev/null; then
    gio set "$DESKTOP_DIR/wiki-mcp.desktop" metadata::trusted true 2>/dev/null || true
  fi
  pass "Desktop shortcut created"
else
  pass "App launcher created (no Desktop folder found)"
fi

# Update icon cache so the icon shows up
gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo ""

# ── Done ────────────────────────────────────────────────────────────────
echo "=============================================="
echo -e "  ${GREEN}wiki-mcp setup complete!${NC}"
echo "=============================================="
echo ""
echo "  Double-click the desktop icon or find"
echo "  'wiki-mcp' in your app launcher."
echo ""
echo "  Config files:"
echo "    ~/.wiki-mcp/opencode.json"
echo "    ~/.wiki-mcp/config.json"
echo ""
if [ -z "${BOT_USER:-}" ]; then
  echo "  ⚠  Credentials not configured. Edit config.json to add them:"
  echo "     nano ~/.wiki-mcp/config.json"
  echo ""
fi
echo "  First run? opencode will download the model (~2GB)."
echo "  This happens once."
echo ""
echo "=============================================="

# Terminal would close immediately on finish — this keeps it open
echo ""
read -r -p "  Press Enter to close this window..."
