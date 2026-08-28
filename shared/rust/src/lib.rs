//! Shared product identity exposed to each Tuist Code application.

use core::ffi::c_char;

/// The product name used by Tuist Code applications.
pub const APP_NAME: &str = "Tuist Code";

/// The primary Tuist brand colour, represented as an RGB hexadecimal value.
pub const BRAND_COLOR: u32 = 0x6F2CFF;

const APP_NAME_C_STRING: &[u8] = b"Tuist Code\0";

/// Returns the shared product name.
pub const fn app_name() -> &'static str {
    APP_NAME
}

/// Returns the shared primary Tuist brand colour.
pub const fn brand_color() -> u32 {
    BRAND_COLOR
}

/// Exposes the product name to Apple application code.
#[unsafe(no_mangle)]
pub extern "C" fn tuist_code_app_name() -> *const c_char {
    APP_NAME_C_STRING.as_ptr().cast()
}

/// Exposes the primary brand colour to native applications.
#[unsafe(no_mangle)]
pub extern "C" fn tuist_code_brand_color() -> u32 {
    brand_color()
}

/// Exposes the primary brand colour to Android application code.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_tuist_code_MainActivity_brandColor(
    _environment: *mut core::ffi::c_void,
    _instance: *mut core::ffi::c_void,
) -> i32 {
    brand_color() as i32
}
