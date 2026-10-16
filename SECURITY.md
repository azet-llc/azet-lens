# Security

## What AZET Lens can and cannot do

| | |
|---|---|
| Network | **None.** Release builds run in the App Sandbox without `com.apple.security.network.client` or `network.server`; macOS refuses every connection. There is no update check, telemetry, crash reporter or analytics. |
| Screen | Reads only the area under a lens, through ScreenCaptureKit, after you grant Screen Recording. Its own overlays are excluded from the capture. |
| Files | Writes nothing except a transcript, and only to the file you pick in the Save panel (`com.apple.security.files.user-selected.read-write`). Settings live in the app's sandbox container. |
| Other permissions | None: no Accessibility, no Input Monitoring, no camera, no microphone, no location, no contacts. |
| Translation | Apple's on-device Translation framework and Foundation Models. Language packs and the Apple Intelligence model are downloaded by macOS, not by the app. |

Verify the entitlements of the app you installed:

```bash
codesign -d --entitlements - "/Applications/AZET Lens.app"
codesign -dvv "/Applications/AZET Lens.app" 2>&1 | grep -E "Authority|TeamIdentifier"   # Developer ID Application: AZET LLC (95P4H2RG24)
spctl -a -vv "/Applications/AZET Lens.app"                                                # accepted, source=Notarized Developer ID
```

`scripts/release.sh` refuses to package a build that is not sandboxed or carries a network entitlement.

## Reporting a vulnerability

Email **hello@azet.io** with "AZET Lens security" in the subject, or open a
[private security advisory](https://github.com/azet-llc/azet-lens/security/advisories/new). Please do not open a public
issue for a vulnerability. We reply within 3 working days and aim to ship a fix within 30 days; we credit reporters
who want it.

Issues that come from the original Mwoyeo code are also reported upstream to
[midagedev/mwoyeo](https://github.com/midagedev/mwoyeo) once fixed here.

## Supported versions

The latest release on [GitHub Releases](https://github.com/azet-llc/azet-lens/releases). Releases are signed with
AZET LLC's Developer ID and notarized by Apple; the disk image's SHA-256 is in each release's notes.
