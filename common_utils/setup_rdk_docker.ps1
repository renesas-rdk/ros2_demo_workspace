#!/usr/bin/env pwsh
# setup_rdk_docker.ps1: quick setup script for a Docker environment used to
# cross-build applications for the Renesas ARM64 platforms (R-Car V4H, RZ/V2H).
#
# Native Windows port of setup_rdk_docker.sh. Requires Docker Desktop running in
# *Linux containers* mode (WSL2 or Hyper-V backend). Docker-outside-of-Docker
# (host socket bind-mount) is intentionally omitted on Windows; qemu/binfmt
# emulation is left to Docker Desktop.
#
# Works with both Windows PowerShell 5.1 and PowerShell 7+ (pwsh).

$ErrorActionPreference = 'Stop'

$DefaultImage         = 'ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:latest'
$DefaultContainerName = 'ros2_cross_build_container'
$DefaultRos2Ws        = Join-Path $HOME 'ros2_ws'
$RemoteScriptUrl      = 'https://github.com/renesas-rdk/ros2_demo_workspace/raw/refs/heads/main/common_utils/setup_rdk_docker.ps1'

$ScriptPath = $PSCommandPath
$ScriptName = Split-Path -Leaf $ScriptPath

# Original args, preserved so we can re-exec after a self-update.
$OrigArgs = @($args)

# ----- Platform positional argument -----------------------------------------
$argList = [System.Collections.ArrayList]@($args)
if ($argList.Count -gt 0) {
    switch ([string]$argList[0]) {
        'rcarv4h' { $DefaultImage = 'ghcr.io/renesas-rdk/rcarv4h_ubuntu_xbuild:latest'; $argList.RemoveAt(0) }
        'rzv2h'   { $DefaultImage = 'ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:latest';   $argList.RemoveAt(0) }
    }
}

$Image          = $DefaultImage
$DockerPlatform = 'native'
$ContainerName  = ''
$Ros2Ws         = ''
$AutoYes        = $false
$AutoPull       = $false
$AutoCreate     = $false
$AutoShell      = $false
$SkipSelfUpdate = $false

