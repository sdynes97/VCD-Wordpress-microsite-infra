#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
<#
.SYNOPSIS
    One-time Azure setup for the WordPress microsite Terraform.

.DESCRIPTION
    Creates (idempotently):
      * Terraform state resource group + locked-down storage account (Entra ID auth only,
        no shared keys, no public blob access, versioning + soft delete)
      * Workload resource group that Terraform deploys into
      * Entra app registration + service principal for GitHub Actions, with OIDC
        federated credentials (no client secret) for pull requests and the
        'production' environment
      * Least-privilege role assignments scoped to the workload RG and state account

    Prints the values to add as GitHub repository variables.

.EXAMPLE
    Connect-AzAccount
    ./bootstrap/Initialize-TerraformBootstrap.ps1 -SubscriptionId '<sub-guid>' -Location eastus2
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $SubscriptionId,

    [string] $Location = 'eastus2',

    [string] $NamePrefix = 'vcdwp',

    [string] $WorkloadResourceGroup = "rg-$NamePrefix-prod",

    [string] $StateResourceGroup = "rg-$NamePrefix-tfstate",

    # 3-24 lowercase alphanumerics, globally unique. Default appends a stable hash of the subscription.
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string] $StateStorageAccount,

    [string] $GitHubRepository = 'sdynes97/VCD-Wordpress-microsite-infra',

    [string] $GitHubEnvironment = 'production',

    [string] $AppDisplayName = "gh-$NamePrefix-terraform",

    # Also grant the signed-in user state + Key Vault access for local terraform runs.
    [switch] $GrantCurrentUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-RoleAssignment {
    param(
        [Parameter(Mandatory)] [string] $ObjectId,
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [string] $Scope
    )
    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $Role -Scope $Scope -ErrorAction SilentlyContinue |
        Where-Object Scope -EQ $Scope
    if ($existing) {
        Write-Verbose "Role '$Role' already assigned at $Scope"
        return
    }
    # New service principals can take a minute to replicate in Entra ID.
    for ($i = 1; $i -le 10; $i++) {
        try {
            New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $Role -Scope $Scope | Out-Null
            Write-Host "  + $Role @ $($Scope.Split('/')[-1])"
            return
        }
        catch {
            if ($i -eq 10) { throw }
            Write-Verbose "Role assignment attempt $i failed: $($_.Exception.Message). Retrying in 15s."
            Start-Sleep -Seconds 15
        }
    }
}

function Get-OrCreateResourceGroup {
    param([string] $Name, [string] $Location)
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if (-not $rg) {
        $rg = New-AzResourceGroup -Name $Name -Location $Location -Tag @{ 'managed-by' = 'bootstrap'; workload = 'wordpress-microsites' }
        Write-Host "Created resource group $Name"
    }
    $rg
}

# --- Context -----------------------------------------------------------------
$ctx = Set-AzContext -Subscription $SubscriptionId.Guid
$tenantId = $ctx.Tenant.Id
Write-Host "Subscription: $($ctx.Subscription.Name) ($SubscriptionId) / Tenant: $tenantId"

if (-not $StateStorageAccount) {
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId.Guid))
    ).ToLowerInvariant().Substring(0, 6)
    $StateStorageAccount = "st$($NamePrefix)tf$hash"
}

# --- Resource groups -----------------------------------------------------------
$stateRg = Get-OrCreateResourceGroup -Name $StateResourceGroup -Location $Location
$workloadRg = Get-OrCreateResourceGroup -Name $WorkloadResourceGroup -Location $Location

# --- State storage ---------------------------------------------------------------
$sa = Get-AzStorageAccount -ResourceGroupName $StateResourceGroup -Name $StateStorageAccount -ErrorAction SilentlyContinue
if (-not $sa) {
    $sa = New-AzStorageAccount -ResourceGroupName $StateResourceGroup -Name $StateStorageAccount -Location $Location `
        -SkuName Standard_LRS -Kind StorageV2 -AccessTier Hot `
        -MinimumTlsVersion TLS1_2 -EnableHttpsTrafficOnly $true `
        -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false `
        -AllowCrossTenantReplication $false
    Write-Host "Created storage account $StateStorageAccount"
}

