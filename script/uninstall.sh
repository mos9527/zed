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

remove_link() {
    if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
        rm -f "$1"
    fi
}

case "$(uname -s)" in
    Linux)
        app_dir="$HOME/.local/zedc$suffix.app"
        data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/zedc"
        config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/zedc"
        app_id="$(printf '%s' "io.github.mos9527.ZedCustom$label" | tr ' ' '-')"

        rm -rf "$app_dir" "$data_dir/db/0-$channel"
        rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$app_id.desktop" "$data_dir/zedc-$channel.sock"
        remove_link "$HOME/.local/bin/zedc" "$app_dir/bin/zedc"
        set -- "$HOME"/.local/zedc*.app
        ;;
    Darwin)
        app_dir="/Applications/Zed Custom$label.app"
        data_dir="$HOME/Library/Application Support/ZedC"
        config_dir="$HOME/.config/zedc"
        app_id="$(printf '%s' "io.github.mos9527.ZedCustom$label" | tr ' ' '-')"

        rm -rf "$app_dir" "$data_dir/db/0-$channel" \
            "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$app_id.sfl"* \
            "$HOME/Library/Caches/$app_id" "$HOME/Library/HTTPStorages/$app_id" \
            "$HOME/Library/Preferences/$app_id.plist" "$HOME/Library/Saved Application State/$app_id.savedState"
        remove_link "$HOME/.local/bin/zedc" "$app_dir/Contents/MacOS/zedc-cli"
        remove_link "/usr/local/bin/zedc" "$app_dir/Contents/MacOS/zedc-cli"
        set -- /Applications/"Zed Custom"*.app
        ;;
    *)
        echo "Unsupported platform: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ ! -e "$1" ]; then
    rm -rf "$data_dir"
    if [ "$(uname -s)" = Darwin ]; then
        rm -rf "$HOME/Library/Logs/ZedC"
    fi
    printf "Do you want to keep your Zed Custom preferences? [Y/n] "
    if read -r response; then
        case "$response" in
            [nN]|[nN][oO]) rm -rf "$config_dir" ;;
        esac
    fi
fi

echo "Zed Custom has been uninstalled."
