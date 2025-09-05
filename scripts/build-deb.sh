#!/bin/bash
set -e

# Default values
CREATE_SERVICE=${CREATE_SERVICE:-true}
APP_NAME="${1:-myapp}"
VERSION=${VERSION:-$(git describe --tags --always --dirty)}
# Remove 'v' prefix from version if it exists
VERSION=${VERSION#v}
ARCH="${2:-arm64}"
BUILD_DIR="build"
DEB_DIR="${BUILD_DIR}/deb"
PACKAGE_DIR="${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}"

# Clean and create build directories
rm -rf "${BUILD_DIR}"
mkdir -p "${PACKAGE_DIR}/DEBIAN" \
         "${PACKAGE_DIR}/usr/local/bin" \
         "${PACKAGE_DIR}/usr/share/doc/${APP_NAME}" \
         "${PACKAGE_DIR}/lib/systemd/system"  # For systemd service file

# Build the application
echo "Building ${APP_NAME} ${VERSION}..."
CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go build -o "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Create control file
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
    
    echo "Systemd service file created at /lib/systemd/system/${APP_NAME}.service"
fi

# Set permissions
chmod 755 "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Build the .deb package
echo "Building Debian package..."
dpkg-deb --build "${PACKAGE_DIR}" "${DEB_DIR}/"

# Clean up build files
rm -rf "${PACKAGE_DIR}"

echo "Package built: ${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}.deb"
