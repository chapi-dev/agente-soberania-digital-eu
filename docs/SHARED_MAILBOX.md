# Crear el buzón compartido en Microsoft 365

> Esta es la **única acción manual** que requiere el setup. La hace el administrador
> del tenant de Microsoft 365.

## Requisitos
- Rol de **Exchange Administrator** (o Global Administrator) en el tenant.
- Acceso a https://admin.microsoft.com.

## Pasos

### 1. Crear el buzón compartido

1. Inicia sesión en https://admin.microsoft.com.
2. Menú lateral → **Equipos y grupos** → **Buzones compartidos**
   *(o en inglés: Teams & groups → Shared mailboxes)*.
3. Pulsa **+ Agregar un buzón compartido**.
4. Rellena:
   - **Nombre**: `Agente Soberanía Digital`
   - **Dirección**: `agente-soberania-digital`
   - **Dominio**: tu dominio principal del tenant (`@<tu-dominio>`)
5. Pulsa **Guardar cambios**. La creación tarda **~1-5 min** en propagarse.

> 🚨 **Sin licencia adicional necesaria** — Microsoft 365 incluye los buzones
> compartidos de hasta 50 GB sin coste extra siempre que ningún usuario los
> use como buzón principal.

### 2. Añadir miembros (quién puede leer/responder)

Tras crear el buzón:

1. Abre el buzón en el portal admin → pestaña **Miembros**.
2. Pulsa **Editar** → **Agregar miembros**.
3. Añade:
   - **Tu propia cuenta** (necesario para autorizar la Logic App)
   - Los compañeros que necesiten leer las respuestas del agente

### 3. (Opcional) Permitir reenvío externo

Si quieres que personas externas a tu organización puedan enviar correos
al buzón:

1. **Microsoft 365 Admin Center** → **Buzones compartidos** → tu buzón →
   **Configuración del correo electrónico** → **Editar** junto a "Bloquear
   reenvío automático para emails enviados fuera de la organización".
2. O simplemente confirma que las reglas anti-spam permiten correo externo.

Por defecto, los buzones aceptan correo externo.

### 4. (Opcional) Reglas de buzón / etiquetado

Recomendado:
- Crear una **etiqueta de retención** que conserve los correos al menos 1 año
  (auditoría regulatoria).
- Configurar una **regla de transporte** que ponga `[AGENTE]` en el asunto
  de los correos entrantes para identificarlos fácil.

### 5. Verificar

Envía un correo de prueba a `agente-soberania-digital@<tu-dominio>` desde
otra cuenta. Debería aparecer en la **Bandeja de entrada** del buzón
compartido en pocos segundos.

## Tras crear el buzón

Pasa al README principal: [Setup Logic App](../README.md#paso-7--logic-app).
Necesitarás el email completo (`agente-soberania-digital@<tu-dominio>`)
como parámetro `sharedMailbox` en el deploy.

## Troubleshooting

| Síntoma | Causa | Solución |
|---|---|---|
| No aparece la opción "Buzones compartidos" | No tienes rol Exchange Admin | Pide el rol al admin global |
| El buzón se crea pero no recibe correos externos | DNS / MX records | Verifica `nslookup -type=MX <tu-dominio>` |
| La Logic App no puede leer correos del buzón | Falta añadirte como miembro | Volver al paso 2 |
| Quiero que el agente RESPONDA al remitente | Por defecto solo lee | Ver "Próximos pasos" en README — habilita Microsoft Graph para enviar |
