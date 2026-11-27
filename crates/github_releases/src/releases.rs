use anyhow::{Context as _, Result, anyhow, bail};
use futures::AsyncReadExt;
use http_client::http::header::{AUTHORIZATION, HeaderValue};
use http_client::{AsyncBody, HttpClient, HttpRequestExt, Request, Url};
use serde::{Deserialize, Deserializer};
use std::{sync::Arc, time::Duration};
use util::command::{Stdio, new_command};

const GITHUB_API_URL: &str = "https://api.github.com";
const GITHUB_RELEASE_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const GITHUB_CLI_TIMEOUT: Duration = Duration::from_secs(2);

pub struct GitHubLspBinaryVersion {
    pub name: String,
    pub url: String,
    pub digest: Option<String>,
}

#[derive(Deserialize, Debug)]
pub struct GithubRelease {
    pub tag_name: String,
    #[serde(rename = "prerelease")]
    pub pre_release: bool,
    pub assets: Vec<GithubReleaseAsset>,
    pub tarball_url: String,
    pub zipball_url: String,
}

#[derive(Deserialize, Debug)]
pub struct GithubReleaseAsset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default, deserialize_with = "deserialize_sha256_digest")]
    pub digest: Option<String>,
}

fn deserialize_sha256_digest<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    const PREFIX: &str = "sha256:";

    let mut digest = Option::<String>::deserialize(deserializer)?;
    if let Some(digest) = digest.as_mut()
        && digest.starts_with(PREFIX)
    {
        digest.replace_range(..PREFIX.len(), "");
    }
    Ok(digest)
}

pub async fn latest_github_release(
    repo_name_with_owner: &str,
    require_assets: bool,
    pre_release: bool,
    http: Arc<dyn HttpClient>,
) -> anyhow::Result<GithubRelease> {
    let url = format!("{GITHUB_API_URL}/repos/{repo_name_with_owner}/releases");

    let request = github_api_request(&url, github_token().await.as_deref())?;

    let mut response = http
        .send(request)
        .await
        .context("error fetching latest release")?;

    let mut body = Vec::new();
    response
        .body_mut()
        .read_to_end(&mut body)
        .await
        .context("error reading latest release")?;

    if response.status().is_client_error() {
        let text = String::from_utf8_lossy(body.as_slice());
        bail!(
            "status error {}, response: {text:?}",
            response.status().as_u16()
        );
    }

    let releases = match serde_json::from_slice::<Vec<GithubRelease>>(body.as_slice()) {
        Ok(releases) => releases,

        Err(err) => {
            log::error!("Error deserializing: {err:?}");
            log::error!(
                "GitHub API response text: {:?}",
                String::from_utf8_lossy(body.as_slice())
            );
            anyhow::bail!("error deserializing latest release: {err:?}");
        }
    };

    releases
        .into_iter()
        .filter(|release| !require_assets || !release.assets.is_empty())
        .find(|release| release.pre_release == pre_release)
        .context("finding a prerelease")
}

pub async fn get_release_by_tag_name(
    repo_name_with_owner: &str,
    tag: &str,
    http: Arc<dyn HttpClient>,
) -> anyhow::Result<GithubRelease> {
    let url = format!("{GITHUB_API_URL}/repos/{repo_name_with_owner}/releases/tags/{tag}");

    let request = github_api_request(&url, github_token().await.as_deref())?;

    let mut response = http
        .send(request)
        .await
        .context("error fetching latest release")?;

    let mut body = Vec::new();
    let status = response.status();
    response
        .body_mut()
        .read_to_end(&mut body)
        .await
        .context("error reading latest release")?;

    if status.is_client_error() {
        let text = String::from_utf8_lossy(body.as_slice());
        bail!(
            "status error {}, response: {text:?}",
            response.status().as_u16()
        );
    }

    let release = serde_json::from_slice::<GithubRelease>(body.as_slice()).map_err(|err| {
        log::error!("Error deserializing: {err:?}");
        log::error!(
            "GitHub API response text: {:?}",
            String::from_utf8_lossy(body.as_slice())
        );
        anyhow!("error deserializing GitHub release: {err:?}")
    })?;

    Ok(release)
}

async fn github_token() -> Option<String> {
    github_cli_token()
        .await
        .or_else(|| std::env::var("GITHUB_TOKEN").ok())
}

