# shipfloor accept também registra o aceite na issue do card — spec

**Issue:** #264 · **Branch:** `feat/264-shipfloor-accept-tambem-registra-o-aceit` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** a decisão do dono no `shipfloor accept` só existe em `accepted.tsv` nesta máquina; se `~/.shipfloor` se perder ou o dono mudar de máquina, o gate `acceptance-intact` volta a bloquear o card sem rastro do porquê.
**Audience:** o dono da fábrica (desenvolvedor que roda o Shipfloor na própria máquina).
**Acceptance criteria**
- **AC-1** — Dado um card com dois arquivos de aceite alterados depois do commit de QA e o gh simulado (`FACTORY_GH`), quando o dono roda `shipfloor accept <projeto> <n> <motivo>`, então o gh recebe exatamente um comentário na issue `#<n>`, feito pela API REST (`gh api`, não GraphQL).
- **AC-2** — Dado o cenário do AC-1, quando o comentário é enviado, então ele traz uma linha por arquivo aceito com o caminho, a chave gravada (blob, chave da edição própria ou `deleted`) e o commit de QA, além do motivo e da data.
- **AC-3** — Dado o cenário do AC-1, quando o `accept` termina, então o `accepted.tsv` tem as mesmas linhas, no mesmo formato, que teria sem esta mudança.
- **AC-4** — Dado um card cujos arquivos de aceite já passam no `acceptance-intact` (nada a aceitar), quando o dono roda `shipfloor accept`, então nenhum comentário é feito e a saída continua "nothing to accept…".
- **AC-5** — Dado o gh simulado falhando no comentário, quando o dono roda `shipfloor accept` com algo a aceitar, então o `accepted.tsv` é gravado, o stderr avisa que a cópia na issue não foi feita e o exit é 0.
- **AC-6** — Dado um arquivo aceito como apagado (stub substituído), quando o comentário é feito, então a linha desse arquivo mostra a chave `deleted`.
**Out of scope:** mudar o formato do `accepted.tsv` ou o gate `acceptance-intact`; o gate ler os aceites da issue ou restaurar `accepted.tsv` a partir dela; levar o `accepted` para o SQLite (#262); tentar de novo um comentário que falhou; arquivo de teste novo (os testes estendem `scripts/test/py/cli_registry.py`).
**Product fit:** serve ao princípio 1 (o board é a fonte da verdade): a decisão do dono passa a viver na issue, fora da máquina, e o princípio 4 (o dono age só onde a fábrica o espera), já que um aceite perdido o faria reaceitar. Não contradiz o posicionamento: o gate continua sendo o script e a cópia na issue é só registro. A fronteira "só o push ntfy sai da máquina" vale para o dashboard; este comentário sai pelo gh, como as demais escritas da fábrica no GitHub.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Camada única: `factory`. Sem migração, sem endpoint, sem mudança de contrato do `accepted.tsv` nem do gate.

- `scripts/shipfloor_core/cli.py` — `cmd_accept`:
  - Duas passadas: a primeira monta a lista `(f, key, qa)` do que falta aceitar e checa `git status --porcelain` de cada arquivo; a segunda grava as linhas no `accepted.tsv` (mesmo formato de hoje) e imprime as mesmas mensagens em stdout.
  - Depois de gravar, se a lista não está vazia, posta **um** comentário: `proc.gh_argv("api", "-X", "POST", "repos/<repo>/issues/<n>/comments", "-F", "body=@<arquivo temporário>")`, com `<repo>` = `_cfg_value("get", "project.repo")[1]` (como em `_doctor_project`). REST, nunca `gh issue comment` (que usa GraphQL).
  - Corpo (texto fixo em inglês, como toda saída do CLI): título `**shipfloor accept** — card #<n>`, uma linha por arquivo `` - `<path>` → `<key>` (QA `<qa[:12]>`) ``, depois `Reason: <motivo>` e `Date: <data ISO, a mesma gravada no tsv>`.
  - Falha do gh (exit ≠ 0, gh ausente/OSError, `project.repo` vazio) → `_err("accepted locally; the copy on issue #<n> was not posted: <motivo curto>")` e `return 0`. O arquivo temporário é sempre apagado.
  - Nada a aceitar → nenhuma chamada ao gh (comportamento e stdout de hoje).
- `scripts/test/py/cli_support.py` — o duplo `GH` ganha o caso `api -X POST repos/*/issues/*/comments*`: copia o arquivo de `body=@…` para `$GH_STUB_DIR/comment-<k>` e sai 1 se existir `$GH_STUB_DIR/comment-fails`. Os demais casos não mudam.
- `scripts/test/py/cli_registry.py` — classe `Accept`: testes novos para os AC-1..AC-6 (dois arquivos num `accept`, nada a aceitar, gh falhando, arquivo apagado), reaproveitando `qa()`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/cli_registry.py` |
| AC-2 | factory | `scripts/test/py/cli_registry.py` |
| AC-3 | factory | `scripts/test/py/cli_registry.py` |
| AC-4 | factory | `scripts/test/py/cli_registry.py` |
| AC-5 | factory | `scripts/test/py/cli_registry.py` |
| AC-6 | factory | `scripts/test/py/cli_registry.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- `accept` checa arquivos não commitados de todos antes de gravar qualquer linha: hoje um `die` no meio do laço deixa parte gravada no tsv e, com esta mudança, sem cópia na issue; tudo ou nada evita esse estado.
- Um comentário por `accept` (não um por arquivo), depois de gravar o tsv: a issue pede um único registro e o aceite local nunca depende da rede.
- `gh api` com `-F body=@arquivo`: REST fica fora da cota GraphQL e o corpo de várias linhas não passa pela linha de comando.
- Texto do comentário em inglês fixo: o CLI não tem tradução e é usado em projetos de qualquer idioma; o conteúdo útil (caminhos, chaves, motivo) não depende do idioma.
- O motivo vai à issue como o dono escreveu: é texto dele, na issue do próprio card, com a mesma visibilidade dos demais comentários da fábrica.
- O dashboard (botão aceitar) não mostra o aviso de stderr: ele só olha o exit code, que segue 0; mostrar o aviso fica fora desta issue.
- Sem arquivo de teste novo: a suíte `cli_registry.py` já cobre o `accept`; o duplo do gh mora em `cli_support.py`, o suporte dela.

## Open questions
- none
