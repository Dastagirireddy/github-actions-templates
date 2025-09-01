#!/bin/bash
set -e

# Default values
APP_NAME="${1:-myapp}"
VERSION=${VERSION:-$(git describe --tags --always --dirty)}
# Remove 'v' prefix from version if it exists
VERSION=${VERSION#v}
ARCH="amd64"
BUILD_DIR="build"
DEB_DIR="${BUILD_DIR}/deb"
PACKAGE_DIR="${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}"

# Clean and create build directories
rm -rf "${BUILD_DIR}"
mkdir -p "${PACKAGE_DIR}/DEBIAN" \
         "${PACKAGE_DIR}/usr/local/bin" \
         "${PACKAGE_DIR}/usr/share/doc/${APP_NAME}"

# Build the application
echo "Building ${APP_NAME} ${VERSION}..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

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
# Add any post-installation commands here
EOF
chmod +x "${PACKAGE_DIR}/DEBIAN/postinst"

# Set permissions
chmod 755 "${PACKAGE_DIR}/usr/local/bin/${APP_NAME}"

# Build the .deb package
echo "Building Debian package..."
dpkg-deb --build "${PACKAGE_DIR}" "${DEB_DIR}/"

# Clean up build files
rm -rf "${PACKAGE_DIR}"

echo "Package built: ${DEB_DIR}/${APP_NAME}_${VERSION}_${ARCH}.deb"
