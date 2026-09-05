# PrinterPhoto

An iOS app for printing photos from your phone to a network printer — either a
thermal receipt printer over raw ESC/POS, or anything AirPrint can reach.

It finds printers on the local network itself (Bonjour plus a subnet scan),
falls back to a manually typed IP when discovery comes up empty, and crops the
photo to a sensible aspect ratio before sending it.

## Requirements

- iOS 17.0 or later
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

The `.xcodeproj` is generated from `project.yml`. After changing the file
layout — adding a source file, adding a test — regenerate it:

```sh
xcodegen generate
open PrinterPhoto.xcodeproj
```

Running the tests from the command line:

```sh
xcodebuild test \
  -project PrinterPhoto.xcodeproj \
  -scheme PrinterPhoto \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## How it works

### Discovery

`PrinterDiscoveryService` runs two strategies at once. `NWBrowser` browses for
`_ipp`, `_ipps`, `_printer` and `_pdl-datastream` over Bonjour, while
`SubnetScanner` probes the current subnet for open printer ports (9100, 631,
515). Results from both merge into one list, ranked with ESC/POS printers first.

A Bonjour result is kept as a *service reference*, not a host string. An
instance name like `EPSON TM-T88VI` is not a DNS name, so Network.framework has
to resolve the service itself at connect time.

### Printing

Raw ESC/POS over port 9100 has no application-level acknowledgement, so
`EscPosPrinterClient` puts a deadline on every phase of the conversation —
connect, send, and wait-for-close — rather than trusting the socket to fail on
its own. `.waiting` is retried by Network.framework indefinitely, so without a
deadline an unreachable printer would hang forever.

The strongest delivery signal available without sending extra command bytes is
the printer closing its end of the connection once it has consumed the job.
That maps to `DeliveryConfirmation.acknowledged`; anything else reports as
`.unconfirmed` with the reason, so a job is never silently claimed as printed.

### Image pipeline

`EscPosImageRenderer` takes the photo to packed 1-bit raster:

1. **Normalize orientation.** A camera photo is stored in sensor orientation
   with an `imageOrientation` flag, so its pixel width is the *displayed*
   height for portrait shots. Everything downstream assumes upright pixels.
2. **Crop** to the chosen aspect ratio, centered.
3. **Resize** to the paper width in dots (384, 420 or 576).
4. **Dither** with Floyd–Steinberg, since the printer is 1-bit.
5. **Pack** into a `GS v 0` raster command, framed with init, feed and cut.

### Crop ratios

Offered: `1:1`, `4:5`, `3:4`, `2:3`, `9:16`, `4:3`, `3:2`, `16:9`, and
`ORIG` (uncropped).

`AUTO` picks for you. It compares the source ratio to each option by distance
in **log space** — so 4:3 and 3:4 read as equally far from square, which plain
subtraction gets wrong — and snaps to the nearest within about 8%. A 4032×3024
camera photo lands exactly on 4:3 and loses nothing.

Past that tolerance it falls back to `ORIG` rather than cutting a meaningful
slice off the frame. A modern iPhone screenshot is roughly 19.5:9, well past
the tallest option, so it prints uncropped instead of losing its top and
bottom. `ORIG` itself is clamped to between 9:16 and 16:9, so a tall panorama
cannot spool an unbounded length of receipt paper.

The chosen ratio applies to the AirPrint path too, so both outputs frame the
photo the same way.

## Layout

| File | Role |
| --- | --- |
| `ContentView.swift` | The whole UI, in four numbered steps |
| `PrinterDiscoveryService.swift` | Bonjour browsing, subnet scanning, merging |
| `EscPosPrinterClient.swift` | TCP delivery with per-phase deadlines |
| `EscPosImageRenderer.swift` | Crop, dither, and ESC/POS raster encoding |
| `Models.swift` | `DiscoveredPrinter`, `PaperWidth`, `CropRatio` |
| `AppSettings.swift` | `UserDefaults`-backed preferences |

## Known gaps

- The last-used printer is saved but not restored at launch, so you re-scan
  each time.
- The crop preview is recomputed on the main thread during view updates, which
  can hitch on large photos.
- Tall crops are sent as a single large raster. Some ESC/POS firmware expects
  the image banded into smaller chunks.
- Center-cropping a portrait into a landscape ratio will cut off heads.
