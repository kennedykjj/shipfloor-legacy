#!/usr/bin/env bash
# shipfloor install refuses a clone that is not a clean, up-to-date main (--force overrides), records the commit it
# came from in factory/.origin, and doctor reports it. Each case builds its own source: a git clone holding a copy of
# scripts/ and templates/, pushed to a bare remote in a temp dir, and runs that copy's scripts/shipfloor against a
# temp SHIPFLOOR_HOME. No network: "cannot fetch" is a remote URL that points at a path that does not exist.
source "$(dirname "$0")/lib.sh"
export GIT_TERMINAL_PROMPT=0

put_plugin() {  # put_plugin <dir>: a plain copy of scripts/ (no tests) and templates/
  mkdir -p "$1/scripts"
  cp -r "$FACTORY_DIR/." "$1/scripts/"
  rm -rf "$1/scripts/test"
  find "$1/scripts" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  cp -r "$FACTORY_DIR/../templates" "$1/templates"
}

mk_src() {  # mk_src: a clean main, level with its bare remote, origin/HEAD set; prints the clone's path
  local r remote; r="$(new_repo)"; remote="$(mktemp -d)"; git init -q --bare "$remote"
  put_plugin "$r"
  git -C "$r" config core.autocrlf false
  git -C "$r" add -A; git -C "$r" commit -qm plugin
  git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  git -C "$r" remote set-head origin main >/dev/null
  echo "$r"
}

g() { local r="$1"; shift; git -C "$r" -c user.email=t@t -c user.name=t "$@"; }
break_branch()   { g "$1" checkout -q -b work; }
break_detached() { g "$1" checkout -q --detach; }
break_dirty()    { echo "# edited" >> "$1/scripts/gate.sh"; }
break_remote()   { g "$1" remote set-url origin "$(mktemp -d)/does-not-exist"; }
break_ahead() {  # break_ahead <src> [n]
  local i; for i in $(seq 1 "${2:-1}"); do g "$1" commit -q --allow-empty -m "local $i"; done
}
break_behind() {  # break_behind <src> [n]: n commits land on the remote from another clone
  local c i; c="$(mktemp -d)/c"; git clone -q "$(git -C "$1" remote get-url origin)" "$c"
  for i in $(seq 1 "${2:-1}"); do g "$c" commit -q --allow-empty -m "remote $i"; done
  g "$c" push -q origin main
}

run_sf() {  # run_sf <src> <home> <args...>: sets OUT (stdout and stderr) and RC
  local src="$1" home="$2"; shift 2
  OUT="$(SHIPFLOOR_HOME="$home" bash "$src/scripts/shipfloor" "$@" 2>&1)"; RC=$?
}
expect_rc()  { [ "$RC" -eq "$2" ] && pass "$1: exits $2" || fail "$1: exits $RC, want $2: $OUT"; }
expect_has() { case "$OUT" in *"$2"*) pass "$1: says '$2'" ;; *) fail "$1: output lacks '$2'; got: $OUT" ;; esac; }
expect_not() { case "$OUT" in *"$2"*) fail "$1: output has '$2'; got: $OUT" ;; *) pass "$1: no '$2'" ;; esac; }
expect_untouched() {  # nothing created or changed under the home
  if [ ! -e "$2/factory" ] && [ ! -e "$2/projects" ] && [ ! -e "$2/logs" ]; then pass "$1: nothing copied"
  else fail "$1: wrote under the home: $(find "$2" -mindepth 1 -maxdepth 2 | head -5 | tr '\n' ' ')"; fi
}
expect_installed() {  # the copy is there
  [ -f "$2/factory/gate.sh" ] && [ -f "$2/factory/templates/spec-template.md" ] && pass "$1: installed" || fail "$1: nothing was installed"
}
origin_of() { cat "$1/factory/.origin" 2>/dev/null; }
tab=$'\t'

# ---- AC-1: a branch other than main
t="AC-1 on a work branch"
src="$(mk_src)"; break_branch "$src"; home="$(mktemp -d)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "not installing from"; expect_has "$t" "on branch work, not main"
expect_has "$t" "checkout main"; expect_has "$t" "shipfloor install --force"

t="AC-1 on a detached HEAD"
src="$(mk_src)"; break_detached "$src"; home="$(mktemp -d)"; short="$(git -C "$src" rev-parse --short HEAD)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "on a detached HEAD at $short, not main"

t="AC-1 an installed copy is left as it was"
src="$(mk_src)"; home="$(mktemp -d)"; run_sf "$src" "$home" install
echo "old" > "$home/factory/gate.sh"; break_branch "$src"
run_sf "$src" "$home" install
expect_rc "$t" 1
[ "$(cat "$home/factory/gate.sh")" = old ] && pass "$t: installed file untouched" || fail "$t: the refused install overwrote factory/gate.sh"

