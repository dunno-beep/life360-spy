#!/usr/bin/env bash
set -euo pipefail
HOST="${1:-}"; TOKEN="${2:-}"
if [ -z "$HOST" ] || [ -z "$TOKEN" ]; then
  echo "usage: bash configure.sh <tailscale-ip> <secret>"
  echo "example: bash configure.sh 100.64.12.34 my-long-secret"
  exit 1
fi

cat > iphone/Config.swift <<EOF
import Foundation

enum Config {
    static let appGroup  = "group.com.you.life360"
    static let relayHost = "$HOST"
    static let relayPort = 8080
    static let token     = "$TOKEN"
}
EOF

cat > android/app/build.gradle.kts <<EOF
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.you.life360monitor"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.you.life360monitor"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
        buildConfigField("String", "RELAY", "\\"$HOST:8080\\"")
        buildConfigField("String", "TOKEN", "\\"$TOKEN\\"")
    }

    buildFeatures { buildConfig = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
EOF

echo "$TOKEN" > .token
echo "Configured."
grep relayHost iphone/Config.swift
grep -E "RELAY|TOKEN" android/app/build.gradle.kts
