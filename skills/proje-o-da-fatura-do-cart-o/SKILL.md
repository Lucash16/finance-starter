---
name: proje-o-da-fatura-do-cart-o
description: Use quando o usuário pedir fatura atual, projeção ou sobra planejada.
---
# Projeção da fatura do cartão

1. Consulte `finance.cashflow_month`, `finance.current_invoice` e `finance.current_bills` somente com SELECT.
2. Use invoice_current, projected_amount, vale_amount, daily_quota e savings_goal como retornados. Não estime renda pela memória nem some cartão físico e virtual fora das views.
3. Responda com fatura atual, projeção, vale e cota diária, e sobra planejada. Identifique saldo ausente e sincronização desatualizada.
4. Compras PENDING já aparecem na fatura; não desconte duas vezes. Recorrências em processamento são uma heurística registrada no banco.

## Regras
Nunca exponha segredos. Use somente views do banco como fonte financeira. VR, benefícios externos e transferências internas são excluídos. Sem dados disponíveis, informe a limitação. Mudanças nas fórmulas exigem migration.
