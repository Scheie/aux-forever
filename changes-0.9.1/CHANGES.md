# auxForever 0.9.1 changes: realm keys, subrealm grouping, Sniper diagnostics

Written 2026-11-23, against auxForever `forever-0.9`.

Files in this folder:

| File | What it is |
|---|---|
| `auxforever-0.9.1.patch` | Unified diff of all code changes (4 files, +365 / -8). |
| `CHANGES.md` | This document. |
| `merge_accounts.lua` | One-off offline script that merges one WoW account's price history into another's (not part of the addon). |
| `sync/` | Automatic price history sync between WoW accounts: `sync.lua` and its macOS launchd job (not part of the addon; see "Sync between WoW accounts"). |

## Applying

From the root of the other repo (the folder that holds `aux-addon.lua`):

```sh
git apply --check path/to/auxforever-0.9.1.patch   # dry run
git apply path/to/auxforever-0.9.1.patch
# or: patch -p1 < path/to/auxforever-0.9.1.patch
```

If the addon sits in a subfolder of the repo, add `--directory=<subfolder>` to `git apply`.
The patch was made against the `forever-0.9` files and verified to apply cleanly and reproduce
the edited files byte for byte. If the other repo has diverged, apply the sections below by hand.

## Background: the bug

The Sniper found no deals, whatever the threshold.

1. aux keys its saved data by realm: `aux.realm[<realm>]`, `aux.faction[<realm>|<faction>]`,
   `aux.character[<realm>|<name>]`, using `GetRealmName()` (`aux-addon.lua`, `AUX_LOADED`).
2. On the Forever client `GetRealmName()` started returning `""` (first seen 2026-11-22), at load
   and, later, even after login.
3. aux then built keys like `"|Alliance"` and started a new, empty price history, while the real
   one stayed under `"CAMWOW EU4 Realm 7 PvE|Alliance"`.
4. The Sniper only judges an item against its usual price once it has `MIN_DAYS` (3) days of
   complete looks (Full scans). In the empty history every item had 0 days, so the only deals
   possible were items listed below vendor price. Tooltip prices and favorite searches were
   affected the same way.

There is a second, related requirement. On Forever all of a region's realms of one kind (for
example EU PvE) are one realm with subrealms (`CAMWOW EU4 Realm 7 PvE`, `CAMWOW EU5 Realm 7 PvE`).
They share an auction house per faction, so aux should keep one set of data per region and play
type. Horde and Alliance auction houses are separate, so the faction stays part of the key.

## Changes by file

### 1. `aux-addon.lua`: realm key, subrealm grouping, joining old data

**New requires:** `local history = require 'aux.core.history'` (for `history.merge_lines`).

**`M.realm_group(name)`** turns a realm name into region plus play type:

- `CAMWOW EU4 Realm 7 PvE` and `CAMWOW EU5 Realm 7 PvE` both give `EU PvE`.
- The region is the first word whose letters (digits after them allowed) are in `REGIONS`
  (`EU US NA OCE KR TW CN`). The play type is the last word, if it is in `REALM_KINDS`
  (`PvE PvP RP RPPvP`, any letter case).
- A name without both (e.g. `Firemaw`) is returned unchanged, so non-Forever realms behave as
  before. `""` stays `""`.

**`M.realm_name()`** is the key aux uses for saved data; it replaces every `GetRealmName()` in
the file (realm, faction and character keys). It returns a realm group, trying in order:

1. `GetRealmName()` when it is not empty. The raw name is also remembered in
   `aux.account.realm_names[GetRealmID()]` and `aux.account.last_realm`.
2. The name remembered for the current `GetRealmID()`.
3. The single realm group this account already has data for (any key of `aux.realm`).
4. `aux.account.last_realm`.
5. `""` when nothing is known.

`GetNormalizedRealmName()` is deliberately not used: it drops the spaces, which would be yet
another key.

**`M.join_realms(in_use)`** moves every saved key that is a subrealm's full name, or the blank
realm `""`, to its realm group, merging with what is already there:

- `aux.realm`: the keys are realm names. `aux.faction` and `aux.character`: the keys are
  `realm|rest`, and only the realm part is regrouped. So `X|Alliance` only ever joins
  `<group>|Alliance` and Horde stays apart.
- Blank keys are only moved once the current group is known (otherwise they wait).
- `in_use` (a set of tables) protects the tables the session already handed out: the Search tab
  (`recent_searches`, `favorite_searches`), `core/cache.lua` (`characters`) and the tooltip
  settings hold references taken at load. When such a table takes part in a join, it is kept and
  the other one is merged into it. Otherwise the table already at the group key is kept.
