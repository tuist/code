use gpui::prelude::*;
use gpui::{
    App, Application, Bounds, Context, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, px, rgb, size,
};

const WINDOW_TITLE: &str = "Code";

struct CodingEnvironment;

impl Render for CodingEnvironment {
    fn render(&mut self, window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(WINDOW_TITLE);

        div()
            .size_full()
            .bg(rgb(0x171717))
            .text_color(rgb(0xf5f5f5))
            .justify_center()
            .items_center()
            .child(WINDOW_TITLE)
    }
}

fn main() {
    Application::new().run(|cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1280.0), px(800.0)), cx);

        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            |_, cx| cx.new(|_| CodingEnvironment),
        )
        .expect("the native window should open");

        cx.activate(true);
    });
}

#[cfg(test)]
mod tests {
    use super::WINDOW_TITLE;

    #[test]
    fn names_the_initial_window() {
        assert_eq!(WINDOW_TITLE, "Code");
    }
}
