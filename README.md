# Tuist Code

Tuist Code is an experimental native coding environment with three first-class applications:

- macOS desktop
- iOS simulator
- Android

The applications use the same Rust implementation of the product identity and brand colour. [Once](https://buildonce.dev/) builds the native macOS and iOS application bundles, packages the Android application, and runs the shared Rust tests.

## Requirements

- [Mise](https://mise.jdx.dev/), which installs the pinned Rust, Java Development Kit, and Once toolchains.
- macOS: Xcode command line tools, including an iOS simulator runtime for the iOS application.
- Android: Android Software Development Kit Platform 35, Build Tools 35.0.0, and the Android Native Development Kit for `arm64-v8a`.

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

## Android setup

Before building the Android application, configure the location of the [Android Software Development Kit](https://developer.android.com/tools) and the [Android Native Development Kit](https://developer.android.com/ndk):

```sh
export ANDROID_SDK_ROOT=/path/to/android-sdk
export ANDROID_NDK_HOME=/path/to/android-ndk
mise run build:android
```

## Updating the logo

`assets/tuist-logo.svg` is the Tuist brand logo. Run `scripts/generate_app_icons.sh` after updating it to regenerate the macOS and iOS application icons and the in-app image assets.
