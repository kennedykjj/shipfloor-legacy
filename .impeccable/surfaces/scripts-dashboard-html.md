---
version: 1
slug: "scripts-dashboard-html"
primary_target: "scripts/dashboard.html"
related_targets: []
---

Scope: scripts/dashboard.html, the local dashboard served by `aghanim dashboard`. Mode: Operate.
Audience: the factory's owner, a developer, in quick checks: open, approve what waits, glance at cost and runs, close.
Task: see pool, slots, live runs, logs, gates and the estimated cost of each card; approve or send back Spec Review and Staged cards.
Constraints: one self-contained HTML file, no CDN, no build; dark and light from prefers-color-scheme; factory names verbatim; no emoji; costs labeled est.
Chosen direction: E, Aghanim's Tooltip, picked by the owner on 2026-10-09 after asking for worlds that speak to the product's name; owner asked for a more polished and elegant layout than the sample.

## Direction contract

THESIS: every card is an item and its drawer is the item tooltip: name, gold cost, sections for sessions and gates, one action. Refuses the generic grey kanban with colored tags.
OWN-WORLD: deep slate panels with a top-lit edge, parchment text, gold for cost numerals only (with a small coin mark), Aghanim azure reserved for what waits for the owner and the owner's actions; hairline gold rule under tooltip headers; light theme as pale stone with the same gold and azure roles.
STORY: the owner sees in one glance how full the pool is, what is running and what waits for them, opens a card, reads its tooltip (cost by session, gates), and approves or sends it back.
FIRST VIEWPORT: a slim top strip (pool and per-stage slots as fractions, today's runs and est. cost in gold, an azure "awaiting you" count that lists those cards, factory state, board age); below, ten board columns in factory order with item cards; the tooltip drawer on the right when a card is open.
FORM: candidate E of the name-derived hand (Aghanim's Tooltip), chosen over the roll's Shop Traveler at the owner's steer; seed 0fecf902. Signature interaction: a running card wears a slow cooldown sweep; reduced motion shows a static quarter.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
