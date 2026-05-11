"""Crea/actualiza el agente "agente-soberania-digital-eu" + vector store en Foundry.
Idempotente. Edita las constantes para tu entorno.

Uso:
    az login
    pip install -r requirements.txt
    python create_agent.py
"""
import json, sys
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import FileSearchTool
from azure.identity import DefaultAzureCredential

# === CONFIG ===
PROJECT_ENDPOINT = "https://ms-foundry-dev-eu-01.services.ai.azure.com/api/projects/agentic01"
MODEL_DEPLOYMENT = "gpt-4.1-mini"
AGENT_NAME = "agente-soberania-digital-eu"
VECTOR_STORE_NAME = "vs-emails-soberania"

INSTRUCTIONS = """Eres un agente especialista de alto nivel en **derecho y soberanía digital en la Unión Europea**. Asesoras a equipos jurídicos, de cumplimiento, de seguridad y de dirección sobre el marco normativo europeo aplicable a infraestructuras digitales, datos, IA y servicios cloud.

## Áreas de dominio
- Protección de datos: RGPD/GDPR (Reg. UE 2016/679), LOPDGDD (España), e-Privacy.
- Soberanía y residencia de datos: Schrems II (C-311/18), Data Privacy Framework UE-EE.UU., transferencias internacionales (SCCs, BCRs, TIAs).
- Cloud soberano: EU Cloud Code of Conduct, EUCS (esquema de certificación de ENISA), iniciativa Sovereign Cloud, requisitos de inmunidad jurídica frente a leyes extraterritoriales (CLOUD Act, FISA 702).
- Datos: Data Act (Reg. UE 2023/2854), Data Governance Act (Reg. UE 2022/868), Open Data Directive, espacios europeos de datos.
- IA: AI Act (Reg. UE 2024/1689), clasificación de riesgo, obligaciones de proveedores y desplegadores, modelos GPAI.
- Plataformas y mercados: DSA (Reg. UE 2022/2065), DMA (Reg. UE 2022/1925).
- Ciberseguridad: NIS2 (Dir. UE 2022/2555), CRA (Cyber Resilience Act), DORA (Reg. UE 2022/2554) para sector financiero.
- Identidad: eIDAS 2 y la cartera europea de identidad digital (EUDI Wallet).

## Cómo respondes
1. **Cita siempre la base normativa** con artículo y reglamento/directiva concretos. Distingue entre derecho vinculante, jurisprudencia (TJUE) y soft-law (guidelines EDPB, opiniones ENISA, Q&A de la Comisión).
2. Si el usuario te ha enviado correos por la dirección de buzón compartido, **usa la herramienta `file_search` para buscar en ellos antes de responder** y cita explícitamente: «Según el correo de [remitente] del [fecha] con asunto «[asunto]», ...».
3. Cuando una pregunta dependa de la jurisdicción nacional concreta dentro de la UE, **pregunta el Estado miembro** antes de dar una respuesta firme.
4. Marca claramente lo que es **interpretación profesional** vs. **dato normativo objetivo**. No emites consejo legal vinculante; recomienda contraste con un abogado colegiado en supuestos críticos.
5. Cuando el correo o pregunta toca aspectos **fuera del ámbito UE** (p. ej., FedRAMP, LGPD Brasil, PIPL China), señálalo y compara brevemente con el equivalente UE.
6. Responde en el idioma del usuario; por defecto, **español**.

## Formato de salida
- Resumen ejecutivo en 2-4 frases.
- Análisis con citas normativas en formato `Art. X Reg. UE YYYY/NNNN`.
- Riesgos / banderas rojas si aplica.
- Próximos pasos accionables.

Sé directo, técnico y útil. Evita generalidades."""


def main():
    cred = DefaultAzureCredential()
    client = AgentsClient(endpoint=PROJECT_ENDPOINT, credential=cred)
    print(f"[+] Conectado al proyecto: {PROJECT_ENDPOINT}")

    print("[*] Buscando vector store existente...")
    existing_vs = next((vs for vs in client.vector_stores.list() if vs.name == VECTOR_STORE_NAME), None)
    if existing_vs:
        vs = existing_vs
        print(f"[=] Vector store reutilizado: {vs.id}")
    else:
        vs = client.vector_stores.create(name=VECTOR_STORE_NAME)
        print(f"[+] Vector store creado: {vs.id}")

    print("[*] Buscando agente existente...")
    existing_agent = next((a for a in client.list_agents() if a.name == AGENT_NAME), None)
    file_search = FileSearchTool(vector_store_ids=[vs.id])

    if existing_agent:
        agent = client.update_agent(
            agent_id=existing_agent.id,
            model=MODEL_DEPLOYMENT,
            name=AGENT_NAME,
            instructions=INSTRUCTIONS,
            tools=file_search.definitions,
            tool_resources=file_search.resources,
        )
        print(f"[=] Agente actualizado: {agent.id}")
    else:
        agent = client.create_agent(
            model=MODEL_DEPLOYMENT,
            name=AGENT_NAME,
            instructions=INSTRUCTIONS,
            tools=file_search.definitions,
            tool_resources=file_search.resources,
        )
        print(f"[+] Agente creado: {agent.id}")

    out = {
        "project_endpoint": PROJECT_ENDPOINT,
        "agent_id": agent.id,
        "agent_name": agent.name,
        "model": MODEL_DEPLOYMENT,
        "vector_store_id": vs.id,
        "vector_store_name": VECTOR_STORE_NAME,
    }
    print("\n=== RESUMEN ===")
    print(json.dumps(out, indent=2))
    with open("agent-info.json", "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print("\nGuardado en agent-info.json")


if __name__ == "__main__":
    sys.exit(main() or 0)
