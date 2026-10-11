# pt-BR for what the factory's scripts say: gate output, the deploy's log lines and card comments, the dispatcher's log.
# The scripts write English; aghanim_say pipes it through this file when the language is pt-BR (sed -E).
# A message with no rule here passes in English. Markers other code reads (staged-head:, deploy-merge:, deploy-fix:,
# "== start", "== end", "Factory report", gate names, column names) have no rule on purpose.
# Order matters: the longer phrase comes before the shorter one it contains.

# gates
s~acceptance tests changed after the QA commit \(beyond what merges from main brought\):~os testes de aceitação mudaram depois do commit do QA (além do que os merges da main trouxeram):~
s~acceptance tests changed after the QA commit~os testes de aceitação mudaram depois do commit do QA~
s~the owner can review these files and record them as they stand: aghanim accept~o owner pode revisar estes arquivos e registrá-los como estão: aghanim accept~
s~(acceptance-intact: .*) changed, but no assertion line did \(acceptance_assertions\); passed~\1 mudou, mas nenhuma linha de asserção mudou (acceptance_assertions); passou~
s~QA commit (.*) has no files~o commit do QA \1 não tem arquivos~
s~the last commit is not a QA commit~o último commit não é um commit do QA~
s~has one QA commit, so nothing was amended~tem um só commit do QA, então nada foi corrigido~
s~the acceptance tests of (#[0-9]+) were already amended ([0-9]+) times; the owner decides now~os testes de aceitação de \1 já foram corrigidos \2 vezes; agora o owner decide~
s~the amendment touches files that are not tests:~a correção toca em arquivos que não são testes:~
s~the amendment switches a test off:~a correção desliga um teste:~
s~the amendment removes ([0-9]+) assertion lines and adds ([0-9]+); an amended test may check differently, not less~a correção remove \1 linhas de asserção e adiciona \2; um teste corrigido pode verificar de outro jeito, não menos~
s~(qa-amend: )ok, ([0-9]+) assertion lines replaced by ([0-9]+)~\1ok, \2 linhas de asserção trocadas por \3~
s~the last commit is not the QA commit: ~o último commit não é o commit do QA: ~
s~build: (.*) build failed~build: o build de \1 falhou~
s~a changed file name has a control character \(newline, tab\.\.\.\)~um nome de arquivo alterado tem caractere de controle (quebra de linha, tab...)~
s~these paths are off-limits to agents:~estes caminhos são proibidos para os agentes:~
s~gate: bad revision~gate: revisão inválida~
s~gate: cannot enter~gate: não foi possível entrar em~
s~gate: config query failed:~gate: a consulta à config falhou:~
s~gate: install failed in (.*): ~gate: a instalação falhou em \1: ~
s~gate: layer '(.*)' has an invalid grep -E pattern:~gate: a camada '\1' tem um padrão grep -E inválido:~
s~gate: unknown layer~gate: camada desconhecida~
s~green: acceptance tests fail:~green: os testes de aceitação falham:~
s~green: no acceptance test ran for~green: nenhum teste de aceitação rodou para~
s~(red|green): selector required~\1: falta o seletor~
s~migration: (.*) already exists on the base; applied migrations are immutable \(add a new file\)~migration: \1 já existe na base; migrations aplicadas são imutáveis (crie um arquivo novo)~
s~migration: base (.*) is not an ancestor of HEAD~migration: a base \1 não é ancestral do HEAD~
s~migration: destructive migration\(s\)(.*) need a filled '## Rollback' section in ~migration: migration(s) destrutiva(s)\1 exigem a seção '## Rollback' preenchida em ~
s~migration: versions of layer '(.*)' must be unique and newer than the base's~migration: as versões da camada '\1' devem ser únicas e mais novas que as da base~
s~version ([0-9.]+) is used by ~a versão \1 é usada por ~
s~: no version in the name \(pattern ~: sem versão no nome (padrão ~
s~red: no assertion failure found in test output~red: nenhuma falha de asserção na saída dos testes~
s~red: tests fail for setup/compile reasons, not behavior:~red: os testes falham por setup ou compilação, não por comportamento:~
s~red: tests passed before implementation; they prove nothing~red: os testes passaram antes da implementação; não provam nada~
s~scope: (.*) touched files outside its area:~scope: \1 alterou arquivos fora da sua área:~
s~scope: only QA writes in tests-only layers:~scope: só o QA escreve em camadas só de testes:~
s~scope: role '(.*)' has no area in the config~scope: o papel '\1' não tem área na config~
s~scope: role required~scope: falta o papel~
s~scope: test runner config is off-limits to implementers:~scope: a config do test runner é proibida para implementadores:~
s~scope: unknown role~scope: papel desconhecido~
s~test-plan: '## Test plan' has no rows in ~test-plan: '## Test plan' não tem linhas em ~
s~test-plan: spec '(.*)' not found~test-plan: spec '\1' não encontrada~
s~test-plan: the pipeline cannot run these acceptance tests \(paths are repo-relative\):~test-plan: o pipeline não consegue rodar estes testes de aceitação (caminhos relativos ao repositório):~

# deploy: comments on the card
s~, with acceptance tests \(~, com testes de aceitação (~
s~^Back to Staged: the deploy merged (.*) and an agent fixed what broke \((.*)\)\. The fix is ([0-9]+) files and ([0-9]+) lines(.*): more than (.*) let through without you\. Review the diff (.*) and approve again\.~Voltou para Staged: o deploy mesclou a \1 e um agente consertou o que quebrou (\2). O conserto tem \3 arquivos e \4 linhas\5: mais do que \6 deixam passar sem você. Revise o diff \7 e aprove de novo.~
s~^Back to Coding: ~Voltou para Coding: ~
s~^Factory deploy stopped: ~O deploy da fábrica parou: ~
s~^Deployed: merge (.*) min from the start of this deploy run\.~Deploy feito: merge \1 min desde o início desta execução do deploy.~
s~^Production deploy failed: ~O deploy em produção falhou: ~
s~The revert could not be prepared automatically: revert (.*) by hand\.~O revert não pôde ser preparado automaticamente: reverta \1 à mão.~
s~Revert PR: ~PR de revert: ~
s~^The end of the log of the failed run:~Fim do log da execução que falhou:~

# deploy: reasons, on the card and in the log
s~([0-9]+) files conflict with main \(limit ([0-9]+)\)~\1 arquivos em conflito com a main (limite \2)~
s~([0-9]+) hunks conflict with main \(limit ([0-9]+)\)~\1 trechos em conflito com a main (limite \2)~
s~a migration conflicts with main: ~uma migration conflita com a main: ~
s~merge failed: ~o merge falhou: ~
s~CI did not finish on the PR after merging main~o CI não terminou no PR depois do merge da main~
s~CI failed on the PR after merging main~o CI falhou no PR depois do merge da main~
s~CI failed on the PR \(~o CI falhou no PR (~
s~gates failed after merging main: ~os gates falharam depois do merge da main: ~
s~gates failed after the fix: ~os gates falharam depois do conserto: ~
s~gates failed: ~os gates falharam: ~
s~the fix round fixed nothing: ~a rodada de conserto não consertou nada: ~
s~the fix round left uncommitted changes~a rodada de conserto deixou mudanças sem commit~
s~--continue with a merge in progress~--continue com um merge em andamento~
s~--continue with the merge still in progress~--continue com o merge ainda em andamento~
s~--continue with unresolved conflicts~--continue com conflitos não resolvidos~
s~--continue without a conflict handed over by deploy\.sh~--continue sem um conflito entregue pelo deploy.sh~
s~--continue: HEAD is not the merge of (.*) and (.*)~--continue: o HEAD não é o merge de \1 e \2~
s~--continue: the PR head moved since the conflicts were handed over~--continue: o head do PR mudou desde que os conflitos foram entregues~
s~--continue: the resolution changed files that did not conflict: ~--continue: a resolução alterou arquivos que não estavam em conflito: ~
s~PR #([0-9]+) changed after it was staged \(head (.*) is not the staged-head nor a recorded merge of main on it\)~o PR #\1 mudou depois de ir para Staged (o head \2 não é o staged-head nem um merge da main registrado sobre ele)~
s~PR #([0-9]+) comes from a fork; the factory deploys only its own branches~o PR #\1 vem de um fork; a fábrica só faz deploy dos próprios branches~
s~expected one open PR for #([0-9]+), found: ~esperava um PR aberto para #\1, encontrou: ~
s~gh pr merge failed: ~gh pr merge falhou: ~
s~main kept moving; three updates in a row~a main não parou de mudar; três atualizações seguidas~
s~no staged-head comment on #~sem comentário staged-head em #~
s~push of (.*) failed \(the branch moved\?\)~o push de \1 falhou (o branch mudou?)~
s~CI on (.*) did not finish \(run ~o CI da \1 não terminou (execução ~
s~CI on (.*) failed \(run ([0-9]+): ([a-z_]+)\); running its failed jobs once more~o CI da \1 falhou (execução \2: \3); rodando os jobs falhos mais uma vez~
s~CI on (.*) failed \(run ~o CI da \1 falhou (execução ~
s~deployment to '(.*)' ended '(.*)'~o deployment em '\1' terminou em '\2'~
s~health check failed: ~o health check falhou: ~
s~no '(.*)' run on (.*) for ~nenhuma execução de '\1' na \2 para ~

# deploy: log lines
s~PR #([0-9]+) has no head sha~o PR #\1 não tem head sha~
s~PR #([0-9]+) merged but its merge commit is not known yet~o PR #\1 foi mesclado, mas o commit do merge ainda não é conhecido~
s~PR #([0-9]+) was already merged as (.*); checking production~o PR #\1 já foi mesclado como \2; conferindo a produção~
s~cannot check out (.*) in ~não foi possível fazer checkout de \1 em ~
s~cannot create ~não foi possível criar ~
s~cannot list merged PRs~não foi possível listar os PRs mesclados~
s~cannot list PRs~não foi possível listar os PRs~
s~cannot read #([0-9]+) comments~não foi possível ler os comentários de #\1~
s~cannot read the GitHub user~não foi possível ler o usuário do GitHub~
s~cannot read the board~não foi possível ler o quadro~
s~cannot record the merge~não foi possível registrar o merge~
s~fetch failed~o fetch falhou~
s~origin/(.*) is not the PR head (.*) yet~origin/\1 ainda não é o head \2 do PR~
s~the card moved meanwhile~o card mudou de coluna nesse meio tempo~
s~#([0-9]+) is in '(.*)', not Ready for Prod~#\1 está em '\2', não em Ready for Prod~
s~conflicts with main; ~conflitos com a main; ~
s~; left for the deploy~; fica para o deploy~
s~; will retry~; vai tentar de novo~
s~another deploy\.sh runs on this card \(pid ~outro deploy.sh roda neste card (pid ~
s~back to Staged: a fix of ([0-9]+) files, ([0-9]+) lines, acceptance tests needs the owner~voltou para Staged: um conserto de \1 arquivos, \2 linhas, com testes de aceitação, precisa do owner~
s~back to Staged: a fix of ([0-9]+) files, ([0-9]+) lines needs the owner~voltou para Staged: um conserto de \1 arquivos, \2 linhas precisa do owner~
s~: back to Coding: ~: voltou para Coding: ~
s~: blocked: ~: bloqueado: ~
s~checks did not finish \(last: ~os checks não terminaram (último: ~
s~checks failed on ~os checks falharam em ~
s~could not comment on #~não foi possível comentar em #~
s~could not label #([0-9]+) blocked~não foi possível marcar #\1 como blocked~
s~could not move the card to ~não foi possível mover o card para ~
s~deployment ([0-9]+) superseded by a newer one~deployment \1 substituído por um mais novo~
s~: done in ([0-9]+) min~: pronto em \1 min~
s~failed after merge: (.*); revert ~falhou depois do merge: \1; revert ~
s~fix round ([0-9]) of 2: ~rodada de conserto \1 de 2: ~
s~fix what (.*) shows, commit, then run: ~conserte o que \1 mostra, faça o commit e rode: ~
s~head (.*) is not approved; not refreshing~o head \1 não está aprovado; sem atualizar~
s~main moved while waiting for CI; updating again~a main mudou durante a espera pelo CI; atualizando de novo~
s~: merged as ~: mesclado como ~
s~merged main into the PR: ~main mesclada no PR: ~
s~migration (.*) renumbered to (.*): (.*) took its version~migration \1 renumerada para \2: a \3 usou a versão dela~
s~no checks reported for (.*) \(allowed\)~nenhum check reportado para \1 (permitido)~
s~not Staged \((.*)\); nothing to refresh~não está em Staged (\1); nada a atualizar~
s~resolve these conflicts, commit, then run: ~resolva estes conflitos, faça o commit e rode: ~
s~small fix \(([0-9]+) files, ([0-9]+) lines\): it ships with the approved head~conserto pequeno (\1 arquivos, \2 linhas): segue com o head aprovado~
s~: up to date with main~: em dia com a main~

# dispatcher
s~Claude usage limit hit recently; waiting~limite de uso do Claude atingido há pouco; aguardando~
s~removed a stale index\.lock \(older than ([0-9]+) min\): ~removido um index.lock velho (mais de \1 min): ~
s~cannot bring the control checkout to ~não foi possível levar o control checkout até ~
s~no \.aghanim/factory\.yml on ~sem .aghanim/factory.yml em ~
s~invalid \.aghanim/factory\.yml on ~.aghanim/factory.yml inválido em ~
s~; skipped$~; pulado~
s~dispatch: invalid config ~dispatch: config inválida: ~
s~dispatch: cannot read limits~dispatch: não foi possível ler os limites~
s~dispatch: cannot read the machine pool~dispatch: não foi possível ler o pool da máquina~
s~dispatch: invalid ~dispatch: arquivo inválido: ~
s~dispatch: could not refresh (.*) from ~dispatch: não foi possível atualizar \1 a partir de ~
s~dispatch: board read failed~dispatch: a leitura do quadro falhou~
