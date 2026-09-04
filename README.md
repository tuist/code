# Tuist Code

Tuist Code is an experimental native coding environment with three first-class applications:

- macOS desktop
- iOS simulator
- Android

The applications use Rust for shared business logic, including the authentication lifecycle. [Once](https://buildonce.dev/) builds the native macOS and iOS application bundles, packages the Android application, and runs the shared Rust tests.

## Architecture

The user interfaces stay with their platforms: SwiftUI renders the macOS and iOS applications, and the Android application uses Android views. Platform code also owns secure credential storage, deep links, and the sign-in browser. Rust defines and tests the authentication state transitions shared by those applications; it does not render a user interface.

## Requirements

- [Mise](https://mise.jdx.dev/), which installs the pinned Rust, Java Development Kit, and Once toolchains.
- macOS: Xcode command line tools, including an iOS simulator runtime for the iOS application.
- Android: a connected device or emulator. Mise installs the Android Software Development Kit and Native Development Kit used by the build.

## Start the app

```sh
mise install
mise run run
```

The first run builds and opens the Tuist Code macOS application bundle. Its dock icon is generated from the current Tuist brand logo.

## Development commands

```sh
mise run format
mise run build
mise run build:ios
mise run build:android
mise run test
mise run validate
```

The `once.toml` file declares all native targets directly: `TuistCodeDesktop`, `TuistCodeiOS`, `TuistCodeAndroid`, and their shared Rust libraries.

## Run every platform

```sh
mise run run
mise run run:ios
mise run run:android
```

The iOS task uses the booted simulator. The Android task provisions a `TuistCode` emulator when needed, then installs and launches the application.

## Optional Tuist connection

Tuist Code works locally without an account: users can add Git repositories and
create worktree-backed agent sessions. Connecting a Tuist account enables
Tuist-backed capabilities, including remote sessions and remote builds.

The connection uses [OAuth 2.0](https://www.rfc-editor.org/rfc/rfc6749)
Authorization Code with [Proof Key for Code Exchange](https://www.rfc-editor.org/rfc/rfc7636),
matching the Tuist iOS application. This is a public-client flow, so the
applications contain a client identifier but never a client secret.

The default origin is `https://tuist.dev`. Each app also accepts another Tuist origin and public client identifier for development or self-hosted environments:

```sh
TUIST_ORIGIN=http://localhost:8080 mise run run
once run TuistCodeiOS --visible -- -tuist-origin http://localhost:8080
adb shell am start -n dev.tuist.code/.MainActivity --es tuist_origin http://10.0.2.2:8080
```

Pass `TUIST_OAUTH_CLIENT_ID`, `-tuist-oauth-client-id`, or `--es tuist_oauth_client_id` when the selected origin has a different client identifier. The built-in Tuist development, staging, and canary origins use the same identifiers as the Tuist provider applications.

## Android setup

Mise installs the Android command-line tools. Run the following once to install Android Platform 35, Build Tools 35.0.0, and the Native Development Kit:

```sh
mise run android:setup
```

`mise run build:android` and `mise run run:android` run this setup task automatically. The first Android launch also downloads and creates the emulator image.

## Updating the logo

`assets/tuist-logo.svg` is the Tuist brand logo. Run `scripts/generate_app_icons.sh` after updating it to regenerate the macOS and iOS application icons and the in-app image assets.
