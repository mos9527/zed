use client::ZED_CUSTOM_URL_SCHEME;
use gpui::{AsyncApp, actions};

actions!(
    cli,
    [
        /// Registers the zedc:// URL scheme handler.
        RegisterZedScheme
    ]
);

pub async fn register_zed_scheme(cx: &AsyncApp) -> anyhow::Result<()> {
    cx.update(|cx| cx.register_url_scheme(ZED_CUSTOM_URL_SCHEME))
        .await
}
