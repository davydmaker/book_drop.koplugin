#!/bin/sh
# Renders the device screens for the README, in English and Portuguese.
# With SERVE=<seconds>, keeps the demo library running and prints its address, to capture the pages in a browser.
set -u
: "${KOREADER_DIR:?Set KOREADER_DIR to the KOReader folder, the one with luajit and reader.lua.}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 -I "$repo/tools/make_demo_library.py" "$work/books"
mkdir -p "$work/shots"
render() {
    language="$1"
    out="$2"
    seconds="$3"
    mkdir -p "$out" "$work/home_$language"
    rm -f "$work/url"
    (
        cd "$KOREADER_DIR" || exit 1
        SDL_VIDEODRIVER=dummy KO_HOME="$work/home_$language" PLUGIN_DIR="$repo" SHOTS_DIR="$work/shots" BOOKS_DIR="$work/books" \
            READY_FILE="$work/url" RUN_SECONDS="$seconds" SHOT_DIR="$out" UI_LANGUAGE="$language" \
            EMULATE_READER_W=600 EMULATE_READER_H=800 EMULATE_READER_DPI=167 ./luajit "$repo/tools/koreader/demo_server.lua" > "$work/log_$language" 2>&1
    ) &
    server=$!
    tries=0
    while [ ! -s "$work/url" ] && [ $tries -lt 150 ]; do sleep 0.1; tries=$((tries + 1)); done
    if [ "$seconds" -gt 0 ]; then
        echo "Open $(cat "$work/url") in a browser. The first device is approved automatically. It stops in $seconds seconds."
    fi
    wait $server
}
render en "$repo/docs/screenshots" "${SERVE:-0}"
render pt "$repo/docs/screenshots/pt" 0
