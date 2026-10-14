#!/usr/bin/env bash
# A card that reaches costs.card_block is commented on through gh with the project's owner/repo (project.repo),
# never with FACTORY_REPO, which is the path of the local clone.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
[ "$(date +%H%M)" -ge 2358 ] && sleep 150  # "today" is the local date: do not straddle midnight

export SHIPFLOOR_HOME="$(mktemp -d)"
export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" CLAUDE_CONFIG_DIR="$(nat "$(mktemp -d)")"
CLONE="$(mktemp -d)/clones/shop"; mkdir -p "$CLONE"; export FACTORY_REPO="$CLONE"  # what shipfloor_use sets: the clone's path
tmp="$(mktemp -d)"; export COST_TMP="$tmp"
mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
printf 'shop\t%s\t/x/wt\tmain\n' "$CLONE" > "$SHIPFLOOR_HOME/registry.tsv"
printf 'claude-opus-5-5: {input: 4.00, output: 20.00, cache_write_5m: 5.00, cache_write_1h: 8.00, cache_read: 0.20}\n' > "$SHIPFLOOR_HOME/prices.yml"
printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\ncosts:\n  card_block: 40\n' > "$SHIPFLOOR_HOME/config.yml"
cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Dev") echo 77 ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
cat > "$tmp/gh" <<'EOG'
#!/usr/bin/env bash
case "$*" in *dependencies/blocked_by*) echo '[]'; exit 0 ;; esac  # the dispatcher's dependency read (#202): none
echo "gh $*" >> "$COST_TMP/gh-calls"
exit 0
EOG
printf '#!/usr/bin/env bash\necho "$(cat)" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/gh" "$tmp/claude"; : > "$tmp/launched"; : > "$tmp/gh-calls"
export FACTORY_BOARD="$tmp/board" FACTORY_GH="$tmp/gh" FACTORY_CLAUDE="$tmp/claude"
export Q_DEV=77
# card 77 spent 41 (US$ at 4 per million input tokens) against a card_block of 40
d="$CLAUDE_CONFIG_DIR/projects/C--x--shipfloor-projects-shop-control"; mkdir -p "$d"; day="$(date +%F)"
{ printf '{"type":"user","timestamp":"%sT12:00:00%s","message":{"role":"user","content":"<command-name>/sf:develop</command-name>\\n<command-args>77</command-args>"}}\n' "$day" "$(date +%:z)"
  printf '{"type":"assistant","timestamp":"%sT12:05:00%s","message":{"id":"m-1","model":"claude-opus-5-5","usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$day" "$(date +%:z)" $(( 41 * 250000 ))
} > "$d/s1.jsonl"

run_dispatch >/dev/null 2>&1
calls="$(cat "$tmp/gh-calls")"
case "$calls" in *"issue comment 77"*) pass "AC-2 the blocked card is commented on" ;; *) fail "AC-2 no comment on #77: $calls" ;; esac
case "$calls" in *"-R acme/shop"*) pass "AC-2 gh is called with -R owner/repo from project.repo" ;; *) fail "AC-2 gh without -R acme/shop: $calls" ;; esac
case "$calls" in *"$CLONE"*) fail "AC-2 gh was given the clone's local path: $calls" ;; *) pass "AC-2 the clone's local path never reaches gh" ;; esac
[ -z "$(cat "$tmp/launched")" ] && pass "AC-2 the blocked card is not launched" || fail "AC-2 the blocked card was launched"
finish
