# Rebrand mylos → Aghanim's Anvil Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the factory from "mylos" to **Aghanim's Anvil** (plugin, CLI, config and machine home `aghanim`; GitHub repo `aghanim-anvil`) without stopping Pickio, which runs on it today.

**Architecture:** Mechanical rename first, with no change in behavior. Then a transition layer: the config is read from `.aghanim/factory.yml` and falls back to the legacy `.mylos/factory.yml`, both paths stay forbidden to agents, and `aghanim migrate-home` moves `~/.mylos` to `~/.aghanim` and repairs its git worktrees. The cutover on the machine and the Pickio PR happen in one maintenance window with the dispatcher paused. Once Pickio has moved, a final task drops the fallback.

**Tech Stack:** bash (Git Bash on Windows), Python 3.11 + PyYAML, PowerShell 5.1 (scheduled task), `gh`, Claude Code plugin marketplace.

**Spec:** naming decision from the 2026-10-09 conversation, recorded in memory `rename-aghanims-anvil.md` and in `~/.claude/dev-journal/decisions-log.md`. No separate design doc.

## Global Constraints

- Brand (README, marketplace, plugin description): **Aghanim's Anvil — a software factory for Claude Code**
- Plugin, marketplace, CLI, skill prefix: `aghanim` → `/aghanim:refine`, `/aghanim:develop`, `/aghanim:validate`, `/aghanim:deploy`; install as `aghanim@aghanim`
- Target-repo config: `.aghanim/factory.yml` (optional `.aghanim/review-criteria.md`)
- Machine home: `~/.aghanim` (env `AGHANIM_HOME`), installed scripts in `~/.aghanim/factory/`
- Env vars: every `MYLOS_*` becomes `AGHANIM_*` (`HOME`, `LIB`, `PY`, `MAX_PARALLEL`, `DISPATCH`, `FACTORY`, `MACHINE_CONFIG`, `WT`). No legacy env var is read.
- Shell functions: `mylos_*` → `aghanim_*`; scripts `mylos` → `aghanim`, `mylos-config.sh` → `aghanim-config.sh`, `mylos-dispatch.sh` → `aghanim-dispatch.sh`, `mylos_config.py` → `aghanim_config.py`
- Scheduled task: `AghanimDispatcher`; the installer removes `MylosDispatcher`
- GitHub repo: `kennedykjj/aghanim-anvil`; local checkout `C:\Users\Kj\git\aghanim-anvil`
- Every line that still names mylos on purpose (the transition fallback) carries the marker `legacy mylos` so the hygiene test can allow it and Task 8 can find it.
- `docs/superpowers/**` (historical specs and plans) stays untouched.
- Plugin version: `0.6.0`.
- Keep the existing commit style, `type(scope): ...`, ending with the Co-Authored-By line.

## Review Focus

1. **An agent edits the legacy config dir during the transition.** Both `.aghanim/` and `.mylos/` must stay forbidden (built-in regex and `factory-guard.yml`). Test in Task 3.
2. **A repo that has both config dirs.** `.aghanim/factory.yml` must win, silently. Test in Task 3.
3. **`migrate-home` runs while a pipeline is running, or when `~/.aghanim` already exists.** It must refuse and leave both dirs untouched. Test in Task 4.
4. **Moved worktrees (`control`, `reports-wt`) stay linked to the project repo.** After the move, `git status` works inside them and the repo lists no prunable worktree. Test in Task 4.
5. **A stale "mylos" left in a shipped file**, for example a skill telling agents to run `~/.mylos/factory/gate.sh`, which no longer exists after the cutover. The hygiene test fails on it. Test in Task 6.

---

## File map

