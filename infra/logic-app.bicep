// Logic App de ingesta de correos para el agente de soberaia digital UE.
// Variante con Microsoft Graph + Managed Identity (sin conector Office 365).
// 
// La Logic App:
//   1. Cada 2 min: GET https://graph.microsoft.com/v1.0/users/{shared}/messages
//      filtrando por isRead=false
//   2. Para cada mensaje no leido:
//      a. POST a Foundry /files (multipart) con el contenido del email
//      b. POST a Foundry /vector_stores/{id}/files para adjuntarlo
//      c. (opcional) PUT del .txt a blob storage para auditoria
//      d. Crea un thread, envia el email como pregunta y lanza un run del agente
//      e. Hace polling del run hasta que termina y lee la respuesta del agente
//      f. Responde automaticamente al remitente via Graph /messages/{id}/reply
//      g. PATCH del mensaje a isRead=true
//
// Tras desplegar, la MSI necesita:
//   - Mail.ReadWrite (Application) en Microsoft Graph
//   - Mail.Send (Application) en Microsoft Graph (para auto-responder)
//   - ApplicationAccessPolicy restringiendola al shared mailbox
//   - Azure AI User en el Foundry account
//   - Storage Blob Data Contributor en el storage account
// El script post-deploy.ps1 hace todo eso automaticamente.

@description('Nombre del Logic App')
param logicAppName string = 'la-email-ingest-soberania'

@description('Region')
param location string = resourceGroup().location

@description('UPN del shared mailbox (debe existir en M365)')
param sharedMailboxUpn string

@description('Endpoint del proyecto Foundry')
param foundryProjectEndpoint string

@description('ID del vector store del agente (vs_xxx)')
param vectorStoreId string

@description('Storage account para guardar copia de auditoria')
param storageAccountName string

@description('Container para los .txt')
param emailsContainerName string = 'emails-raw'

@description('Frecuencia de polling en minutos')
param pollIntervalMinutes int = 2

