#!/bin/bash
# Builds ArchiveLMA-<version>.zip in the repo root, laid out the way
# Slim::Utils::PluginDownloader expects (install.xml at the top level of
# the "ArchiveLMA/" prefix inside the zip). Prints the version and sha1
# so they can be pasted into repository.xml.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

VERSION=$(grep -oP '(?<=<version>)[^<]+' install.xml)
ZIP_NAME="ArchiveLMA-${VERSION}.zip"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir "$WORK_DIR/ArchiveLMA"
cp Plugin.pm Settings.pm install.xml strings.txt "$WORK_DIR/ArchiveLMA/"
cp -r HTML "$WORK_DIR/ArchiveLMA/"

rm -f "$ZIP_NAME"
(cd "$WORK_DIR" && python3 -c '
import os, sys, zipfile
zf = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED)
for root, dirs, files in os.walk("ArchiveLMA"):
	for f in files:
		path = os.path.join(root, f)
		zf.write(path, path)
zf.close()
' "$REPO_DIR/$ZIP_NAME")

SHA1=$(sha1sum "$ZIP_NAME" | cut -d' ' -f1)

echo "Built: $ZIP_NAME"
echo "Version: $VERSION"
echo "SHA1:    $SHA1"
