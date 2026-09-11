<#
.SYNOPSIS
    Builds and deploys Easy Quries as a single-origin IIS site (backend serves the built frontend).

.DESCRIPTION
    Prompts for the settings needed to deploy, builds the frontend and backend, copies the
    frontend's build output into the backend so it can serve it as static files, publishes the
    backend, writes appsettings.Production.json, sets up the query data folder, and creates/updates
    the IIS application pool and site.

    Must be run as Administrator, on the machine that has IIS installed, with the .NET 10 SDK and
    Node.js/npm available on PATH. See the "Hosting on IIS" wiki page for background on what this
    script automates.
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

Write-Host "=== Easy Quries: single-origin IIS deployment ===" -ForegroundColor Cyan
Write-Host ""

# --- Prompts -----------------------------------------------------------

$ConnectionString = Read-HostWithDefault -Prompt "SQL Server connection string" -Required
$AppPoolName      = Read-HostWithDefault -Prompt "Application pool name" -Default "Easy-Queries"
$DeployPath       = Read-HostWithDefault -Prompt "Where to put the published app" -Default "D:\easy-queries\app"
$BindingHost      = Read-HostWithDefault -Prompt "Binding host name (leave blank for no host header)"
$DataDir          = Read-HostWithDefault -Prompt "Where the data files (favorites.json, queries/*.sql) live" -Default "D:\easy-queries\data"

$CurrentUser = "$env:USERDOMAIN\$env:USERNAME"
$AppPoolCredential = Get-Credential -UserName $CurrentUser -Message "Password for $CurrentUser (the application pool will run as this account, instead of an anonymous identity)"

Write-Host ""

# --- Pre-flight checks ---------------------------------------------------

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator (it configures IIS)."
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

$RepoRoot        = $PSScriptRoot
$FrontendDir     = Join-Path $RepoRoot "frontend"
$BackendDir      = Join-Path $RepoRoot "backend\EasyQueries.Api"
$BackendProject  = Join-Path $BackendDir "EasyQueries.Api.csproj"
$BackendWwwRoot  = Join-Path $BackendDir "wwwroot"

if (-not (Test-Path $BackendProject)) {
    Write-Error "Couldn't find $BackendProject. Run this script from the repo root."
    exit 1
}

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

# --- Copy the frontend build into the backend's wwwroot --------------------

Write-Host "--- Copying frontend build into backend/wwwroot ---" -ForegroundColor Cyan
if (Test-Path $BackendWwwRoot) {
    Remove-Item $BackendWwwRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $BackendWwwRoot | Out-Null
Copy-Item (Join-Path $FrontendDir "dist\*") $BackendWwwRoot -Recurse

# --- Stop the app pool first, so it isn't holding the published files open ---

function Stop-AppPoolAndWait {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSeconds = 60
    )

    if (-not (Test-Path "IIS:\AppPools\$Name")) {
        return
    }

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

Stop-AppPoolAndWait -Name $AppPoolName

# --- Prepare the deployment path and publish the backend --------------------

Write-Host "--- Publishing backend to $DeployPath ---" -ForegroundColor Cyan

if (-not (Test-Path $DeployPath)) {
    New-Item -ItemType Directory -Path $DeployPath -Force | Out-Null
}
else {
    $existingItems = Get-ChildItem $DeployPath -Force -ErrorAction SilentlyContinue
    if ($existingItems) {
        Write-Host "The deployment path '$DeployPath' already contains files." -ForegroundColor Yellow
        $confirm = Read-Host "Its contents will be deleted and replaced. Continue? (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Aborted."
            exit 1
        }
        Remove-Item (Join-Path $DeployPath "*") -Recurse -Force
    }
}

dotnet publish $BackendProject -c Release -o $DeployPath
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

# ASPNETCORE_ENVIRONMENT is normally unset under IIS, which makes the app default to
# Production - but if a machine- or user-level ASPNETCORE_ENVIRONMENT variable happens to be
# set on this server (e.g. left over from local .NET development), the app pool would inherit
# it and could end up running as Development instead, loading the wrong appsettings file
# entirely. Pin it explicitly in web.config so the deployment doesn't depend on the host's
# ambient environment variables.
$webConfigPath = Join-Path $DeployPath "web.config"
if (Test-Path $webConfigPath) {
    [xml]$webConfig = Get-Content $webConfigPath
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

    $webConfig.Save($webConfigPath)
    Write-Host "Pinned ASPNETCORE_ENVIRONMENT=Production in web.config."
}
else {
    Write-Warning "web.config not found at $webConfigPath; couldn't pin ASPNETCORE_ENVIRONMENT explicitly."
}

# appsettings.Development.json is git-ignored but dotnet publish copies it anyway if it
# happens to exist on the machine running this script. It's now guaranteed not to be loaded
# at runtime (the environment is pinned to Production above), but it shouldn't sit on the
# server holding a developer's connection string regardless, so remove it if present.
$publishedDevSettings = Join-Path $DeployPath "appsettings.Development.json"
if (Test-Path $publishedDevSettings) {
    Remove-Item $publishedDevSettings -Force
    Write-Host "Removed appsettings.Development.json from the published output (not used in Production, shouldn't ship)."
}

# --- Write appsettings.Production.json --------------------------------------

Write-Host "--- Writing appsettings.Production.json ---" -ForegroundColor Cyan

$productionSettings = @{
    ConnectionStrings = @{ database = $ConnectionString }
    DataDirectory     = $DataDir
}
$productionSettings | ConvertTo-Json -Depth 5 |
    Set-Content -Path (Join-Path $DeployPath "appsettings.Production.json") -Encoding UTF8

