use gpui::ClipboardItem;
use latex_render::{LatexRenderer, MathPlacement, latex_formula_element};
use ui::prelude::*;

use super::OutputContent;

pub struct LatexView {
    source: SharedString,
    renderer: LatexRenderer,
}

impl LatexView {
    pub fn new(source: SharedString, cx: &mut Context<Self>) -> Self {
        Self {
            source,
            renderer: LatexRenderer::for_view(cx.background_executor().clone(), cx),
        }
    }
}

fn formula_source(source: &str) -> &str {
    let source = source.trim();
    // Jupyter kernels may include math delimiters, which RaTeX does not need.
    for (opening, closing) in [("$$", "$$"), ("$", "$"), (r"\[", r"\]"), (r"\(", r"\)")] {
        if let Some(formula) = source
            .strip_prefix(opening)
            .and_then(|source| source.strip_suffix(closing))
        {
            return formula;
        }
    }
    source
}

impl OutputContent for LatexView {
    fn clipboard_content(&self, _window: &Window, _cx: &App) -> Option<ClipboardItem> {
        Some(ClipboardItem::new_string(self.source.to_string()))
    }

    fn has_clipboard_content(&self, _window: &Window, _cx: &App) -> bool {
        true
    }
}

impl Render for LatexView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let result = self.renderer.render(formula_source(&self.source), true);
        div()
            .id("latex-output")
            .w_full()
            .overflow_x_scroll()
            .py_2()
            .text_color(cx.theme().colors().text)
            .child(match result {
                Some(Ok(formula)) => div()
                    .flex()
                    .child(div().flex_none().mx_auto().child(latex_formula_element(
                        formula,
                        MathPlacement::Display,
                        1.2,
                    )))
                    .into_any_element(),
                Some(Err(_)) => div().child(self.source.clone()).into_any_element(),
                None => div().h(rems(1.2)).into_any_element(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::formula_source;

    #[test]
    fn test_latex_output_delimiters() {
        let formula = r"\displaystyle M_{A \to B}";
        for source in [
            formula.to_string(),
            format!(" ${formula}$ "),
            format!("$${formula}$$"),
            format!(r"\[{formula}\]"),
            format!(r"\({formula}\)"),
        ] {
            assert_eq!(formula_source(&source), formula);
        }
    }
}