# ---- AC-2: tracked changes block, untracked do not
t="AC-2 a tracked file with an uncommitted change"
src="$(mk_src)"; break_dirty "$src"; home="$(mktemp -d)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "1 tracked file(s) with uncommitted changes"; expect_has "$t" "scripts/gate.sh"
expect_has "$t" "shipfloor install --force"

t="AC-2 lists the first 10 changed files and counts the rest"
src="$(mk_src)"; home="$(mktemp -d)"
for f in $(git -C "$src" ls-files scripts | head -12); do echo "# edited" >> "$src/$f"; done
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "12 tracked file(s) with uncommitted changes"; expect_has "$t" "and 2 more"

t="AC-2 only untracked files do not block"
src="$(mk_src)"; home="$(mktemp -d)"
echo "echo new" > "$src/scripts/brand-new.sh"; echo "x" > "$src/notes.txt"
run_sf "$src" "$home" install
expect_rc "$t" 0; expect_installed "$t" "$home"
[ -f "$home/factory/brand-new.sh" ] && pass "$t: the untracked script is copied as today" || fail "$t: the untracked script was not copied"
expect_not "$t" "not installing"
[ "$(origin_of "$home" | cut -f3)" = verified ] && pass "$t: recorded as verified" || fail "$t: .origin does not say verified: '$(origin_of "$home")'"

# ---- AC-3: behind / ahead of the remote after a fetch
t="AC-3 behind the remote"
src="$(mk_src)"; break_behind "$src" 2; home="$(mktemp -d)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "2 commit(s) behind origin/main"; expect_has "$t" "git -C $src pull"
expect_not "$t" "ahead of"

t="AC-3 ahead of the remote"
src="$(mk_src)"; break_ahead "$src" 3; home="$(mktemp -d)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "3 commit(s) ahead of origin/main"; expect_has "$t" "push"
expect_not "$t" "behind origin"

t="AC-3 every reason that applies is listed"
src="$(mk_src)"; break_branch "$src"; break_dirty "$src"; break_ahead "$src" 1; home="$(mktemp -d)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "on branch work, not main"; expect_has "$t" "1 tracked file(s) with uncommitted changes"
expect_has "$t" "1 commit(s) ahead of origin/main"

# ---- AC-4: the remote cannot be fetched
t="AC-4 the remote cannot be fetched"
src="$(mk_src)"; break_remote "$src"; home="$(mktemp -d)"
run_sf "$src" "$home" install
expect_rc "$t" 1; expect_untouched "$t" "$home"
expect_has "$t" "could not check the remote (git fetch origin main failed)"
expect_has "$t" "shipfloor install --force"
expect_not "$t" "behind origin"; expect_not "$t" "ahead of origin"

# ---- AC-5: --force installs anyway and says so in one line
for kind in branch dirty behind ahead remote; do
  t="AC-5 --force over a source that is $kind"
  src="$(mk_src)"; "break_$kind" "$src"; home="$(mktemp -d)"
  br="$(git -C "$src" symbolic-ref -q --short HEAD)"; short="$(git -C "$src" rev-parse --short HEAD)"
  run_sf "$src" "$home" install --force
  expect_rc "$t" 0; expect_installed "$t" "$home"
  expect_has "$t" "WARN installed copy is not a verified main: branch $br, commit $short ("
  [ "$(printf '%s\n' "$OUT" | grep -c 'not a verified main')" = 1 ] && pass "$t: one warning line" || fail "$t: want one 'not a verified main' line in: $OUT"
  case "$(printf '%s\n' "$OUT" | tail -n 1)" in "WARN installed copy is not a verified main"*) pass "$t: the warning comes last" ;; *) fail "$t: the last line is not the warning: $OUT" ;; esac
  [ "$(origin_of "$home")" = "$(git -C "$src" rev-parse HEAD)${tab}${br}${tab}forced" ] && pass "$t: .origin says forced" || fail "$t: .origin is '$(origin_of "$home")', want <commit>${tab}$br${tab}forced"
done

t="AC-5 --force over a clean main is a plain install"
src="$(mk_src)"; home="$(mktemp -d)"
run_sf "$src" "$home" install --force
expect_rc "$t" 0; expect_installed "$t" "$home"; expect_not "$t" "not a verified"
[ "$(origin_of "$home" | cut -f3)" = verified ] && pass "$t: recorded as verified" || fail "$t: .origin does not say verified: '$(origin_of "$home")'"

