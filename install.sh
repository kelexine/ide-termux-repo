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
echo -e "\n${YELLOW}${INFO} Configuring GPG keys...${RESET}"
key_url="https://raw.githubusercontent.com/kelexine/ide-termux-repo/main/public.key"
key_file="$PREFIX/etc/apt/trusted.gpg.d/kelexine.gpg"

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
