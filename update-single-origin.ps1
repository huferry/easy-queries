<#
.SYNOPSIS
    Rebuilds and redeploys the backend and frontend code for an existing single-origin
    IIS deployment of Easy Quries, without touching its settings or data.

.DESCRIPTION
    Prompts for the application pool that identifies the deployment (same default as
    install-single-origin.ps1), stops it, builds the backend and frontend, locates the
    IIS site/application(s) using that pool, and mirrors the freshly built code into
    their physical path(s) - leaving appsettings.Production.json (connection string,
    data directory) and the external data folder untouched. Restarts the pool when done.

    Must be run as Administrator, on the machine that has IIS installed, with the .NET 10
    SDK and Node.js/npm available on PATH. Use install-single-origin.ps1 first if the site
    doesn't exist yet.
#>

$ErrorActionPreference = 'Stop'

function Read-HostWithDefault {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default = '',
        [switch]$Required
    )

    while ($true) {
        $promptText = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = Read-Host $promptText

        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($Default) { return $Default }
            if ($Required) {
                Write-Host "This value is required." -ForegroundColor Yellow
                continue
            }
            return ''
        }

        return $value
    }
}

function Stop-AppPoolAndWait {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSeconds = 60
    )

    $state = (Get-WebAppPoolState -Name $Name).Value
    if ($state -eq 'Stopped') {
        Write-Host "Application pool '$Name' is already stopped."
        return
    }

    Write-Host "Stopping application pool '$Name' (currently $state)..."
    Stop-WebAppPool -Name $Name

    $elapsed = 0
    while ((Get-WebAppPoolState -Name $Name).Value -ne 'Stopped') {
        if ($elapsed -ge $TimeoutSeconds) {
            throw "Application pool '$Name' did not stop within $TimeoutSeconds seconds."
        }
        Start-Sleep -Seconds 1
        $elapsed++
    }

    Write-Host "Application pool '$Name' stopped."
}

function Start-AppPoolIfStopped {
    param([Parameter(Mandatory)] [string]$Name)

    if (-not (Test-Path "IIS:\AppPools\$Name")) { return }

    if ((Get-WebAppPoolState -Name $Name).Value -ne 'Started') {
        Start-WebAppPool -Name $Name
        Write-Host "Started application pool '$Name'."
    }
    else {
        Write-Host "Application pool '$Name' is already running."
    }
}

# Finds every IIS site or sub-application whose application pool is $PoolName, returning
# each one's physical path so the fresh build can be copied there.
function Find-DeploymentTargets {
    param([Parameter(Mandatory)] [string]$PoolName)

    $targets = @()

    foreach ($site in Get-Website) {
        if ($site.applicationPool -eq $PoolName) {
            $targets += [PSCustomObject]@{
                Description  = $site.Name
                PhysicalPath = $site.physicalPath
            }
        }

        Get-WebApplication -Site $site.Name | ForEach-Object {
            if ($_.applicationPool -eq $PoolName -and $_.physicalPath) {
                $targets += [PSCustomObject]@{
                    Description  = "$($site.Name)$($_.path)"
                    PhysicalPath = $_.physicalPath
                }
            }
        }
    }

    return $targets
}

# Re-pins ASPNETCORE_ENVIRONMENT=Production in web.config, same as install-single-origin.ps1,
# so a refreshed web.config doesn't end up depending on the host's ambient environment variable.
function Set-ProductionEnvironmentInWebConfig {
    param([Parameter(Mandatory)] [string]$WebConfigPath)

    if (-not (Test-Path $WebConfigPath)) {
        Write-Warning "web.config not found at $WebConfigPath; couldn't pin ASPNETCORE_ENVIRONMENT explicitly."
        return
    }

    [xml]$webConfig = Get-Content $WebConfigPath
    $aspNetCoreNode = $webConfig.configuration.location.'system.webServer'.aspNetCore

    $envVarsNode = $aspNetCoreNode.environmentVariables
    if (-not $envVarsNode) {
        $envVarsNode = $webConfig.CreateElement("environmentVariables")
        $aspNetCoreNode.AppendChild($envVarsNode) | Out-Null
    }

    $envVarNode = $envVarsNode.SelectSingleNode("environmentVariable[@name='ASPNETCORE_ENVIRONMENT']")
    if (-not $envVarNode) {
        $envVarNode = $webConfig.CreateElement("environmentVariable")
        $envVarNode.SetAttribute("name", "ASPNETCORE_ENVIRONMENT") | Out-Null
        $envVarsNode.AppendChild($envVarNode) | Out-Null
    }
    $envVarNode.SetAttribute("value", "Production") | Out-Null

    $webConfig.Save($WebConfigPath)
}

Write-Host "=== Easy Quries: single-origin IIS update ===" -ForegroundColor Cyan
Write-Host ""

# --- Prompts -----------------------------------------------------------

$AppPoolName = Read-HostWithDefault -Prompt "Application pool name" -Default "Easy-Queries"

Write-Host ""

