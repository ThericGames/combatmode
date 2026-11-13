---
name: changelog
description: Add or edit a CombatMode/CHANGELOG.md entry in house style and sync it to the in-game viewer. Use when the user asks for a changelog entry or after they approve one.
---

# Changelog entry

1. Read only the top of `CombatMode/CHANGELOG.md` (`head -60`) to find the current version section (it must match `## Version` in `CombatMode/CombatMode.toc`) and copy its tone.
2. Add the entry under the right Keep a Changelog heading (`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`) in that section. Player-facing wording: say what the player sees, use "Action Combat Mode", bold the option or feature name, no internal function or file names.
3. **Write it like a person, for a player.** The reader wants to know what changed in their game, not how or why we built it.
   - One short sentence per change, two at most. Lead with what the player now gets or no longer suffers; skip the implementation story and the history of the old behavior.
   - Leave out what nobody asked about: how popups or panels are laid out (bullets, wording, ordering), internal mechanics (secure frames, CVar plumbing, load order, caching, event names), restyles too small to notice, and anything the new text already makes obvious.
   - Don't list every option a change touches or enumerate every translated or reworded string. Name the one or two things a player would look for, then stop.
   - Group related tweaks into a single entry instead of one bullet each, and put sub-bullets only where a feature genuinely has separate options to explain (a new headline feature, not a polish pass).
   - Plain words over jargon: "your cursor", "the crosshair", "the ally under your crosshair", not "reticle soft-target resolution". Option names stay bold and exactly as shown in the options window.
   - A fix says what was wrong from the player's seat ("Target Lock no longer locks a friendly NPC"), not what the code did.
   - Before saving, reread each line and cut anything a player would skim past. A polish release can be three short lines.
4. The PostToolUse hook regenerates `UI/Changelog/ChangelogData.lua` after every Edit/Write of `CHANGELOG.md`. If you changed it another way (script, shell), run `pwsh ./scripts/sync-changelog-to-lua.ps1`. Never edit `ChangelogData.lua` by hand; `check-repo` fails CI when it's out of sync.
5. Don't bump the version, create a new section or commit unless the user asked. A new version section also needs its compare link at the bottom (`[x.y.z]: https://github.com/ThericGames/combatmode/compare/<previous>...x.y.z`) and the `[Unreleased]` link moved to compare from it.
