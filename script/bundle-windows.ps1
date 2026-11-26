[CmdletBinding()]
Param(
    [Parameter()][Alias('i')][switch]$Install,
    [Parameter()][Alias('h')][switch]$Help,
    [Parameter()][Alias('a')][string]$Architecture,
    [Parameter()][string]$Name
)

. "$PSScriptRoot/lib/workspace.ps1"

# https://stackoverflow.com/questions/57949031/powershell-script-stops-if-program-fails-like-bash-set-o-errexit
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$buildSuccess = $false
$canCodeSign = $false
$includeExplorerPackage = $false

$OSArchitecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    "X64" { "x86_64" }
    "Arm64" { "aarch64" }
    default { throw "Unsupported architecture" }
}

$Architecture = if ($Architecture) {
    $Architecture
} else {
    $OSArchitecture
}

$CargoOutDir = "./target/$Architecture-pc-windows-msvc/release"

function Get-VSArch {
    param(
        [string]$Arch
    )

    switch ($Arch) {
        "x86_64" { "amd64" }
        "aarch64" { "arm64" }
    }
}

Push-Location
& "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch (Get-VSArch -Arch $Architecture) -HostArch (Get-VSArch -Arch $OSArchitecture)
Pop-Location

$target = "$Architecture-pc-windows-msvc"

if ($Help) {
    Write-Output "Usage: test.ps1 [-Install] [-Help]"
    Write-Output "Build the installer for Windows.\n"
    Write-Output "Options:"
    Write-Output "  -Architecture, -a Which architecture to build (x86_64 or aarch64)"
    Write-Output "  -Install, -i      Run the installer after building."
    Write-Output "  -Help, -h         Show this help message."
    exit 0
}

Push-Location -Path crates/zed
$channel = Get-Content "RELEASE_CHANNEL"
$env:ZED_RELEASE_CHANNEL = $channel
$env:RELEASE_CHANNEL = $channel
Pop-Location

function CheckEnvironmentVariables {
    if(-not $env:CI) {
        return
    }

    $requiredVars = @('ZED_WORKSPACE', 'RELEASE_VERSION', 'ZED_RELEASE_CHANNEL')

    foreach ($var in $requiredVars) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($var))) {
            Write-Error "$var is not set"
            exit 1
        }
    }

    # On PRs from forks the signing secrets are not populated,
    # so skip code signing instead of failing, like bundle-mac does.
    $signingVars = @(
        'AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET',
        'ACCOUNT_NAME', 'CERT_PROFILE_NAME', 'ENDPOINT',
        'FILE_DIGEST', 'TIMESTAMP_DIGEST', 'TIMESTAMP_SERVER'
    )

    $missingVars = @($signingVars | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
    if ($missingVars.Count -eq 0) {
        $script:canCodeSign = $true
    } else {
        Write-Host "====== WARNING ======"
        Write-Host "One or more of the following variables are missing: $($missingVars -join ', ')"
        Write-Host "This bundle will not be code signed"
        Write-Host "====== WARNING ======"
    }
}

function PrepareForBundle {
    if (Test-Path "$innoDir") {
        Remove-Item -Path "$innoDir" -Recurse -Force
    }
    New-Item -Path "$innoDir" -ItemType Directory -Force
    Copy-Item -Path "$env:ZED_WORKSPACE\crates\zed\resources\windows\*" -Destination "$innoDir" -Recurse -Force
    New-Item -Path "$innoDir\make_appx" -ItemType Directory -Force
    New-Item -Path "$innoDir\appx" -ItemType Directory -Force
    New-Item -Path "$innoDir\bin" -ItemType Directory -Force
    New-Item -Path "$innoDir\tools" -ItemType Directory -Force

    rustup target add $target
}

function GenerateLicenses {
    . $PSScriptRoot/generate-licenses.ps1
}

function BuildZedAndItsFriends {
    Write-Output "Building Zed and its friends, for channel: $channel"
    # Build zedc.exe, cli.exe and auto-update-helper.exe
    cargo --config .cargo/bundle-config.toml build --release --package zed --package cli --package auto_update_helper --target $target
    Copy-Item -Path ".\$CargoOutDir\zedc.exe" -Destination "$innoDir\zedc.exe" -Force
    Copy-Item -Path ".\$CargoOutDir\cli.exe" -Destination "$innoDir\cli.exe" -Force
    Copy-Item -Path ".\$CargoOutDir\auto-update-helper.exe" -Destination "$innoDir\auto_update_helper.exe" -Force
    if (-not $includeExplorerPackage) {
        return
    }
    # Build explorer_command_injector.dll
    switch ($channel) {
        "stable" {
            cargo --config .cargo/bundle-config.toml build --release --features stable --no-default-features --package explorer_command_injector --target $target
        }
        "preview" {
            cargo --config .cargo/bundle-config.toml build --release --features preview --no-default-features --package explorer_command_injector --target $target
        }
        default {
            cargo --config .cargo/bundle-config.toml build --release --package explorer_command_injector --target $target
        }
    }
    Copy-Item -Path ".\$CargoOutDir\explorer_command_injector.dll" -Destination "$innoDir\zed_explorer_command_injector.dll" -Force
}

