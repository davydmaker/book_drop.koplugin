#!/bin/sh
set -u
: "${KOREADER_DIR:?Set KOREADER_DIR to the KOReader folder, the one with luajit and reader.lua.}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/shots" "$work/home" "$work/down" "$work/unzip" "$work/books/serie/livro.sdr" "$work/books/.oculta" "$work/send"
dd if=/dev/urandom of="$work/shots/grande.png" bs=1024 count=3072 2>/dev/null
dd if=/dev/urandom of="$work/shots/pequena.jpg" bs=1024 count=40 2>/dev/null
dd if=/dev/urandom of="$work/shots/notas.txt" bs=1024 count=1 2>/dev/null
echo "segredo" > "$work/segredo.png"
dd if=/dev/urandom of="$work/books/antigo.epub" bs=1024 count=2048 2>/dev/null
dd if=/dev/urandom of="$work/books/serie/volume.pdf" bs=1024 count=64 2>/dev/null
echo "dados" > "$work/books/serie/livro.sdr/metadata.epub"
echo "dados" > "$work/books/.oculta/escondido.epub"
echo "dados" > "$work/books/config.lua"
ln -s "$work/segredo.png" "$work/books/atalho.epub"
echo "sobra" > "$work/books/.book_drop-77.part"
dd if=/dev/urandom of="$work/send/novo livro.epub" bs=1024 count=25600 2>/dev/null
mkdir -p "$work/epub/META-INF" "$work/epub/OEBPS/img"
printf '<container><rootfiles><rootfile full-path="OEBPS/c.opf" media-type="application/oebps-package+xml"/></rootfiles></container>' > "$work/epub/META-INF/container.xml"
printf '<package><metadata><meta name="cover" content="capa"/></metadata><manifest><item id="capa" href="img/capa.jpg" media-type="image/jpeg"/></manifest></package>' > "$work/epub/OEBPS/c.opf"
{ printf '\377\330\377'; dd if=/dev/urandom bs=1024 count=8 2>/dev/null; } > "$work/epub/OEBPS/img/capa.jpg"
(cd "$work/epub" && zip -qr "$work/books/com capa.epub" .)
failures=0
check() {
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAILED $1: expected $2, got $3"; failures=$((failures + 1)); fi
}
(
    cd "$KOREADER_DIR" || exit 1
    SDL_VIDEODRIVER=dummy KO_HOME="$work/home" PLUGIN_DIR="$repo" SHOTS_DIR="$work/shots" BOOKS_DIR="$work/books" READY_FILE="$work/url" APPROVE_FILE="$work/approve" RUN_SECONDS=45 UI_LANGUAGE=en \
        EMULATE_READER_W=600 EMULATE_READER_H=800 EMULATE_READER_DPI=167 OUTPUT_DIR="${OUTPUT_DIR:-}" ./luajit "$repo/tools/koreader/check_server.lua" > "$work/log" 2>&1
) &
server=$!
tries=0
while [ ! -s "$work/url" ] && [ $tries -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
url="$(cat "$work/url")"
base="${url%/*/}"
fetch() { curl -s --max-time 15 -o /dev/null -w "%{http_code}" "$@"; }
page="$(curl -s --max-time 5 "$url")"
case "$page" in *"Confirm on the e-reader"*) check "asks for confirmation before approval" 1 1 ;; *) check "asks for confirmation before approval" 1 0; echo "      answer: $(printf %s "$page" | cut -c1-80)" ;; esac
early="$(curl -s --max-time 5 "${url}shot/1")"
case "$early" in *"Confirm on the e-reader"*) check "gives no file before approval" 1 1 ;; *) check "gives no file before approval" 1 0 ;; esac
check "takes no upload before approval" 404 "$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -H "Expect:" -H "X-File-Name: antes.epub" --data-binary "abc" "${url}upload")"
touch "$work/approve"
sleep 2
check "send page after approval" 200 "$(fetch "$url")"
check "screenshot list" 200 "$(fetch "${url}shots")"
check "upload script" 200 "$(fetch "${url}upload.js")"
listing="$(curl -s --max-time 5 "${url}shots")"
case "$listing" in *grande.png*) a=1 ;; *) a=0 ;; esac; check "the list shows the image" 1 "$a"
case "$listing" in *notas.txt*) a=1 ;; *) a=0 ;; esac; check "the list hides what is not an image" 0 "$a"
curl -s --max-time 15 -o "$work/down/1" "${url}shot/1"
curl -s --max-time 15 -o "$work/down/2" "${url}shot/2"
sums() { shasum -a 256 "$1" | cut -d' ' -f1; }
one="$(sums "$work/down/1")"; two="$(sums "$work/down/2")"
small="$(sums "$work/shots/pequena.jpg")"; big="$(sums "$work/shots/grande.png")"
check "40 KB image arrives intact" "$small" "$one"
check "3 MB image arrives intact" "$big" "$two"
curl -s --max-time 15 -o "$work/down/p1" "${url}shot/2" & p1=$!
curl -s --max-time 15 -o "$work/down/p2" "${url}shot/2" & p2=$!
wait $p1 $p2
check "two downloads at once" "$big" "$(sums "$work/down/p2")"
zip_head="$(curl -s --max-time 5 -D - -o /dev/null "${url}all.zip")"
case "$zip_head" in *"HTTP/1.1 503"*"Retry-After: 2"*) a=1 ;; *) a=0 ;; esac; check "the first request for the zip asks to wait" 1 "$a"
zip_status=503
tries=0
while [ "$zip_status" = 503 ] && [ $tries -lt 20 ]; do
    zip_status="$(curl -s --max-time 15 -o "$work/down/all.zip" -w "%{http_code}" "${url}all.zip")"
    [ "$zip_status" = 503 ] && sleep 1
    tries=$((tries + 1))
