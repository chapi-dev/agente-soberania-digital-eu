// Logic App de ingesta de correos para el agente de soberanía digital UE.
// Trigger: nuevo correo en buzón compartido (Office 365 Outlook).
// Acciones:
//   1. Componer texto plano (asunto + cuerpo + metadatos)
//   2. Subir como archivo a Foundry y adjuntar al vector store del agente
//   3. Guardar copia .eml en blob storage para auditoría
//
// Tras desplegar, ABRIR la Logic App en el portal y autorizar la API connection
// de Office 365 Outlook con una cuenta que tenga permisos sobre el shared mailbox.

@description('Nombre del Logic App workflow')
param logicAppName string = 'la-email-ingest-soberania'

@description('Región')
param location string = resourceGroup().location

@description('Email del buzón compartido (debe existir en M365)')
param sharedMailbox string

@description('Endpoint del proyecto Foundry, p.ej. https://<acc>.services.ai.azure.com/api/projects/<proj>')
param foundryProjectEndpoint string

@description('ID del vector store del agente (vs_xxx)')
param vectorStoreId string

@description('Storage account para guardar copia .eml de auditoría')
param storageAccountName string

@description('Container donde guardar los .eml')
param emailsContainerName string = 'emails-raw'

// ---------------------------------------------------------------------------
// API connection a Office 365 Outlook (requiere autorización manual post-deploy)
// ---------------------------------------------------------------------------
resource o365Connection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'office365'
  location: location
  kind: 'V2'
  properties: {
    displayName: 'Office 365 Outlook (autorizar tras deploy)'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

// ---------------------------------------------------------------------------
// Logic App
// ---------------------------------------------------------------------------
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    parameters: {
      '$connections': {
        value: {
          office365: {
            connectionId: o365Connection.id
            connectionName: 'office365'
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
          }
        }
      }
      sharedMailbox: { value: sharedMailbox }
      foundryProjectEndpoint: { value: foundryProjectEndpoint }
      vectorStoreId: { value: vectorStoreId }
      storageAccountName: { value: storageAccountName }
      emailsContainerName: { value: emailsContainerName }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': { type: 'Object' }
        sharedMailbox: { type: 'String' }
        foundryProjectEndpoint: { type: 'String' }
        vectorStoreId: { type: 'String' }
        storageAccountName: { type: 'String' }
        emailsContainerName: { type: 'String' }
      }
      triggers: {
        When_a_new_email_arrives_in_a_shared_mailbox: {
          recurrence: {
            frequency: 'Minute'
            interval: 1
          }
          type: 'ApiConnection'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'office365\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/v2/SharedMailbox/Mail/OnNewEmail'
            queries: {
              mailboxAddress: '@parameters(\'sharedMailbox\')'
              folderPath: 'Inbox'
              importance: 'Any'
              fetchOnlyWithAttachment: false
              includeAttachments: true
            }
          }
        }
      }
      actions: {
        Compose_email_text: {
          type: 'Compose'
          inputs: '@{concat(\'From: \', triggerBody()?[\'from\'], \'\\nTo: \', triggerBody()?[\'toRecipients\'], \'\\nDate: \', triggerBody()?[\'receivedDateTime\'], \'\\nSubject: \', triggerBody()?[\'subject\'], \'\\n\\n\', triggerBody()?[\'body\'])}'
        }

        Upload_to_Foundry_files: {
          type: 'Http'
          runAfter: { Compose_email_text: ['Succeeded'] }
          inputs: {
            method: 'POST'
            uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/files?api-version=v1\')}'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://ai.azure.com'
            }
            headers: {
              'Content-Type': 'multipart/form-data; boundary=----foundryboundary'
            }
            body: '@{concat(\'------foundryboundary\\r\\nContent-Disposition: form-data; name="purpose"\\r\\n\\r\\nassistants\\r\\n------foundryboundary\\r\\nContent-Disposition: form-data; name="file"; filename="email-\', triggerBody()?[\'id\'], \'.txt"\\r\\nContent-Type: text/plain\\r\\n\\r\\n\', outputs(\'Compose_email_text\'), \'\\r\\n------foundryboundary--\\r\\n\')}'
          }
        }

        Attach_to_vector_store: {
          type: 'Http'
          runAfter: { Upload_to_Foundry_files: ['Succeeded'] }
          inputs: {
            method: 'POST'
            uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/vector_stores/\', parameters(\'vectorStoreId\'), \'/files?api-version=v1\')}'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://ai.azure.com'
            }
            headers: { 'Content-Type': 'application/json' }
            body: {
              file_id: '@{body(\'Upload_to_Foundry_files\')?[\'id\']}'
            }
          }
        }

        Save_raw_eml_to_blob: {
          type: 'Http'
          runAfter: { Attach_to_vector_store: ['Succeeded'] }
          inputs: {
            method: 'PUT'
            uri: '@{concat(\'https://\', parameters(\'storageAccountName\'), \'.blob.core.windows.net/\', parameters(\'emailsContainerName\'), \'/\', formatDateTime(utcNow(),\'yyyy/MM/dd\'), \'/email-\', triggerBody()?[\'id\'], \'.txt\')}'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://storage.azure.com/'
            }
            headers: {
              'x-ms-blob-type': 'BlockBlob'
              'x-ms-version': '2024-08-04'
              'Content-Type': 'text/plain'
            }
            body: '@outputs(\'Compose_email_text\')'
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output logicAppName string = logicApp.name
output logicAppPrincipalId string = logicApp.identity.principalId
output o365ConnectionId string = o365Connection.id
output postDeployActions string = '1) Autoriza la API connection "office365" en el portal con un usuario con acceso al shared mailbox. 2) Asigna a la MSI ${logicApp.identity.principalId} los roles: "Azure AI User" sobre el Foundry account, "Storage Blob Data Contributor" sobre el storage account.'
