# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

A Python 3.11+ package (stdlib + PyYAML), `scripts/shipfloor_core`, behind thin Bash wrappers that keep the script names callers know; all installed in `~/.shipfloor/factory`. The local dashboard is one self-contained HTML file served by `scripts/dashboard.py`: no framework, no CDN, no build.

## Users

The factory's owner, a developer who runs Shipfloor on their own machine, and other developers who install the plugin. The dashboard is used in quick checks: open it, approve what is waiting, glance at cost and runs, close it.

## Product Purpose

Shipfloor is a software factory: GitHub issues become shipped PRs through agents (refine, develop, validate, deploy) held by deterministic gates. The dashboard is its local control room: pool and slots, live runs, each run's log, the estimated cost of each card from Inbox to Done, and the review pages where the owner approves or sends back Spec Review and Staged cards.

## Positioning

The gates are scripts, not the agents' word; the agents build and the gates hold. Cost is measured from the Claude Code transcripts of every run, not from what an agent reports.

## Operating Context

The GitHub Project board is the source of truth for card columns; the dashboard reads the dispatcher's snapshot and moves only the owner's cards. Runs, logs, locks and reports live under `~/.shipfloor`. The owner works in a terminal and a browser on Windows, macOS or Linux.

## Capabilities and Constraints

- Columns, in order: Inbox, Ready for Refinement, Technical Refinement, Spec Review, Ready for Dev, Coding, Validation, Staged, Ready for Prod, Done. Stages: refine, develop, validate, deploy.
- Owner-only actions: approve and request changes on Spec Review and Staged cards; from the maximized Lifecycle, send an Inbox card to refinement, take a card out of Ready for Refinement, send a Ready for Dev card back to refinement with a note, take a card blocked for them back to Ready for Dev, Ready for Refinement or the Inbox, and set the order of Inbox, Ready for Refinement and Ready for Dev (the item's position in the GitHub Project, which the dispatcher follows).
- Cost is an estimate from a price table (`~/.shipfloor/prices.yml`), always labeled as such.
- The owner can set an optional CPU and memory ceiling for the factory in the dashboard's Settings; it is saved in `~/.shipfloor/config.yml` and applied by reinstalling the scheduler (Linux with systemd only).
- The dashboard stays local (127.0.0.1, no remote access); the one thing that leaves the machine is the optional one-way phone push through ntfy, off until the owner sets a topic and carrying only the project and a card's number, title and state.

## Brand Commitments

Name: Shipfloor (CLI: `shipfloor`; plugin and slash commands: `sf`). Brand line: "Shipfloor — a software factory". The name is "shop floor" with ship: the floor of the factory that software ships from.

## Evidence on Hand

Real data from the owner's factory under `~/.shipfloor` (registry, board snapshot, logs, reports) and the run transcripts. No testimonials, customers or benchmarks exist; none may be invented.

## Product Principles

1. The board is the source of truth; the dashboard never keeps card state of its own.
2. Deterministic gates outrank any agent's claim.
3. Numbers are exact and sourced; estimates say so.
4. The owner acts only where the factory waits for the owner.