done
check "the zip is served once it is ready" 200 "$zip_status"
(cd "$work/unzip" && unzip -q "$work/down/all.zip")
check "the zip has the image intact" "$big" "$(sums "$work/unzip/grande.png")"
check "the zip has only the images" 2 "$(ls "$work/unzip" | wc -l | tr -d ' ')"
check "no code" 404 "$(fetch "$base/")"
check "wrong code" 404 "$(fetch "$base/errado/")"
check "outside the folder" 404 "$(fetch --path-as-is "${url}../../segredo.png")"
check "outside the folder, encoded" 404 "$(fetch --path-as-is "${url}shot/..%2f..%2fsegredo.png")"
check "number that does not exist" 404 "$(fetch "${url}shot/99")"
check "file that is not an image" 404 "$(fetch "${url}shot/3")"
check "POST on the page" 404 "$(fetch -X POST "$url")"
books="$(curl -s --max-time 5 "${url}books")"
contains() { case "$books" in *"$1"*) echo 1 ;; *) echo 0 ;; esac; }
check "books show the one in the folder" 1 "$(contains antigo)"
check "books show a subfolder" 1 "$(contains serie/volume)"
check "books hide what is not a book" 0 "$(contains config)"
check "books hide .sdr" 0 "$(contains metadata)"
check "books hide a hidden folder" 0 "$(contains escondido)"
check "books do not follow links" 0 "$(contains atalho)"
curl -s --max-time 15 -o "$work/down/livro" "${url}book/1"
check "downloaded book intact" "$(sums "$work/books/antigo.epub")" "$(sums "$work/down/livro")"
curl -s --max-time 15 -D "$work/down/capa.head" -o "$work/down/capa" "${url}cover/2"
check "cover read from the EPUB, intact" "$(sums "$work/epub/OEBPS/img/capa.jpg")" "$(sums "$work/down/capa")"
case "$(cat "$work/down/capa.head")" in *"Content-Type: image/jpeg"*) a=1 ;; *) a=0 ;; esac; check "cover with the right type" 1 "$a"
case "$(curl -s --max-time 15 -D - -o /dev/null "${url}cover/1")" in *"Content-Type: image/svg+xml"*) a=1 ;; *) a=0 ;; esac; check "a book without a cover gets the placeholder" 1 "$a"
check "book list" 200 "$(fetch "${url}books/list")"
disposition="$(curl -s --max-time 5 -D - -o /dev/null "${url}book/1")"
case "$disposition" in *"Content-Disposition: attachment"*) a=1 ;; *) a=0 ;; esac; check "a book downloads as an attachment" 1 "$a"
check "a leftover from an earlier upload is removed" 0 "$(ls -a "$work/books" | grep -c '^\.book_drop-')"
upload() { curl -s --max-time 40 -o "$work/down/answer" -w "%{http_code}" -H "Expect:" -H "Content-Type: application/octet-stream" -H "X-File-Name: $1" --data-binary "@$2" "${url}upload"; }
check "25 MB upload" 201 "$(upload "novo%20livro.epub" "$work/send/novo livro.epub")"
check "uploaded file intact" "$(sums "$work/send/novo livro.epub")" "$(sums "$work/books/novo livro.epub")"
before="$(sums "$work/books/antigo.epub")"
check "does not replace what exists" 409 "$(upload "antigo.epub" "$work/send/novo livro.epub")"
check "the existing file stays the same" "$before" "$(sums "$work/books/antigo.epub")"
check "refuses a script" 415 "$(upload "ataque.sh" "$work/segredo.png")"
check "refuses leaving the folder" 400 "$(upload "..%2F..%2Fsaiu.epub" "$work/segredo.png")"
check "nothing written outside the folder" 0 "$(ls "$work" | grep -c saiu)"
check "refuses an empty body" 400 "$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -H "Expect:" -H "X-File-Name: vazio.epub" -X POST "${url}upload")"
check "refuses another origin" 404 "$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -H "Expect:" -H "Origin: http://evil.example" -H "X-File-Name: o.epub" --data-binary "abc" "${url}upload")"
check "check before upload accepts" 200 "$(fetch "${url}can-upload?name=outro.epub&size=10")"
check "check before upload refuses what exists" 409 "$(fetch "${url}can-upload?name=antigo.epub&size=10")"
python_cut() { curl -s --max-time 2 --limit-rate 512K -o /dev/null -H "Expect:" -H "X-File-Name: cortado.epub" --data-binary "@$work/send/novo livro.epub" "${url}upload"; }
python_cut
sleep 1
check "a cut upload leaves no partial file" 0 "$(ls -a "$work/books" | grep -c cortado)"
check "a cut upload leaves no temporary file" 0 "$(ls -a "$work/books" | grep -c '^\.book_drop-')"
check "after a cut, another upload works" 201 "$(upload "depois.epub" "$work/segredo.png")"
slow_one() { curl -s --max-time 6 --limit-rate 1M -o /dev/null -w "%{http_code}" -H "Expect:" -H "X-File-Name: lento.epub" --data-binary "@$work/send/novo livro.epub" "${url}upload"; }
slow_one > "$work/slow" &
slow=$!
sleep 1
check "two uploads at once: the second waits" 409 "$(upload "segundo.epub" "$work/segredo.png")"
wait $slow
check "another Host" 404 "$(fetch -H "Host: exemplo.com" "$url")"
head="$(curl -s --max-time 5 -D - -o /dev/null "$url")"
case "$head" in *"Cache-Control: no-store"*) a=1 ;; *) a=0 ;; esac; check "security header" 1 "$a"
wait $server
grep -E "approved|connections on closing|temporary zip|port closed|received|keeps awake|attempt|traceback|screen overflow" "$work/log" | sed 's/^/log   /'
check "no temporary file on closing" 0 "$(ls -a "$work/books" | grep -c '^\.book_drop-')"
grep -q "keeps awake on opening: true" "$work/log" || { echo "FAILED did not keep awake"; failures=$((failures + 1)); }
grep -q "keeps awake after closing: false" "$work/log" || { echo "FAILED stayed awake after closing"; failures=$((failures + 1)); }
grep -q "temporary zip left: false" "$work/log" || { echo "FAILED the temporary zip was left behind"; failures=$((failures + 1)); }
grep -q "port closed after closing: true" "$work/log" || { echo "FAILED the port stayed open after closing"; failures=$((failures + 1)); }
echo "failures: $failures"
[ "$failures" -eq 0 ]
