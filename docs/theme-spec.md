# Tuist Code theme specification

## Purpose

This specification defines the semantic appearance roles that every Tuist Code
client resolves locally. A theme never identifies views by screen or component;
clients ask for roles such as `accent` and `textSecondary` instead. That keeps
the same theme meaningful on macOS, iPhone Operating System, and Android.

## Theme identity

| Identifier | Appearance preference | Meaning |
| --- | --- | --- |
| `system` | Follow the operating system | Use each platform's semantic colours and current appearance. |
| `light` | Light | Use the light palette. |
| `dark` | Dark | Use the dark palette. |

The selected identifier is a user preference. System accessibility settings,
including increased contrast and text size, continue to take priority over a
theme's visual choices.

## Semantic tokens

| Token | Use |
| --- | --- |
| `accent` | Primary actions, selection, and focus. |
| `canvas` | Main application background. |
| `surface` | Raised content such as sheets and grouped panels. |
| `selection` | Selected rows and controls. |
| `textPrimary` | Main labels and headings. |
| `textSecondary` | Supporting text and metadata. |
| `textOnAccent` | Content placed on the accent colour. |
| `separator` | Dividers and inactive borders. |
| `danger` | Destructive actions and failures. |

Each client maps system-theme tokens to its own semantic system colours. Light
and dark palettes use the same roles and Tuist purple (`#6F2CFF`) as their
accent. Typography uses the platform's dynamic text styles instead of fixed
theme font sizes.

## Client contract

- New interface code consumes semantic tokens through its platform theme layer.
- Interface code does not persist raw colour values or a platform appearance.
- Shared Rust code does not decide appearance. It can carry a theme identifier
  when product data needs one, while each client resolves that identifier into
  platform-native colours.
- New themes add token values without changing view logic.
