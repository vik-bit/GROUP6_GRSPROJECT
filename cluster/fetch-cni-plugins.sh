#!/usr/bin/env bash
# Downloads the reference CNI plugins (bridge, host-local, loopback, ...) that the
# Kind setup scripts copy into each node. Kept out of git: about 100 MB of binaries.
set -euo pipefail

CNI_VERSION="${CNI_VERSION:-v1.4.1}"
DEST="$(cd "$(dirname "$0")" && pwd)/cni-plugins"

if [ -x "$DEST/bridge" ]; then
    echo "CNI plugins already present in $DEST"
    exit 0
fi

mkdir -p "$DEST"
TARBALL="cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
curl -L --fail -o "$DEST/$TARBALL" \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/${TARBALL}"
tar -xzf "$DEST/$TARBALL" -C "$DEST"
rm -f "$DEST/$TARBALL"
echo "CNI plugins ${CNI_VERSION} installed in $DEST"
