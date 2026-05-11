# Troubleshooting

## Permisos / RBAC

### `Foundry project MSI doesn't have appropriate permissions on the storage account`

La identidad del proyecto Foundry necesita acceso al storage backing del vector store:

```powershell
$projMi = az cognitiveservices account project show `
  --name <foundry-acc> -g <rg> --project-name <proj> `
  --query identity.principalId -o tsv
$saId = az storage account show -n <sa> -g <rg> --query id -o tsv
az role assignment create --assignee-object-id $projMi `
  --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope $saId
```

### `(403) Failed to upload file using upload_url`

El storage está cerrado a internet. Opciones:

1. **Producción**: añadir resource access rule para el Foundry account:
   ```powershell
   az storage account network-rule add -n <sa> -g <rg> `
     --resource-id <foundry-account-id> --tenant-id <tenant-id>
   ```

2. **Desarrollo**: temporalmente abrir con `defaultAction=Allow` o whitelist tu IP:
   ```powershell
   az storage account network-rule add -n <sa> -g <rg> --ip-address <tu-ip>
   ```

## Modelo

### `Model deployment not found`

Verifica el nombre del deployment (no el nombre del modelo). Lista:

```powershell
az cognitiveservices account deployment list `
  --name ms-foundry-dev-eu-01 -g rg-agentic-dev-eu -o table
```

### Quota exceeded

Sube la capacidad del deployment o pide aumento de quota:

```powershell
az cognitiveservices account deployment update `
  --name <foundry-acc> -g <rg> --deployment-name gpt-4.1-mini `
  --sku-name GlobalStandard --sku-capacity 100
```

## Logic App

### El conector Office 365 está "unauthorized"

Es una **acción manual obligatoria**. Tras desplegar el bicep:

1. Abre el portal Azure → Logic App `la-email-ingest-soberania`.
2. **API connections** → `office365` → **Edit API connection**.
3. **Authorize** con una cuenta que sea **miembro del shared mailbox**.
4. **Save**.

### El trigger no dispara cuando llega un correo

- Verifica que la cuenta autorizada tiene **Read** sobre el shared mailbox
  (panel del buzón → Miembros).
- El trigger hace polling cada 1 minuto por defecto. Latencia esperada: 30-60s.
- Revisa "Run history" de la Logic App para ver errores.

### El correo se sube pero el agente no lo ve

- Comprueba que el `vector_store_files` POST devolvió `status: completed`.
- En el playground del agente: hay una pestaña "Files" que lista los documentos
  del vector store. Si tu correo no aparece ahí, el batch falló.
- Logs del run en el portal Foundry → Agents → Runs.

## Agente

### Las respuestas no citan correos aunque sí existen

Refuerza el system prompt para que **siempre llame a `file_search` antes de
responder**, o usa `tool_choice: {"type":"file_search"}` en el run para forzarlo.

### Respuestas demasiado genéricas

- Verifica que el modelo es `gpt-4.1-mini` o superior, no un mini-mini.
- Aumenta `temperature` a 0.3-0.5 para análisis legal más matizado.
- Considera cambiar a `gpt-4.1` (no mini) si la calidad no es suficiente.

## Costes inesperados

Lista las top-N llamadas por coste:

```powershell
az monitor metrics list --resource <foundry-acc-id> `
  --metric "TokenTransaction" --aggregation Total --interval P1D
```

## Auth desde la app cliente

`DefaultAzureCredential` prueba varias fuentes (CLI, env vars, MSI...). En
producción, prefiere `ManagedIdentityCredential` explícito para evitar latencias
y comportamiento impredecible.