| Area | Files |
|---|---|
| CLI and libs | `scripts/mylos` → `scripts/aghanim`, `scripts/lib/project.sh`, `scripts/mylos-config.sh` → `scripts/aghanim-config.sh`, `scripts/mylos_config.py` → `scripts/aghanim_config.py`, `scripts/mylos-dispatch.sh` → `scripts/aghanim-dispatch.sh`, `scripts/run-dispatcher.sh` |
| Scripts that use them | `scripts/{gate,board,deploy,dispatch,report,metrics,setup-board}.sh`, `scripts/review-template.html` |
| Plugin surface | `.claude-plugin/{plugin,marketplace}.json`, `skills/*/SKILL.md`, `agents/*.md`, `templates/{factory-guard.yml,review-criteria.md}`, `examples/factory.yml` |
| Installer | `installer/install-dispatcher.ps1` |
| Docs | `README.md`, `.gitattributes` |
| Tests | `scripts/test/lib.sh`, `mylos-cli.test.sh` → `aghanim-cli.test.sh`, `mylos-dispatch.test.sh` → `aghanim-dispatch.test.sh`, all `*.test.sh` that name mylos; new `scripts/test/transition.test.sh`; `scripts/test/hygiene.test.sh` |
| Outside this repo | Pickio (`.mylos/`, `.claude/settings.json`, `.claude/agents/*-engineer.md`, `.github/workflows/factory-guard.yml`, `CLAUDE.md`), `~/.claude/settings.json`, `~/.claude/plugins/*`, `~/.mylos/`, scheduled task, Claude project memory dir |

---

### Task 0: Clean baseline

**Files:** none

- [ ] **Step 1:** The working tree has uncommitted changes from another session (`scripts/deploy.sh`, `scripts/gate.sh`, `scripts/test/*`). Ask the owner whether to commit or stash them. Do not start the rebrand on top of them.
- [ ] **Step 2:** Branch: `git switch -c rebrand/aghanim`
- [ ] **Step 3:** Baseline: `bash scripts/test/run.sh`. Expected: every file passes (33 files at the last run). Write down the ok count; Task 1 must end with the same count.

### Task 1: Mechanical rename (no behavior change)

Every `mylos` identifier becomes `aghanim`, except the target-repo config dir and the forbidden-path regex. Those keep `.mylos/` until Task 3, so the suite proves this task changed only names.

**Files:** the CLI/libs, scripts, tests and installer rows of the file map (not the plugin surface or docs).

- [ ] **Step 1: Rename the files with history**

```bash
git mv scripts/mylos scripts/aghanim
git mv scripts/mylos-config.sh scripts/aghanim-config.sh
git mv scripts/mylos-dispatch.sh scripts/aghanim-dispatch.sh
git mv scripts/mylos_config.py scripts/aghanim_config.py
git mv scripts/test/mylos-cli.test.sh scripts/test/aghanim-cli.test.sh
git mv scripts/test/mylos-dispatch.test.sh scripts/test/aghanim-dispatch.test.sh
```

- [ ] **Step 2: Rewrite identifiers, protecting the config dir and the forbidden regex**

```bash
files=$(git grep -lI mylos -- scripts installer .gitattributes)
sed -i \
  -e 's#~/\.mylos#~/.aghanim#g' -e 's#\$HOME/\.mylos#$HOME/.aghanim#g' -e "s#'\.mylos\\\\#'.aghanim\\\\#g" \
  -e 's#\.mylos/#.KEEPCFG/#g' \
  -e 's/MYLOS_/AGHANIM_/g' -e 's/mylos_/aghanim_/g' \
  -e 's/MylosDispatcher/AghanimDispatcher/g' \
  -e 's/mylos/aghanim/g' -e 's/Mylos/Aghanim/g' \
  -e 's#\.KEEPCFG/#.mylos/#g' \
  $files
```