# --- Pre-flight checks ---------------------------------------------------

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator (it controls IIS)."
    exit 1
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "'dotnet' was not found on PATH. Install the .NET 10 SDK first."
    exit 1
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Error "'npm' was not found on PATH. Install Node.js first."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    Write-Error "The WebAdministration PowerShell module isn't available. Install the 'IIS Management Scripts and Tools' feature (Install-WindowsFeature Web-Scripting-Tools) first."
    exit 1
}
Import-Module WebAdministration

if (-not (Get-Command robocopy -ErrorAction SilentlyContinue)) {
    Write-Error "'robocopy' was not found on PATH (unexpected on Windows)."
    exit 1
}

if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    Write-Error "Application pool '$AppPoolName' doesn't exist. Run install-single-origin.ps1 first to create the deployment."
    exit 1
}

$RepoRoot       = $PSScriptRoot
$FrontendDir    = Join-Path $RepoRoot "frontend"
$BackendDir     = Join-Path $RepoRoot "backend\EasyQueries.Api"
$BackendProject = Join-Path $BackendDir "EasyQueries.Api.csproj"
$BackendWwwRoot = Join-Path $BackendDir "wwwroot"

if (-not (Test-Path $BackendProject)) {
    Write-Error "Couldn't find $BackendProject. Run this script from the repo root."
    exit 1
}

# --- Find where this app pool is actually deployed, before touching anything ---

$targets = Find-DeploymentTargets -PoolName $AppPoolName
if (-not $targets -or $targets.Count -eq 0) {
    Write-Error "No IIS site or application uses application pool '$AppPoolName'. Nothing to update."
    exit 1
}

Write-Host "Application pool '$AppPoolName' is used by:"
foreach ($t in $targets) {
    Write-Host " - $($t.Description) -> $($t.PhysicalPath)"
}
Write-Host ""

$StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "easy-queries-update-$(Get-Date -Format yyyyMMddHHmmss)"

try {
    # --- Stop the app pool first, so nothing is holding files open once we copy ---

    Stop-AppPoolAndWait -Name $AppPoolName

    # --- Build the backend ---------------------------------------------------

    Write-Host "--- Building backend ---" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    dotnet publish $BackendProject -c Release -o $StagingDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

    # appsettings.Development.json is git-ignored but dotnet publish copies it anyway if it
    # happens to exist on the machine running this script. It's not used in Production, and
    # shouldn't be copied over a live deployment's settings regardless.
    $publishedDevSettings = Join-Path $StagingDir "appsettings.Development.json"
    if (Test-Path $publishedDevSettings) {
        Remove-Item $publishedDevSettings -Force
    }

    # dotnet publish will also have copied whatever appsettings.Production.json currently
    # sits in the repo (if any). The live one on the server is the source of truth for
    # settings, so make sure the fresh build never overwrites it.
    $publishedProdSettings = Join-Path $StagingDir "appsettings.Production.json"
    if (Test-Path $publishedProdSettings) {
        Remove-Item $publishedProdSettings -Force
    }

    Set-ProductionEnvironmentInWebConfig -WebConfigPath (Join-Path $StagingDir "web.config")

    # --- Build the frontend ---------------------------------------------------

    Write-Host "--- Building frontend ---" -ForegroundColor Cyan
    Push-Location $FrontendDir
    try {
        npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed." }

        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed." }
    }
    finally {
        Pop-Location
    }

    # --- Merge the frontend build into the staged backend output's wwwroot ------

    Write-Host "--- Copying frontend build into staged wwwroot ---" -ForegroundColor Cyan
    $stagedWwwRoot = Join-Path $StagingDir "wwwroot"
    if (Test-Path $stagedWwwRoot) {
        Remove-Item $stagedWwwRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stagedWwwRoot | Out-Null
    Copy-Item (Join-Path $FrontendDir "dist\*") $stagedWwwRoot -Recurse

    # --- Mirror the staged build into each deployment target ---------------------

    foreach ($t in $targets) {
        Write-Host "--- Updating $($t.Description) at $($t.PhysicalPath) ---" -ForegroundColor Cyan

        # /MIR mirrors the staged build into the live path (adding, overwriting, and removing
        # stale files), except for appsettings.Production.json and appsettings.Development.json,
        # which hold this deployment's settings (connection string, data directory) and must
        # survive the update untouched. The external data directory (favorites.json, queries/*.sql)
        # isn't under this physical path at all, so it's never touched by this copy.
        robocopy $StagingDir $t.PhysicalPath /MIR /XF appsettings.Production.json appsettings.Development.json /R:3 /W:2 /NFL /NDL | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed updating $($t.PhysicalPath) (exit code $LASTEXITCODE)."
        }
    }

    Write-Host ""
    Write-Host "=== Done ===" -ForegroundColor Green
}
finally {
    if (Test-Path $StagingDir) {
        Remove-Item $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Always try to bring the pool back up, even if a build or copy step failed above.
    Start-AppPoolIfStopped -Name $AppPoolName
}
