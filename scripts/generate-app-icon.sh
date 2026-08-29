#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
SOURCE_ICON="${1:-$PROJECT_DIRECTORY/Resources/ExplorerIcon.png}"
OUTPUT_ICON="${2:-$PROJECT_DIRECTORY/Resources/Explorer.icns}"

ICON_PROPERTIES="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha "$SOURCE_ICON")"
if [[ "$ICON_PROPERTIES" != *"pixelWidth: 1024"* ||
      "$ICON_PROPERTIES" != *"pixelHeight: 1024"* ||
      "$ICON_PROPERTIES" != *"hasAlpha: no"* ]]; then
    echo "The source icon must be a 1024x1024 opaque PNG: $SOURCE_ICON" >&2
    exit 1
fi

TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d /tmp/explorer-app-icon.XXXXXX)"
ICONSET_DIRECTORY="$TEMPORARY_DIRECTORY/Explorer.iconset"
trap '/bin/rm -rf "$TEMPORARY_DIRECTORY"' EXIT
/bin/mkdir -p "$ICONSET_DIRECTORY"

render_icon() {
    local pixels="$1"
    local filename="$2"
    /usr/bin/sips -z "$pixels" "$pixels" "$SOURCE_ICON" \
        --out "$ICONSET_DIRECTORY/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIRECTORY" -o "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
