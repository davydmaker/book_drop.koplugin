#!/bin/sh
set -eu
: "${KOREADER_DIR:?Set KOREADER_DIR to the KOReader folder, the one with luajit and reader.lua.}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
home="${KO_HOME:-$repo/.ko-home}"
mkdir -p "$home/plugins"
ln -sfn "$repo" "$home/plugins/book_drop.koplugin"
cd "$KOREADER_DIR"
exec env KO_HOME="$home" EMULATE_READER_W=600 EMULATE_READER_H=800 EMULATE_READER_DPI=167 ./luajit reader.lua "$@"
