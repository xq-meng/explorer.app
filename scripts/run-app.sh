#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
"${SCRIPT_DIRECTORY}/package-app.sh"
APP_BUNDLE="$PROJECT_DIRECTORY/.build/artifacts/Explorer.app"
/usr/bin/open "$APP_BUNDLE"