function BuildRemoteServer {
    Write-Output "Building remote_server for $target"
    cargo --config .cargo/bundle-config.toml build --release --package remote_server --target $target

    # SSH clients expect remote_server.exe inside the archive.
    Copy-Item -Path ".\$CargoOutDir\remote-server.exe" -Destination "$innoDir\remote_server.exe" -Force
    $remoteServerSrc = (Resolve-Path "$innoDir\remote_server.exe").Path

    if ($canCodeSign) {
        Write-Output "Code signing remote_server.exe"
        & "$innoDir\sign.ps1" $remoteServerSrc
    }

    $remoteServerDst = "$env:ZED_WORKSPACE\target\zed-remote-server-windows-$Architecture.zip"
    Write-Output "Compressing remote_server to $remoteServerDst"
    Compress-Archive -Path $remoteServerSrc -DestinationPath $remoteServerDst -Force
    Remove-Item -Path $remoteServerSrc -Force

    Write-Output "Remote server compressed successfully"
}

function ZipZedAndItsFriendsDebug {
    $items = @(
        ".\$CargoOutDir\zedc.pdb",
        ".\$CargoOutDir\cli.pdb",
        ".\$CargoOutDir\auto_update_helper.pdb",
        ".\$CargoOutDir\remote_server.pdb"
    )

    if ($includeExplorerPackage) {
        $items += ".\$CargoOutDir\explorer_command_injector.pdb"
    }

    Compress-Archive -Path $items -DestinationPath ".\$CargoOutDir\zed-$env:RELEASE_VERSION-$env:ZED_RELEASE_CHANNEL.dbg.zip" -Force
}


function UploadToSentry {
    if (-not (Get-Command "sentry-cli" -ErrorAction SilentlyContinue)) {
        Write-Output "sentry-cli not found. skipping sentry upload."
        Write-Output "install with: 'winget install -e --id=Sentry.sentry-cli'"
        return
    }
    if ([string]::IsNullOrWhiteSpace($env:SENTRY_AUTH_TOKEN)) {
        Write-Output "missing SENTRY_AUTH_TOKEN. skipping sentry upload."
        return
    }
    Write-Output "Uploading zed debug symbols to sentry..."
    for ($i = 1; $i -le 3; $i++) {
        try {
            sentry-cli debug-files upload --include-sources --wait -p zed -o zed-dev $CargoOutDir
            break
        }
        catch {
            Write-Output "Sentry upload attempt $i failed: $_"
            if ($i -eq 3) {
                Write-Output "All sentry upload attempts failed"
                throw
            }
            Start-Sleep -Seconds 2
        }
    }
}

function MakeAppx {
    if (-not $includeExplorerPackage) {
        return
    }
    switch ($channel) {
        "stable" {
            $manifestFile = "$env:ZED_WORKSPACE\crates\explorer_command_injector\AppxManifest.xml"
        }
        "preview" {
            $manifestFile = "$env:ZED_WORKSPACE\crates\explorer_command_injector\AppxManifest-Preview.xml"
        }
        default {
            $manifestFile = "$env:ZED_WORKSPACE\crates\explorer_command_injector\AppxManifest-Nightly.xml"
        }
    }
    [xml]$manifest = Get-Content -LiteralPath $manifestFile -Raw
    $manifest.Package.Identity.Publisher = $env:ZED_CUSTOM_APPX_PUBLISHER
    $manifest.Save("$innoDir\make_appx\AppxManifest.xml")
    # Add makeAppx.exe to Path
    $sdk = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64"
    $env:Path += ';' + $sdk
    makeAppx.exe pack /d "$innoDir\make_appx" /p "$innoDir\zed_explorer_command_injector.appx" /nv
}

function SignZedAndItsFriends {
    if (-not $canCodeSign) {
        return
    }

    $files = @("$innoDir\zedc.exe", "$innoDir\cli.exe", "$innoDir\auto_update_helper.exe")
    if ($includeExplorerPackage) {
        $files += "$innoDir\zed_explorer_command_injector.dll", "$innoDir\zed_explorer_command_injector.appx"
    }
    & "$innoDir\sign.ps1" ($files -join ',')
}

