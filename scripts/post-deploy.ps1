# Script post-deploy: concede a la MSI de la Logic App los permisos necesarios
# para leer correos via Graph y escribir en Foundry / Storage.
#
# Requisitos:
# - az login con cuenta Global Administrator (o similar) del tenant M365
# - El bicep de la Logic App ya desplegado
#
# Uso:
#   .\post-deploy.ps1 `
#     -ResourceGroup rg-agentic-dev-eu `
#     -LogicAppName la-email-ingest-soberania `
#     -SharedMailboxUpn agente-soberania-digital@<tu-tenant>.onmicrosoft.com `
#     -FoundryAccountName ms-foundry-dev-eu-01 `
#     -StorageAccountName saagentic01

param(
  [Parameter(Mandatory=$true)] [string] $ResourceGroup,
  [Parameter(Mandatory=$true)] [string] $LogicAppName,
  [Parameter(Mandatory=$true)] [string] $SharedMailboxUpn,
  [Parameter(Mandatory=$true)] [string] $FoundryAccountName,
  [Parameter(Mandatory=$true)] [string] $StorageAccountName,
  [string] $ScopeGroupAlias = "sg-agente-soberania-scope"
)

$ErrorActionPreference = "Stop"

Write-Host "===== Resolving identities =====" -ForegroundColor Cyan
$msiObjectId = az resource show --ids `
  "/subscriptions/$((az account show --query id -o tsv))/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName" `
  --query "identity.principalId" -o tsv
Write-Host "Logic App MSI ObjectId: $msiObjectId"
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$msi = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$msiObjectId" -Headers @{Authorization="Bearer $token"}
$msiAppId = $msi.appId
Write-Host "Logic App MSI AppId:    $msiAppId"

$foundryId = az cognitiveservices account show -n $FoundryAccountName -g $ResourceGroup --query id -o tsv
$storageId = az storage account show -n $StorageAccountName -g $ResourceGroup --query id -o tsv

Write-Host "`n===== 1) Graph Mail.ReadWrite (Application) =====" -ForegroundColor Cyan
$graphSpId = (az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query "[0].id" -o tsv).Trim()
$graphSp = az ad sp show --id $graphSpId -o json | ConvertFrom-Json
$mailRwRole = $graphSp.appRoles | Where-Object { $_.value -eq "Mail.ReadWrite" }
$body = @{ principalId = $msiObjectId; resourceId = $graphSpId; appRoleId = $mailRwRole.id } | ConvertTo-Json
try {
  Invoke-RestMethod -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$msiObjectId/appRoleAssignments" `
    -Headers @{Authorization="Bearer $token"; 'Content-Type'='application/json'} -Body $body | Out-Null
  Write-Host "[+] Mail.ReadWrite granted" -ForegroundColor Green
} catch {
  if ($_.ErrorDetails.Message -match 'already exists') { Write-Host "[=] Already granted" -ForegroundColor Yellow }
  else { throw }
}

Write-Host "`n===== 2) Azure AI User on Foundry =====" -ForegroundColor Cyan
az role assignment create --assignee-object-id $msiObjectId --assignee-principal-type ServicePrincipal `
  --role "Azure AI User" --scope $foundryId 2>&1 | Out-Null

Write-Host "===== 3) Cognitive Services User on Foundry =====" -ForegroundColor Cyan
az role assignment create --assignee-object-id $msiObjectId --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services User" --scope $foundryId 2>&1 | Out-Null

Write-Host "===== 4) Storage Blob Data Contributor =====" -ForegroundColor Cyan
az role assignment create --assignee-object-id $msiObjectId --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope $storageId 2>&1 | Out-Null

Write-Host "`n===== 5) ApplicationAccessPolicy (restrict MSI to ONLY shared mailbox) =====" -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
  Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement
$exoToken = az account get-access-token --resource "https://outlook.office365.com" --query accessToken -o tsv
$me = az ad signed-in-user show --query userPrincipalName -o tsv
Connect-ExchangeOnline -AccessToken $exoToken -UserPrincipalName $me -ShowBanner:$false | Out-Null

$tenantDomain = $SharedMailboxUpn.Split('@')[1]
$groupUpn = "$ScopeGroupAlias@$tenantDomain"
$grp = Get-DistributionGroup -Identity $groupUpn -ErrorAction SilentlyContinue
if (-not $grp) {
  Write-Host "Creating mail-enabled security group $groupUpn..."
  New-DistributionGroup -Name "SG Agente Soberania Scope" -Alias $ScopeGroupAlias `
    -PrimarySmtpAddress $groupUpn -Type "Security" -RequireSenderAuthenticationEnabled $true | Out-Null
  Start-Sleep -Seconds 10
}
try { Add-DistributionGroupMember -Identity $groupUpn -Member $SharedMailboxUpn -ErrorAction Stop } catch {
  if ($_.Exception.Message -notmatch 'already a member') { throw }
}

# Remove previous policies for this app, then create
Get-ApplicationAccessPolicy | Where-Object { $_.AppId -eq $msiAppId } | ForEach-Object {
  Remove-ApplicationAccessPolicy -Identity $_.Identity -Confirm:$false
}
New-ApplicationAccessPolicy -AppId $msiAppId -PolicyScopeGroupId $groupUpn `
  -AccessRight RestrictAccess `
  -Description "Restringe la Logic App de ingesta a leer SOLO el shared mailbox del agente." | Out-Null

Start-Sleep -Seconds 30
Write-Host "`n[*] Verifying access (must be Granted)..."
Test-ApplicationAccessPolicy -Identity $SharedMailboxUpn -AppId $msiAppId | Format-List Identity, AccessCheckResult

Disconnect-ExchangeOnline -Confirm:$false | Out-Null

Write-Host "`n===== DONE =====" -ForegroundColor Green
Write-Host "La Logic App ya puede leer correos del shared mailbox y publicarlos en Foundry."
Write-Host "Triggera manualmente para verificar:"
Write-Host "  az rest --method POST --uri 'https://management.azure.com/subscriptions/<sub>/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName/triggers/Recurrence/run?api-version=2016-06-01'"
