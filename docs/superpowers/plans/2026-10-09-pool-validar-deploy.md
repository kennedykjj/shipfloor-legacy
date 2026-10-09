# Pool, /validar e deploy sem regressão — plano

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** pool de runs por máquina com cotas absolutas por etapa, esteira `/validar`, gate de migrations que impede versões repetidas/fora de ordem, e `/deployar` que resolve conflitos.

**Spec:** `docs/superpowers/specs/2026-10-09-pool-validar-deploy-design.md`

## Global Constraints
- Gates: 0 passa, 1 bloqueia, 2 uso/config inválida.
- Python com `-I`, saída com `\n`; scripts referenciados como `bash ~/.mylos/factory/<script>`.
- Etapas fixas: `refinar`, `desenvolver`, `validar`, `deployar`.

## Review Focus
- Run vivo de uma etapa em outro projeto ocupa a vaga da etapa → teste em Task 2.
- `~/.mylos/config.yml` inválido → nada é lançado, nunca um limite infinito → Task 1/2.
- Migration vinda do `main` depois do merge não conta como "nova" quando o base é o merge-base → Task 3.
- Nome de migration que não casa o regex de versão → bloqueia (não é ignorado) → Task 3.

### Task 1: config da máquina
Files: `scripts/mylos_config.py` (comando `machine`), `scripts/lib/project.sh` (`mylos_machine`), `scripts/test/machine.test.sh`.
- [ ] Testes: padrões sem arquivo (`pool`=4, stages 2/2/2/1); valores lidos; inválidos (stage desconhecida, stage > pool, pool 0, não-inteiro) → `machine validate` exit 1; `machine set pool 6` e `machine set stages.validar 3` gravam e preservam o resto.
- [ ] Implementar; commit `feat(pool): machine-wide agent pool config`.

### Task 2: dispatcher com cotas e `/validar`
Files: `scripts/dispatch.sh`, `scripts/mylos_config.py` (limits.validar), `scripts/test/dispatch-pool.test.sh`, testes de dispatch existentes.
- [ ] Testes: cota `desenvolver: 1` com run vivo de `desenvolver` em outro projeto → nada; `pool` 1 com run vivo de `refinar` → nada; `validar` lança da fila Validation; Validation não é órfão de `desenvolver`; config da máquina inválida → nada e exit ≠ 0.
- [ ] Implementar; commit `feat(dispatch): per-stage slots from the machine pool and the validar stage`.

### Task 3: gate de migrations
Files: `scripts/gate.sh`, `scripts/mylos_config.py` (`migration-check`, validação de `migrations.version`, `deploy.conflict_max_*`), `scripts/test/gate-migration-order.test.sh`.
- [ ] Testes: versão repetida na árvore → 1; nova menor que existente no base → 1; base = merge-base após merge do main (V27 do main existente, branch com V28) → 0; nome fora do regex → 1; regex configurável (`000027_x.up.sql`).
- [ ] Implementar; commit `feat(gate): unique and ordered migration versions`.

### Task 4: skills e CLI
Files: `skills/desenvolver`, `skills/validar` (novo), `skills/deployar`, `scripts/mylos` (`pool`), `README.md`, `examples/factory.yml`, `scripts/test/mylos-cli.test.sh`, `scripts/test/hygiene.test.sh`.
- [ ] Testes CLI: `mylos pool` mostra pool e etapas; `pool set`/`pool stage` gravam; valor inválido → exit 1 sem gravar. Higiene: `skills/validar/SKILL.md` existe.
- [ ] Reescrever as skills conforme a spec; commit `feat: validar stage and conflict-resolving deploy`.
