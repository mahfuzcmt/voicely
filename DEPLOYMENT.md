# Voicely Deployment & Configuration Guide

## Overview

**Application:** Voicely - Real-time Push-to-Talk Communication App
**Version:** 1.0.0+1
**Tech Stack:** Flutter 3.38.8+ / Dart 3.10.7+ / Firebase 3.x / WebRTC

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Development Environment Setup](#2-development-environment-setup)
3. [Firebase Configuration](#3-firebase-configuration)
4. [Android Configuration](#4-android-configuration)
5. [iOS Configuration](#5-ios-configuration)
6. [Environment Variables](#6-environment-variables)
7. [Build Commands](#7-build-commands)
8. [Release Deployment](#8-release-deployment)
9. [Production Checklist](#9-production-checklist)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Prerequisites

### Required Software

| Software | Minimum Version | Purpose |
|----------|-----------------|---------|
| Flutter SDK | 3.38.8 | Cross-platform framework |
| Dart SDK | 3.10.7 | Programming language |
| Android Studio | Latest | Android SDK, emulator |
| Xcode | 15+ | iOS development (macOS only) |
| Java JDK | 17 | Android build tools |
| Git | 2.x | Version control |
| Node.js | 18+ | FlutterFire CLI |

### Verify Installation

```bash
# Check Flutter installation
flutter doctor -v

# Expected output should show:
# [✓] Flutter (Channel stable, 3.38.8+)
# [✓] Android toolchain
# [✓] Xcode (macOS only)
# [✓] Android Studio
```

### Install FlutterFire CLI

```bash
npm install -g firebase-tools
dart pub global activate flutterfire_cli
```

---

## 2. Development Environment Setup

### Clone and Initialize

```bash
# Clone repository
git clone <repository-url> voicely
cd voicely

# Install dependencies
flutter pub get

# Generate code (freezed models, riverpod providers)
flutter pub run build_runner build --delete-conflicting-outputs
```

### IDE Configuration

**VS Code Extensions:**
- Flutter
- Dart
- Flutter Riverpod Snippets
- Error Lens

**Android Studio Plugins:**
- Flutter
- Dart
- Flutter Riverpod Snippets

### Project Structure

```
voicely/
├── lib/
│   ├── main.dart                 # Entry point
│   ├── firebase_options.dart     # Firebase config (generated)
│   ├── core/                     # Shared utilities
│   ├── di/                       # Dependency injection
│   ├── features/                 # Feature modules
│   └── services/                 # Platform services
├── android/                      # Android native config
├── ios/                          # iOS native config
├── assets/                       # Static resources
└── test/                         # Unit/widget tests
```

---

## 3. Firebase Configuration

### Step 1: Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Click **Add Project**
3. Enter project name: `voicely-production` (or preferred name)
4. Enable/disable Google Analytics as needed
5. Click **Create Project**

### Step 2: Enable Firebase Services

Enable these services in Firebase Console:

| Service | Path | Required Settings |
|---------|------|-------------------|
| Authentication | Build → Authentication | Enable Email/Password, Phone |
| Firestore | Build → Firestore Database | Start in production mode |
| Storage | Build → Storage | Configure rules |
| Cloud Messaging | Engage → Messaging | Auto-enabled |

### Step 3: Configure Flutter App

```bash
# Login to Firebase
firebase login

# Configure FlutterFire (run from project root)
flutterfire configure --project=<your-firebase-project-id>

# Select platforms: Android, iOS
# This generates/updates lib/firebase_options.dart
```

### Step 4: Download Platform Credentials

**Android:**
1. Firebase Console → Project Settings → Your Apps → Android
2. Download `google-services.json`
3. Place in: `android/app/google-services.json`

**iOS:**
1. Firebase Console → Project Settings → Your Apps → iOS
2. Download `GoogleService-Info.plist`
3. Place in: `ios/Runner/GoogleService-Info.plist`

### Firestore Security Rules

Deploy these rules to Firestore:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users collection
    match /users/{userId} {
      allow read: if request.auth != null;
      allow write: if request.auth.uid == userId;
    }

    // Channels collection
    match /channels/{channelId} {
      allow read: if request.auth != null;
      allow create: if request.auth != null;
      allow update, delete: if request.auth != null
        && resource.data.creatorId == request.auth.uid;

      // Channel members subcollection
      match /members/{memberId} {
        allow read, write: if request.auth != null;
      }
    }

    // Messages collection
    match /messages/{messageId} {
      allow read: if request.auth != null;
      allow create: if request.auth != null;
    }

    // Audio history collection
    match /audioHistory/{recordId} {
      allow read: if request.auth != null;
      allow create: if request.auth != null;
    }
  }
}
```

### Storage Security Rules

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    // User avatars
    match /avatars/{userId}/{allPaths=**} {
      allow read: if request.auth != null;
      allow write: if request.auth.uid == userId;
    }

    // Audio files
    match /audio/{channelId}/{allPaths=**} {
      allow read: if request.auth != null;
      allow write: if request.auth != null;
    }
  }
}
```

---

## 4. Android Configuration

### Application ID

**File:** `android/app/build.gradle.kts`

```kotlin
android {
    namespace = "com.bitsoft.voicely"

    defaultConfig {
        applicationId = "com.bitsoft.voicely"  // Change for production
        minSdk = 24  // Android 7.0+
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }
}
```

### Signing Configuration

#### Generate Release Keystore

```bash
keytool -genkey -v -keystore android/app/voicely-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias voicely-key
```

#### Create Key Properties File

**File:** `android/key.properties` (DO NOT commit to git)

```properties
storePassword=<your-keystore-password>
keyPassword=<your-key-password>
keyAlias=voicely-key
storeFile=voicely-release.jks
```

#### Configure Gradle for Signing

**File:** `android/app/build.gradle.kts`

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}
```

### ProGuard Rules

**File:** `android/app/proguard-rules.pro`

```proguard
# Flutter WebRTC
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }

# Firebase
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.firebase.** { *; }

# Gson (if used)
-keepattributes Signature
-keep class com.google.gson.** { *; }
```

### Required Permissions

**File:** `android/app/src/main/AndroidManifest.xml`

Already configured with:
- `INTERNET` - Network access
- `RECORD_AUDIO` - Microphone for PTT
- `CAMERA` - Video features
- `ACCESS_FINE_LOCATION` - GPS location
- `FOREGROUND_SERVICE` - Background PTT
- `POST_NOTIFICATIONS` - Push notifications
- `BLUETOOTH_CONNECT` - Bluetooth audio devices

---

## 5. iOS Configuration

### Bundle Identifier

**File:** `ios/Runner.xcodeproj/project.pbxproj`

Update `PRODUCT_BUNDLE_IDENTIFIER` to your production bundle ID.

Or via Xcode:
1. Open `ios/Runner.xcworkspace`
2. Select Runner target → Signing & Capabilities
3. Set Bundle Identifier: `com.yourcompany.voicely`

### Info.plist Permissions

**File:** `ios/Runner/Info.plist`

Add usage descriptions:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Voicely needs microphone access for push-to-talk communication</string>

<key>NSCameraUsageDescription</key>
<string>Voicely needs camera access for profile photos</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>Voicely needs location access to share your position with team members</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Voicely needs background location access for real-time team tracking</string>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
    <string>fetch</string>
    <string>remote-notification</string>
</array>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>Voicely uses Bluetooth for audio device connectivity</string>
```

### Apple Developer Setup

1. Create App ID in Apple Developer Portal
2. Create Provisioning Profiles (Development + Distribution)
3. Configure Push Notification capability
4. Upload APNs key to Firebase

### CocoaPods Dependencies

```bash
cd ios
pod install --repo-update
cd ..
```

---

## 6. Environment Variables

### Configuration File

Create environment-specific config:

**File:** `lib/core/config/app_config.dart`

```dart
enum Environment { development, staging, production }

class AppConfig {
  static Environment environment = Environment.development;

  static String get signalingServerUrl {
    switch (environment) {
      case Environment.development:
        return 'ws://localhost:3000';
      case Environment.staging:
        return 'wss://staging.voicelyent.xyz';
      case Environment.production:
        return 'wss://voicelyent.xyz';
    }
  }

  static List<Map<String, String>> get iceServers {
    switch (environment) {
      case Environment.development:
        return [
          {'urls': 'stun:stun.l.google.com:19302'},
        ];
      case Environment.production:
        return [
          {'urls': 'stun:stun.voicely.com:3478'},
          {
            'urls': 'turn:turn.voicely.com:3478',
            'username': 'voicely',
            'credential': '<turn-server-password>',
          },
        ];
      default:
        return [{'urls': 'stun:stun.l.google.com:19302'}];
    }
  }
}
```

### Build Flavors

**Android (build.gradle.kts):**

```kotlin
android {
    flavorDimensions += "environment"

    productFlavors {
        create("development") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
        }
        create("production") {
            dimension = "environment"
        }
    }
}
```

---

## 7. Build Commands

### Development

```bash
# Run on connected device (debug mode)
flutter run

# Run with specific flavor
flutter run --flavor development

# Hot reload enabled by default
# Press 'r' for hot reload, 'R' for hot restart
```

### Code Generation

```bash
# One-time build
flutter pub run build_runner build --delete-conflicting-outputs

# Watch mode (continuous generation)
flutter pub run build_runner watch --delete-conflicting-outputs
```

### Testing

```bash
# Run all tests
flutter test

# Run with coverage
flutter test --coverage

# Run specific test file
flutter test test/widget_test.dart
```

### Release Builds

```bash
# Android APK (for testing)
flutter build apk --release

# Android App Bundle (for Play Store)
flutter build appbundle --release

# iOS Archive
flutter build ios --release
# Then archive via Xcode: Product → Archive
```

### Build with Flavor

```bash
# Development APK
flutter build apk --flavor development --release

# Production App Bundle
flutter build appbundle --flavor production --release
```

---

## 8. Release Deployment

### Google Play Store

#### Prepare Assets

1. **App Icon:** 512x512 PNG
2. **Feature Graphic:** 1024x500 PNG
3. **Screenshots:** Phone and tablet (min 2 each)
4. **Privacy Policy URL:** Required

#### Upload Process

1. Go to [Google Play Console](https://play.google.com/console)
2. Create new app
3. Complete store listing
4. Upload AAB: `build/app/outputs/bundle/release/app-release.aab`
5. Set up pricing and distribution
6. Submit for review

#### Version Management

Update version in `pubspec.yaml`:

```yaml
version: 1.0.1+2  # format: major.minor.patch+buildNumber
```

Build number must increment for each Play Store upload.

### Apple App Store

#### Prepare Assets

1. **App Icon:** 1024x1024 PNG (no alpha)
2. **Screenshots:** All required device sizes
3. **Privacy Policy URL:** Required
4. **App Preview Video:** Optional

#### Upload Process

1. Open Xcode: `ios/Runner.xcworkspace`
2. Select "Any iOS Device" as destination
3. Product → Archive
4. Distribute App → App Store Connect
5. Complete App Store Connect listing
6. Submit for review

#### TestFlight (Beta Testing)

1. Archive and upload to App Store Connect
2. Go to TestFlight tab
3. Add internal/external testers
4. Testers receive email invitation

---

## 9. Production Checklist

### Pre-Launch

- [ ] Firebase project configured with production credentials
- [ ] `google-services.json` in place (Android)
- [ ] `GoogleService-Info.plist` in place (iOS)
- [ ] `firebase_options.dart` generated
- [ ] Release signing keys created and secured
- [ ] `key.properties` configured (not in git)
- [ ] ProGuard rules tested
- [ ] App icons designed and added
- [ ] Splash screen configured
- [ ] All permission descriptions added

### Security

- [ ] API keys secured (not hardcoded)
- [ ] Firebase security rules deployed
- [ ] Storage security rules deployed
- [ ] HTTPS enforced for all endpoints
- [ ] Sensitive files in `.gitignore`

### Backend Infrastructure

- [ ] Signaling server deployed
- [ ] TURN server configured (for NAT traversal)
- [ ] SSL certificates installed
- [ ] Server monitoring enabled
- [ ] Database backups configured

### Testing

- [ ] Unit tests passing
- [ ] Widget tests passing
- [ ] Integration tests passing
- [ ] Manual QA completed
- [ ] Performance testing done
- [ ] Battery usage tested

### Compliance

- [ ] Privacy policy published
- [ ] Terms of service published
- [ ] GDPR compliance (if EU users)
- [ ] Data retention policy defined
- [ ] Age rating determined

### Store Listings

- [ ] App name finalized
- [ ] Description written
- [ ] Keywords/tags selected
- [ ] Screenshots captured
- [ ] Feature graphic created
- [ ] Contact email configured

---

## 10. Troubleshooting

### Common Build Errors

#### Gradle Sync Failed

```bash
# Clean and rebuild
cd android
./gradlew clean
cd ..
flutter clean
flutter pub get
```

#### CocoaPods Issues

```bash
cd ios
pod deintegrate
pod cache clean --all
pod install --repo-update
cd ..
```

#### Code Generation Errors

```bash
# Delete generated files and rebuild
flutter pub run build_runner clean
flutter pub run build_runner build --delete-conflicting-outputs
```

#### Firebase Initialization Failed

1. Verify `google-services.json` is in `android/app/`
2. Verify `GoogleService-Info.plist` is in `ios/Runner/`
3. Run `flutterfire configure` again
4. Check Firebase project settings match

### Runtime Errors

#### WebRTC Connection Failed

1. Check ICE server configuration
2. Verify TURN server credentials (production)
3. Check network firewall settings
4. Test on real devices (emulator has limitations)

#### Audio Permission Denied

1. Verify manifest permissions
2. Check runtime permission handling
3. Test on fresh app install

#### Push Notifications Not Working

**Android:**
1. Verify FCM token generation
2. Check `google-services.json`

**iOS:**
1. Verify APNs key uploaded to Firebase
2. Check push capability enabled
3. Test on physical device (required)

### Debug Commands

```bash
# Verbose logging
flutter run -v

# Analyze code issues
flutter analyze

# Check outdated packages
flutter pub outdated

# Verify environment
flutter doctor -v
```

---

## Support

For deployment issues:
1. Check [Flutter Documentation](https://docs.flutter.dev/deployment)
2. Check [Firebase Documentation](https://firebase.google.com/docs/flutter)
3. Review project `TODO.md` for known issues

---

*Document Version: 1.0.0*
*Last Updated: February 2026*
