#!/bin/bash
# update-repo.sh - AndroidIDE Repository Management Script
# Manages package signing, key generation, and repository maintenance
# Repository structure: https://github.com/kelexine/ide-termux-repo

set -eo pipefail

# ======================
# Configuration
# ======================
REPO_NAME="kelexine"               # APT repository suite name
COMPONENT="main"                   # Repository component
ARCHES=("aarch64" "arm" "i686" "x86_64")  # Supported architectures
GPG_KEY_FILE="kelexine.key"        # GPG private key file
PUBLIC_KEY_FILE="public.key"       # Exported public key
DEBS_SOURCE_DIR="../output"        # Original location of built .deb files
FIXED_DEBS_DIR="../debs"           # Directory for fixed .deb files
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Script location
GPG_KEY_FPR=""                     # Will store the GPG key fingerprint

# Read passphrase from environment or prompt user
GPG_PASSPHRASE=${GPG_PASSPHRASE:-""}
if [[ -z "$GPG_PASSPHRASE" ]]; then
    read -s -p "Enter GPG key passphrase: " GPG_PASSPHRASE
    echo
fi

# ======================
# Dependency Installation
# ======================
install_dependencies() {
    echo "[*] Checking for required dependencies..."
    local deps=("gpg" "dpkg-scanpackages" "apt-ftparchive" "rsync" "dpkg-deb" "shred")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "[*] Missing dependencies detected: ${missing[*]}"
        if command -v apt-get >/dev/null; then
            echo "[*] Installing missing packages using apt-get..."
            sudo apt-get update
            local apt_deps=()
            for dep in "${missing[@]}"; do
                case "$dep" in
                    gpg)
                        apt_deps+=("gnupg")
                        ;;
                    dpkg-scanpackages)
                        apt_deps+=("dpkg-dev")
                        ;;
                    apt-ftparchive)
                        apt_deps+=("apt-utils")
                        ;;
                    rsync)
                        apt_deps+=("rsync")
                        ;;
                    dpkg-deb)
                        apt_deps+=("dpkg")
                        ;;
                    shred)
                        apt_deps+=("coreutils")
                        ;;
                    *)
                        apt_deps+=("$dep")
                        ;;
                esac
            done
            sudo apt-get install -y "${apt_deps[@]}"
        else
            echo "ERROR: Missing dependencies: ${missing[*]} and apt-get not found for automatic installation."
            exit 1
        fi
    else
        echo "[*] All dependencies are already installed."
    fi
}

