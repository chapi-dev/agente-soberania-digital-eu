# Crear el shared mailbox autom\u00e1ticamente (PowerShell)

> Si tienes Exchange Admin (o Global Admin), este script crea el buz\u00f3n
> compartido sin tener que entrar al portal.

## Uso

```powershell
az login    # con cuenta Global Admin / Exchange Admin
.\create-shared-mailbox.ps1 `
  -MailboxAlias agente-soberania-digital `
  -DisplayName "Agente Soberania Digital" `
  -TenantDomain MngEnvMCAP184496.onmicrosoft.com `
  -GrantAccessTo admin@MngEnvMCAP184496.onmicrosoft.com
```

## Script

Guarda como `scripts/create-shared-mailbox.ps1`:

```powershell
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
Connect-ExchangeOnline -AccessToken $token -UserPrincipalName $me -ShowBanner:$false

$upn = "$MailboxAlias@$TenantDomain"
$existing = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
if (-not $existing) {
  New-Mailbox -Shared -Name $DisplayName -DisplayName $DisplayName `
              -Alias $MailboxAlias -PrimarySmtpAddress $upn
}

if ($GrantAccessTo) {
  Add-MailboxPermission -Identity $upn -User $GrantAccessTo `
                        -AccessRights FullAccess -InheritanceType All -AutoMapping $false
  Add-RecipientPermission -Identity $upn -Trustee $GrantAccessTo `
                          -AccessRights SendAs -Confirm:$false
}

Disconnect-ExchangeOnline -Confirm:$false
Write-Host "[+] Shared mailbox listo: $upn" -ForegroundColor Green
```

## Si prefieres el portal

Sigue [`SHARED_MAILBOX.md`](SHARED_MAILBOX.md) (versi\u00f3n manual).
