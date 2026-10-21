FOREVER LEDGER 1.1.0
Track every character across multiple WoW accounts. For WoW Forever (interface 16001).

INSTALL
Copy the ForeverLedger folder into Interface/AddOns, then /reload or restart.
Do this on every account you play. First login opens a setup wizard.

WHAT IT DOES
- Gold, bags, bank, professions and auctions for every character
- Warehouse and AH-seller roles, plus assigned professions
- Cross-account sync between linked characters (or Export/Import text)
- Wealth history, growth chart and stats
- Transaction ledger: vendors, mail, trades, auction house, loot and quest gold
- Time played across all synced characters
- Zone notes and ratings, shown on the in-game world map
  (Ctrl+click a zone map to add a note, Shift+right-click a pin to delete)
- Shared to-do list

COMMANDS
/ledger (/fl)  open the window
/ledger help      full command list
/ledger debug     check hooks and the world map overlay
/ledger mapoverlay  turn the world map overlay on/off

NOTES
- Loot gold is logged as it drops; drops within a few minutes are merged into one line (e.g. "looted gold (40 drops)"). Quest gold is logged per turn-in.
- Auction sales are logged when you collect the mail.
- Zone tints on continent maps are rectangles; the game provides no outlines.


CHANGES IN 1.0.0

- Forever first + last names: characters are tracked by full name, so two characters sharing a
  first name on one account no longer clash. Existing data moves to the full-name key when you
  log in on each character. Link other-account characters by full name: /ledger link First Last

- /ledger whisperstyle dash|space (default: space, "First Last", as Forever whispers use)

- Ledger now records loot gold and quest reward gold (new Loot and Quest filters).

- Faction awareness: every character shows an [A] or [H] tag. Lists (overview, materials, auctions,
  move list, ledger, wealth, playtime) show your logged-in character's faction by default. The faction
  button at the top of the window cycles: your faction / the other faction / both. /ledger faction mine|other|all
- The move list only suggests moves between same-faction characters (no cross-faction mail or trade).

- Ruleset filter: lists only show characters on your current ruleset (Normal, PvP, RP, Hardcore each
  separate). The ruleset button beside the faction button switches to all rulesets. /ledger ruleset this|all
  The ruleset is taken from the realm name the game reports for each character: run /ledger debug and
  check the "ruleset/realm" line shows a different value per ruleset.


- Logout safety: from the moment the game starts logging out/quitting (PLAYER_LOGOUT) the add-on stops
  touching game data, sending sync messages or redrawing, in case that contributed to logout crashes.
- /ledger debug shows how much data is saved and the add-on's memory use.

- Real-time sync. While a linked character is online, changes (gold, bags, professions, auctions,
  ledger lines, notes, to-dos) are pushed to it automatically, at most every 45 seconds. With nobody
  online, a one-line hello goes out every 3 minutes so a character that logs in later is found fast.
  /ledger live on|off, /ledger links shows who is online, /ledger debug shows the live status.
- Linking one character of the other account now covers every character of that account that has
  synced to you once (only one can be online at a time). Give each account its own label in setup
  (they must differ) for this to work.


- Ruleset filter now compares the ruleset word in the realm name (Normal/PvE, PvP, RP, Hardcore) instead of
  the exact string, so characters on the same ruleset but with differently named realms (e.g. "PvE 1"
  and "PvE 2") are no longer hidden. /ledger debug lists the realm names it has seen.


- Timed full sync: every X minutes (default 5) everything is sent to online linked characters -- every
  character on this account plus notes and to-dos -- on top of the instant change pushes.
  Change X with the Auto-sync button at the bottom of the window, or /ledger syncevery <minutes>|off.


- Sync log: every sync message sent or received this session is recorded. "Sync log" button at the bottom
  of the window (or /ledger synclog) shows it in a copyable box; /ledger synclog chat N prints the last N lines
  in chat; /ledger synclog clear empties it. Messages from characters that are not linked are shown as REJECTED.