Order matters. The home-dir forms (`~/.mylos`, `$HOME/.mylos`, the `.mylos\` Windows path) become `.aghanim` first. Only then does `.KEEPCFG/` shield the remaining repo-relative `.mylos/` (`factory.yml`, `review-criteria.md`, the forbidden regex) from the general rename. `$MYLOS_HOME/...` becomes `$AGHANIM_HOME/...` through the `MYLOS_` rule. Then check by hand:
  - `git grep -n '\.mylos' scripts installer` must show only the repo-relative config paths: `lib/project.sh` snapshot, `aghanim` add, `aghanim_config.py` BUILTIN_FORBIDDEN and docstrings, `board.sh` comment, tests that build `.mylos/factory.yml` fixtures, and `templates/` (not touched yet).
  - `git grep -n 'aghanim/factory\|\.aghanim' scripts installer` must show only home-dir uses.
  - In `installer/install-dispatcher.ps1` the Windows path is `'.aghanim\factory\run-dispatcher.sh'` and the task is `AghanimDispatcher`.

- [ ] **Step 3: The installer removes the old task**

In `installer/install-dispatcher.ps1`, before `Register-ScheduledTask`:

```powershell
# The task was called MylosDispatcher before the rename (legacy mylos); it would run a script that no longer exists.
if (Get-ScheduledTask -TaskName 'MylosDispatcher' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'MylosDispatcher' -Confirm:$false }
```

- [ ] **Step 4: Run the suite**

Run: `bash scripts/test/run.sh`
Expected: the same ok count as Task 0, 0 FAIL. A failure here means sed hit something it should not have; fix it by hand, not by changing a test's expectation.

- [ ] **Step 5: Commit**

```bash
git add -A scripts installer .gitattributes
git commit -m "refactor: rename mylos to aghanim in scripts, CLI, env and scheduled task"
```

### Task 2: Plugin surface and dispatcher prompt

**Files:** `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/*/SKILL.md`, `agents/*.md`, `templates/review-criteria.md`, `examples/factory.yml`, `scripts/dispatch.sh` (prompt `/aghanim:$p`, done by Task 1's sed; verify)

- [ ] **Step 1:** `plugin.json`: `"name": "aghanim"`, `"version": "0.6.0"`, `"description": "Aghanim's Anvil — a software factory for Claude Code. Turns GitHub issues into shipped PRs: agents refine, build and validate; deterministic gates they can't edit decide what passes."`. `marketplace.json`: marketplace and plugin `name` become `aghanim`, with the same description.
- [ ] **Step 2:** Skills and agents: same sed as Task 1 Step 2 over `skills agents templates examples`, but here `.mylos/` becomes `.aghanim/` (drop the `KEEPCFG` lines). Skill names are directory names (`refine`, `develop`…), so they stay; the prefix comes from the plugin name. The engineer agent's rule "never touch … `.mylos/`" becomes `.aghanim/`. Do not touch `templates/factory-guard.yml` here (Task 3 owns it).
- [ ] **Step 3:** `git grep -n '/mylos:\|~/.mylos' skills agents scripts` → empty.
- [ ] **Step 4:** `bash scripts/test/run.sh` → all green (`dispatch*.test.sh` asserts the prompt it sends, so a missed `/mylos:` fails here).
- [ ] **Step 5:** Commit: `feat(plugin): rename the plugin to aghanim (Aghanim's Anvil) 0.6.0`

### Task 3: Config dir `.aghanim/` with legacy fallback, both forbidden

**Files:**
- Modify: `scripts/lib/project.sh` (`aghanim_snapshot`), `scripts/aghanim` (`cmd_add`), `scripts/aghanim_config.py` (`BUILTIN_FORBIDDEN`, docstring, describe default text), `templates/factory-guard.yml`
- Create: `scripts/test/transition.test.sh`

**Interfaces:**
- Produces: `aghanim_config_path <git-dir> <rev>` in `lib/project.sh`. It prints `.aghanim/factory.yml`, or `.mylos/factory.yml` when only the legacy file exists at `<rev>`, and returns 1 when neither exists. On the legacy path it prints a one-line warning to stderr: `aghanim: <git-dir>: using legacy .mylos/factory.yml; move it to .aghanim/`.

- [ ] **Step 1: Write the failing test** `scripts/test/transition.test.sh`

```bash
#!/usr/bin/env bash
# During the rename the factory reads .aghanim/factory.yml, falls back to the legacy .mylos/ one,
# and keeps both dirs off-limits to agents.
source "$(dirname "$0")/lib.sh"
M="$FACTORY_DIR/aghanim"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export AGHANIM_HOME="$(mktemp -d)"
FIX="$(cat "$FACTORY_DIR/test/fixture/factory.yml")"

repo_with() {  # repo_with <dir>...: a repo whose origin/main has the fixture config in each dir
  local remote r d; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"
  for d in "$@"; do mkdir -p "$r/$d"; printf '%s\n' "$FIX" > "$r/$d/factory.yml"; done
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  echo "$r"
}

# new dir: registered, no warning
r="$(repo_with .aghanim)"
out="$(bash "$M" add "$r" 2>&1)"; rc=$?
[ $rc = 0 ] && pass "add reads .aghanim/factory.yml" || fail "add .aghanim → $rc: $out"
case "$out" in *legacy*) fail "warned on the new dir" ;; *) pass "no warning on the new dir" ;; esac

# legacy dir only: registered, with a warning
bash "$M" remove shop >/dev/null 2>&1
r="$(repo_with .mylos)"
out="$(bash "$M" add "$r" 2>&1)"; rc=$?
[ $rc = 0 ] && pass "add falls back to .mylos/factory.yml" || fail "add .mylos → $rc: $out"
assert_contains "$out" "legacy .mylos/factory.yml"
[ -f "$AGHANIM_HOME/projects/shop/factory.yml" ] && pass "snapshot from the legacy dir" || fail "no snapshot"

# both dirs: the new one wins, silently
bash "$M" remove shop >/dev/null 2>&1
r="$(repo_with .aghanim .mylos)"
echo "# from-aghanim" >> "$r/.aghanim/factory.yml"  # same slug in both; only the new file has the marker; git -C "$r" commit -qam mark; git -C "$r" push -q origin main
out="$(bash "$M" add "$r" 2>&1)"
case "$out" in *legacy*) fail "warned although .aghanim exists" ;; *) pass "both dirs: no warning" ;; esac
grep -q 'from-aghanim' "$AGHANIM_HOME/projects/shop/factory.yml" && pass ".aghanim wins over .mylos" || fail "read the legacy file"

# both dirs stay forbidden to agents
re="$(FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" bash "$FACTORY_DIR/aghanim-config.sh" regex forbidden)"
for p in .aghanim/factory.yml .mylos/factory.yml; do
  printf '%s\n' "$p" | grep -qE -- "$re" && pass "forbidden: $p" || fail "not forbidden: $p"
done
grep -q '\\.aghanim/' "$FACTORY_DIR/../templates/factory-guard.yml" && pass "guard blocks .aghanim/" || fail "guard misses .aghanim/"
grep -q '\\.mylos/' "$FACTORY_DIR/../templates/factory-guard.yml" && pass "guard blocks .mylos/" || fail "guard misses .mylos/"

# neither dir: refused
bash "$M" remove shop >/dev/null 2>&1
assert_exit 1 bash "$M" add "$(new_repo)"
finish
```

- [ ] **Step 2: Run it, expect FAIL**

Run: `bash scripts/test/run.sh transition.test.sh`
Expected: FAIL on "add reads .aghanim/factory.yml" (the code still reads only `.mylos/`) and on "forbidden: .aghanim/factory.yml".

- [ ] **Step 3: Implement the fallback** in `scripts/lib/project.sh`

```bash
aghanim_config_path() {  # aghanim_config_path <git-dir> <rev>: the config path committed at rev
  local d="$1" rev="$2" p
  for p in .aghanim/factory.yml .mylos/factory.yml; do  # legacy mylos: drop .mylos once no project uses it
    if MSYS2_ARG_CONV_EXCL="*" git -C "$d" cat-file -e "$rev:$p" 2>/dev/null; then
      [ "$p" = .aghanim/factory.yml ] || echo "aghanim: $d: using legacy .mylos/factory.yml; move it to .aghanim/" >&2  # legacy mylos
      echo "$p"; return 0
    fi
  done
  return 1
}

aghanim_snapshot() {  # aghanim_snapshot: FACTORY_CONFIG = the project config as committed at control's HEAD
  local d p tmp="$FACTORY_CONFIG.tmp"; d="$(aghanim_native "$FACTORY_HOME/control")"
  p="$(aghanim_config_path "$d" HEAD)" || return 1
  # Git Bash would take "HEAD:.aghanim/..." for a path list and mangle it
  MSYS2_ARG_CONV_EXCL="*" git -C "$d" show "HEAD:$p" > "$tmp" 2>/dev/null && mv "$tmp" "$FACTORY_CONFIG" || { rm -f "$tmp"; return 1; }
}
```

Keep the existing body of `aghanim_snapshot` (the `tmp` naming and `mv`); only the path lookup changes. In `scripts/aghanim` `cmd_add`:

```bash
  local p; p="$(aghanim_config_path "$(aghanim_native "$repo")" "origin/$main")" || die "origin/$main has no .aghanim/factory.yml"
  MSYS2_ARG_CONV_EXCL="*" git -C "$(aghanim_native "$repo")" show "origin/$main:$p" > "$cfg" 2>/dev/null || die "cannot read $p on origin/$main"
  FACTORY_CONFIG="$cfg" aghanim_validate || die "invalid $p on origin/$main"
```

Also update `aghanim-dispatch.sh` lines 43-44: their messages say `.mylos/factory.yml`; make them say `.aghanim/factory.yml`.

- [ ] **Step 4: Forbid both dirs**

`scripts/aghanim_config.py`:

```python
BUILTIN_FORBIDDEN = r"^(\.github/|\.githooks/|\.claude/|\.aghanim/|\.mylos/)|^(CLAUDE\.md|\.gitattributes|\.mcp\.json)$|(^|/)\.env"  # legacy mylos dir stays forbidden
```

`templates/factory-guard.yml` line 26: `\.claude/|\.mylos/)` → `\.claude/|\.aghanim/|\.mylos/)`, and append ` # legacy mylos dir stays forbidden` at the end of that shell line. Update the docstring and the describe default (`~/.aghanim/factory/templates/review-criteria.md`), and `templates/review-criteria.md` (`.aghanim/factory.yml`, `.aghanim/review-criteria.md`).

- [ ] **Step 5: Move the test fixtures to the new dir**

The other tests (`aghanim-cli`, `aghanim-dispatch`, `dispatch-project`, `project-resolve`…) build `.mylos/factory.yml`. Switch them to `.aghanim/` with `sed -i 's#\.mylos/#.aghanim/#g'` on those test files. `transition.test.sh` is the only test that still builds `.mylos/`.

- [ ] **Step 6:** `bash scripts/test/run.sh` → all green, including `transition.test.sh`.
- [ ] **Step 7:** Commit: `feat(config): read .aghanim/factory.yml with legacy .mylos fallback; both dirs forbidden`

### Task 4: `aghanim migrate-home`

**Files:** Modify `scripts/aghanim` (new command plus a usage line in the header comment); Test: append to `scripts/test/transition.test.sh`

**Interfaces:**
- Produces: `aghanim migrate-home [OLD]` (default `OLD=$HOME/.mylos`). Exit 0 after the move; exit 1 with nothing touched when OLD is missing, `$AGHANIM_HOME` exists, or any `*.lock` exists under `OLD/projects/*/locks` or `OLD/locks`.

- [ ] **Step 1: Failing test** (append before `finish`):

```bash
# migrate-home moves the old home and keeps its worktrees linked
mk_old() {  # mk_old: a legacy home with one project whose control is a worktree of a repo; prints "old repo"
  local base old repo; base="$(mktemp -d)"; old="$base/.mylos"; mkdir -p "$old/projects/shop/locks"
  repo="$(new_repo)"; git -C "$repo" worktree add -q --detach "$old/projects/shop/control" main
  echo "$old $repo"
}
read -r old repo <<< "$(mk_old)"
export AGHANIM_HOME="$(mktemp -d)/.aghanim"
assert_exit 0 bash "$M" migrate-home "$old"
[ ! -e "$old" ] && pass "old home gone" || fail "old home still there"
assert_exit 0 git -C "$AGHANIM_HOME/projects/shop/control" status
case "$(git -C "$repo" worktree list --porcelain)" in *prunable*) fail "worktree left prunable" ;; *) pass "worktree relinked" ;; esac

