#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
name=book_drop.koplugin
for file in LICENSE LICENSE-CONTENT NOTICE; do
    if [ ! -f "$file" ]; then
        echo "$file not found: the package cannot be built without it." >&2
        exit 1
    fi
done
rm -rf dist
mkdir -p "dist/stage/$name"
cp -R _meta.lua main.lua LICENSE LICENSE-CONTENT NOTICE book_drop assets "dist/stage/$name/"
find dist/stage \( -name '._*' -o -name '.DS_Store' \) -delete
(cd dist/stage && zip -qrX "../$name.zip" "$name")
rm -rf dist/stage
(cd dist && shasum -a 256 "$name.zip" > "$name.zip.sha256")
echo "Package built: dist/$name.zip"
