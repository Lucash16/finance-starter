---
name: atualizar-bancos-agora-pluggy-sync
description: Use quando o usuário pedir sincronização dos bancos.
---
# Atualizar bancos agora

1. No diretório do starter, execute `scripts/sync-now.sh` com `FINANCE_SYNC_URL` e `FINANCE_SYNC_TOKEN` fornecidos pelo ambiente. Nunca imprima o token.
2. Confira os estados retornados; HTTP 202 significa aceitação, não conclusão. Consulte `finance.sync_health` e `finance.pluggy_sync_status` com SELECT para confirmar.
3. MeuPluggy não aceita atualização forçada por PATCH /items (400). A atualização ocorre aproximadamente a cada 24 horas ou ao tocar Atualizar no app MeuPluggy; a sincronização local lê os dados disponíveis. Os webhooks item/updated e transactions/* funcionam.
4. Consulte `finance.cashflow_month` e informe projeção, vale, cota diária e horário dos dados; reporte MFA ou reconexão quando necessário.

## Regras
Nunca exponha segredos. Use somente views do banco como fonte financeira. VR, benefícios externos e transferências internas são excluídos. Sem dados disponíveis, informe a limitação. Mudanças nas fórmulas exigem migration.