async fn github_cli_token() -> Option<String> {
    let executable = which::which_global("gh").ok()?;
    let mut command = new_command(executable);
    command
        .args(["auth", "token", "--hostname", "github.com"])
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);

    let output = smol::future::race(async { command.output().await.ok() }, async {
        smol::Timer::after(GITHUB_CLI_TIMEOUT).await;
        None
    })
    .await?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    let token = stdout.trim();
    (!token.is_empty() && token.bytes().all(|byte| byte.is_ascii_graphic()))
        .then(|| token.to_owned())
}

fn github_api_request(url: &str, token: Option<&str>) -> Result<Request<AsyncBody>> {
    let mut request = Request::get(url)
        .follow_redirects(http_client::RedirectPolicy::FollowAll)
        .timeout(GITHUB_RELEASE_REQUEST_TIMEOUT);
    if let Some(token) = token {
        let mut authorization = HeaderValue::from_str(&format!("Bearer {token}"))?;
        authorization.set_sensitive(true);
        request = request.header(AUTHORIZATION, authorization);
    }
    Ok(request.body(Default::default())?)
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum AssetKind {
    TarGz,
    TarBz2,
    Gz,
    Zip,
}

pub fn build_asset_url(repo_name_with_owner: &str, tag: &str, kind: AssetKind) -> Result<String> {
    let mut url = Url::parse(&format!(
        "https://github.com/{repo_name_with_owner}/archive/refs/tags",
    ))?;
    // We're pushing this here, because tags may contain `/` and other characters
    // that need to be escaped.
    let asset_filename = format!(
        "{tag}.{extension}",
        extension = match kind {
            AssetKind::TarGz => "tar.gz",
            AssetKind::TarBz2 => "tar.bz2",
            AssetKind::Gz => "gz",
            AssetKind::Zip => "zip",
        }
    );
    url.path_segments_mut()
        .map_err(|()| anyhow!("cannot modify url path segments"))?
        .push(&asset_filename);
    Ok(url.to_string())
}

#[cfg(test)]
mod tests {
    use super::{
        AssetKind, GITHUB_RELEASE_REQUEST_TIMEOUT, GithubReleaseAsset, build_asset_url,
        github_api_request,
    };
    use http_client::RequestTimeout;
    use http_client::http::header::AUTHORIZATION;

    #[test]
    fn test_asset_digest_deserialization() {
        let parse = |json: &str| {
            serde_json::from_str::<GithubReleaseAsset>(json)
                .unwrap()
                .digest
        };

        assert_eq!(
            parse(r#"{"name":"a","browser_download_url":"u","digest":"sha256:abc"}"#),
            Some("abc".to_string())
        );
        assert_eq!(
            parse(r#"{"name":"a","browser_download_url":"u","digest":"abc"}"#),
            Some("abc".to_string())
        );
        assert_eq!(
            parse(r#"{"name":"a","browser_download_url":"u","digest":null}"#),
            None
        );
        assert_eq!(parse(r#"{"name":"a","browser_download_url":"u"}"#), None);
    }

    #[test]
    fn github_api_requests_have_a_total_deadline() {
        let request = github_api_request(
            "https://api.github.com/repos/zed-industries/zed/releases",
            None,
        )
        .unwrap();

        assert_eq!(
            request.extensions().get::<RequestTimeout>(),
            Some(&RequestTimeout(GITHUB_RELEASE_REQUEST_TIMEOUT))
        );
    }

    #[test]
    fn github_api_requests_use_sensitive_bearer_authentication() {
        let request = github_api_request(
            "https://api.github.com/repos/zed-industries/zed/releases",
            Some("test-token"),
        )
        .unwrap();

        let authorization = request.headers().get(AUTHORIZATION).unwrap();
        assert_eq!(authorization, "Bearer test-token");
        assert!(authorization.is_sensitive());
    }

    #[test]
    fn test_build_asset_url() {
        let tag = "release/2.3.5";
        let repo_name_with_owner = "microsoft/vscode-eslint";

        let tarball = build_asset_url(repo_name_with_owner, tag, AssetKind::TarGz).unwrap();
        assert_eq!(
            tarball,
            "https://github.com/microsoft/vscode-eslint/archive/refs/tags/release%2F2.3.5.tar.gz"
        );

        let zip = build_asset_url(repo_name_with_owner, tag, AssetKind::Zip).unwrap();
        assert_eq!(
            zip,
            "https://github.com/microsoft/vscode-eslint/archive/refs/tags/release%2F2.3.5.zip"
        );
    }
}
