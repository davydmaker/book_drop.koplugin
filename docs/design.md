# Book Drop: design and tools

Sends books to the device and downloads books, screenshots and Book Rewind images to a phone or computer, over the local Wi-Fi network, with a QR code and nothing to install on the other device. `book_drop` is the plugin identifier.

## How it works

1. In the Tools menu, **Book Drop**. The device must be on Wi-Fi.
2. The screen shows a QR code and the address. After approval, it shows who is connected and what was received.
3. The phone, on the same network, opens the address, and the device asks whether to allow it.
4. The browser shows three pages: **Send**, for one or more books; **Books**, a grid with covers or a list; and **Screenshots**, one by one or all in a `.zip`.
5. **Stop** turns everything off. If a book arrived, the library is refreshed on closing.

Books go to KOReader's home folder (`home_dir`), and images come from the folder used by KOReader's `Screenshoter`. The language follows KOReader's `language` setting, on the device and in the browser.

## Security

None of these layers makes the connection fully secure: there is no HTTPS, so someone capturing traffic on the same network could see the files, or the code in the address. That is why the screen warns against public networks.

| Layer | What it does |
|---|---|
| Only on while in use | The server exists while the screen is open. It closes on Stop, on sleep and after 10 minutes without use. Only the approved device counts as use, so strangers or an unanswered approval cannot keep it running. |
| One network | It listens only on the Wi-Fi address, not on USB networking. |
| Firewall | The port opens in `iptables` during the transfer, and the rule goes away on closing. |
| Secret code | The address carries a random code from `/dev/urandom`, new at each opening. Without it, every answer is the same 404. |
| Approval on the device | The first device with the code must be approved on the screen. |
| One device | Once approved, no other address is served. |
| No paths to download | Files are requested by number from a list built by the server, the number never changes within a session, and the file must still be on the list. There is no path parameter. |
| What can be downloaded | Only images from the screenshots folder and book formats from the books folder. `.sdr` folders, hidden items, links and KOReader's data folder stay out. |
| Restricted uploads | Only book formats, up to 500 MB, always to the same place. A name cannot carry a folder, control characters, invalid UTF-8 or characters that reverse how it is shown, and leading dots are removed, so it cannot create a hidden file. |
| No replacing | An existing name is refused, before sending and again at the end. |
| Space | Refuses a file that would leave less than 50 MB free. |
| Temporary file | An upload is written to `.book_drop-N.part` and only gets its name once complete. A cut upload removes it, and leftovers go away on the next opening. |
| Uploads from its own page only | `POST` requires the `X-File-Name` header, which another site's page cannot send without permission, and an `Origin` equal to the server's when present. Repeated headers and `Transfer-Encoding` are refused. |
| Private networks only | Refuses to start outside 10.x, 172.16-31.x and 192.168.x, and refuses clients from outside. |
| `Host` check | Blocks DNS rebinding, where a malicious page open on the phone would try to reach the device. |
| Limits | Headers up to 8 KB, one upload at a time, and 30 seconds without progress end a connection. The device in use (approved, or waiting for approval) has 6 connections of its own; the other addresses share 6 more, at most 2 each, so they can never take its places. A blocked address is dropped as soon as it connects. |
| Strikes per address | 20 invalid requests block that address only, so someone else on the network cannot end the session. The approved device is never blocked. |
| Pages | Escaped names, a restrictive `Content-Security-Policy`, `nosniff`, and no cache except for covers. The only script is the upload one, served by the plugin, and the other pages work without it. |
| Errors stay contained | An error while handling a request ends that connection only, so it cannot reach KOReader's interface loop. |
| After a crash | A marker file records that sharing started. If KOReader crashes or quits with the screen open, the next start closes the port, lets the device sleep again and removes temporary files. |

### Covers

Covers are read on demand from EPUBs, and an EPUB can be crafted, so everything inside is untrusted:

- **Before opening:** the file must start as a ZIP, and its end record must declare at most 20,000 entries and a 4 MB directory. KOReader's archive library accepts many formats and loads the whole list of entries, so this check keeps a disguised archive away from it.
- **Reading metadata:** tags are found in a single pass. A pattern such as `<item[^>]*>` rescans the rest of the text from every `<item`, which turns a crafted 1 MB file into minutes with the interface frozen.
- **Sizes:** the size declared in the file decides how much memory is allocated, so metadata is limited to 1 MB and the image to 5 MB before anything is read.
- **Paths:** the location of the image is compared with the names listed in the archive, and is never used as a path.
- **Type:** the content decides the type, so only JPEG, PNG, GIF and WebP are served. An SVG or a page named `.jpg` gets the placeholder, and so does a book with no cover.

### What this does not protect against

- **The local network itself.** Without HTTPS, someone on the same Wi-Fi who captures the traffic can read the code and the files, or pretend to be the approved address.
- **The content of a book.** An uploaded book reaches the same parsers as any book copied by cable.

## Sleep

While the screen is open, the device does not sleep: if it did, the Wi-Fi would drop in the middle of a transfer. On Kindle, the plugin turns on `preventScreenSaver` in `powerd`, and on any device it sets `PluginShare.pause_auto_suspend`. Both go back on closing, unless the `keepalive` plugin is active. The 10 minute limit avoids draining the battery if the screen is left open.

## Limits

- There is no `.zip` of books, because building one would freeze the screen for a long time.
- The screenshots zip has no compression, since PNG is already compressed. The screen may freeze for a moment while it is built. It is kept while the screenshots stay the same, so asking again serves the same file, and it is refused when it would leave less than 50 MB free, since the cache shares its partition with KOReader's settings. A zip smaller than its files counts as a failed write and is not served.
- Each cover is read while the interface waits, typically for a few milliseconds.
- Networks with client isolation, common on guest Wi-Fi, stop the phone from reaching the device.
- `Writer:addFileFromMemory` in KOReader writes the `0644` permission as decimal 644, which leaves extracted files unreadable. That is why the plugin uses `addPath`.

## Structure

```
book_drop.koplugin/
  _meta.lua, main.lua     registration in KOReader, and recovery after a crash
  book_drop/
    access.lua            access rules and pages, independent from KOReader and the network
    cover.lua             reads covers from EPUBs
    i18n.lua              texts in Portuguese, English and Spanish
    storage.lua           what can be listed in the books folder and how a file gets there
    server.lua            HTTP server that does not block the interface
    ui/screen.lua         QR code, state, approval, firewall, sleep and closing
  tests/, tools/, docs/   development
```

## Tools

- `luajit tests/access_spec.lua`: tests for the rules, including attack attempts and crafted EPUB metadata.
- `luajit tests/server_spec.lua`: tests for the server with fake connections: places per address, uploads, downloads and errors.
- With `KOREADER_DIR` pointing to a desktop KOReader:
  - `tools/koreader/check_server.sh` starts the real server and tests it with `curl`: approval, integrity of downloads and uploads, covers, the zip, cut and simultaneous uploads, and attack attempts.
  - `tools/koreader/run_emulator.sh` opens a window with the plugin.
  - `tools/koreader/render_readme_screens.sh` renders the device screens for the README. With `SERVE=600`, it also keeps a demo library online for 10 minutes, to capture the pages in a browser.
  - `python3 -I tools/make_brand_art.py` draws the icon, the banner and the social preview.
- `tools/package.sh` builds the release package.

The firewall and `preventScreenSaver` exist only on Kindle and are not exercised by these tests.

## Releasing

1. Update the version in `_meta.lua` and the section in `CHANGELOG.md`.
2. Run the tests above.
3. Create a GitHub release with the tag `v<version>`. The workflow checks that the tag matches `_meta.lua`, runs the tests, builds the package and attaches it.