# refuses while a run holds a lock
read -r old repo <<< "$(mk_old)"; mkdir "$old/projects/shop/locks/develop-12.lock"
export AGHANIM_HOME="$(mktemp -d)/.aghanim"
assert_exit 1 bash "$M" migrate-home "$old"
[ -d "$old" ] && [ ! -e "$AGHANIM_HOME" ] && pass "lock: nothing moved" || fail "moved with a live lock"

# refuses to merge into an existing home
read -r old repo <<< "$(mk_old)"
export AGHANIM_HOME="$(mktemp -d)"   # exists already
assert_exit 1 bash "$M" migrate-home "$old"
[ -d "$old/projects/shop/control" ] && pass "existing target: nothing moved" || fail "touched the old home"

# missing old home
assert_exit 1 bash "$M" migrate-home "$(mktemp -d)/nope"
```

- [ ] **Step 2:** `bash scripts/test/run.sh transition.test.sh` → FAIL: unknown command `migrate-home`.
- [ ] **Step 3: Implement** in `scripts/aghanim`:

```bash
cmd_migrate_home() {  # migrate-home [OLD]: move the legacy mylos home to $AGHANIM_HOME and relink its worktrees
  local old="${1:-$HOME/.mylos}" d  # legacy mylos home
  [ -d "$old" ] || die "nothing to migrate: $old does not exist"
  [ ! -e "$AGHANIM_HOME" ] || die "$AGHANIM_HOME already exists; move or remove it first"
  if [ -n "$(find "$old/locks" "$old"/projects/*/locks -mindepth 1 -maxdepth 1 -name '*.lock' 2>/dev/null)" ]; then
    die "runs in progress in $old (locks present); wait for them to end"
  fi
  mkdir -p "$(dirname "$AGHANIM_HOME")"
  mv "$old" "$AGHANIM_HOME" || die "cannot move $old to $AGHANIM_HOME"
  for d in "$AGHANIM_HOME"/projects/*/control "$AGHANIM_HOME"/projects/*/reports-wt; do
    [ -e "$d/.git" ] && { git -C "$d" worktree repair >/dev/null 2>&1 || echo "aghanim: could not relink $d (git worktree repair)" >&2; }
  done
  echo "moved $old to $AGHANIM_HOME; run 'aghanim install' and the dispatcher installer next"
}
```

Add `migrate-home) cmd_migrate_home "$@" ;;` to the command `case`, and to the header: `#   migrate-home [OLD]            move the old ~/.mylos home here (one-time, after the rename)`.