function DownloadConpty {
    # TODO: Switch back to the stable channel once Microsoft finally decides to publish v1.26
    $url = "https://github.com/microsoft/terminal/releases/download/v1.25.1912.0/Microsoft.Windows.Console.ConPTY.1.25.260710002-preview.nupkg"
    $zipPath = ".\Microsoft.Windows.Console.ConPTY.1.25.260710002-preview.nupkg"
    Invoke-WebRequest -Uri $url -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath ".\conpty" -Force
}

function CollectFiles {
    if ($includeExplorerPackage) {
        Move-Item -Path "$innoDir\zed_explorer_command_injector.appx" -Destination "$innoDir\appx\zed_explorer_command_injector.appx" -Force
        Move-Item -Path "$innoDir\zed_explorer_command_injector.dll" -Destination "$innoDir\appx\zed_explorer_command_injector.dll" -Force
    }
    Move-Item -Path "$innoDir\cli.exe" -Destination "$innoDir\bin\zedc.exe" -Force
    Move-Item -Path "$innoDir\zed.sh" -Destination "$innoDir\bin\zedc" -Force
    Move-Item -Path "$innoDir\auto_update_helper.exe" -Destination "$innoDir\tools\auto_update_helper.exe" -Force
    if($Architecture -eq "aarch64") {
        New-Item -Type Directory -Path "$innoDir\arm64" -Force
        Move-Item -Path ".\conpty\build\native\runtimes\arm64\OpenConsole.exe" -Destination "$innoDir\arm64\OpenConsole.exe" -Force
        Move-Item -Path ".\conpty\runtimes\win-arm64\native\conpty.dll" -Destination "$innoDir\conpty.dll" -Force
    }
    else {
        New-Item -Type Directory -Path "$innoDir\x64" -Force
        New-Item -Type Directory -Path "$innoDir\arm64" -Force
        Move-Item -Path ".\conpty\build\native\runtimes\x64\OpenConsole.exe" -Destination "$innoDir\x64\OpenConsole.exe" -Force
        Move-Item -Path ".\conpty\build\native\runtimes\arm64\OpenConsole.exe" -Destination "$innoDir\arm64\OpenConsole.exe" -Force
        Move-Item -Path ".\conpty\runtimes\win-x64\native\conpty.dll" -Destination "$innoDir\conpty.dll" -Force
    }
}