- Returns true when anything was joined.

**Merge rules** (local functions `fill`, `merge_searches`, `merge_realm`, `merge_faction`,
`merge_character`, `rekey`):

| Data | Rule |
|---|---|
| `characters` | union, latest timestamp per name |
| `favorite_searches`, `recent_searches` | the kept list first, then the other's, each `filter_string` once |
| faction `history` | per item `history.merge_lines` (only from `history_version` 2 or 3) |
| `price_keys_since` | the earlier of the two |
| `history_trimmed` | cleared, so `forget_old_prices` runs again at login |
| `bid_auction_ids` | union |
| anything else | `fill`: keys missing from the kept table are copied, tables recursively |

**Calls:**

- `AUX_LOADED`: `realm_rejoined = join_realms()`, right after the `assign(aux, {...})` of the
  stores and before the realm, faction and character tables are picked.
- `PLAYER_LOGIN`: `join_realms({[realm_data] = true, [faction_data] = true, [character_data] = true})`
  before the login handlers run (`core/history.lua` takes the price history at login). Afterwards
  it prints *"Your saved data is now one set for all EU PvE subrealms…"* when something was
  joined, or *"The game has not said which realm this is…"* when `realm_name()` is still `""`.

### 2. `core/history.lua`: `M.merge_lines(a, b)`

Added after `write_record`. It merges two saved history lines of one item into one line:

- If one of the two is nil, the other is returned unchanged (no unpacking).
- Every day that either line knows is kept: the "today" fields and the past `points`.
- On a day both know, a market (a complete look, with units) beats a lowest price only, and the
  lower lowest price is kept. If both have a market, the one from the look that saw more units is
  kept; on a tie, the lower price. The result does not depend on the order of the two lines.
- The newest day becomes the `day/low/market/units` fields (`read_record` moves it into the past
  days once that day is over). At most `MAX_POINTS` past days are kept.
- Old 0.4 lines are handled through `unpack_record` (`convert_old`).

Example: `"20777#22499#125000#31#20775@19900@15;20773@144900@57"` merged with `"20779#35000###"`
gives `"20779#35000###20777@125000@31;20775@19900@15;20773@144900@57"`, which is 3 complete past
days. The result does not depend on the order of the two lines.

### 3. `tabs/sniper/core.lua`: `/aux debug sniper` diagnostics

This adds no behaviour change to the Sniper's deal finding; it only counts.