- [ ] **Step 4:** `bash scripts/test/run.sh` → all green.
- [ ] **Step 5:** Commit: `feat(cli): migrate-home moves the legacy home and relinks its worktrees`

### Task 5: `doctor` points at the move

**Files:** Modify `scripts/aghanim` (`cmd_doctor`); Test: `scripts/test/aghanim-cli.test.sh`

- [ ] **Step 1: Failing test** (append before `finish`):

```bash
# doctor tells a machine that still has the old home to migrate it
fake="$(mktemp -d)"; mkdir -p "$fake/.mylos"
out="$(HOME="$fake" AGHANIM_HOME="$fake/.aghanim" bash "$M" doctor 2>&1)"
assert_contains "$out" "aghanim migrate-home"
```

- [ ] **Step 2:** Run `bash scripts/test/run.sh aghanim-cli.test.sh` → FAIL (missing text).
- [ ] **Step 3:** In `cmd_doctor`, next to the other checks:

```bash
  if [ -d "$HOME/.mylos" ] && [ ! -e "$AGHANIM_HOME" ]; then  # legacy mylos home
    echo "warn: found $HOME/.mylos from before the rename; run: aghanim migrate-home"
  fi
```

Follow the existing `doctor` output style (check how other lines print warn/fail before choosing the prefix).
- [ ] **Step 4:** Suite green.
- [ ] **Step 5:** Commit: `feat(cli): doctor flags a machine that still has the legacy home`