Update-AzStorageBlobServiceProperty -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount `
    -IsVersioningEnabled $true | Out-Null
Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount `
    -RetentionDays 30 | Out-Null

if (-not (Get-AzRmStorageContainer -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount -Name 'tfstate' -ErrorAction SilentlyContinue)) {
    New-AzRmStorageContainer -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount -Name 'tfstate' | Out-Null
    Write-Host 'Created container tfstate'
}

# --- GitHub Actions identity (OIDC, no secrets) -----------------------------------
$app = Get-AzADApplication -DisplayName $AppDisplayName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) {
    $app = New-AzADApplication -DisplayName $AppDisplayName
    Write-Host "Created app registration $AppDisplayName"
}
$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if (-not $sp) {
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
    Write-Host 'Created service principal'
}

$federated = @(
    @{ Name = 'github-pull-request'; Subject = "repo:${GitHubRepository}:pull_request" }
    @{ Name = "github-env-$GitHubEnvironment"; Subject = "repo:${GitHubRepository}:environment:${GitHubEnvironment}" }
)
$existingSubjects = @(Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id | ForEach-Object Subject)
foreach ($fic in $federated) {
    if ($existingSubjects -notcontains $fic.Subject) {
        New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -Name $fic.Name `
            -Issuer 'https://token.actions.githubusercontent.com' -Subject $fic.Subject `
            -Audience 'api://AzureADTokenExchange' | Out-Null
        Write-Host "Added federated credential $($fic.Subject)"
    }
}

# --- Role assignments ------------------------------------------------------------------
Write-Host 'Role assignments for GitHub Actions identity:'
Set-RoleAssignment -ObjectId $sp.Id -Role 'Storage Blob Data Contributor' -Scope $sa.Id
Set-RoleAssignment -ObjectId $sp.Id -Role 'Contributor' -Scope $workloadRg.ResourceId
# Needed so Terraform can grant the VM identity read access to Key Vault.
Set-RoleAssignment -ObjectId $sp.Id -Role 'Role Based Access Control Administrator' -Scope $workloadRg.ResourceId
# Granted up front (not by Terraform) to avoid RBAC propagation delays on first apply.
Set-RoleAssignment -ObjectId $sp.Id -Role 'Key Vault Secrets Officer' -Scope $workloadRg.ResourceId

if ($GrantCurrentUser) {
    $me = Get-AzADUser -SignedIn
    Write-Host "Role assignments for $($me.UserPrincipalName):"
    Set-RoleAssignment -ObjectId $me.Id -Role 'Storage Blob Data Contributor' -Scope $sa.Id
    Set-RoleAssignment -ObjectId $me.Id -Role 'Key Vault Secrets Officer' -Scope $workloadRg.ResourceId
}

# --- Output ----------------------------------------------------------------------------
$vars = [ordered]@{
    AZURE_CLIENT_ID        = $app.AppId
    AZURE_TENANT_ID        = $tenantId
    AZURE_SUBSCRIPTION_ID  = $SubscriptionId.Guid
    TFSTATE_RESOURCE_GROUP = $StateResourceGroup
    TFSTATE_STORAGE_ACCOUNT = $StateStorageAccount
}

Write-Host "`nAdd these as GitHub repository *variables* (Settings > Secrets and variables > Actions > Variables):" -ForegroundColor Cyan
$vars.GetEnumerator() | ForEach-Object { '{0,-24} {1}' -f $_.Key, $_.Value } | Write-Host
Write-Host "`nAdd CLOUDFLARE_API_TOKEN as a repository *secret*, and create the '$GitHubEnvironment' environment." -ForegroundColor Cyan
Write-Host "Set resource_group_name = `"$WorkloadResourceGroup`" in terraform/environments/prod.tfvars." -ForegroundColor Cyan

# Optional: push variables with the GitHub CLI if it's installed and authenticated.
if (Get-Command gh -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($GitHubRepository, 'Set GitHub Actions variables with gh')) {
        foreach ($kv in $vars.GetEnumerator()) {
            gh variable set $kv.Key --repo $GitHubRepository --body $kv.Value
        }
    }
}

[pscustomobject]$vars
