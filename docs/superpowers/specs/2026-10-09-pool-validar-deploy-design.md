# Pool de agentes, esteira de validação e deploy sem regressão — design

**Data:** 2026-10-09 · **Status:** decidido em conversa (pool por máquina, números absolutos, critérios de conflito)

## Contexto

No Shop, #74 e #70 foram desenvolvidos em paralelo a partir do mesmo `main`, cada um criou uma `V27` e entraram com 2 minutos de diferença: o `main` ficou vermelho e nenhum deploy subiu até o #75 renumerar. Cada PR passou no CI sozinho; nenhum foi testado em cima do outro. Além disso, o `/deployar` devolvia o card para Coding em qualquer conflito de merge.

## Objetivos

1. **Pool de agentes por máquina.** O dono escolhe quantos runs simultâneos a máquina roda (`pool`) e quantos cabem em cada etapa, em números absolutos.
2. **Validação como etapa própria**, para que planejamento, implementação e validação tenham cotas separadas.
3. **Nunca mais duas migrations com a mesma versão, nem migration fora de ordem**, e nunca um merge que não foi testado em cima do `main` atual.
4. **O deploy resolve conflitos sozinho** e só devolve para Coding por critérios definidos.

## 1. Pool (`~/.mylos/config.yml`)

```yaml
pool: 4                 # runs simultâneos nesta máquina, somando todos os projetos
stages:                 # máximo de runs por etapa (absoluto)
  refinar: 2            # planejamento
  desenvolver: 2        # implementação
  validar: 2            # validação
  deployar: 1           # deploy
```

- Arquivo ausente = os valores acima. Validação: `pool` inteiro ≥ 1; `stages` só com essas quatro chaves, cada uma inteira entre 0 e `pool`. Config inválida → o dispatcher não lança nada naquele ciclo (log).
- Um run começa só se houver vaga no `pool`, na etapa (contando runs vivos daquela etapa em todos os projetos) e no limite do projeto (`limits.<etapa>.parallel` do `factory.yml`, que continua existindo para um projeto pedir menos).
- `MYLOS_MAX_PARALLEL` no ambiente sobrepõe `pool` (testes e emergência).
- CLI: `mylos pool` mostra a configuração e os runs vivos por etapa; `mylos pool set <n>`; `mylos pool stage <etapa> <n>`.

## 2. Esteira `/validar`

- O board não muda. `Validation` passa a ser a fila do `/validar` (antes era coluna de trabalho do `/desenvolver`). O WIP `desenvolver.wip` continua contando Coding + Validation.
- `/desenvolver`: plano → testes de aceite → implementação → **atualiza com o `main`** → gates → push → move para Validation. Não abre PR.
- `/validar`: atualiza com o `main` → gates → review do Tech Lead, UX `validate` (se houve UX), Cybersec `diff` (com label) → 🔴 volta para o dono do arquivo (máx. 2 rodadas) → push → PR (cria ou reaproveita) → CI → Staged com `staged-head`.
- Dispatcher: `validar` com fila `Validation`, sem colunas de órfãos (a fila é a própria coluna); `desenvolver` passa a ter só `Coding` como órfão.

## 3. Migrations e `main` atual

- **Gate `migration <base> <spec>`** ganha duas regras por camada com `migrations`:
  - *versões únicas*: nenhuma versão repetida entre todos os arquivos de migration da árvore;
  - *em ordem*: toda migration adicionada desde `<base>` tem versão maior que todas as que já existiam em `<base>`.
  A versão vem do nome do arquivo pelo regex `migrations.version` (padrão `^[A-Za-z]*([0-9]+(?:[._][0-9]+)*)`, que cobre `V27__x.sql` e `000027_x.up.sql`).
- **Atualizar com o `main`** (em `/desenvolver` antes do PR, em `/validar` e em `/deployar`): `git merge origin/<main>`, e os gates passam a usar `base=$(git merge-base HEAD origin/<main>)`, para que só as migrations do card contem como novas.
- **`/deployar` só faz merge se o head do PR contiver o `origin/<main>` atual** (`git merge-base --is-ancestor`) e o CI tiver passado naquele head. Senão atualiza, roda os gates, faz push e espera o CI de novo.

## 4. Conflito no deploy

Ao atualizar com o `main`:
- **Sem conflito:** commit de merge, gates, push, CI.
- **Com conflito,** devolve para Coding (comentário com o motivo e os arquivos) se:
  - algum arquivo em conflito é migration de alguma camada;
  - há mais de `deploy.conflict_max_files` arquivos (padrão 5) ou mais de `deploy.conflict_max_hunks` hunks (padrão 20) em conflito.
- Caso contrário resolve: cada arquivo vai para o agente da camada dona (`layer-of`) com os hunks; arquivo sem camada é resolvido pelo próprio Tech Lead. Commit de merge, gates (`migration`, `build`, `green` dos testes de aceite), push, CI.
- **Gates ou CI falham depois de resolver** → devolve para Coding com a saída.
- O commit aprovado continua sendo o `staged-head`; o deploy aceita como novo head só o commit de merge cujo primeiro pai é o aprovado e o segundo é o `origin/<main>` usado, e registra isso no comentário de sucesso.

## Testes

- Config da máquina: padrões, valores, inválidos (chave desconhecida, etapa > pool, pool 0).
- Dispatcher: limite por etapa somando projetos; `pool` global; `validar` lança da fila Validation; `desenvolver` não trata Validation como órfão.
- Gate `migration`: versão repetida (inclusive vinda do `main` após o merge) e migration nova com versão menor que uma existente → bloqueia; caso normal passa; regex de versão configurável.
- CLI: `mylos pool`, `pool set`, `pool stage`.
- Higiene: a skill `validar` existe e nada cita Shop.