t="AC-5 an unknown argument exits 2 with the usage and installs nothing"
src="$(mk_src)"; home="$(mktemp -d)"
run_sf "$src" "$home" install --bogus
expect_rc "$t" 2; expect_has "$t" "usage"; expect_untouched "$t" "$home"

# ---- AC-6: a clean main level with its remote installs as today, and records its commit
t="AC-6 a clean main level with its remote"
src="$(mk_src)"; home="$(mktemp -d)"; srcpath="$(cd "$src" && pwd)"
run_sf "$src" "$home" install
expect_rc "$t" 0; expect_installed "$t" "$home"
expect_has "$t" "installed $srcpath → $home/factory"; expect_has "$t" "next: shipfloor add"
expect_not "$t" "not installing"; expect_not "$t" "WARN"
[ "$(cat "$home/factory/.source")" = "$srcpath" ] && pass "$t: .source keeps the one-line path" || fail "$t: .source is '$(cat "$home/factory/.source")'"
want="$(git -C "$src" rev-parse HEAD)${tab}main${tab}verified"
[ "$(origin_of "$home")" = "$want" ] && pass "$t: .origin records commit, branch, verified" || fail "$t: .origin is '$(origin_of "$home")', want '<commit>${tab}main${tab}verified'"
[ "$(wc -l < "$home/factory/.origin" 2>/dev/null | tr -d ' ')" = 1 ] && pass "$t: .origin is one line" || fail "$t: .origin is not one line"
run_sf "$src" "$home" install
expect_rc "$t again" 0
[ "$(origin_of "$home")" = "$want" ] && pass "$t: a second install keeps .origin" || fail "$t: after a second install .origin is '$(origin_of "$home")'"

# ---- AC-7: a source that is not a git clone installs as today
t="AC-7 a source that is not a git clone"
plain="$(mktemp -d)"; put_plugin "$plain"; home="$(mktemp -d)"
mkdir -p "$home/factory"; printf 'oldcommit\tmain\tverified\n' > "$home/factory/.origin"
run_sf "$plain" "$home" install
expect_rc "$t" 0; expect_installed "$t" "$home"; expect_not "$t" "not installing"; expect_not "$t" "WARN"
[ ! -e "$home/factory/.origin" ] && pass "$t: no .origin (an older one is removed)" || fail "$t: .origin left: '$(origin_of "$home")'"
run_sf "$plain" "$home" install --force
expect_rc "$t with --force" 0; expect_not "$t with --force" "WARN"
run_sf "$plain" "$home" doctor
expect_has "$t, doctor" "WARN installed copy has no recorded commit"

t="AC-7 a plain copy inside a dirty clone on a work branch is not checked"
outer="$(mk_src)"; break_branch "$outer"; break_dirty "$outer"; home="$(mktemp -d)"
put_plugin "$outer/vendored"
run_sf "$outer/vendored" "$home" install
expect_rc "$t" 0; expect_installed "$t" "$home"; expect_not "$t" "not installing"
[ ! -e "$home/factory/.origin" ] && pass "$t: no .origin" || fail "$t: .origin written for a source that has no .git of its own"

# ---- AC-8: doctor names the commit
t="AC-8 doctor after a verified install"
src="$(mk_src)"; home="$(mktemp -d)"; short="$(git -C "$src" rev-parse --short HEAD)"
run_sf "$src" "$home" install
run_sf "$src" "$home" doctor
expect_has "$t" "ok   installed from main at $short"; expect_has "$t" "installed copy matches"
expect_not "$t" "WARN installed copy"

t="AC-8 doctor after a forced install"
src="$(mk_src)"; break_branch "$src"; home="$(mktemp -d)"; short="$(git -C "$src" rev-parse --short HEAD)"
run_sf "$src" "$home" install --force
run_sf "$src" "$home" doctor
expect_has "$t" "WARN installed copy was forced from branch work at $short, not a verified main (shipfloor install from a clean main)"
expect_has "$t" "installed copy matches"
expect_not "$t" "ok   installed from"
case "$OUT" in *"FAIL installed"*|*"FAIL not installed"*) fail "$t: doctor FAILs on the forced copy: $OUT" ;; *) pass "$t: no FAIL for the forced copy" ;; esac

t="AC-8 doctor on a copy with no recorded commit"
src="$(mk_src)"; home="$(mktemp -d)"
run_sf "$src" "$home" install; rm -f "$home/factory/.origin"
run_sf "$src" "$home" doctor
expect_has "$t" "WARN installed copy has no recorded commit (not a git clone, or installed before this check)"
case "$OUT" in *"FAIL installed"*|*"FAIL not installed"*) fail "$t: doctor FAILs on it: $OUT" ;; *) pass "$t: no FAIL" ;; esac

finish
