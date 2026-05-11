# Agente especialista en Derecho y Soberanía Digital en Europa

Agente AI hospedado en **Microsoft Foundry (Azure AI Foundry Agent Service)** que actúa como
asesor experto en el marco normativo europeo (RGPD, AI Act, NIS2, DSA, DMA, Data Act,
Schrems II, EU Cloud Code of Conduct, EUCS, eIDAS 2, DORA, CRA…) y que **lee correos
enviados a un buzón compartido de Outlook/Microsoft 365** para usarlos como contexto.

---

## Índice
- [Arquitectura](#arquitectura)
- [Componentes desplegados](#componentes-desplegados)
- [Cómo usarlo](#cómo-usarlo)
- [Setup desde cero (otra suscripción)](#setup-desde-cero-otra-suscripción)
- [Estructura del repo](#estructura-del-repo)
- [Costes estimados](#costes-estimados)
- [Seguridad y red](#seguridad-y-red)
- [Próximos pasos / mejoras](#próximos-pasos--mejoras)

---

## Arquitectura

```
                              ┌─────────────────────────────┐
                              │  Empleados / colaboradores  │
                              │   (envían/reenvían email)   │
                              └──────────────┬──────────────┘
                                             │
                                             ▼
                          ┌─────────────────────────────────────┐
                          │   SHARED MAILBOX en M365 tenant     │
                          │ p.ej. agente-soberania@empresa.com  │
                          │   (gratis, sin licencia adicional)  │
                          └──────────────┬──────────────────────┘
                                         │ Microsoft Graph API
                                         │ (auth = Logic App MSI con Mail.ReadWrite
                                         │  RESTRINGIDO al buzón vía
                                         │  ApplicationAccessPolicy)
                                         ▼
                  ┌──────────────────────────────────────────────────┐
                  │  LOGIC APP CONSUMPTION  la-email-ingest-soberania │
                  │  ─────────────────────────────────────────────── │
                  │  trigger: Recurrence cada 2 min                  │
                  │  1. GET /users/{shared}/messages?isRead=false    │
                  │  2. for each unread message:                     │
                  │     a. compose: subject + body + headers → texto │
                  │     b. POST /files (multipart) → Foundry         │
                  │     c. POST /vector_stores/{id}/files            │
                  │     d. PUT raw .txt → blob audit                 │
                  │     e. PATCH message isRead=true                 │
                  └─────────────────────────┬────────────────────────┘
                                            │
                          ┌─────────────────┼─────────────────┐
                          │                 │                 │
                          ▼                 ▼                 ▼
              ┌──────────────────┐  ┌────────────────┐  ┌────────────────┐
              │ Vector store     │  │ Agent          │  │ Blob container │
              │ vs-emails-       │◄─┤ agente-        │  │ emails-raw     │
              │ soberania        │  │ soberania-     │  │ (.txt audit)   │
              │ (chunks + idx)   │  │ digital-eu     │  └────────────────┘
              └──────────────────┘  │ model:         │
                                    │ gpt-4.1-mini   │
                                    │ tool:          │
                                    │ file_search    │
                                    └────────┬───────┘
                                             │
                                             ▼
                    Foundry Playground / app cliente / Teams bot / etc.
```

> 🔒 **Nota de seguridad**: la Logic App MSI tiene Graph `Mail.ReadWrite`
> (Application). El permiso por defecto sería sobre TODO el tenant. Está
> **explícitamente restringido** al buzón compartido vía una
> `ApplicationAccessPolicy` de Exchange Online (creada por `post-deploy.ps1`).
> Verificable con `Test-ApplicationAccessPolicy`.

---

## Componentes desplegados

| Recurso | Nombre | Tipo | Resource group | Región |
|---|---|---|---|---|
| Foundry account | `ms-foundry-dev-eu-01` | `Microsoft.CognitiveServices/accounts` | `rg-agentic-dev-eu` | `eastus` |
| Foundry project | `agentic01` | `Microsoft.CognitiveServices/accounts/projects` | `rg-agentic-dev-eu` | `eastus` |
| Model deployment | `gpt-4.1-mini` (v2025-04-14, GlobalStandard, 50 TPM) | OpenAI deployment | — | global |
| Vector store | `vs-emails-soberania` (id `vs_tnn20yMg3aMC4w117ndT47bd`) | Foundry Agent Service VS | — | — |
| Agent | `agente-soberania-digital-eu` (id `asst_WtKGwogw9Bqks1zytvocU4yY`) | Foundry Agent Service agent | — | — |
| Storage account | `saagentic01` | `Microsoft.Storage/storageAccounts` | `rg-agentic-dev-eu` | `eastus` |
| Blob container | `emails-raw` | container (audit `.eml`) | `saagentic01` | — |
| Logic App | `la-email-ingest-soberania` | `Microsoft.Logic/workflows` | `rg-agentic-dev-eu` | `eastus` |
| Shared mailbox | `agente-soberania-digital@MngEnvMCAP184496.onmicrosoft.com` | Exchange Online (creado) | — | — |
| Scope security group | `sg-agente-soberania-scope@MngEnvMCAP184496.onmicrosoft.com` | mail-enabled SG (para ApplicationAccessPolicy) | — | — |

**Project endpoint:** `https://ms-foundry-dev-eu-01.services.ai.azure.com/api/projects/agentic01`

---

## Cómo usarlo

### 1. Reenviar correos

Cualquier persona del tenant puede:
- Enviar un correo nuevo a la dirección del buzón compartido, o
- Reenviar un email recibido a esa dirección

Una vez la Logic App está activa, cada correo entrante:
1. Queda guardado como `.eml` en el blob container `emails-raw` (auditoría)
2. Se sube como archivo al vector store del agente
3. El agente lo puede citar en respuestas posteriores

### 2. Conversar con el agente

Tres maneras:

**(a) Foundry Playground** — `https://ai.azure.com` → proyecto `agentic01` → Agents → `agente-soberania-digital-eu` → "Try in playground".

**(b) SDK Python** — ver `samples/chat_agent.py`. Resumido:

```python
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import MessageRole
from azure.identity import DefaultAzureCredential

client = AgentsClient(
    endpoint="https://ms-foundry-dev-eu-01.services.ai.azure.com/api/projects/agentic01",
    credential=DefaultAzureCredential(),
)
thread = client.threads.create()
client.messages.create(thread_id=thread.id, role=MessageRole.USER,
    content="¿Qué obligaciones tengo bajo el AI Act como desplegador de un sistema de IA de alto riesgo?")
run = client.runs.create_and_process(thread_id=thread.id, agent_id="asst_WtKGwogw9Bqks1zytvocU4yY")
for m in reversed(list(client.messages.list(thread_id=thread.id))):
    if m.role == "assistant":
        print(m.content[0].text.value)
        break
```

**(c) REST** — Bearer token de `https://ai.azure.com/.default`, POST a:
- `…/api/projects/agentic01/threads`
- `…/api/projects/agentic01/threads/{tid}/messages`
- `…/api/projects/agentic01/threads/{tid}/runs`

Ver `docs/REST.md`.

### 3. Ver / actualizar el prompt del agente

El system prompt vive en `scripts/create_agent.py` (variable `INSTRUCTIONS`). Edítalo y
relanza el script — es **idempotente** (detecta y actualiza si ya existe).

```powershell
az login
cd scripts
python create_agent.py
```

---

## Setup desde cero (otra suscripción)

> Si quieres replicar este montaje en otra suscripción/tenant.

### Paso 1 · Foundry account + project
```powershell
az group create -n rg-soberania-eu -l eastus
az cognitiveservices account create `
  -n my-foundry-eu-01 -g rg-soberania-eu -l eastus `
  --kind AIServices --sku S0 --custom-domain my-foundry-eu-01 `
  --assign-identity
az cognitiveservices account project create `
  --name my-foundry-eu-01 -g rg-soberania-eu --project-name soberania
```

### Paso 2 · Modelo
```powershell
az cognitiveservices account deployment create `
  --name my-foundry-eu-01 -g rg-soberania-eu `
  --deployment-name gpt-4.1-mini `
  --model-name gpt-4.1-mini --model-version 2025-04-14 --model-format OpenAI `
  --sku-name GlobalStandard --sku-capacity 50
```

### Paso 3 · Storage para emails raw
```powershell
az storage account create -n stsoberaniaeu01 -g rg-soberania-eu -l eastus `
  --kind StorageV2 --sku Standard_LRS
az storage container create -n emails-raw --account-name stsoberaniaeu01 --auth-mode login
```

### Paso 4 · RBAC
```powershell
$me = az ad signed-in-user show --query id -o tsv
$projMi = az cognitiveservices account project show --name my-foundry-eu-01 -g rg-soberania-eu `
  --project-name soberania --query identity.principalId -o tsv
$saId = az storage account show -n stsoberaniaeu01 -g rg-soberania-eu --query id -o tsv

az role assignment create --assignee-object-id $me --assignee-principal-type User `
  --role "Azure AI Project Manager" `
  --scope (az cognitiveservices account show -n my-foundry-eu-01 -g rg-soberania-eu --query id -o tsv)
az role assignment create --assignee-object-id $projMi --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope $saId
```

### Paso 5 · Agente y vector store
Edita `scripts/create_agent.py` cambiando `PROJECT_ENDPOINT` y `MODEL_DEPLOYMENT`, luego:
```powershell
pip install -r scripts/requirements.txt
python scripts/create_agent.py
```

### Paso 6 · Buzón compartido

**Opción A — automática (recomendada, requiere Exchange Admin / Global Admin)**:
```powershell
.\scripts\create-shared-mailbox.ps1 `
  -MailboxAlias agente-soberania-digital `
  -DisplayName "Agente Soberania Digital" `
  -TenantDomain MngEnvMCAP184496.onmicrosoft.com `
  -GrantAccessTo admin@MngEnvMCAP184496.onmicrosoft.com
```

**Opción B — manual desde el portal**: ver [`docs/SHARED_MAILBOX.md`](docs/SHARED_MAILBOX.md).

### Paso 7 · Logic App
```powershell
az deployment group create -g rg-soberania-eu `
  --template-file infra/logic-app.bicep `
  --parameters logicAppName=la-email-ingest-soberania `
               sharedMailboxUpn=agente-soberania-digital@<tudominio> `
               foundryProjectEndpoint=https://my-foundry-eu-01.services.ai.azure.com/api/projects/soberania `
               vectorStoreId=<vs_id> `
               storageAccountName=stsoberaniaeu01
```

### Paso 8 · Permisos para la Logic App MSI (Graph + Foundry + Storage + ApplicationAccessPolicy)

```powershell
.\scripts\post-deploy.ps1 `
  -ResourceGroup rg-soberania-eu `
  -LogicAppName la-email-ingest-soberania `
  -SharedMailboxUpn agente-soberania-digital@<tudominio> `
  -FoundryAccountName my-foundry-eu-01 `
  -StorageAccountName stsoberaniaeu01
```

Este script:
1. Concede a la MSI Graph `Mail.ReadWrite` (Application)
2. La asigna `Azure AI User` + `Cognitive Services User` sobre el Foundry account
3. La asigna `Storage Blob Data Contributor` sobre el storage
4. Crea una mail-enabled security group `sg-agente-soberania-scope` con el shared mailbox
5. Crea una `ApplicationAccessPolicy` que **restringe** la MSI a leer SOLO ese buzón
6. Verifica con `Test-ApplicationAccessPolicy` que está `Granted` para el target
   y `Denied` para el resto del tenant

**Cero clicks. Cero OAuth interactivo.**

---

## Estructura del repo

```
agente-soberania-digital-eu/
├── README.md                        ← este archivo
├── infra/
│   └── logic-app.bicep              ← Logic App (polling Graph + MSI auth)
├── scripts/
│   ├── create_agent.py              ← crear/actualizar agente y vector store
│   ├── test_agent.py                ← smoke test con email simulado
│   ├── chat_agent.py                ← cliente CLI conversacional
│   ├── create-shared-mailbox.ps1    ← crear shared mailbox via PowerShell
│   ├── post-deploy.ps1              ← RBAC + Graph perm + ApplicationAccessPolicy
│   └── requirements.txt
├── docs/
│   ├── SHARED_MAILBOX.md            ← cómo crear el buzón en M365 (manual)
│   ├── SHARED_MAILBOX_AUTO.md       ← creación automática via script
│   ├── REST.md                      ← invocar el agente vía REST
│   ├── PROMPT.md                    ← prompt del sistema (versionado)
│   └── TROUBLESHOOTING.md
├── samples/
│   └── sample-email.txt             ← correo de ejemplo para tests
├── LICENSE
└── .gitignore
```

---

## Costes estimados (mensual, uso bajo)

> Asume ~500 correos/mes y ~200 consultas/mes de 2K tokens c/u.

| Componente | SKU | Coste aprox. (USD/mes) |
|---|---|---|
| `gpt-4.1-mini` GlobalStandard | $0.40/MTok in + $1.60/MTok out | **~$2-5** |
| `text-embedding-ada-002` (vector store) | $0.10/MTok | **<$1** |
| Vector store storage | $0.10/GB-day (primeros 1GB gratis) | **$0** |
| Storage account | Standard_LRS | **<$1** |
| Logic App Consumption | $0.000025/acción | **<$1** (500 correos × ~6 acciones) |
| **Total estimado** | | **~$5-10/mes** |

Costes principales: el modelo y los embeddings. Si el volumen sube mucho, considera
provisioned throughput o cambiar a `gpt-4o-mini` (similar precio) o `gpt-5-nano`.

---

## Seguridad y red

- **Storage `saagentic01`**: actualmente con `defaultAction=Allow` por debugging. Para
  producción → cierra a `Deny` y deja únicamente:
  - **Resource access rule** para el Foundry account (ya configurada)
  - **Resource access rule** para el Logic App (añadir en deploy)
  - O **Private Endpoint** si tu red lo requiere
- **`allowSharedKeyAccess=false`**: bien — solo Entra ID auth.
- **Identidades**: project MSI `b1d2e9ee-87a0-4c3b-8092-ebe5469b7152` tiene
  `Storage Blob Data Contributor` sobre `saagentic01`.
- **Datos sensibles en correos**: si los empleados van a reenviar correos con datos
  personales, valora aplicar políticas de DLP de Microsoft Purview sobre el buzón
  compartido y revisar el régimen RGPD/LOPDGDD del propio agente (ironía).

---

## Próximos pasos / mejoras

- [ ] Añadir conector **Microsoft Graph** para que el agente pueda **responder**
      directamente al remitente original
- [ ] Conectar **Azure AI Search** (`bbdd01`) con índice de jurisprudencia EUR-Lex
- [ ] Añadir **Bing Grounding** tool para consultar últimas noticias regulatorias
- [ ] Configurar **continuous evaluation** con dataset de preguntas-respuestas
      sobre derecho UE
- [ ] **MCP tool** para conectarlo a tu base documental jurídica corporativa
- [ ] Frontend simple en **Static Web Apps** o **Teams bot** para uso interno
- [ ] Monitorización con **Application Insights** (`ai-founfry-monitoring`)

---

## Licencia

MIT — ver [`LICENSE`](LICENSE).

## Autor

Antonio Chapinal Reyes ([@chapi-dev](https://github.com/chapi-dev))
