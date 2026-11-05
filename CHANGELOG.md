# Changelog

## [1.0.1]

- The approval question closes when sharing stops, and a tap outside it no longer counts as Deny.
- The device in use keeps its own connections, so other devices on the network cannot take them.
- The screenshots `.zip` is reused while the screenshots stay the same, checks free space first, and is never served incomplete.
- Covers and downloads no longer walk the whole books folder, and a received book no longer makes the screen read it again.
- Updates on the e-reader screen no longer flash the whole screen each time.
- Less memory per cover, and books without a cover are not opened again.
- Faster transfers, with several connections moving in the same moment.
- An upload refused while it is being sent now shows the reason instead of "connection lost".
- The length of a download comes from the file itself.
- Errors in requests go to KOReader's log.

## [1.0.0]

First public release.

- Send books to the device from a browser, one or many at a time, with progress for each file.
- Download books, in a grid with covers or in a list, and screenshots, one by one or all in a `.zip`.
- A QR code to connect, with no app to install on the other device.
- One device at a time, approved on the screen of the e-reader.
- A screen that shows who is connected and what was received.
- The device stays awake while the screen is open, so a transfer is not cut short.
- In English, Portuguese and Spanish, following KOReader's language, on the device and in the browser.
