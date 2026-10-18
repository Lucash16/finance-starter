---
name: painel-financeiro-html
description: Use quando o usuário pedir um painel financeiro HTML.
---
# Painel financeiro HTML

1. Consulte somente as views `finance.dashboard_cashflow`, `finance.dashboard_categories`, `finance.dashboard_monthly`, `finance.credit_limits` e `finance.sync_health` pelo MCP configurado para o projeto do usuário.
2. Preserve os valores retornados em um objeto de dados local privado; gere HTML offline com números provenientes dessas views, sem cálculos financeiros no HTML ou no agente.
3. Apresente fatura atual, projeção, vale, cota diária, meta de poupança, categorias e atualização. Formate moeda e datas no fuso configurado.
4. Confira que cada valor exibido corresponde à resposta consultada. Se faltar informação, mostre indisponível; não invente saldo. Entregue o HTML sem credenciais ou referências externas obrigatórias.

## Regras
Nunca exponha segredos. Use somente views do banco como fonte financeira. VR, benefícios externos e transferências internas são excluídos. Sem dados disponíveis, informe a limitação. Mudanças nas fórmulas exigem migration.
