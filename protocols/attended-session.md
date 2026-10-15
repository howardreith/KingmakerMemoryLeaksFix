# Protocol — owner-attended screening session (W02, W03, W05, W06) — NOT RUN

Status: **specification only**. It needs (1) the owner at the controls, (2) an owner decision on save containment, and (3) for H01 a
configuration without KingmakerBugfixes. KMLD itself never sends input to the desktop and never declares an existing save disposable.

## Save containment the owner must choose first

The save folder is shared with the owner's campaigns and the Buff Planner / Gunslinger fixtures, and the game autosaves on area
transitions. Acceptable options, in order of preference:

1. A **dedicated fixture campaign**: copy an existing baseline save to `Manual_NNN_KMLD_AUTOMATION_BASELINE_<fixture>.zks`
   (hash recorded, never overwritten), and accept that `Auto_*` rotation during the session may replace older autosaves of *any*
   campaign — the owner must first confirm which autosaves (if any) matter and back them up outside the game folder.
2. A separate Windows user profile or machine with its own `LocalLow` (not available on this host today).

Mod-dependent fixtures must only be loaded with their defining mods present (the KBP/KMG fixtures require their mods).

## Running it

```powershell
pwsh -File scripts/Invoke-KmldRun.ps1 -Workload Attended -RunId kmld-att-<scenario>-<n> -MaxRunSeconds 5400 `
     -AllowActiveConsole -AuthorizationNote "owner attended: <scenario>"
# in a second terminal, at each boundary:
pwsh -File scripts/Set-KmldMarker.ps1 -Cycle 1 -Phase action  -Note "load fixture"
pwsh -File scripts/Set-KmldMarker.ps1 -Cycle 1 -Phase settle  -Note "loaded, camera still, paused"
```

The controller samples until the game exits; protected-save hashing still runs — **any** save change will be recorded as a blocking
violation, so for W03/W07 the owner must review and acknowledge the expected autosave/save changes afterwards.

## Scenario steps (each cycle ends in the same observation state, game paused, camera untouched)

* **W02 reload ×20:** main menu → Load → fixture → wait for area → pause → marker `settle` 30 s → Esc → Load the same fixture again.
  Two warm-up cycles, then 20 measured. Never save.
* **W03 A→B→A ×10:** from the loaded fixture, travel to a safe adjacent area B and back to A via the same exits; `settle` 30 s in A.
  Record every autosave created.
* **W05 turn-based tracker (H01/H01b):** start a reproducible turn-based fight; `hold` 5 min without input; then a buff-change series
  (cast/dispel the same buff N times) with `settle` markers; separately toggle **Settings → reset to defaults** once while the
  tracker is shown (the only static path that may re-show the tracker without hiding it — H01b). Compare M0 with a configuration
  without KingmakerBugfixes only when a compatible fixture exists.
* **W06 UI open/close ×50:** inventory, character sheet, spellbook in turn; marker per 10 pairs.

Analyse with `kmld_analyze.py --settle-phase settle --warmup-cycles 2`.
