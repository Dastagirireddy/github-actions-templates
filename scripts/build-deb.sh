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

log "Starting build process for ${APP_NAME}"
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
         "${PACKAGE_DIR}/lib/systemd/system"  # For systemd service file

# Build the application
log "Building ${APP_NAME} version ${VERSION} for ${ARCH}"
log "Build command: CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go build -o ${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"
CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go build -o "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Verify the binary was built
if [ -f "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}" ]; then
    log "Successfully built ${APP_NAME} binary"
    ls -lh "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"
else
    log "ERROR: Failed to build ${APP_NAME} binary"
    exit 1
fi

# Create control file
log "Creating DEBIAN/control file"
cat > "${PACKAGE_DIR}/DEBIAN/control" << EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: Dastagirireddy<dastagirireddy99.r@gmail.com>
Description: ${APP_NAME} application
EOF

# Create postinst script
log "Creating post-installation script"
cat > "${PACKAGE_DIR}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

# Handle systemd service if enabled
if [ "$1" = "configure" ] && [ -f "/lib/systemd/system/${APP_NAME}.service" ]; then
    # Reload systemd to pick up new unit file
    systemctl daemon-reload >/dev/null 2>&1 || :
    
    # Enable and start the service
    systemctl enable ${APP_NAME}.service >/dev/null 2>&1 || :
    systemctl start ${APP_NAME}.service >/dev/null 2>&1 || :
fi

# Handle upgrades
if [ "$1" = "configure" ] && [ -d "/run/systemd/system" ]; then
    systemctl try-restart ${APP_NAME}.service >/dev/null 2>&1 || :
fi
EOF
chmod +x "${PACKAGE_DIR}/DEBIAN/postinst"

# Create prerm script for cleanup
log "Creating pre-removal script"
cat > "${PACKAGE_DIR}/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e

# Only stop the service if we're removing the package, not upgrading
if [ "$1" = "remove" ] && [ -x "$(command -v systemctl)" ] && \
   systemctl is-active --quiet ${APP_NAME}.service 2>/dev/null; then
    systemctl stop ${APP_NAME}.service || :
    systemctl disable ${APP_NAME}.service >/dev/null 2>&1 || :
fi
EOF
chmod +x "${PACKAGE_DIR}/DEBIAN/prerm"

# Create systemd service file if enabled
if [ "$CREATE_SERVICE" = "true" ]; then
    log "Creating systemd service file (CREATE_SERVICE=${CREATE_SERVICE})"
    cat > "${PACKAGE_DIR}/lib/systemd/system/${APP_NAME}.service" << EOF
[Unit]
Description=${APP_NAME} service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/${APP_NAME}
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions for the service file
    chmod 644 "${PACKAGE_DIR}/lib/systemd/system/${APP_NAME}.service"
    log "Systemd service file created at ${PACKAGE_DIR}/lib/systemd/system/${APP_NAME}.service"
    log "Service file contents:"
    cat "${PACKAGE_DIR}/lib/systemd/system/${APP_NAME}.service" | sed 's/^/  /'
else
    log "Skipping systemd service file creation (CREATE_SERVICE=${CREATE_SERVICE})"
    # Remove the directory if we're not using it
    rmdir -p "${PACKAGE_DIR}/lib/systemd/system" 2>/dev/null || :
fi

# Set permissions
log "Setting permissions for ${APP_NAME} binary"
chmod 755 "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"
ls -l "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Build the .deb package
log "Building Debian package..."
log "dpkg-deb --build ${PACKAGE_DIR} ${DEB_DIR}/"
dpkg-deb --build "${PACKAGE_DIR}" "${DEB_DIR}/"

# Verify the .deb file was created
DEB_FILE="${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}.deb"
if [ -f "${DEB_FILE}" ]; then
    log "Package successfully built: ${DEB_FILE}"
    log "Package information:"
    dpkg-deb --info "${DEB_FILE}" | sed 's/^/  /'
    log "Package contents:"
    dpkg-deb -c "${DEB_FILE}" | sed 's/^/  /'
else
    log "ERROR: Failed to build Debian package. Expected file not found: ${DEB_FILE}"
    log "Contents of ${DEB_DIR}:"
    ls -la "${DEB_DIR}" || :
    exit 1
fi

# Clean up build files
log "Cleaning up build directory"
rm -rf "${PACKAGE_DIR}"

log "Build process completed successfully"
