# Invocar el agente vía REST

Útil si quieres integrarlo desde una app que no tenga el SDK de Azure (ej. n8n,
Power Automate, frontend JS).

## Endpoint base

```
https://ms-foundry-dev-eu-01.services.ai.azure.com/api/projects/agentic01
```

## Auth

Bearer token Entra ID con audience `https://ai.azure.com/.default`:

```bash
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
```

El llamante debe tener al menos el rol **Azure AI User** sobre el Foundry account.

## Flujo mínimo

```bash
BASE="https://ms-foundry-dev-eu-01.services.ai.azure.com/api/projects/agentic01"
AGENT_ID="asst_WtKGwogw9Bqks1zytvocU4yY"

# 1. Crear thread
THREAD=$(curl -s -X POST "$BASE/threads?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}' \
  | jq -r .id)
echo "Thread: $THREAD"

# 2. Añadir mensaje
curl -s -X POST "$BASE/threads/$THREAD/messages?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"role":"user","content":"¿Que obligaciones impone el AI Act a un desplegador de IA de alto riesgo?"}'

# 3. Lanzar run
RUN=$(curl -s -X POST "$BASE/threads/$THREAD/runs?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"assistant_id\":\"$AGENT_ID\"}" \
  | jq -r .id)

# 4. Polling hasta completed
while true; do
  STATUS=$(curl -s "$BASE/threads/$THREAD/runs/$RUN?api-version=v1" \
    -H "Authorization: Bearer $TOKEN" | jq -r .status)
  echo "Status: $STATUS"
  [[ "$STATUS" == "completed" || "$STATUS" == "failed" ]] && break
  sleep 2
done

# 5. Leer la respuesta
curl -s "$BASE/threads/$THREAD/messages?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.data[] | select(.role=="assistant") | .content[0].text.value'
```

## Subir un archivo y adjuntarlo al vector store del agente

```bash
VS_ID="vs_tnn20yMg3aMC4w117ndT47bd"

# Subir
FILE_ID=$(curl -s -X POST "$BASE/files?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" \
  -F "purpose=assistants" \
  -F "file=@./mi-correo.txt" | jq -r .id)

# Adjuntar al vector store
curl -s -X POST "$BASE/vector_stores/$VS_ID/files?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\"}"
```