### Task 6: README with the brand, hygiene guard

**Files:** `README.md`, `scripts/test/hygiene.test.sh`

- [ ] **Step 1: Failing test**: add to `hygiene.test.sh` before `finish`:

```bash
# The rename left no live "mylos": only lines marked "legacy mylos" (the transition fallback) may name it.
stale="$(cd "$root" && grep -rIniE 'mylos' skills agents scripts templates installer examples README.md .claude-plugin .gitattributes 2>/dev/null \
  | grep -v '^scripts/test/' | grep -v 'legacy mylos' || true)"
[ -z "$stale" ] && pass "no stale mylos references" || fail "stale mylos:
$stale"
grep -q "^# Aghanim's Anvil" "$root/README.md" && pass "README carries the brand" || fail "README title"
```

Also change the last line's `mylos-config.sh` to `aghanim-config.sh` if Task 1 missed it.
- [ ] **Step 2:** `bash scripts/test/run.sh hygiene.test.sh` → FAIL listing the README lines.
- [ ] **Step 3: README**. Title and lead:

```markdown
# Aghanim's Anvil

**A software factory for Claude Code.** Turns GitHub issues into shipped PRs: agents refine, build and validate; deterministic gates they can't edit decide what passes.

> Aghanim's Scepter upgrades a hero. The Anvil is what everything is shaped against: it doesn't move. The agents strike; the gates hold.
```