@description('ID del agente Foundry (asst_xxx) que responde automaticamente a los correos')
param agentId string = 'asst_WtKGwogw9Bqks1zytvocU4yY'

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    parameters: {
      sharedMailboxUpn: { value: sharedMailboxUpn }
      foundryProjectEndpoint: { value: foundryProjectEndpoint }
      vectorStoreId: { value: vectorStoreId }
      storageAccountName: { value: storageAccountName }
      emailsContainerName: { value: emailsContainerName }
      agentId: { value: agentId }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        sharedMailboxUpn: { type: 'String' }
        foundryProjectEndpoint: { type: 'String' }
        vectorStoreId: { type: 'String' }
        storageAccountName: { type: 'String' }
        emailsContainerName: { type: 'String' }
        agentId: { type: 'String' }
      }
      triggers: {
        Recurrence: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Minute'
            interval: pollIntervalMinutes
          }
        }
      }
      actions: {
        Get_unread_messages: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: '@{concat(\'https://graph.microsoft.com/v1.0/users/\', parameters(\'sharedMailboxUpn\'), \'/mailFolders/Inbox/messages\')}'
            queries: {
              '$filter': 'isRead eq false'
              '$select': 'id,subject,from,toRecipients,receivedDateTime,bodyPreview,body'
              '$top': '20'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://graph.microsoft.com'
            }
          }
        }
        For_each_message: {
          type: 'Foreach'
          runAfter: { Get_unread_messages: ['Succeeded'] }
          foreach: '@body(\'Get_unread_messages\')?[\'value\']'
          actions: {
            Compose_email_text: {
              type: 'Compose'
              inputs: '@{concat(\'From: \', items(\'For_each_message\')?[\'from\']?[\'emailAddress\']?[\'address\'], \'\\nDate: \', items(\'For_each_message\')?[\'receivedDateTime\'], \'\\nSubject: \', items(\'For_each_message\')?[\'subject\'], \'\\n\\n\', items(\'For_each_message\')?[\'bodyPreview\'])}'
            }
            Build_multipart_body: {
              type: 'Compose'
              runAfter: { Compose_email_text: ['Succeeded'] }
              inputs: '@{concat(\'------foundryboundary\', decodeUriComponent(\'%0D%0A\'), \'Content-Disposition: form-data; name="purpose"\', decodeUriComponent(\'%0D%0A%0D%0A\'), \'assistants\', decodeUriComponent(\'%0D%0A\'), \'------foundryboundary\', decodeUriComponent(\'%0D%0A\'), \'Content-Disposition: form-data; name="file"; filename="email-\', items(\'For_each_message\')?[\'id\'], \'.txt"\', decodeUriComponent(\'%0D%0A\'), \'Content-Type: text/plain\', decodeUriComponent(\'%0D%0A%0D%0A\'), outputs(\'Compose_email_text\'), decodeUriComponent(\'%0D%0A\'), \'------foundryboundary--\', decodeUriComponent(\'%0D%0A\'))}'
            }
            Upload_to_Foundry: {
              type: 'Http'
              runAfter: { Build_multipart_body: ['Succeeded'] }
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
                body: '@outputs(\'Build_multipart_body\')'
              }
            }
            Attach_to_vector_store: {
              type: 'Http'
              runAfter: { Upload_to_Foundry: ['Succeeded'] }
              inputs: {
                method: 'POST'
                uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/vector_stores/\', parameters(\'vectorStoreId\'), \'/files?api-version=v1\')}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://ai.azure.com'
                }
                headers: { 'Content-Type': 'application/json' }
                body: {
                  file_id: '@{body(\'Upload_to_Foundry\')?[\'id\']}'
                }
              }
            }
            Save_audit_blob: {
              type: 'Http'
              runAfter: { Attach_to_vector_store: ['Succeeded'] }
              inputs: {
                method: 'PUT'
                uri: '@{concat(\'https://\', parameters(\'storageAccountName\'), \'.blob.core.windows.net/\', parameters(\'emailsContainerName\'), \'/\', formatDateTime(utcNow(),\'yyyy/MM/dd\'), \'/email-\', items(\'For_each_message\')?[\'id\'], \'.txt\')}'
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
            Create_thread: {
              type: 'Http'
              runAfter: {
                Save_audit_blob: ['Succeeded']
              }
              inputs: {
                method: 'POST'
                uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/threads?api-version=v1\')}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://ai.azure.com'
                }
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {}
              }
            }
            Compose_agent_prompt: {
              type: 'Compose'
              runAfter: {
                Create_thread: ['Succeeded']
              }
              inputs: '@{concat(\'Eres el asistente del buzon de soberania digital de la UE. Redacta una respuesta profesional, clara y bien fundamentada al siguiente correo, en el mismo idioma del remitente, citando la normativa europea aplicable cuando proceda. Devuelve UNICAMENTE el cuerpo del correo de respuesta, sin asunto ni encabezados.\', decodeUriComponent(\'%0D%0A%0D%0A\'), \'--- CORREO RECIBIDO ---\', decodeUriComponent(\'%0D%0A\'), outputs(\'Compose_email_text\'))}'
            }
            Add_message: {
              type: 'Http'
              runAfter: {
                Compose_agent_prompt: ['Succeeded']
              }
              inputs: {
                method: 'POST'
                uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/threads/\', body(\'Create_thread\')?[\'id\'], \'/messages?api-version=v1\')}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://ai.azure.com'
                }
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  role: 'user'
                  content: '@{outputs(\'Compose_agent_prompt\')}'
                }
              }
            }
            Create_run: {
              type: 'Http'
              runAfter: {
                Add_message: ['Succeeded']
              }
              inputs: {
                method: 'POST'
                uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/threads/\', body(\'Create_thread\')?[\'id\'], \'/runs?api-version=v1\')}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://ai.azure.com'
                }
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  assistant_id: '@{parameters(\'agentId\')}'
                }
              }
            }
            Until_run_complete: {
              type: 'Until'
              runAfter: {
                Create_run: ['Succeeded']
              }
              expression: '@or(equals(body(\'Get_run_status\')?[\'status\'], \'completed\'), equals(body(\'Get_run_status\')?[\'status\'], \'failed\'), equals(body(\'Get_run_status\')?[\'status\'], \'cancelled\'), equals(body(\'Get_run_status\')?[\'status\'], \'expired\'))'
              limit: {
                count: 60
                timeout: 'PT5M'
              }
              actions: {
                Delay_poll: {
                  type: 'Wait'
                  inputs: {
                    interval: {
                      count: 3
                      unit: 'Second'
                    }
                  }
                }
                Get_run_status: {
                  type: 'Http'
                  runAfter: {
                    Delay_poll: ['Succeeded']
                  }
                  inputs: {
                    method: 'GET'
                    uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/threads/\', body(\'Create_thread\')?[\'id\'], \'/runs/\', body(\'Create_run\')?[\'id\'], \'?api-version=v1\')}'
                    authentication: {
                      type: 'ManagedServiceIdentity'
                      audience: 'https://ai.azure.com'
                    }
                  }
                }
              }
            }
            If_run_completed: {
              type: 'If'
              runAfter: {
                Until_run_complete: ['Succeeded']
              }
              expression: {
                and: [
                  {
                    equals: [
                      '@body(\'Get_run_status\')?[\'status\']'
                      'completed'
                    ]
                  }
                ]
              }
              actions: {
                Get_messages: {
                  type: 'Http'
                  inputs: {
                    method: 'GET'
                    uri: '@{concat(parameters(\'foundryProjectEndpoint\'), \'/threads/\', body(\'Create_thread\')?[\'id\'], \'/messages?api-version=v1\')}'
                    authentication: {
                      type: 'ManagedServiceIdentity'
                      audience: 'https://ai.azure.com'
                    }
                  }
                }
                Filter_assistant: {
                  type: 'Query'
                  runAfter: {
                    Get_messages: ['Succeeded']
                  }
                  inputs: {
                    from: '@body(\'Get_messages\')?[\'data\']'
                    where: '@equals(item()?[\'role\'], \'assistant\')'
                  }
                }
                Compose_reply: {
                  type: 'Compose'
                  runAfter: {
                    Filter_assistant: ['Succeeded']
                  }
                  inputs: '@{coalesce(first(body(\'Filter_assistant\'))?[\'content\']?[0]?[\'text\']?[\'value\'], \'Gracias por su correo. Lo hemos recibido y sera procesado por el equipo.\')}'
                }
                Send_reply: {
                  type: 'Http'
                  runAfter: {
                    Compose_reply: ['Succeeded']
                  }
                  inputs: {
                    method: 'POST'
                    uri: '@{concat(\'https://graph.microsoft.com/v1.0/users/\', parameters(\'sharedMailboxUpn\'), \'/messages/\', items(\'For_each_message\')?[\'id\'], \'/reply\')}'
                    authentication: {
                      type: 'ManagedServiceIdentity'
                      audience: 'https://graph.microsoft.com'
                    }
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      comment: '@{outputs(\'Compose_reply\')}'
                    }
                  }
                }
              }
            }
            Mark_as_read: {
              type: 'Http'
              runAfter: {
                If_run_completed: ['Succeeded', 'Failed', 'Skipped']
              }
              inputs: {
                method: 'PATCH'
                uri: '@{concat(\'https://graph.microsoft.com/v1.0/users/\', parameters(\'sharedMailboxUpn\'), \'/messages/\', items(\'For_each_message\')?[\'id\'])}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://graph.microsoft.com'
                }
                headers: { 'Content-Type': 'application/json' }
                body: { isRead: true }
              }
            }
          }
        }
      }
    }
  }
}

output logicAppName string = logicApp.name
output logicAppPrincipalId string = logicApp.identity.principalId
