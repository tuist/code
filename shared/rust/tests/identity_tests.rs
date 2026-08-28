use tuist_code_shared::{APP_NAME, BRAND_COLOR, app_name, brand_color};

#[test]
fn shares_the_product_name() {
    assert_eq!(app_name(), APP_NAME);
    assert_eq!(APP_NAME, "Tuist Code");
}

#[test]
fn shares_the_tuist_brand_colour() {
    assert_eq!(brand_color(), BRAND_COLOR);
    assert_eq!(BRAND_COLOR, 0x6F2CFF);
}