function Show-Usage {
    @"
Usage: $ScriptName [platform] [options]

Platform: if specified, sets the default image and some config for a particular Renesas platform. If not specified, defaults to RZ/V2H.
  rcarv4h                      Use R-Car V4H image
  rzv2h                        Use RZ/V2H image (default)

Options:
  -i, --image IMAGE            Docker image
      --platform PLATFORM      Docker platform: native, linux/amd64, or linux/arm64
                               (default: native)
  -n, --container-name NAME    Container name
  -w, --workspace PATH         Host ROS 2 workspace path (absolute or relative)
  -y, --yes                    Non-interactive; accept yes for confirmations
      --pull                   Automatically pull/update image if needed
      --create                 Automatically create/start container if needed
      --shell                  Open shell in container after setup
      --no-self-update         Skip checking the remote repo for a newer script
  -h, --help                   Show this help

Examples:
  .\$ScriptName
  .\$ScriptName rcarv4h
  .\$ScriptName rzv2h
  .\$ScriptName rcarv4h -n my_container -w C:\Users\me\ros2_ws
  .\$ScriptName rzv2h -n my_container -w ~/ros2_ws -y --pull --create
  .\$ScriptName rzv2h --platform linux/arm64 -n my_container -w ~/ros2_ws -y --pull --create --shell
"@ | Write-Host
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Confirm-Yes {
    param([string]$Prompt)
    if ($AutoYes) { return $true }
    $reply = Read-Host "$Prompt [Y/n]"
    if ([string]::IsNullOrEmpty($reply)) { $reply = 'Y' }
    return ($reply -match '^[Yy]$')
}

function Confirm-NoDefault {
    param([string]$Prompt)
    if ($AutoShell) { return $true }
    if ($AutoYes)   { return $false }
    $reply = Read-Host "$Prompt [y/N]"
    if ([string]::IsNullOrEmpty($reply)) { $reply = 'N' }
    return ($reply -match '^[Yy]$')
}

# Resolve a user-supplied path to an absolute Windows path. Expands a leading
# '~' to the current user's home; ~user is not supported on Windows.
function Resolve-InputPath {
    param([string]$Path)
    if ($Path -eq '~') {
        $Path = $HOME
    } elseif ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        $Path = Join-Path $HOME $Path.Substring(2)
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-DockerNativeArch {
    $arch = (docker info --format '{{.Architecture}}' 2>$null)
    switch -Regex ("$arch") {
        '^(amd64|x86_64)$'  { return 'amd64' }
        '^(arm64|aarch64)$' { return 'arm64' }
        default             { return '' }
    }
}

function Get-PlatformArch {
    switch ($DockerPlatform) {
        'linux/amd64' { return 'amd64' }
        'linux/arm64' { return 'arm64' }
        'native'      { return (Get-DockerNativeArch) }
        default       { return '' }
    }
}

function Test-LocalImage {
    docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) { return $false }

    $expected = Get-PlatformArch
    if ([string]::IsNullOrEmpty($expected)) { return $true }

    $localArch = (docker image inspect $Image --format '{{.Architecture}}' 2>$null)
    return ("$localArch" -eq $expected)
}

# Strip the tag from an image reference (registry:port/repo:tag -> registry:port/repo).
function Get-ImageRepo {
    param([string]$Ref)
    $lastSlash = $Ref.LastIndexOf('/')
    $lastColon = $Ref.LastIndexOf(':')
    if ($lastColon -gt $lastSlash) { return $Ref.Substring(0, $lastColon) }
    return $Ref
}

# Check the remote repository for a newer version of this script and, with the
# user's consent, replace the local copy and re-execute it.
function Invoke-SelfUpdate {
    if ($env:RDK_SCRIPT_SELF_UPDATED -eq '1' -or $SkipSelfUpdate) { return }
    if ([string]::IsNullOrEmpty($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return }

    $tmpFile = New-TemporaryFile
    try {
        Write-Host ''
        Write-Host '==> Checking remote for a newer version of this script...'
        Write-Host "==> Fetching $RemoteScriptUrl"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch {}

        $fetchOk = $true
        try {
            Invoke-WebRequest -Uri $RemoteScriptUrl -OutFile $tmpFile.FullName -UseBasicParsing
        } catch {
            $fetchOk = $false
        }

        if (-not $fetchOk -or (Get-Item $tmpFile.FullName).Length -eq 0) {
            Write-Host 'Could not fetch remote script; continuing with current version.'
            return
        }

        $remoteHash = (Get-FileHash -LiteralPath $tmpFile.FullName -Algorithm SHA256).Hash
        $localHash  = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
        if ($remoteHash -eq $localHash) {
            Write-Host 'Script is already up to date.'
            return
        }

        Write-Host 'A newer version of the script is available.'
        if (-not (Confirm-Yes 'Update local script and restart with the new version?')) {
            Write-Host 'Update skipped.'
            return
        }

        try {
            Copy-Item -LiteralPath $tmpFile.FullName -Destination $ScriptPath -Force
        } catch {
            Write-Host "Failed to write '$ScriptPath' (permission denied?). Continuing with current version."
            return
        }

        Write-Host 'Script updated. Re-executing...'
        $env:RDK_SCRIPT_SELF_UPDATED = '1'
        $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @OrigArgs
        exit $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

# ----- Argument parsing ------------------------------------------------------
$i = 0
while ($i -lt $argList.Count) {
    $a = [string]$argList[$i]
    if ($a -eq '-i' -or $a -eq '--image') {
        $Image = [string]$argList[$i + 1]; $i += 2
    } elseif ($a -eq '--platform') {
        $DockerPlatform = [string]$argList[$i + 1]; $i += 2
    } elseif ($a -like '--platform=*') {
        $DockerPlatform = $a.Substring('--platform='.Length); $i += 1
    } elseif ($a -eq '-n' -or $a -eq '--container-name') {
        $ContainerName = [string]$argList[$i + 1]; $i += 2
    } elseif ($a -eq '-w' -or $a -eq '--workspace') {
        $Ros2Ws = [string]$argList[$i + 1]; $i += 2
    } elseif ($a -eq '-y' -or $a -eq '--yes') {
        $AutoYes = $true; $i += 1
    } elseif ($a -eq '--pull') {
        $AutoPull = $true; $i += 1
    } elseif ($a -eq '--create') {
        $AutoCreate = $true; $i += 1
    } elseif ($a -eq '--shell') {
        $AutoShell = $true; $i += 1
    } elseif ($a -eq '--no-self-update') {
        $SkipSelfUpdate = $true; $i += 1
    } elseif ($a -eq '-h' -or $a -eq '--help') {
        Show-Usage; exit 0
    } else {
        Write-Host "Error: unknown option: $a"
        Write-Host ''
        Show-Usage
        exit 1
    }
}

# ----- Validate platform -----------------------------------------------------
if ($DockerPlatform -notin @('native', 'linux/amd64', 'linux/arm64')) {
    Write-Error "Error: invalid --platform '$DockerPlatform'. Use native, linux/amd64, or linux/arm64."
    exit 1
}

Invoke-SelfUpdate

if (-not (Test-Command docker)) {
    Write-Host "Error: required command 'docker' not found."
    exit 1
}

Write-Host '=============================================='
Write-Host ' Renesas RDK Docker Cross-Build Setup'
Write-Host '=============================================='
Write-Host ''

if ([string]::IsNullOrEmpty($ContainerName)) {
    $reply = Read-Host "Enter container name [default: $DefaultContainerName]"
    if ([string]::IsNullOrEmpty($reply)) { $ContainerName = $DefaultContainerName } else { $ContainerName = $reply }
}

$existingNames = @(docker ps -a --format '{{.Names}}')
if ($existingNames -contains $ContainerName) {
    Write-Host ''
    Write-Host "A Docker container named '$ContainerName' already exists."
    Write-Host 'Please choose a different name or remove the existing container.'
    Write-Host "To remove the existing container, use: docker rm -f $ContainerName"
    Write-Host 'Or choose a different container name and run the script again.'
    exit 1
}

if ([string]::IsNullOrEmpty($Ros2Ws)) {
    $reply = Read-Host "Enter ROS 2 workspace path on host (absolute or relative) [default: $DefaultRos2Ws]"
    if ([string]::IsNullOrEmpty($reply)) { $Ros2WsInput = $DefaultRos2Ws } else { $Ros2WsInput = $reply }
} else {
    $Ros2WsInput = $Ros2Ws
}

$Ros2Ws = Resolve-InputPath $Ros2WsInput

Write-Host ''
Write-Host 'Configuration:'
Write-Host "  Docker image   : $Image"
Write-Host "  Docker platform: $DockerPlatform"
Write-Host "  Container name : $ContainerName"
Write-Host "  ROS 2 workspace: $Ros2Ws"
Write-Host ''

if (-not (Confirm-Yes 'Proceed with this configuration?')) {
    Write-Host 'Aborted by user.'
    exit 0
}

New-Item -ItemType Directory -Force -Path $Ros2Ws | Out-Null

$LocalDigest  = ''
$RemoteDigest = ''
$ShouldPull   = $false

$PlatformArgs = @()
if ($DockerPlatform -ne 'native') { $PlatformArgs = @('--platform', $DockerPlatform) }

$ImageRepo = Get-ImageRepo $Image

Write-Host ''
Write-Host '==> Checking local image...'
if (Test-LocalImage) {
    Write-Host 'Local image exists.'
    $repoDigests = @(docker image inspect $Image --format '{{join .RepoDigests "\n"}}' 2>$null)
    foreach ($line in $repoDigests) {
        if ($line -like "$ImageRepo@sha256:*") { $LocalDigest = ($line -split '@')[1]; break }
    }
    if ($LocalDigest) { Write-Host "Local digest: $LocalDigest" } else { Write-Host 'Local digest not available.' }
} else {
    Write-Host 'Local image does not exist for the requested platform.'
    $ShouldPull = $true
}

if (-not $ShouldPull) {
    Write-Host ''
    docker buildx version *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '==> Checking remote image digest...'
        $remoteRaw = @(docker buildx imagetools inspect $Image 2>$null)
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $remoteRaw) {
                if ($line -match 'Digest:\s+(\S+)') { $RemoteDigest = $matches[1]; break }
            }
            if ($RemoteDigest) { Write-Host "Remote digest: $RemoteDigest" } else { Write-Host 'Could not determine remote digest.' }
        } else {
            Write-Host 'Could not inspect remote image.'
        }
    } else {
        Write-Host 'docker buildx not available; skipping remote image check.'
    }

    if ($RemoteDigest -and $LocalDigest) {
        if ($LocalDigest -ne $RemoteDigest) {
            Write-Host 'Remote image differs from local image.'
            $ShouldPull = $true
        } else {
            Write-Host 'Local image is up to date.'
        }
    } elseif (-not $LocalDigest -and $RemoteDigest) {
        Write-Host 'Local digest unavailable. Pull required.'
        $ShouldPull = $true
    } else {
        Write-Host 'Remote comparison unavailable. Keeping local image.'
    }
}

if ($ShouldPull) {
    Write-Host ''
    if ($AutoPull -or (Confirm-Yes 'Pull/update image now?')) {
        Write-Host '==> Pulling Docker image...'
        docker pull @PlatformArgs $Image
        if ($LASTEXITCODE -ne 0) { Write-Host 'Error: docker pull failed.'; exit 1 }
    } else {
        Write-Host 'Image pull skipped by user.'
        if (-not (Test-LocalImage)) {
            Write-Host 'Error: image is not available locally for the requested platform, cannot continue.'
            exit 1
        }
    }
}

Write-Host ''
Write-Host "==> Container '$ContainerName' does not exist."
if ($AutoCreate -or (Confirm-Yes 'Create and start container now?')) {
    # Docker-outside-of-Docker is not supported on the native Windows port:
    # the host Docker endpoint is a named pipe, not a bind-mountable Unix
    # socket, and --group-add has no effect. Run in WSL2 if you need DooD.
    $runArgs = @('run', '-dt', '--name', $ContainerName)
    $runArgs += $PlatformArgs
    $runArgs += @('--privileged', '--hostname', 'ubuntu-xbuild', '-v', "${Ros2Ws}:/home/ubuntu/ros2_ws", $Image)

    docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host 'Error: docker run failed.'; exit 1 }
    Write-Host 'Container created and started.'
} else {
    Write-Host 'Container creation skipped.'
    exit 0
}

Write-Host ''
if (Confirm-NoDefault 'Open a shell inside the container now?') {
    docker exec -it $ContainerName bash
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host 'Setup complete.'
Write-Host 'To access the container later, run:'
Write-Host "  docker exec -it `"$ContainerName`" bash"
Write-Host ''
Write-Host 'Inside the container, go to:'
Write-Host '  cd ~/ros2_ws'
