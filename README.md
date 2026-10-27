# ECOCYCLE

Android dashboard for the ECOCYCLE food waste composting machine. The app reads
live data written by the machine's ESP32 to Firebase Realtime Database and
shows it on a single dashboard.

Current version: **1.0.1**

## Features

- Email/password sign-in with Firebase Authentication (sign in once, stay signed in).
- 6-digit PIN unlock every time the app is opened or returns from the
  background. The PIN is stored per account in the Realtime Database as a salted
  SHA-256 hash and cached in secure storage for offline unlock. Five wrong
  attempts sign the user out.
- Forgot PIN (re-enter account password) and Change PIN.
- Forgot password (reset email) on the login screen.
- Dashboard: current activity, hopper levels (food waste, loam soil) and a
  paginated production records table with tap-to-highlight rows.
- Menu: Settings (Change PIN, Change password, Create account), About, Log out.
- Create account is shown only to the super admin and requires their password.

## Dashboard layout

```txt
|-----------------------------------------------|
| [menu] ECOCYCLE                  (dot) Online |
|-----------------------------------------------|
| Current Activity                              |
| (activity name)                               |
|-----------------------------------------------|
| Hopper Status                                 |
| Food Waste {%}        | Loam Soil {%}         |
|-----------------------------------------------|
| Production Records                            |
| Batch | Temperature | Moisture | Date | Time  |
| (table)                                       |
| (pagination: records per page, prev / next)   |
|-----------------------------------------------|
```

## Realtime Database structure

| Path              | Value                                                               |
| ----------------- | ------------------------------------------------------------------- |
| `activity`        | Integer code, mapped to a label by `activityMap` in `lib/main.dart` |
| `food_level`      | Food waste hopper level (percent)                                   |
| `soil_level`      | Loam soil hopper level (percent)                                    |
| `records`         | Map of strings: `batch,unixSeconds,temperature,moisture`            |
| `superadmin`      | Email (or list/map of emails) allowed to create accounts            |
| `users/<uid>/pin` | `{ salt, hash }` for the account's PIN                              |

Example record: `EC-001,1790905290,29.4,58.0`

Suggested rules:

- Everything readable/writable only when `auth != null`.
- `superadmin`: `.write` is `false` (edit it in the console).
- `users/$uid`: read/write only when `auth.uid === $uid`.

The super admin check in the app is client-side only. For stronger enforcement
use a Cloud Function or the Admin SDK to create accounts.

## Getting started

Requirements: Flutter (Dart SDK ^3.13.4), Android SDK, a Firebase project.

1. Create a Firebase project with Authentication (Email/Password) and a
   Realtime Database.
2. Add the Android app and place `google-services.json` in `android/app/`.
3. Generate `lib/firebase_options.dart` with `flutterfire configure`
   (make sure it includes the `databaseURL`).
4. Install dependencies and run:

```sh
flutter pub get
flutter run
```

`google-services.json` and `lib/firebase_options.dart` are git-ignored, so each
checkout must provide its own.

## Build

```sh
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

Set the version in `pubspec.yaml` (`version: 1.0.1+2`, name+build number).
Configure a release keystore before distributing the APK.

## Project structure

| File                           | Purpose                                    |
| ------------------------------ | ------------------------------------------ |
| `lib/main.dart`                | App entry, auth/PIN gate, dashboard        |
| `lib/login_page.dart`          | Sign in and forgot password                |
| `lib/pin_lock.dart`            | PIN storage, unlock, set, change, app lock |
| `lib/settings_page.dart`       | Settings and change password               |
| `lib/create_account_page.dart` | Super admin account creation               |
| `lib/about_page.dart`          | About screen                               |
| `lib/firebase_options.dart`    | Generated Firebase configuration           |

## Troubleshooting

If `flutter run` fails because files in `build/` are locked, stop the Gradle
daemons (`java.exe`), delete the `build/` folder and run again.
