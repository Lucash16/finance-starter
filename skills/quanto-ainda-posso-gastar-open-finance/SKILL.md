---
name: quanto-ainda-posso-gastar-open-finance
description: Use quando o usuário perguntar quanto pode gastar no mês.
---
# Quanto ainda posso gastar

1. Consulte `finance.cashflow_month`, `finance.budget_status`, `finance.dashboard_categories`, `finance.dashboard_monthly` e `finance.sync_health` com SELECT pelo MCP somente leitura.
2. Informe vale_amount, daily_quota, gastos registrados, categorias principais e horário da sincronização. Orçamento de envelope e vale são métricas distintas; mantenha os rótulos das views.
3. Se houver informações novas sobre despesas ou renda, peça cadastro no banco pelo fluxo autorizado; não desconte ou some valores por conta própria.
4. Não confunda mês calendário com ciclo da fatura. MeuPluggy atualiza aproximadamente a cada 24 horas ou pelo botão Atualizar no app; não recomende PATCH /items para forçar atualização.

## Regras
Nunca exponha segredos. Use somente views do banco como fonte financeira. VR, benefícios externos e transferências internas são excluídos. Sem dados disponíveis, informe a limitação. Mudanças nas fórmulas exigem migration.
