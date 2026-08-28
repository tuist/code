# Code

Code is an experimental native coding environment.

Its first screen uses [GPUI, a GPU-accelerated user interface framework](https://gpui.rs/) from the creators of [Zed](https://zed.dev/). [Once](https://buildonce.dev/) owns the build and test graph, so local development and GitHub Actions exercise the same targets.

## Requirements

- [Mise](https://mise.jdx.dev/), which installs the pinned Rust and Once toolchains.
- macOS: Xcode command line tools and the Metal Toolchain component. GPUI renders with Metal. Install the component with `xcodebuild -downloadComponent MetalToolchain` when Xcode does not already provide it.
- Linux: development packages for Fontconfig, Wayland or the [X Window System (X11)](https://www.x.org/wiki/), the X Keyboard Extension, and Vulkan. The GitHub Actions workflow shows the Debian and Ubuntu package names.

## Start the app

```sh
mise install
mise run run
```

The first run fetches the locked Rust packages, builds GPUI, and opens a centered native window.

## Development commands

```sh
mise run format
mise run build
mise run test
mise run validate
```

`once.toml` adapts the Cargo workspace into Once targets. The current targets are `cargo_code_bin_code` for the application and `cargo_code_bin_code_unit_tests` for its tests.
