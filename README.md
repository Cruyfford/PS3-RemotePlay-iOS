# PS3 Remote Play for iOS

An iPhone/iPad client for the PlayStation 3 Remote Play protocol (PREMO): the PS3 picture and sound
on the phone, with on-screen controls or a Bluetooth controller.

Status: early build. The protocol core is tested against a mock PS3 (`tools/test`), not yet against
a real console.

## How it works

- `Core/premo.c` - session handshake, authentication, encrypted video/audio streams, pad channel.
- `Core/rp_player.c` - decoding with FFmpeg (H.264, MPEG-4, AAC, ATRAC3).
- `App/` - SwiftUI/UIKit app.
- `tools/ps3rp.py` - reads or creates the Remote Play registration in the PS3 `xRegistry.sys`
  and tests the connection from a computer.

## Getting the registration keys

The PS3 only accepts devices registered for Remote Play. On a CFW/HEN console:

1. Download `/dev_flash2/etc/xRegistry.sys` from the PS3 by FTP. Keep it private: it also holds
   network and PSN settings.
2. `python tools/ps3rp.py keys xRegistry.sys` - uses an existing registration if there is one.
3. Otherwise `python tools/ps3rp.py register xRegistry.sys`, upload `xRegistry_new.sys` back as
   `/dev_flash2/etc/xRegistry.sys` and reboot the PS3. A `.backup` copy is kept. This step is
   experimental.
4. Import the resulting `ps3rp.json` in the app (file or clipboard).

## Using it

On the PS3 open Network > Remote Play, then enter the PS3 IP in the app and press Connect.

## Building

GitHub Actions builds an unsigned IPA on every push to `main` and publishes it as the `latest`
release. Locally: `bash scripts/build-ffmpeg-ios.sh && xcodegen generate`, then build in Xcode.

## Credits and license

The protocol implementation follows [Open Remote Play](https://github.com/shoobyban/open-rp) by
Darryl Sokoloski. GPLv2, see `LICENSE`. Not affiliated with Sony.
