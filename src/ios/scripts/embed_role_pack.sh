#!/bin/sh
# Embed FlavorConfig.json + RolePack/ into the app bundle based on FLAVOR_ID.
# Used by every App Target (Minis + vertical flavors).
set -eu

FLAVOR_ID="${FLAVOR_ID:-openminis}"
SRC="${SRCROOT}/Flavors/${FLAVOR_ID}"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if [ ! -d "$SRC" ]; then
  echo "error: Flavor pack directory missing: $SRC" >&2
  exit 1
fi

if [ ! -f "$SRC/FlavorConfig.json" ]; then
  echo "error: FlavorConfig.json missing in $SRC" >&2
  exit 1
fi

if [ ! -d "$SRC/RolePack" ]; then
  echo "error: RolePack/ missing in $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"
cp "$SRC/FlavorConfig.json" "$DEST/FlavorConfig.json"
rm -rf "$DEST/RolePack"
# Preserve directory structure (skills/, ui/, etc.)
cp -R "$SRC/RolePack" "$DEST/RolePack"

echo "note: Embedded flavor=${FLAVOR_ID} → $DEST"
