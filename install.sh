#!/bin/bash

# Colors and Emojis
GREEN="\e[32m"    RED="\e[31m"     YELLOW="\e[33m" 
BLUE="\e[34m"      RESET="\e[0m"    CHECK="✅"       
CROSS="❌"         INFO="🔷"        WARN="🔶"

# Error Handler
handle_error() {
  echo -e "\n${RED}${CROSS} Error: $1${RESET}"
  exit 1
}

# Check existing repository
check_existing_repo() {
  if grep -qr "kelexine.github.io/ide-termux-repo" $PREFIX/etc/apt/sources.list.d/; then
    echo -e "${YELLOW}${WARN} Repository already exists in sources!${RESET}"
    return 1
  fi
}

# Header
echo -e "${BLUE}════════════════════════════════════════${RESET}"
echo -e "${GREEN}        AndroidIDE Repo Installer        ${RESET}"
echo -e "${BLUE}════════════════════════════════════════${RESET}"

# Dependency Installation
echo -e "\n${YELLOW}${INFO} Installing dependencies...${RESET}"
pkg_list=("gnupg" "curl")
if ! apt install "${pkg_list[@]}" -y &>/dev/null; then
  handle_error "Failed to install dependencies. Check internet connection."
fi
echo -e "${GREEN}${CHECK} Dependencies installed!${RESET}"

# Repository Setup
echo -e "\n${YELLOW}${INFO} Configuring repository...${RESET}"
repo_file="$PREFIX/etc/apt/sources.list.d/kelexine.list"

if check_existing_repo; then
  mkdir -p "$(dirname "$repo_file")" || handle_error "Can't create sources dir"
  echo "deb [trusted=yes arch=all] https://kelexine.github.io/ide-termux-repo kelexine main" > "$repo_file"
  echo -e "${GREEN}${CHECK} Repository added to: ${BLUE}$repo_file${RESET}"
else
  echo -e "${YELLOW}${WARN} Using existing repository configuration${RESET}"
fi

# GPG Key Management
# Add repository key (using apt-key)
echo -e "${YELLOW}${INFO} Adding GPG key for Kelexine's repository...${RESET}"
key_url="https://raw.githubusercontent.com/kelexine/ide-termux-repo/main/kelexine.key"

# Temporary file for key storage
tmp_key=$(mktemp)

if ! curl -fsSL "$key_url" > "$tmp_key"; then
    handle_error "Failed to download GPG key from: $key_url"
fi

if ! apt-key add "$tmp_key" >/dev/null 2>&1; then
    rm -f "$tmp_key"
    handle_error "Failed to add GPG key using apt-key"
fi
rm -f "$tmp_key"
echo -e "${GREEN}${CHECK} GPG key added using apt-key!${RESET}"

# Attempt to organize keys (legacy compatibility)
echo -e "\n${YELLOW}${INFO} Organizing GPG keys (legacy compatibility)...${RESET}"
if [ -f "$PREFIX/etc/apt/trusted.gpg" ]; then
    if ! mkdir -p "$PREFIX/etc/apt/trusted.gpg.d"; then
        echo -e "${RED}${WARN} Failed to create trusted.gpg.d directory${RESET}"
    else
        if ! mv "$PREFIX/etc/apt/trusted.gpg" "$PREFIX/etc/apt/trusted.gpg.d/"; then
            echo -e "${RED}${WARN} Failed to move trusted.gpg file${RESET}"
        else
            echo -e "${GREEN}${CHECK} Moved trusted.gpg to trusted.gpg.d/${RESET}"
        fi
    fi
else
    echo -e "${YELLOW}${WARN} trusted.gpg file not found - new apt versions may store keys differently${RESET}"
fi

if ! curl -fsSL "$key_url" > "$key_file"; then
  handle_error "Failed to download GPG key. Check URL: $key_url"
fi
echo -e "${GREEN}${CHECK} GPG key stored to: ${BLUE}$key_file${RESET}"

# System Update
echo -e "\n${YELLOW}${INFO} Updating package lists...${RESET}"
if ! apt update -y &>/dev/null; then
  handle_error "Repository update failed. Check configuration."
fi
echo -e "${GREEN}${CHECK} Package lists updated successfully!${RESET}"

# Final Output
echo -e "\n${BLUE}════════════════════════════════════════${RESET}"
echo -e "${GREEN}✅ Repository setup completed successfully!${RESET}"
echo -e "${YELLOW}ℹ️  Install packages with: ${BLUE}apt install <package>${RESET}"
echo -e "${BLUE}════════════════════════════════════════${RESET}"
