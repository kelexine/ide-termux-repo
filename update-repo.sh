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
DEBS_SOURCE_DIR="../debs"          # Location of built .deb files
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Script location
GPG_KEY_FPR=""                     # Will store the GPG key fingerprint

# Read passphrase from environment or prompt user
GPG_PASSPHRASE=${GPG_PASSPHRASE:-""}
if [[ -z "$GPG_PASSPHRASE" ]]; then
    read -s -p "Enter GPG key passphrase: " GPG_PASSPHRASE
    echo
fi

# ======================
# Helper Functions
# ======================
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

check_dependencies() {
    local deps=("gpg" "dpkg-scanpackages" "apt-ftparchive" "rsync")
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null || error_exit "Required dependency '$dep' not found. Install corresponding package."
    done
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
    
    # Create a temporary batch file for key generation
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

    # Generate the key
    gpg --batch --generate-key "$BATCH_FILE"
    
    # Securely remove the batch file
    shred -u "$BATCH_FILE"
    
    # Export the secret key
    gpg --armor --export-secret-keys --batch --passphrase "$GPG_PASSPHRASE" > "${GPG_KEY_FILE}"
    
    if [[ ! -f "${GPG_KEY_FILE}" ]]; then
        error_exit "Failed to generate GPG key."
    fi
    
    echo "[+] New GPG keys saved to ${GPG_KEY_FILE}"
}

find_existing_key() {
    # Look for an existing key for AndroidIDE Kelexine Repo
    local email="kelexine@gmail.com"
    local existing_key
    
    existing_key=$(gpg --list-secret-keys --with-colons "${email}" 2>/dev/null)
    
    if [[ -n "$existing_key" ]]; then
        # Extract the fingerprint of the existing key
        GPG_KEY_FPR=$(echo "$existing_key" | awk -F: '/^fpr:/ {print $10; exit}')
        echo "[+] Found existing GPG key with fingerprint: ${GPG_KEY_FPR}"
        return 0
    fi
    
    return 1
}

import_gpg_key() {
    echo "[+] Setting up GPG signing key"
    
    # First check if we already have a suitable key in the keyring
    if find_existing_key; then
        # Key found, we'll use it
        echo "[+] Using existing GPG key for signing"
    elif [[ -f "${GPG_KEY_FILE}" ]]; then
        # No key in keyring but we have a key file, import it
        echo "[+] Importing GPG key from ${GPG_KEY_FILE}"
        
        # Import the key and check for errors
        if ! gpg --batch --import "${GPG_KEY_FILE}" 2>/dev/null; then
            error_exit "Failed to import GPG key."
        fi
        
        # Extract full 40-character fingerprint
        GPG_KEY_FPR=$(gpg --list-secret-keys --with-colons --fingerprint | 
                     awk -F: '/^fpr:/ {print $10; exit}')
    else
        # No key in keyring and no key file, generate a new one
        generate_gpg_key
        
        # Extract full 40-character fingerprint after generation
        GPG_KEY_FPR=$(gpg --list-secret-keys --with-colons --fingerprint | 
                     awk -F: '/^fpr:/ {print $10; exit}')
    fi
    
    if [[ -z "$GPG_KEY_FPR" ]]; then
        error_exit "Failed to determine GPG key fingerprint."
    fi
    
    # Set trust level for the key
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
    
    # Create destination directory if it doesn't exist
    mkdir -p "pool/${COMPONENT}/"
    
    # Count how many .deb files exist
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
        
        # Generate Packages file
        if ! dpkg-scanpackages --arch "${arch}" "pool/${COMPONENT}" /dev/null |
             sed "s|/data/data/com.termux/files/usr|/data/data/com.itsaky.androidide/files/usr|g" \
             > "$PKG_FILE"; then
            error_exit "Failed to generate Packages file for ${arch}"
        fi
        
        # Generate compressed version
        gzip -k -f "$PKG_FILE" || error_exit "Failed to compress Packages file for ${arch}"
    done
    
    echo "[+] Successfully generated Packages files for all architectures"
}

generate_release() {
    echo "[+] Generating Release file"
    
    # Create space-separated list of architectures
    local ARCH_LIST=$(printf "%s " "${ARCHES[@]}")
    
    # Generate Release file
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
    
    # Ensure we have a valid fingerprint
    if [[ -z "$GPG_KEY_FPR" ]]; then
        error_exit "GPG key fingerprint not set. Run import_gpg_key first."
    fi
    
    # Remove existing signature files
    rm -f "dists/${REPO_NAME}/InRelease" "dists/${REPO_NAME}/Release.gpg"
    
    # Generate InRelease (clearsigned)
    if ! gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
        --local-user "${GPG_KEY_FPR}" \
        --clearsign -o "dists/${REPO_NAME}/InRelease" \
        "dists/${REPO_NAME}/Release"; then
        error_exit "Failed to generate InRelease file"
    fi
    
    # Generate Release.gpg (detached signature)
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
    
    # Ensure we have a valid fingerprint
    if [[ -z "$GPG_KEY_FPR" ]]; then
        error_exit "GPG key fingerprint not set. Run import_gpg_key first."
    fi
    
    # Export the public key
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
    # Check for dependencies
    check_dependencies
    
    # Setup environment
    cd "${REPO_ROOT}" || error_exit "Failed to change to repository root directory"
    init_dirs
    import_gpg_key
    copy_debs_to_repo
    
    # Generate repository metadata
    generate_packages
    generate_release
    sign_metadata
    export_public_key
    
    echo -e "\n[REPOSITORY UPDATED SUCCESSFULLY]"
    echo -e "Add to clients with:"
    echo -e "deb https://kelexine.github.io/ide-termux-repo ${REPO_NAME} ${COMPONENT}"
    echo -e "Public key: ${PUBLIC_KEY_FILE}"
}

# Execute main workflow
main
