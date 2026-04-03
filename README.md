# Live IP DVR

Flutter-based IP camera viewer and face alert system for Hikvision IP cameras and Dahua XVR devices.

## Features

- Hikvision snapshot capture with Digest/Basic auth handling
- Dahua XVR support with RTSP live view on the selected primary channel
- Live preview box with full-screen double-tap mode
- Face-target selection from captured frame
- Alert monitoring with full-screen alarm overlay
- Custom app icons across Android, iOS, macOS, Windows, and web

## Supported Devices

- `Hikvision IP Camera`
  - Snapshot endpoint flow
  - Live preview uses repeated image refresh
- `Dahua XVR`
  - Snapshot capture for target saving and monitoring
  - RTSP live stream for the primary channel

## Main Workflow

1. Choose device type: `Hikvision IP Camera` or `Dahua XVR`
2. Enter device URL and login credentials
3. Start live stream
4. Capture a frame from the primary channel
5. Select the face area and save it as the alert target
6. Start monitoring to raise an alert when the saved face appears again

## Dahua RTSP Notes

Dahua live mode uses an RTSP URL in this style:

```text
rtsp://username:password@host:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif
```

If live video does not connect:

- confirm RTSP is enabled on the XVR
- confirm the RTSP port, usually `554`
- confirm the correct channel number
- try HTTP snapshot first to confirm connectivity and credentials

## Project Structure

```text
lib/main.dart        Main application UI and camera logic
test/widget_test.dart  Basic widget smoke test
android/ ios/ macos/ windows/ web/  Platform launchers and app icons
```

## Setup

```bash
flutter pub get
flutter run -d windows
```

You can also run on Android if the target device and network allow direct access to the camera or XVR.

## Verification

```bash
flutter analyze
flutter test
```

## Build and Release

See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## Repository

GitHub remote:

```text
https://github.com/onenet786/liveip-dvr
```