function BuildInstaller {
    $issFilePath = "$innoDir\zed.iss"
    switch ($channel) {
        "stable" {
            $appId = "{{31FDE773-D672-4070-A435-B25C5DA91F2B}"
            $appIconName = "app-icon"
            $appName = "Zed Custom"
            $appDisplayName = "Zed Custom"
            $appSetupName = "ZedCustom-$Architecture"
            # The mutex name here should match the mutex name in crates\zed\src\zed\windows_only_instance.rs
            $appMutex = "ZedCustom-Stable-Instance-Mutex"
            $appExeName = "zedc"
            $regValueName = "ZedCustom"
            $appUserId = "io.github.mos9527.ZedCustom"
            $appxName = "Mos9527.ZedCustom"
            $appShellNameShort = "Z&ed Custom"
        }
        "preview" {
            $appId = "{{4CA59352-0B97-4687-8F2C-ADC67A65261B}"
            $appIconName = "app-icon-preview"
            $appName = "Zed Custom Preview"
            $appDisplayName = "Zed Custom Preview"
            $appSetupName = "ZedCustom-$Architecture"
            # The mutex name here should match the mutex name in crates\zed\src\zed\windows_only_instance.rs
            $appMutex = "ZedCustom-Preview-Instance-Mutex"
            $appExeName = "zedc"
            $regValueName = "ZedCustomPreview"
            $appUserId = "io.github.mos9527.ZedCustom-Preview"
            $appxName = "Mos9527.ZedCustom.Preview"
            $appShellNameShort = "Z&ed Custom Preview"
        }
        "nightly" {
            $appId = "{{57A828FA-45EA-4CD7-8972-03C9AC1CD6ED}"
            $appIconName = "app-icon-nightly"
            $appName = "Zed Custom Nightly"
            $appDisplayName = "Zed Custom Nightly"
            $appSetupName = "ZedCustom-$Architecture"
            # The mutex name here should match the mutex name in crates\zed\src\zed\windows_only_instance.rs
            $appMutex = "ZedCustom-Nightly-Instance-Mutex"
            $appExeName = "zedc"
            $regValueName = "ZedCustomNightly"
            $appUserId = "io.github.mos9527.ZedCustom-Nightly"
            $appxName = "Mos9527.ZedCustom.Nightly"
            $appShellNameShort = "Z&ed Custom Nightly"
        }
        "dev" {
            $appId = "{{F6B7D974-4868-4AB1-9A93-1BD400FE1B1D}"
            $appIconName = "app-icon-dev"
            $appName = "Zed Custom Dev"
            $appDisplayName = "Zed Custom Dev"
            $appSetupName = "ZedCustom-$Architecture"
            # The mutex name here should match the mutex name in crates\zed\src\zed\windows_only_instance.rs
            $appMutex = "ZedCustom-Dev-Instance-Mutex"
            $appExeName = "zedc"
            $regValueName = "ZedCustomDev"
            $appUserId = "io.github.mos9527.ZedCustom-Dev"
            $appxName = "Mos9527.ZedCustom.Dev"
            $appShellNameShort = "Z&ed Custom Dev"
        }
        default {
            Write-Error "can't bundle installer for $channel."
            exit 1
        }
    }

    # Windows runner 2022 default has iscc in PATH, https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md
    # Currently, we are using Windows 2022 runner.
    # Windows runner 2025 doesn't have iscc in PATH for now, https://github.com/actions/runner-images/issues/11228
    $innoSetupPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

    $definitions = @{
        "AppId"          = $appId
        "AppIconName"    = $appIconName
        "OutputDir"      = "$env:ZED_WORKSPACE\target"
        "AppSetupName"   = $appSetupName
        "AppName"        = $appName
        "AppDisplayName" = $appDisplayName
        "RegValueName"   = $regValueName
        "AppMutex"       = $appMutex
        "AppExeName"     = $appExeName
        "ResourcesDir"   = "$innoDir"
        "ShellNameShort" = $appShellNameShort
        "AppUserId"      = $appUserId
        "Version"        = "$env:RELEASE_VERSION"
        "SourceDir"      = "$env:ZED_WORKSPACE"
        "AppxName"       = $appxName
    }

    if ($includeExplorerPackage) {
        $definitions["IncludeExplorerPackage"] = "1"
    }

    $defs = @()
    foreach ($key in $definitions.Keys) {
        $defs += "/d$key=`"$($definitions[$key])`""
    }

    $innoArgs = @($issFilePath) + $defs
    if($canCodeSign) {
        # Checked by zed.iss to decide whether to sign the installer.
        $env:ZED_SIGN_BUNDLE = "1"
        $signTool = "powershell.exe -ExecutionPolicy Bypass -File $innoDir\sign.ps1 `$f"
        $innoArgs += "/sDefaultsign=`"$signTool`""
    }

    # Execute Inno Setup
    Write-Host "🚀 Running Inno Setup: $innoSetupPath $innoArgs"
    $process = Start-Process -FilePath $innoSetupPath -ArgumentList $innoArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -eq 0) {
        Write-Host "✅ Inno Setup successfully compiled the installer"
        Write-Output "SETUP_PATH=target/$appSetupName.exe" >> $env:GITHUB_ENV
        $script:buildSuccess = $true
    }
    else {
        Write-Host "❌ Inno Setup failed: $($process.ExitCode)"
        $script:buildSuccess = $false
    }
}

ParseZedWorkspace
$innoDir = "$env:ZED_WORKSPACE\inno\$Architecture"
$debugArchive = "$CargoOutDir\zed-$env:RELEASE_VERSION-$env:ZED_RELEASE_CHANNEL.dbg.zip"
$debugStoreKey = "$env:ZED_RELEASE_CHANNEL/zed-$env:RELEASE_VERSION-$env:ZED_RELEASE_CHANNEL.dbg.zip"

CheckEnvironmentVariables
$includeExplorerPackage = $canCodeSign -and $channel -ne "dev" -and -not [string]::IsNullOrWhiteSpace($env:ZED_CUSTOM_APPX_PUBLISHER)
PrepareForBundle
GenerateLicenses
BuildZedAndItsFriends
BuildRemoteServer
MakeAppx
SignZedAndItsFriends
ZipZedAndItsFriendsDebug
DownloadConpty
CollectFiles
BuildInstaller

if($env:CI) {
    UploadToSentry
}

if ($buildSuccess) {
    Write-Output "Build successful"
    if ($Install) {
        Write-Output "Installing Zed Custom..."
        Start-Process -FilePath "$env:ZED_WORKSPACE/target/ZedCustom-$Architecture.exe"
    }
    exit 0
}
else {
    Write-Output "Build failed"
    exit 1
}
