# Release Checklist

## Before Build

- Verify the correct device mode works: `Hikvision IP Camera` or `Dahua XVR`
- Test login credentials on the target network
- Confirm live view works on the intended deployment machine
- Confirm face target capture and alert workflow works end-to-end
- Run:

```bash
flutter analyze
flutter test
```

## Windows Desktop Build

- Use:

```bash
flutter build windows
```

- Test the built app from:

```text
build\windows\x64\runner\Release\
```

- Confirm:
  - live view opens
  - full-screen live mode works
  - sound/alert overlay works
  - firewall/network permissions do not block camera access

## Android Build

- Use:

```bash
flutter build apk --release
```

- Test the APK on the same local network as the camera/XVR
- Confirm:
  - HTTP/RTSP access is allowed
  - credentials are accepted
  - device battery/background restrictions do not interrupt monitoring

## Configuration Checks

- Hikvision snapshot URL is correct
- Dahua XVR base URL is correct
- Dahua RTSP port is correct
- Primary channel is correct
- Match threshold is tuned to reduce false alerts

## Release Packaging

- Update app name/version if needed
- Keep screenshots of the final UI
- Keep a note of tested camera models and working URL patterns
- Tag the release commit in Git if you want traceable builds

## Recommended Final Git Commands

```bash
git status
git add .
git commit -m "Prepare release"
git push
```
