<p align="center">
  <img src="assets/tuist-logo.svg" alt="Tuist Code logo" width="96">
</p>

# Tuist Code

> [!WARNING]
> Tuist Code is a work in progress. Expect rough edges and breaking changes while we explore the experience. The mobile applications are currently distributed through GitHub Releases, but we might distribute them through the [Apple App Store](https://developer.apple.com/app-store/) and [Google Play](https://play.google.com/) in the future.

Tuist Code is a native coding environment for macOS, iOS, and Android. We believe coding can flow naturally across environments without first requiring cache infrastructure, making it faster to move between a desk, phone, and tablet while staying in the same workspace.

The project is experimental, and the best way to try it today is to install the latest application for your platform.

## Install Tuist Code

Download the files for the latest version from [GitHub Releases](https://github.com/tuist/code/releases/latest). Each release includes checksum files named `SHA256SUMS.txt` and `SHA512SUMS.txt` so you can verify a download before installing it.

### macOS

1. Download `Tuist-Code-macOS-<version>.zip` and extract it.
2. Move `Tuist Code.app` to the Applications folder.
3. Open Tuist Code from the Applications folder.

The application is signed and notarized by Apple. After installation, [Sparkle](https://sparkle-project.org/) checks GitHub Releases for updates and offers new versions from within the application.

### iOS

The iOS package uses ad hoc distribution and only works on devices whose identifiers are included in the provisioning profile.

1. Download `Tuist-Code-iOS-<version>.ipa` on a Mac.
2. Connect a registered iPhone or iPad to the Mac.
3. Open [Apple Configurator](https://support.apple.com/apple-configurator), select the device, and choose **Add > Apps > Choose from my Mac**.
4. Select the downloaded package and wait for installation to finish.

### Android

1. Download `Tuist-Code-Android-<version>.apk` on the Android device.
2. Allow the browser or file manager to install unknown applications when Android prompts you.
3. Open the downloaded package and confirm the installation.

You can also install it from a computer with [Android Debug Bridge](https://developer.android.com/tools/adb):

```sh
adb install Tuist-Code-Android-*.apk
```

### Verify a download

Download `SHA256SUMS.txt` alongside the application package, then run the command for your file from the download directory. For example, to verify the macOS archive:

```sh
grep 'Tuist-Code-macOS-' SHA256SUMS.txt | shasum -a 256 --check
```

## How it works

Tuist Code works locally without an account. You can add Git repositories and create worktree-backed coding sessions. Connecting a Tuist account adds Tuist-backed capabilities, including remote sessions and remote builds.
