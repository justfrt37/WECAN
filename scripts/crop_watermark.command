#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$1" ]; then
  echo "Drag a folder onto this icon (don't double-click directly)."
  read -p "Press enter to exit..."
  exit 1
fi
python3 "$DIR/crop_watermark.py" "$1"
read -p "Press enter to close..."
