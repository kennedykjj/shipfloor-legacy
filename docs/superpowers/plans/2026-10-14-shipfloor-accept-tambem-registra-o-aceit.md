# Plano — shipfloor accept registra o aceite na issue (#264)

Camada única: `factory` (agente: engineer; executado pelo Tech Lead, peso standard).

1. Tarefa 1 (factory) — `scripts/shipfloor_core/cli.py` (`cmd_accept`): duas passadas; depois de gravar o tsv, um `gh api -X POST repos/<repo>/issues/<n>/comments -F body=@<tmp>`; falha vira aviso em stderr, exit 0.
2. Tarefa 2 (factory) — `scripts/test/py/cli_support.py`: o duplo `GH` ganha o caso do comentário (QA, junto dos testes).
3. Testes de aceite (QA) — `scripts/test/py/cli_registry.py`, classe `Accept`: AC-1..AC-6.

Dependências: QA primeiro (testes vermelhos), depois a tarefa 1.