- **`M.why_not(...)`** takes the same arguments as `judge` and returns why `judge` said no (in
  `judge`'s own order), plus the percent of the reference price. The reasons are: no price; below
  vendor, profit too small; no usual price; fewer than 3 days of history; today's market is
  lower; price above your percent; profit too small.
- **`stats`**, reset by `start()` and `settings_changed()`, records rounds, items judged, reasons
  on the item list, the outcomes of opened candidates, and the 8 closest misses (`note_miss`).
- **Counting points:**
  - `check_list` counts every judged item: ignored; gear name not loaded yet; item not loaded
    yet; a candidate; or turned down for the `why_not` reason.
  - `check_item` counts: no answer from the auction house; no buyout from another player; a
    deal; or turned down after opening for the `why_not` reason, with the facts read again.
  - `start_round`'s `on_complete` counts finished rounds.
- **`M.debug_report()`** gives the chat lines. They include:
  - the realm group in use, and whether `aux.faction[...]` for it is the table in use (this
    catches a split like the one above);
  - how many history items there are, and how many have 3 or more days;
  - the settings, then the counts and the closest misses.

  It reads the faction store as `_G.aux.faction`: in this file `aux` is the module, not the
  saved variables.

### 4. `core/slash.lua`

- New command `/aux debug sniper`, which prints `debug_report()`. It sits before the plain
  `/aux debug` branch, which toggles the timing log.
- New help line: `- debug sniper (why the Sniper turned items down)`.

## Effect on existing saved data

- At the first login after the change, all subrealm and blank keys are joined into their groups,
  for example `CAMWOW EU4 Realm 7 PvE|Alliance` and `|Alliance` into `EU PvE|Alliance`. This
  happens once; later logins find nothing to join.
- Each WoW account folder (`WTF/Account/<account>/`) has its own saved file, so accounts cannot
  share data at run time. `merge_accounts.lua` does a one-off offline merge, run with the game
  closed:

  ```sh
  lua merge_accounts.lua <addon dir> <source account file> <target account file> <output file>
  ```

  It loads the addon's own `util.lua`, `util/persistence.lua`, `core/history.lua` and
  `aux-addon.lua`, so the patch must be applied to `<addon dir>` first. It then:
  1. runs `join_realms` on the target;
  2. merges each source `realm|faction` price history into `<group>|faction` of the same faction;
  3. writes `aux = {...}` to the output file and checks that it reads back identical.

  Back up both files, then copy the output over the target file.

## Sync between WoW accounts (`sync/`)

WoW gives each WoW account in a Battle.net login its own saved file, and an addon cannot read
another account's file. `sync/sync.lua` keeps the price history the same across all of them. It
works with both games running at once.

**How it works.** launchd runs the script whenever a `SavedVariables` folder changes, that is,
whenever a game saves (logout, exit, `/reload`). The script:

1. finds every `WTF/Account/*/SavedVariables/auxForever.lua`;
2. waits until none has been written for 3 seconds;
3. merges the price history of all of them, per realm group and faction (Alliance only with
   Alliance, Horde only with Horde), using the same rules as `history.merge_lines`;
4. writes the merged history into every file that lacks some of it.

Only `aux.faction[...].history` is synced. Settings, favorites, Post data and character data stay
per account.

- **Union:** a running game overwrites its own file at its next save, but the other files keep
  everything, and the run after that save restores the full set. Nothing is lost.
- **When a running game sees the merged prices:** only when it enters the world again. Log out to
  character select, wait a few seconds, then log in. `/reload` is not enough, because WoW saves
  first and then reads back what it just wrote.
- **Safety:**
  - A file is only written when it gains something. A `state` file of mtimes and sizes ends runs
    caused by the script's own writes, so it does not loop.
  - Writes go through a temporary file that must read back identical before it replaces the
    original.
  - The last 5 versions of each account's file are kept in `backups/`.
  - A half-written or unreadable file is skipped untouched.
  - A file that changes during the merge is left for the next run.
- **Logs:** `sync.log` (one line per write, plus skips and errors) and `launchd.log`, both in the
  state folder.
- **Checked:** the script's `merge_lines` gives the same result as the addon's on all 17,577
  items both accounts shared, merging twice changes nothing, and the result does not depend on
  the order of the files.

**Install (macOS):**

```sh
mkdir -p ~/Library/Application\ Support/auxForever-sync/backups
cp sync/sync.lua ~/Library/Application\ Support/auxForever-sync/
cp sync/no.auxforever.sync.plist ~/Library/LaunchAgents/
# edit the plist first: the lua path (`which lua`), the home folder in the paths, and one
# WatchPaths entry per WTF/Account/<account>/SavedVariables folder
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/no.auxforever.sync.plist
```

**Turn off:** `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/no.auxforever.sync.plist`
(delete the plist so it does not come back at the next Mac login).

**Run by hand:** `lua sync.lua "<WoW>/_forever_/WTF/Account" [<state folder>]`

When a new WoW account is added, add its `SavedVariables` folder to `WatchPaths` and load the job
again. The script itself finds all accounts on its own.

## Testing done

- `luac -p` on all changed files.
- The patch applied to the original `forever-0.9` files gives the edited files byte for byte;
  `git apply --check` passes.
- `merge_lines`, `realm_group`, `realm_name` and `join_realms` were run outside the game
  (Lua 5.4, with the addon's own modules loaded) against copies of real saved variables:
  - with the realm name given, and with `GetRealmName()` returning `""`;
  - on both the load path and the login path;
  - with a second subrealm present.

  Result: one `EU PvE` key per store; 8,735 items with 3 or more days of history, up from 0;
  favorites, Post settings and bid IDs kept; a second run joins nothing.
- In game: after the change the Sniper finds deals again. `/aux debug sniper` and the subrealm
  join message have not yet been seen in game.

## Known limits

- Rule 3 of `realm_name()` (the single realm group with data) only helps while an account has
  data for one group. A second group played while `GetRealmName()` is empty falls back to the
  name remembered by realm ID; with none remembered, it falls back to the last name seen.
- `realm_group` takes the region and play type from the name's words. It assumes every
  `<region> <type>` subrealm shares one auction house per faction, whatever the `Realm <n>` part
  says.
- If two saved lines both have a market for the same item on the same day, the merge keeps the
  one that saw more units instead of combining them.
- The Nov 22 Full scan saved only lowest prices (169 of 23,061 items had a market), probably
  because it was stopped before its final step. This is unrelated to the patch: let a Full scan
  finish before closing the auction house.