Then replace every `mylos` in the body: `/aghanim:*`, `.aghanim/factory.yml`, `~/.aghanim/...`, `aghanim pool`, `claude plugin install aghanim@aghanim`, `alias aghanim='bash ~/.aghanim/factory/aghanim'`, `aghanim doctor/add/setup-board`. Add a short "Upgrading from mylos" section after Install:

```markdown
## Upgrading from mylos

1. `mylos pause` and wait until `mylos pool` shows no runs.
2. Install the new plugin (`claude plugin install aghanim@aghanim`), then `bash <plugin>/scripts/aghanim migrate-home` and `aghanim install`.
3. Run `installer/install-dispatcher.ps1` again (it replaces `MylosDispatcher` with `AghanimDispatcher`).
4. In each repo, move `.mylos/` to `.aghanim/` and update anything that calls `~/.mylos/factory/` (agents, `.claude/settings.json`, `factory-guard.yml`). Until then the factory still reads `.mylos/factory.yml`, with a warning.
5. `aghanim resume`.
```

- [ ] **Step 4:** Mark each line of the "Upgrading from mylos" section with a trailing `<!-- legacy mylos -->` so the single hygiene rule allows it. Then the suite must be green, and `git grep -n mylos -- ':!docs/superpowers' ':!scripts/test'` must show only lines containing `legacy mylos`.
- [ ] **Step 5:** Commit: `docs: Aghanim's Anvil README and upgrade notes; hygiene guards stale mylos`

### Task 7: Cutover on the machine and in Pickio (owner present, maintenance window)

No code; the owner runs it or approves each step. Order matters: Pickio's agents call `~/.mylos/factory/gate.sh` until its PR is merged, so the dispatcher stays paused from step 1 to step 9.

