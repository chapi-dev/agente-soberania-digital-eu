"""Smoke test: sube un correo simulado al vector store y hace 1 pregunta al agente."""
import json, sys
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import FilePurpose, MessageRole
from azure.identity import DefaultAzureCredential

with open("agent-info.json", encoding="utf-8") as f:
    info = json.load(f)

SAMPLE = """From: maria.gomez@empresa-cliente.es
To: agente-soberania-digital@miempresa.com
Date: 2026-05-10 14:32 +0200
Subject: Consulta urgente - transferencia datos a proveedor SaaS de EE.UU.

Buenos días,
Estamos evaluando contratar un nuevo CRM SaaS cuyo proveedor (Acme Corp)
está establecido en California. Procesarán datos personales de nuestros
clientes europeos (perfiles, contactos, histórico de compra). El proveedor
nos asegura que están adheridos al EU-US Data Privacy Framework. Nuestra
duda: ¿Esto es suficiente como base de transferencia internacional o
necesitamos añadir SCCs y un TIA? El RGPD/LOPDGDD nos obliga a documentar
algo extra? Tenemos 2 semanas para tomar la decisión.
Gracias,
María
"""

cred = DefaultAzureCredential()
client = AgentsClient(endpoint=info["project_endpoint"], credential=cred)

with open("sample-email.txt", "w", encoding="utf-8") as f:
    f.write(SAMPLE)
uploaded = client.files.upload_and_poll(file_path="sample-email.txt", purpose=FilePurpose.AGENTS)
print(f"file_id = {uploaded.id}")
batch = client.vector_store_files.create_and_poll(vector_store_id=info["vector_store_id"], file_id=uploaded.id)
print(f"vs_file status = {batch.status}")

thread = client.threads.create()
client.messages.create(thread_id=thread.id, role=MessageRole.USER,
    content="Mira el correo que te ha llegado de María Gómez (empresa-cliente.es). ¿Qué le contestamos? Déjalo accionable.")
run = client.runs.create_and_process(thread_id=thread.id, agent_id=info["agent_id"])
print(f"run status = {run.status}")
if run.status == "failed":
    print(f"error = {run.last_error}"); sys.exit(1)

print("\n=== RESPUESTA ===\n")
for m in reversed(list(client.messages.list(thread_id=thread.id))):
    if m.role == "assistant":
        for c in m.content:
            if hasattr(c, "text") and c.text:
                print(c.text.value)
        break
