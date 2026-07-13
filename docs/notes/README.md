# Engineering notes

Historical design docs and incident write-ups, kept for the record. They describe
the repo as it was **at the time of writing** — file names, line numbers, and
"current state" claims in them may be stale. The authoritative docs are the
top-level [README](../../README.md) and the comments in the hooks themselves.

| Doc | What it is |
|---|---|
| [2026-06-spawn-storm-*](2026-06-spawn-storm-fix-plan.md) | Post-mortem + fix plan for a fork-storm incident: the uncached status bar + tmux-continuum's per-redraw save stacked processes under load. Led to the current stale-while-revalidate bar cache and throttled heartbeat. |
| [2026-06-upstream-tty-clamp-crash.md](2026-06-upstream-tty-clamp-crash.md) | Draft upstream bug report: tmux 3.6b server crash (`fatal: tty_clamp_area`) with multiple different-sized clients attached. |
| [2026-07-cockpit-v3.1-plan.md](2026-07-cockpit-v3.1-plan.md) | Design/handoff plan for the `prefix+o` cockpit popup, v3.1. |