- [ ] **1. Pause:** `mylos pause`; wait until `mylos pool` shows no runs and `find ~/.mylos -name '*.lock'` is empty.
- [ ] **2. Merge the branch:** PR `rebrand/aghanim` → `main` (CI green), then merge.
- [ ] **3. Rename on GitHub:** `gh repo rename aghanim-anvil -R kennedykjj/mylos-factory`; `git remote set-url origin https://github.com/kennedykjj/aghanim-anvil.git`. GitHub redirects the old URL. Then `gh repo edit kennedykjj/aghanim-anvil --description "Aghanim's Anvil — a software factory for Claude Code: GitHub issues to shipped PRs, with agents and deterministic gates." --add-topic claude-code,software-factory,ai-agents,claude-code-plugin,kanban`.
- [ ] **4. Rename the local checkout:** close the Claude sessions in this dir, then `mv C:/Users/Kj/git/mylos-factory C:/Users/Kj/git/aghanim-anvil`. Move the Claude project memory: `C:\Users\Kj\.claude\projects\C--Users-Kj-git-mylos-factory` → `...\C--Users-Kj-git-aghanim-anvil` (it holds `MEMORY.md`, `pickio-migration-pending.md`, `rename-aghanims-anvil.md`).
- [ ] **5. Plugin:** `claude plugin uninstall mylos@mylos`; `claude plugin marketplace remove mylos`; `claude plugin marketplace add C:/Users/Kj/git/aghanim-anvil`; `claude plugin install aghanim@aghanim`. Check that `~/.claude/settings.json` no longer has `mylos@mylos` or the `mylos` marketplace, and that it has `aghanim`.
- [ ] **6. Home:** `bash C:/Users/Kj/git/aghanim-anvil/scripts/aghanim migrate-home`, then `bash ~/.aghanim/factory/aghanim install`. In the shell profile, replace `alias mylos=...` with `alias aghanim='bash ~/.aghanim/factory/aghanim'`. Then `aghanim doctor` → no warnings; `aghanim list` shows `pickio`. `aghanim migrate-home` moves the PAUSE file along with the rest, so the dispatcher stays paused.
- [ ] **7. Scheduled task:** `powershell -File installer/install-dispatcher.ps1`; `Get-ScheduledTask -TaskName MylosDispatcher` → not found; `AghanimDispatcher` → Ready.
- [ ] **8. Pickio PR (by hand: these are forbidden paths for agents):** in a branch off Pickio `main`:
  - `git mv .mylos .aghanim`; update the header comment of `.aghanim/factory.yml` (`Aghanim's Anvil`, new repo URL).
  - `.claude/settings.json`: `~/.mylos/factory/` → `~/.aghanim/factory/` and `mylos-config.sh` → `aghanim-config.sh` (lines 32-38, including the `/c/Users/Kj/...` and `C:/Users/Kj/...` forms).
  - `.claude/agents/backend-engineer.md`, `frontend-engineer.md`: `~/.mylos/factory/gate.sh` → `~/.aghanim/factory/gate.sh`.
  - `.github/workflows/factory-guard.yml`: add `\.aghanim/` next to `\.mylos/` in the regex.
  - `CLAUDE.md` line 78: `/aghanim:refine`, `/aghanim:develop`, `/aghanim:validate`, `/aghanim:deploy`. These also fix the stale `refinar/desenvolver/deployar` names, the missing validate stage, the plugin name, `.aghanim/factory.yml`, `AghanimDispatcher`, `aghanim list`, `aghanim pause pickio`, `~/.aghanim/factory/board.sh`.
  - `docs/engineering/factory-context.md`: same replacements, where they apply.
  - Merge, then `aghanim add C:/Users/Kj/git/pickio` (refreshes the snapshot from `.aghanim/`, no legacy warning).
- [ ] **9. Smoke and resume:** `bash ~/.aghanim/factory/gate.sh -C C:/Users/Kj/git/pickio forbidden origin/main` → exit 0; `aghanim resume`; after 3 minutes, `tail ~/.aghanim/logs/dispatcher.log` shows a cycle with no error. Run one card (any column) through one stage and check that its log starts with `== start /aghanim:`.
- [ ] **10. Memory:** update `rename-aghanims-anvil.md` (migration done, date) and `pickio-migration-pending.md` (Pickio on aghanim 0.6.0).

### Task 8: Drop the fallback (after Task 7, once no registered project has `.mylos/`)

**Files:** `scripts/lib/project.sh`, `scripts/aghanim` (`migrate-home` and doctor check stay; only the config fallback goes), `scripts/test/transition.test.sh`, README upgrade section (keep it, it is history for other users)

- [ ] **Step 1:** In `transition.test.sh`, change the legacy case to expect refusal: `assert_exit 1 bash "$M" add "$(repo_with .mylos)"`, and delete the "both dirs" case.
- [ ] **Step 2:** Run → FAIL (legacy is still accepted).
- [ ] **Step 3:** `aghanim_config_path` loops only over `.aghanim/factory.yml` (or inline it back into `aghanim_snapshot`/`cmd_add`). Keep `.mylos/` in `BUILTIN_FORBIDDEN` and `factory-guard.yml`: forbidding it costs nothing and blocks an agent from planting a decoy config.
- [ ] **Step 4:** Suite green; `git grep -n 'legacy mylos'` lists only forbidden-path, `migrate-home`, doctor and installer lines.
- [ ] **Step 5:** Commit: `refactor(config): drop the legacy .mylos/factory.yml fallback`
