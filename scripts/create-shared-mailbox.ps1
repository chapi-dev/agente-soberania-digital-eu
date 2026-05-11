param(
  [Parameter(Mandatory=$true)] [string] $MailboxAlias,
  [Parameter(Mandatory=$true)] [string] $DisplayName,
  [Parameter(Mandatory=$true)] [string] $TenantDomain,
  [string] $GrantAccessTo
)

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
  Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
}
Import-Module ExchangeOnlineManagement

$me = az ad signed-in-user show --query userPrincipalName -o tsv
$token = az account get-access-token --resource "https://outlook.office365.com" --query accessToken -o tsv
Connect-ExchangeOnline -AccessToken $token -UserPrincipalName $me -ShowBanner:$false | Out-Null

$upn = "$MailboxAlias@$TenantDomain"
$existing = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
if (-not $existing) {
  New-Mailbox -Shared -Name $DisplayName -DisplayName $DisplayName `
              -Alias $MailboxAlias -PrimarySmtpAddress $upn | Out-Null
  Write-Host "[+] Created $upn" -ForegroundColor Green
} else {
  Write-Host "[=] $upn already exists" -ForegroundColor Yellow
}

if ($GrantAccessTo) {
  Add-MailboxPermission -Identity $upn -User $GrantAccessTo `
                        -AccessRights FullAccess -InheritanceType All -AutoMapping $false `
                        -ErrorAction SilentlyContinue | Out-Null
  Add-RecipientPermission -Identity $upn -Trustee $GrantAccessTo `
                          -AccessRights SendAs -Confirm:$false `
                          -ErrorAction SilentlyContinue | Out-Null
  Write-Host "[+] Granted FullAccess + SendAs to $GrantAccessTo" -ForegroundColor Green
}

Disconnect-ExchangeOnline -Confirm:$false | Out-Null
Write-Host "[+] Shared mailbox ready: $upn" -ForegroundColor Green