# --- Set up the data directory ----------------------------------------------

Write-Host "--- Setting up data directory at $DataDir ---" -ForegroundColor Cyan

$dataDirHasContent = (Test-Path $DataDir) -and (Get-ChildItem $DataDir -Force -ErrorAction SilentlyContinue)
$localDataDir = Join-Path $RepoRoot "data"

if ($dataDirHasContent) {
    Write-Host "Data directory already has content; leaving it as-is."
}
elseif (Test-Path $localDataDir) {
    Write-Host "Copying local 'data' folder to $DataDir."
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Copy-Item (Join-Path $localDataDir "*") $DataDir -Recurse -Force
}
else {
    Write-Host "No local 'data' folder found; creating an empty skeleton at $DataDir." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path (Join-Path $DataDir "queries") -Force | Out-Null
    Set-Content -Path (Join-Path $DataDir "favorites.json") -Value "[]" -Encoding UTF8
    Write-Host "Populate $DataDir with favorites.json and queries/*.sql before this deployment is useful (see the 'Setup' and 'Writing SQL Queries' wiki pages)." -ForegroundColor Yellow
}

# --- IIS setup ---------------------------------------------------------------

Write-Host "--- Configuring IIS ---" -ForegroundColor Cyan

if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    New-WebAppPool -Name $AppPoolName | Out-Null
    Write-Host "Created application pool '$AppPoolName'."
}
else {
    Write-Host "Application pool '$AppPoolName' already exists; reusing it."
}
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value ""

# Run the pool as the account that ran this script, rather than the default virtual
# ApplicationPoolIdentity - that virtual account has no real network credentials, so calls to
# SQL Server over Integrated Security show up there as NT AUTHORITY\ANONYMOUS LOGON.
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.identityType -Value "SpecificUser"
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.userName -Value $AppPoolCredential.UserName
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.password -Value $AppPoolCredential.GetNetworkCredential().Password
Write-Host "Application pool '$AppPoolName' will run as $($AppPoolCredential.UserName)."

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    $resolved = Resolve-Path $expanded -ErrorAction SilentlyContinue
    if (-not $resolved) { return $null }

    return $resolved.Path.TrimEnd('\')
}

$resolvedDeployPath = Get-NormalizedPath $DeployPath
$existingSite = Get-Website | Where-Object {
    $sitePath = Get-NormalizedPath $_.physicalPath
    $sitePath -and $resolvedDeployPath -and ($sitePath -eq $resolvedDeployPath)
}

if ($existingSite) {
    Write-Host "Site '$($existingSite.Name)' already points at $DeployPath; reusing it and switching it to application pool '$AppPoolName'."
    Set-ItemProperty "IIS:\Sites\$($existingSite.Name)" -Name applicationPool -Value $AppPoolName

    if ($BindingHost) {
        $hasBinding = Get-WebBinding -Name $existingSite.Name | Where-Object { $_.bindingInformation -like "*:80:$BindingHost" }
        if (-not $hasBinding) {
            New-WebBinding -Name $existingSite.Name -Protocol http -Port 80 -HostHeader $BindingHost
            Write-Host "Added binding for host '$BindingHost' on port 80."
        }
    }

    $siteName = $existingSite.Name
}
elseif (Test-Path "IIS:\Sites\$AppPoolName") {
    Write-Host "Site '$AppPoolName' already exists; updating its physical path and application pool."
    Set-ItemProperty "IIS:\Sites\$AppPoolName" -Name physicalPath -Value $DeployPath
    Set-ItemProperty "IIS:\Sites\$AppPoolName" -Name applicationPool -Value $AppPoolName

    if ($BindingHost) {
        $hasBinding = Get-WebBinding -Name $AppPoolName | Where-Object { $_.bindingInformation -like "*:80:$BindingHost" }
        if (-not $hasBinding) {
            New-WebBinding -Name $AppPoolName -Protocol http -Port 80 -HostHeader $BindingHost
            Write-Host "Added binding for host '$BindingHost' on port 80."
        }
    }

    $siteName = $AppPoolName
}
else {
    $siteParams = @{
        Name            = $AppPoolName
        PhysicalPath    = $DeployPath
        Port            = 80
        ApplicationPool = $AppPoolName
    }
    if ($BindingHost) { $siteParams["HostHeader"] = $BindingHost }

    New-Website @siteParams | Out-Null
    Write-Host "Created IIS site '$AppPoolName' at $DeployPath."

    $siteName = $AppPoolName
}

# We stopped the app pool earlier to release its file locks before publishing; a newly
# created pool starts on its own, but a pre-existing one that we stopped needs restarting.
if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Started') {
    Start-WebAppPool -Name $AppPoolName
    Write-Host "Started application pool '$AppPoolName'."
}

# --- Done ---------------------------------------------------------------

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Site:          $siteName"
Write-Host "Physical path: $DeployPath"
Write-Host "Data folder:   $DataDir"
if ($BindingHost) {
    Write-Host "Try:           http://$BindingHost/"
}
else {
    Write-Host "Try:           http://localhost/  (or the server's hostname/IP)"
}
Write-Host ""
Write-Host "Reminders:" -ForegroundColor Yellow
Write-Host " - If the connection string uses Integrated Security, the '$AppPoolName' app pool identity needs a SQL Server login."
Write-Host " - HTTPS/certificate bindings aren't set up by this script; add one in IIS Manager if needed."
if ($BindingHost) {
    Write-Host " - Make sure DNS (or the hosts file) actually resolves '$BindingHost' to this server."
}
