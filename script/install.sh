#!/usr/bin/env sh
set -eu

channel="${ZED_CHANNEL:-stable}"
case "$channel" in
    stable) suffix=""; label="" ;;
    nightly) suffix="-nightly"; label=" Nightly" ;;
    preview) suffix="-preview"; label=" Preview" ;;
    dev) suffix="-dev"; label=" Dev" ;;
    *) echo "Unknown release channel: $channel" >&2; exit 1 ;;
esac

temp="$(mktemp -d "${TMPDIR:-/tmp}/zedc-XXXXXX")"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach -quiet "$temp/mount" || return
    fi
    rm -rf "$temp"
}
trap cleanup EXIT

platform="$(uname -s)"
bundle="${ZED_BUNDLE_PATH:-${1:-}}"
if [ -z "$bundle" ]; then
    case "$(uname -m)" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64) arch=x86_64 ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    case "$platform" in
        Darwin) asset="ZedCustom-$arch.dmg" ;;
        Linux) asset="zedc-linux-$arch.tar.gz" ;;
        *) echo "Unsupported platform: $platform" >&2; exit 1 ;;
    esac

    release_base="https://github.com/mos9527/zed/releases"
    if [ -n "${ZED_VERSION:-}" ] && [ "$ZED_VERSION" != latest ]; then
        url="$release_base/download/$ZED_VERSION/$asset"
    elif [ "$channel" = stable ]; then
        url="$release_base/latest/download/$asset"
    else
        echo "Set ZED_VERSION to a release tag or provide a local bundle for $channel." >&2
        exit 1
    fi

    bundle="$temp/$asset"
    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$bundle"
    elif command -v wget >/dev/null 2>&1; then
        wget "$url" -O "$bundle"
    else
        echo "Install curl or wget, or provide a downloaded bundle." >&2
        exit 1
    fi
elif [ ! -f "$bundle" ]; then
    echo "Bundle not found: $bundle" >&2
    exit 1
fi

case "$platform" in
    Linux)
        app_id="io.github.mos9527.ZedCustom$label"
        app_id="$(printf '%s' "$app_id" | tr ' ' '-')"
        app_name="zedc$suffix.app"
        tar -xzf "$bundle" -C "$temp" "$app_name"
        staged_app="$temp/$app_name"
        if [ ! -x "$staged_app/bin/zedc" ] || [ ! -x "$staged_app/libexec/zedc-editor" ] ||
            [ ! -f "$staged_app/share/applications/$app_id.desktop" ]; then
            echo "Invalid Zed Custom bundle for channel $channel" >&2
            exit 1
        fi

        if command -v ldd >/dev/null 2>&1; then
            missing="$(ldd "$staged_app/libexec/zedc-editor" 2>/dev/null | sed -n 's/^[[:space:]]*\(.*\) => not found$/\1/p')"
            if [ -n "$missing" ]; then
                echo "Zed Custom needs these missing libraries:"
                echo "$missing" | sed 's/^/    /'
            fi
        fi

        app_dir="$HOME/.local/$app_name"
        desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
        mkdir -p "$HOME/.local/bin" "$desktop_dir"
        rm -rf "$app_dir"
        mv "$staged_app" "$app_dir"
        cli="$app_dir/bin/zedc"
        # Escape the replacement text for sed and quote the executable in the desktop entry.
        desktop_path="$(printf '%s' "$app_dir" | sed 's/[\\&|]/\\&/g')"
        sed -e "s|^Icon=zedc$|Icon=$desktop_path/share/icons/hicolor/512x512/apps/zedc.png|" \
            -e "s|^Exec=zedc |Exec=\"$desktop_path/bin/zedc\" |" \
            -e "s|^TryExec=zedc$|TryExec=$desktop_path/bin/zedc|" \
            "$app_dir/share/applications/$app_id.desktop" > "$desktop_dir/$app_id.desktop"
        ;;
    Darwin)
        app_name="Zed Custom$label.app"
        hdiutil attach -quiet -nobrowse -readonly "$bundle" -mountpoint "$temp/mount"
        mounted=true
        source_app="$temp/mount/$app_name"
        if [ ! -x "$source_app/Contents/MacOS/zedc" ] || [ ! -x "$source_app/Contents/MacOS/zedc-cli" ]; then
            echo "Invalid Zed Custom bundle for channel $channel" >&2
            exit 1
        fi

        app_dir="/Applications/$app_name"
        mkdir -p "$HOME/.local/bin"
        rm -rf "$app_dir"
        ditto "$source_app" "$app_dir"
        cli="$app_dir/Contents/MacOS/zedc-cli"
        ;;
    *)
        echo "Unsupported platform: $platform" >&2
        exit 1
        ;;
esac

ln -sf "$cli" "$HOME/.local/bin/zedc"
echo "Zed Custom is installed. Run zedc or use $HOME/.local/bin/zedc."
