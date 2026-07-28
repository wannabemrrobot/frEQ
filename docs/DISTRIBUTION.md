# Distributing FrEQ (DMG)

`scripts/create-dmg.sh` (or `make dmg`) produces `build/FrEQ.dmg`, a
compressed disk image containing:

```
FrEQ (volume)
├── FrEQ.app                 universal (arm64 + x86_64) menu-bar app
├── Install FrEQ.command     double-click installer (elevates once)
├── Uninstall FrEQ.command   double-click uninstaller
├── Support/FrEQ.driver      the HAL plug-in the installer places in /Library
├── Profiles/                  example AutoEq profile(s)
└── README.txt                 end-user instructions
```

## Why an installer, not drag-to-Applications

FrEQ has two parts. The app can live in `/Applications`, but the **HAL
driver must go to `/Library/Audio/Plug-Ins/HAL` and be owned by root**, which
requires admin rights, and `coreaudiod` must be restarted for the virtual
device to appear. A drag-install can't do that, so the DMG ships a
double-clickable `Install FrEQ.command` that performs both copies under a
single macOS password prompt and restarts the audio server.

## Two levels of "shareable"

### 1. Ad-hoc (default) — fine for yourself / a few trusting users

```sh
make dmg          # or scripts/create-dmg.sh
```

The app and driver are ad-hoc signed. On the **recipient's** Mac, Gatekeeper
will not recognize the developer, so the first launch of the installer needs
**right-click → Open** once (the README in the DMG says this). The installer
clears the quarantine flag on the copies it places, so the app and driver run
normally afterwards. This works on a normal SIP-enabled Mac because HAL
plug-ins load in `coreaudiod` without Developer-ID library validation — but
some users are (reasonably) wary of the unidentified-developer prompt.

### 2. Developer ID + notarization — friction-free for anyone

Requires an Apple Developer account ($99/yr) and a "Developer ID Application"
certificate in your keychain.

```sh
# 1. Build + sign both bundles and the DMG with your Developer ID.
make dmg SIGN="Developer ID Application: Your Name (TEAMID)"

# 2. Notarize the DMG (Apple scans it and issues a ticket).
#    One-time credential setup:
xcrun notarytool store-credentials autoeq-notary \
    --apple-id you@example.com --team-id TEAMID \
    --password <app-specific-password>

xcrun notarytool submit build/FrEQ.dmg \
    --keychain-profile autoeq-notary --wait

# 3. Staple the ticket so offline Gatekeeper checks pass.
xcrun stapler staple build/FrEQ.dmg
```

Notes:
- The hardened runtime + `com.apple.security.device.audio-input` entitlement
  are applied to the app automatically when you pass `--sign` (see
  `scripts/build-app.sh`).
- Notarize the **DMG**; because the app and driver inside are already signed
  with the same Developer ID and hardened runtime, stapling the DMG is
  sufficient for distribution. (You may also staple the `.app`/`.driver`
  before building the DMG if you distribute them separately.)
- After stapling, the recipient just double-clicks the installer — no
  right-click, no warnings.

## Verifying the DMG before you send it

```sh
# Mount, inspect, unmount
hdiutil attach build/FrEQ.dmg -nobrowse
ls -la /Volumes/FrEQ
lipo -info "/Volumes/FrEQ/FrEQ.app/Contents/MacOS/FrEQ"        # arm64 + x86_64
lipo -info "/Volumes/FrEQ/Support/FrEQ.driver/Contents/MacOS/FrEQDriver"
hdiutil detach /Volumes/FrEQ

# For a notarized build, confirm the ticket is stapled:
xcrun stapler validate build/FrEQ.dmg
spctl -a -vvv -t install build/FrEQ.dmg    # should say "accepted / Notarized Developer ID"
```