# ======================
# Helper Functions
# ======================
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# ======================
# Fix .deb Packages
# ======================
fix_debs() {
    echo "[+] Fixing .deb packages from ${DEBS_SOURCE_DIR}"
    
    rm -rf "${FIXED_DEBS_DIR}"
    mkdir -p "${FIXED_DEBS_DIR}"
    
    for deb in "${DEBS_SOURCE_DIR}"/*.deb; do
        [ -e "$deb" ] || continue
        echo "[*] Processing $(basename "$deb")"
        
        work_dir=$(mktemp -d)
        dpkg-deb -R "$deb" "$work_dir" || {
            echo "Failed to extract $deb"
            rm -rf "$work_dir"
            exit 1
        }
        
        # --- Conffile Cleanup Section ---
        if [ -f "$work_dir/DEBIAN/conffiles" ]; then
            tmp_conffiles=$(mktemp)
            while IFS= read -r file; do
                rel_file="${file#/}"
                if [ ! -f "$work_dir/$rel_file" ]; then
                    echo "Warning: conffile '$file' not found in package. Removing entry." >&2
                else
                    echo "$file" >> "$tmp_conffiles"
                fi
            done < "$work_dir/DEBIAN/conffiles"
            mv "$tmp_conffiles" "$work_dir/DEBIAN/conffiles"
        fi
        # --- End Conffile Cleanup Section ---
        
        # --- Maintainer Scripts Permissions Fix ---
        for script in preinst postinst prerm postrm; do
            if [ -f "$work_dir/DEBIAN/$script" ]; then
                chmod 0755 "$work_dir/DEBIAN/$script"
                echo "[*] Set permissions for $script: $(ls -l "$work_dir/DEBIAN/$script")"
            fi
        done
        # --- End Maintainer Scripts Permissions Fix ---
        
        fixed_deb="${FIXED_DEBS_DIR}/$(basename "$deb")"
        dpkg-deb -Zxz -b "$work_dir" "$fixed_deb" || {
            echo "Failed to rebuild $deb"
            rm -rf "$work_dir"
            exit 1
        }
        
        rm -rf "$work_dir"
        echo "[+] Successfully processed $(basename "$deb")"
    done
    
    DEBS_SOURCE_DIR="${FIXED_DEBS_DIR}"
    echo "[+] All fixed packages are in ${DEBS_SOURCE_DIR}"
}

# ======================
# Initialize Environment
# ======================
init_dirs() {
    echo "[+] Initializing repository directories"
    mkdir -p {dists,pool}/"${COMPONENT}"
    for arch in "${ARCHES[@]}"; do
        mkdir -p "dists/${REPO_NAME}/${COMPONENT}/binary-${arch}"
    done
}

# ======================
# Key Management
# ======================
generate_gpg_key() {
    echo "[+] Generating new GPG key pair..."
    BATCH_FILE=$(mktemp)
    cat > "$BATCH_FILE" << EOF
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: AndroidIDE Kelexine Repo
Name-Email: kelexine@gmail.com
Expire-Date: 0
Passphrase: ${GPG_PASSPHRASE}
%commit
%echo Done
EOF
    gpg --batch --generate-key "$BATCH_FILE"
    shred -u "$BATCH_FILE"
    gpg --armor --export-secret-keys --batch --passphrase "$GPG_PASSPHRASE" > "${GPG_KEY_FILE}"
    if [[ ! -f "${GPG_KEY_FILE}" ]]; then
        error_exit "Failed to generate GPG key."
    fi
    echo "[+] New GPG keys saved to ${GPG_KEY_FILE}"
}

find_existing_key() {
    local email="kelexine@gmail.com"
    local existing_key
    existing_key=$(gpg --list-secret-keys --with-colons "${email}" 2>/dev/null)
    if [[ -n "$existing_key" ]]; then
        GPG_KEY_FPR=$(echo "$existing_key" | awk -F: '/^fpr:/ {print $10; exit}')
        echo "[+] Found existing GPG key with fingerprint: ${GPG_KEY_FPR}"
        return 0
    fi
    return 1
}

import_gpg_key() {
    echo "[+] Setting up GPG signing key"
    if find_existing_key; then
        echo "[+] Using existing GPG key for signing"
    elif [[ -f "${GPG_KEY_FILE}" ]]; then
        echo "[+] Importing GPG key from ${GPG_KEY_FILE}"
        if ! gpg --batch --import "${GPG_KEY_FILE}" 2>/dev/null; then
            error_exit "Failed to import GPG key."
        fi
        GPG_KEY_FPR=$(gpg --list-secret-keys --with-colons --fingerprint | awk -F: '/^fpr:/ {print $10; exit}')
    else
        generate_gpg_key
        GPG_KEY_FPR=$(gpg --list-secret-keys --with-colons --fingerprint | awk -F: '/^fpr:/ {print $10; exit}')
    fi
    if [[ -z "$GPG_KEY_FPR" ]]; then
        error_exit "Failed to determine GPG key fingerprint."
    fi
    echo "${GPG_KEY_FPR}:6:" | gpg --import-ownertrust
    gpg-connect-agent reloadagent /bye >/dev/null
    echo "[+] Successfully set up GPG key with fingerprint: ${GPG_KEY_FPR}"
}

# ======================
# Package Management
# ======================
copy_debs_to_repo() {
    echo "[+] Copying .deb files from ${DEBS_SOURCE_DIR}"
    if [[ ! -d "${DEBS_SOURCE_DIR}" ]]; then
        error_exit "DEBS_SOURCE_DIR ${DEBS_SOURCE_DIR} not found!"
    fi
    mkdir -p "pool/${COMPONENT}/"
    DEB_COUNT=$(find "${DEBS_SOURCE_DIR}" -name "*.deb" | wc -l)
    if [[ $DEB_COUNT -eq 0 ]]; then
        error_exit "No .deb files found in ${DEBS_SOURCE_DIR}"
    fi
    rsync -avh --progress "${DEBS_SOURCE_DIR}/"*.deb "pool/${COMPONENT}/" || 
        error_exit "Failed to copy .deb files."
    echo "[+] Successfully copied $DEB_COUNT .deb files to repository"
}

# ======================
# Repository Metadata
# ======================
generate_packages() {
    echo "[+] Generating Packages files"
    for arch in "${ARCHES[@]}"; do
        echo "  → Processing ${arch}"
        PKG_FILE="dists/${REPO_NAME}/${COMPONENT}/binary-${arch}/Packages"
        if ! dpkg-scanpackages --arch "${arch}" "pool/${COMPONENT}" /dev/null |
             sed "s|/data/data/com.termux/files/usr|/data/data/com.itsaky.androidide/files/usr|g" \
             > "$PKG_FILE"; then
            error_exit "Failed to generate Packages file for ${arch}"
        fi
        gzip -k -f "$PKG_FILE" || error_exit "Failed to compress Packages file for ${arch}"
    done
    echo "[+] Successfully generated Packages files for all architectures"
}

generate_release() {
    echo "[+] Generating Release file"
    local ARCH_LIST
    ARCH_LIST=$(printf "%s " "${ARCHES[@]}")
    if ! apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="AndroidIDE" \
        -o APT::FTPArchive::Release::Label="AndroidIDE Repository" \
        -o APT::FTPArchive::Release::Suite="${REPO_NAME}" \
        -o APT::FTPArchive::Release::Codename="${REPO_NAME}" \
        -o APT::FTPArchive::Release::Architectures="${ARCH_LIST}" \
        -o APT::FTPArchive::Release::Components="${COMPONENT}" \
        release "dists/${REPO_NAME}" > "dists/${REPO_NAME}/Release"; then
        error_exit "Failed to generate Release file"
    fi
    echo "[+] Successfully generated Release file"
}

# ======================
# Repository Signing
# ======================
sign_metadata() {
    echo "[+] Signing repository metadata"
    if [[ -z "$GPG_KEY_FPR" ]]; then
        error_exit "GPG key fingerprint not set. Run import_gpg_key first."
    fi
    rm -f "dists/${REPO_NAME}/InRelease" "dists/${REPO_NAME}/Release.gpg"
    if ! gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
        --local-user "${GPG_KEY_FPR}" \
        --clearsign -o "dists/${REPO_NAME}/InRelease" \
        "dists/${REPO_NAME}/Release"; then
        error_exit "Failed to generate InRelease file"
    fi
    if ! gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
        --local-user "${GPG_KEY_FPR}" \
        -abs -o "dists/${REPO_NAME}/Release.gpg" \
        "dists/${REPO_NAME}/Release"; then
        error_exit "Failed to generate Release.gpg file"
    fi
    echo "[+] Successfully signed repository metadata"
}

# ======================
# Public Key Export
# ======================
export_public_key() {
    echo "[+] Exporting public key for client verification"
    if [[ -z "$GPG_KEY_FPR" ]]; then
        error_exit "GPG key fingerprint not set. Run import_gpg_key first."
    fi
    if ! gpg --armor --export "${GPG_KEY_FPR}" > "${PUBLIC_KEY_FILE}"; then
        error_exit "Failed to export public key"
    fi
    echo "[+] Public key fingerprint: ${GPG_KEY_FPR}"
    echo "[!] Users must import this key to verify packages:"
    echo "    wget https://kelexine.github.io/ide-termux-repo/${PUBLIC_KEY_FILE}"
    echo "    apt-key add ${PUBLIC_KEY_FILE}"
}

# ======================
# Main Workflow
# ======================
main() {
    install_dependencies
    cd "${REPO_ROOT}" || error_exit "Failed to change to repository root directory"
    init_dirs
    import_gpg_key
    fix_debs
    copy_debs_to_repo
    generate_packages
    generate_release
    sign_metadata
    export_public_key
    echo -e "\n[REPOSITORY UPDATED SUCCESSFULLY]"
    echo -e "Add to clients with:"
    echo -e "deb https://kelexine.github.io/ide-termux-repo ${REPO_NAME} ${COMPONENT}"
    echo -e "Public key: ${PUBLIC_KEY_FILE}"
}

main
