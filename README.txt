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
/ledger (or /al, /fl)  open the window
/ledger help      full command list
/ledger debug     check hooks and the world map overlay
/ledger mapoverlay  turn the world map overlay on/off

NOTES
- Loot gold is logged as it drops; drops within a few minutes are merged into one line (e.g. "looted gold (40 drops)"). Quest gold is logged per turn-in.
- Auction sales are logged when you collect the mail.
- Zone tints on continent maps are rectangles; the game provides no outlines.

CHANGES IN 1.0.1
- Forever first + last names: characters are tracked by full name, so two characters sharing a
  first name on one account no longer clash. Existing data moves to the full-name key when you
  log in on each character. Link other-account characters by full name: /ledger link First Last
- /ledger whisperstyle dash|space (default: space, "First Last", as Forever whispers use)

CHANGES IN 1.1.0
- Ledger now records loot gold and quest reward gold (new Loot and Quest filters).
