#!/bin/bash
set -e

# Enable debug logging by default (can be disabled with DEBUG=false)
[ "${DEBUG:-true}" != "false" ] && set -x

# Log function for consistent output
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Default values
CREATE_SERVICE=${CREATE_SERVICE:-true}
APP_NAME="${1:-myapp}"
FRONTEND_DIR="${FRONTEND_DIR:-ui}"  # Default to 'ui' directory
ENV_VARS="${3:-}"  # Comma-separated list of environment variables

log "Starting full-stack build process for ${APP_NAME}"
log "CREATE_SERVICE set to: ${CREATE_SERVICE}"
VERSION=${VERSION:-$(git describe --tags --always --dirty)}
# Remove 'v' prefix from version if it exists
VERSION=${VERSION#v}
ARCH="${2:-arm64}"
BUILD_DIR="build"
DEB_DIR="${BUILD_DIR}/deb"
PACKAGE_DIR="${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}"

# Clean and create build directories
log "Cleaning build directory: ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${PACKAGE_DIR}/DEBIAN" \
         "${PACKAGE_DIR}/usr/local/bin" \
         "${PACKAGE_DIR}/usr/share/doc/${APP_NAME}" \
         "${PACKAGE_DIR}/lib/systemd/system"

# Create necessary directories for the application
log "Creating application directories"
mkdir -p "${PACKAGE_DIR}/usr/share/${APP_NAME}"

# Build the Next.js UI
log "Building Next.js UI in ${FRONTEND_DIR}"
if [ -d "${FRONTEND_DIR}" ]; then
    cd "${FRONTEND_DIR}" || { log "Failed to enter ${FRONTEND_DIR}"; exit 1; }
    
    # Ensure pnpm is installed
    if ! command -v pnpm &> /dev/null; then
        log "Installing pnpm"
        npm install -g pnpm@8.15.4 || { log "Failed to install pnpm"; exit 1; }
    fi
    
    # Install dependencies
    log "Installing UI dependencies with pnpm"
    pnpm install --frozen-lockfile --prefer-offline || { 
        log "Failed to install dependencies, trying with --force"
        pnpm install --frozen-lockfile --force || { 
            log "Failed to install dependencies"; 
            exit 1; 
        }
    }
    
    # Build the Next.js application
    log "Building Next.js application"
    NODE_ENV=production pnpm run build || { 
        log "Next.js build failed"; 
        exit 1; 
    }
    
    # Verify build output
    if [ ! -d "build" ]; then
        log "ERROR: Next.js build output not found in ${FRONTEND_DIR}/build"
        log "Build directory contents:"
        ls -la
        exit 1
    fi
    
    # Go back to the project root
    cd - > /dev/null || exit 1
    
    # Copy all necessary files and directories
    log "Copying project files to /usr/share/${APP_NAME}"
    
    # Copy root level Go files
    for file in "${FRONTEND_DIR}"/*.go "${FRONTEND_DIR}"/go.mod "${FRONTEND_DIR}"/go.sum; do
        if [ -f "$file" ]; then
            cp "$file" "${PACKAGE_DIR}/usr/share/${APP_NAME}/"
        fi
    done
    
    # Copy the api directory if it exists
    if [ -d "${FRONTEND_DIR}/api" ]; then
        mkdir -p "${PACKAGE_DIR}/usr/share/${APP_NAME}/api"
        cp -r "${FRONTEND_DIR}/api/"* "${PACKAGE_DIR}/usr/share/${APP_NAME}/api/"
    fi
    
    # Create and copy the ui directory contents
    mkdir -p "${PACKAGE_DIR}/usr/share/${APP_NAME}/ui"
    
    # Copy the Next.js build output
    if [ -d "${FRONTEND_DIR}/build" ]; then
        cp -r "${FRONTEND_DIR}/build" "${PACKAGE_DIR}/usr/share/${APP_NAME}/ui/"
    fi
    
    # Copy UI Go files
    for file in "${FRONTEND_DIR}/ui"/*.go; do
        if [ -f "$file" ]; then
            cp "$file" "${PACKAGE_DIR}/usr/share/${APP_NAME}/ui/"
        fi
    done
    
    # Set correct permissions
    find "${PACKAGE_DIR}/usr/share/${APP_NAME}" -type d -exec chmod 755 {} \;
    find "${PACKAGE_DIR}/usr/share/${APP_NAME}" -type f -exec chmod 644 {} \;
    
    # Make sure main binary is executable
    if [ -f "${PACKAGE_DIR}/usr/share/${APP_NAME}/main.go" ]; then
        chmod +x "${PACKAGE_DIR}/usr/share/${APP_NAME}/main.go"
    fi
    else
        log "ERROR: Next.js build output not found in ${FRONTEND_DIR}/build"
        exit 1
    fi
else
    log "ERROR: Frontend directory not found at ${FRONTEND_DIR}"
    exit 1
fi

# Build the Go application with CGO for SQLite support
log "Building ${APP_NAME} version ${VERSION} for ${ARCH}"
log "Build command: CGO_ENABLED=1 GOOS=linux GOARCH=${ARCH} go build -o ${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Ensure the binary directory exists
mkdir -p "${PACKAGE_DIR}/usr/local/bin"

# Build with CGO enabled for SQLite
CGO_ENABLED=1 GOOS=linux GOARCH=${ARCH} go build -o "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Verify the binary was built
if [ -f "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}" ]; then
    log "Successfully built ${APP_NAME} binary with SQLite support"
    ldd "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}" || true
else
    log "ERROR: Failed to build ${APP_NAME} binary"
    exit 1
fi

# Create environment file if variables are provided
if [ -n "${ENV_VARS}" ]; then
    log "Creating environment file with variables: ${ENV_VARS}"
    mkdir -p "${PACKAGE_DIR}/etc/${APP_NAME}"
    echo "# Environment variables for ${APP_NAME}" > "${PACKAGE_DIR}/etc/${APP_NAME}/environment"
    IFS=',' read -ra VARS <<< "${ENV_VARS}"
    for var in "${VARS[@]}"; do
        if [ -n "${!var:-}" ]; then
            echo "${var}=${!var}" >> "${PACKAGE_DIR}/etc/${APP_NAME}/environment"
        fi
    done
    chmod 640 "${PACKAGE_DIR}/etc/${APP_NAME}/environment"
fi

# Create control file
log "Creating DEBIAN/control file"
cat > "${PACKAGE_DIR}/DEBIAN/control" << EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: Dastagirireddy <dastagirireddy99.r@gmail.com>
Depends: libc6, libsqlite3-0
Description: ${APP_NAME} application with embedded web UI
 ${APP_NAME} is a Go application with an embedded web interface.
 .
 This package contains the ${APP_NAME} binary and its web assets.
EOF

# Create systemd service file
log "Creating systemd service file"
cat > "${PACKAGE_DIR}/lib/systemd/system/${APP_NAME}.service" << EOF
[Unit]
Description=${APP_NAME} Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/share/${APP_NAME}
Environment=NODE_ENV=production
ExecStart=/usr/local/bin/${APP_NAME}
Restart=always
EnvironmentFile=-/etc/${APP_NAME}/environment

[Install]
WantedBy=multi-user.target
EOF

# Set permissions on the service file
chmod 644 "${PACKAGE_DIR}/lib/systemd/system/${APP_NAME}.service"

# Create postinst script
log "Creating post-installation script"
cat > "${PACKAGE_DIR}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

# Get the package name from dpkg
PACKAGE_NAME="${DPKG_MAINTSCRIPT_PACKAGE:-$1}"
SERVICE_NAME="${PACKAGE_NAME}.service"
SERVICE_FILE="/lib/systemd/system/${SERVICE_NAME}"
ENV_FILE="/etc/${PACKAGE_NAME}/environment"

# Only proceed if we're configuring the package
if [ "$1" != "configure" ]; then
    exit 0
fi

# Check if systemd is available
if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found, skipping service setup"
    exit 0
fi

# Check if the service file exists
if [ ! -f "${SERVICE_FILE}" ]; then
    echo "Service file ${SERVICE_FILE} not found, skipping service setup"
    exit 0
fi

# Reload systemd to pick up new unit file
if ! systemctl daemon-reload; then
    echo "Failed to reload systemd daemon" >&2
    exit 1
fi

# Enable the service
if ! systemctl enable "${SERVICE_NAME}" >/dev/null; then
    echo "Failed to enable ${SERVICE_NAME}" >&2
    exit 1
fi

# Start the service if not already running
if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    # Set environment variables from the environment file if it exists
    if [ -f "${ENV_FILE}" ]; then
        echo "Sourcing environment from ${ENV_FILE}"
        set -o allexport
        . "${ENV_FILE}"
        set +o allexport
    fi
    
    if ! systemctl start "${SERVICE_NAME}"; then
        echo "Failed to start ${SERVICE_NAME}" >&2
        systemctl status "${SERVICE_NAME}" || true
        journalctl -u "${SERVICE_NAME}" -n 50 --no-pager || true
        exit 1
    fi
    echo "Started ${SERVICE_NAME}"
fi
echo "Service ${SERVICE_NAME} enabled and started successfully"
exit 0
EOF

# Create prerm script
log "Creating pre-removal script"
cat > "${PACKAGE_DIR}/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e

# Get the package name from dpkg
PACKAGE_NAME="${DPKG_MAINTSCRIPT_PACKAGE:-$1}"
SERVICE_NAME="${PACKAGE_NAME}.service"

# Only run on removal, not on upgrade
if [ "$1" != "remove" ]; then
    exit 0
fi

# Check if systemd is available
if ! command -v systemctl >/dev/null 2>&1; then
    exit 0
fi

# Stop and disable the service if it exists
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "Stopping ${SERVICE_NAME}"
    systemctl stop "${SERVICE_NAME}" || true
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}"; then
    echo "Disabling ${SERVICE_NAME}"
    systemctl disable "${SERVICE_NAME}" >/dev/null || true
fi

exit 0
EOF

# Create postrm script
log "Creating post-removal script"
cat > "${PACKAGE_DIR}/DEBIAN/postrm" << 'EOF'
#!/bin/sh
set -e

# Get the package name from dpkg
PACKAGE_NAME="${DPKG_MAINTSCRIPT_PACKAGE:-$1}"
SERVICE_NAME="${PACKAGE_NAME}.service"
SERVICE_FILE="/lib/systemd/system/${SERVICE_NAME}"

# Only run on complete removal
if [ "$1" != "remove" ]; then
    exit 0
fi

# Check if systemd is available
if command -v systemctl >/dev/null 2>&1; then
    # Reload systemd to remove the service
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# Remove the service file if it exists
if [ -f "${SERVICE_FILE}" ]; then
    rm -f "${SERVICE_FILE}"
fi

exit 0
EOF

# Make scripts executable
chmod 755 "${PACKAGE_DIR}/DEBIAN/postinst" \
          "${PACKAGE_DIR}/DEBIAN/prerm" \
          "${PACKAGE_DIR}/DEBIAN/postrm"

# Set proper permissions for the binary
chmod 755 "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Create the deb package
log "Building Debian package..."
mkdir -p "${DEB_DIR}"
dpkg-deb --build --root-owner-group "${PACKAGE_DIR}" "${DEB_DIR}"

# Verify the package was created
DEB_FILE="${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}.deb"
if [ -f "${DEB_FILE}" ]; then
    log "Successfully created package: $(basename "${DEB_FILE}")"
    dpkg-deb --info "${DEB_FILE}" | grep -E 'Package:|Version:|Architecture:'
    ls -lh "${DEB_FILE}"
else
    log "ERROR: Failed to create Debian package"
    exit 1
fi

exit 0
