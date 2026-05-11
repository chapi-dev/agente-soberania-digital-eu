"""Cliente CLI conversacional para chatear con el agente desde terminal.

Uso:
    az login
    python chat_agent.py
"""
import json, sys
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import MessageRole
from azure.identity import DefaultAzureCredential

with open("agent-info.json", encoding="utf-8") as f:
    info = json.load(f)

cred = DefaultAzureCredential()
client = AgentsClient(endpoint=info["project_endpoint"], credential=cred)
thread = client.threads.create()
print(f"Thread {thread.id}. Escribe 'salir' para terminar.\n")

while True:
    try:
        q = input("Tú: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        break
    if q.lower() in ("salir", "exit", "quit"):
        break
    if not q:
        continue
    client.messages.create(thread_id=thread.id, role=MessageRole.USER, content=q)
    run = client.runs.create_and_process(thread_id=thread.id, agent_id=info["agent_id"])
    if run.status != "completed":
        print(f"  [run {run.status}] {getattr(run,'last_error',None)}"); continue
    last = next((m for m in client.messages.list(thread_id=thread.id) if m.role == "assistant"), None)
    if last:
        for c in last.content:
            if hasattr(c, "text") and c.text:
                print(f"\nAgente: {c.text.value}\n")
                break
