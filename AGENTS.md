# Regras para agentes

- Todo valor financeiro do dashboard e de relatórios vem das views do schema `finance`, consultadas no servidor. Nenhuma soma, projeção, saldo ou orçamento é calculado no frontend. Conversão decimal para centavos, formatação BRL e proporções visuais são apresentação.
- Mocks somente na rota `/preview`; fixtures sintéticas de testes não são fontes do dashboard.
- VR e outros benefícios externos não entram no orçamento. Transferências internas, pagamentos de fatura e investimentos não contam como despesa; registrar identidades do titular para classificar transferências próprias.
- Alterações de schema e fórmulas exigem migration em `db/migrations`; depois do primeiro deploy, criar uma nova migration.
- Nunca ler, imprimir ou versionar credenciais, respostas com tokens, dados pessoais ou arquivos `.env`.
- Agentes consultam com papel somente leitura e não alteram cadastros sem instrução explícita.
- Não acessar rede ou banco para validar código sem autorização. Usar testes locais com mocks.
