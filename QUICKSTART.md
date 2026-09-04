# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not an HOA management system" section of `README.md`. Short version: this kit puts each lot on your phone, GPS-stamps arrival at the curb, and collects a photo Violation Report; it does not mail courtesy letters, open hearings, collect fines, or generate a branded PDF. Homeowner names and gate codes stay on your computer; ZenSched only ever sees a lot label (`Lot 14 - Oak Lane`), an address, and the Violation Report.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\hoa-ops` (Windows) or `/Users/yourname/hoa-ops` (Mac). Note the full path. It will hold homeowner names and gate codes, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "hoa-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/hoa-ops/hoa-ops.db" }
    }
  }
}
```

- On Windows, double every backslash: `"C:\\Users\\YourName\\hoa-ops\\hoa-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My HOA Inspector". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my hoa-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

The AI will run 52 statements and confirm the tables exist.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Ridgeway Inspections in Austin, Central time. It's just me, Jordan Hale, jordan@ridgeway.example. Set me up. Check-in radius 150 m, allow 15 minutes early.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the inspector on the phone), and calls `form_create` once (free) to build the Violation Report you fill in at each lot: Trash / Parking / Paint / Lawn / Boat / Other / None, photo evidence (max 4), and notes. No signature pad. It stores the form id so every wave gets it. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

Agency: "Add my sub Maya Ortiz, maya@example.com, Austin, I pay her $2 a lot."

## 6. Set up your first monthly wave

Paste the association's lot roster. For example:

> New wave. Association is Oakridge HOA, CAM Priya Chen, priya@oakridge.example, billing ap@oakridge.example, net 30. Monthly drive-through, weekdays 8 to noon, Sep 1 through Sep 30. $4 a lot to them, $2 to a sub. Lots: 12, 410 Oak Lane, Austin TX 78735, Hale / 18, 418 Oak Lane, Austin TX 78735, Ruiz / 22, 422 Oak Lane, Austin TX 78735, Patel / 7, 407 Maple Court, Austin TX 78735, Nguyen. Gate 4411.

Behind the scenes the AI saves the association and wave locally, adds the four lots to its lot cache (homeowner names and the gate code stay local), attaches the Violation Report (free), asks you before geocoding the four lots ($0.12, may trigger the $5 activation deposit the first time), creates one event per lot for the wave with the form attached, and creates four open visits. You just see a confirmation. Each completed visit will cost about $0.25 (clean) or $0.35 (photos) on ZenSched.

A 200-lot community is the same motion: paste the roster, confirm the geocode cost (~$6 the first month), and assign a morning (or two) of sequenced curb stops.

## 7. Assign the drive-through

> I'll take the four Oakridge lots Tuesday morning.

The AI sequences 8-minute slots inside the 8–noon window, creates one shift per lot on ZenSched in the lot's own time zone, and confirms by street. You get a push notification per lot with the form attached. At the curb, **Check in** (GPS-verified), open the **Violation Report**, mark None or the violation(s), photograph evidence if any (up to 4), submit, **Check out**, roll to the next lot.

Or say "fill the open visits" and the AI proposes who should take what.

## 8. Close out and export the board pack

> Close out Oakridge.

The AI pulls your GPS-verified arrival and departure (free), reads the Violation Reports (metered, so it tells you the cost first), updates each lot, and leads with flags: a check-in after the slot, a violation with no photo, a 30-second "visit".

> Export the Oakridge board pack.

A plain-text pack: lots inspected, lots clean, then one block per violation (lot code, street, GPS in/out, categories, notes, photo links). You paste it into email or the CAM's portal. This is not a courtesy letter and not a branded PDF.

## 9. Money

> Invoice Oakridge HOA.

A plain-text invoice under their terms with one line per lot (your wave, lot code, fee, clean or the violation keys). Nothing about homeowners on it.

> Who owes me money?

Open invoices aged current / 1–30 / 31–60 / 61–90 / 90+ days past due.

> Oakridge paid INV-2026-0001.

Marks it paid.

Agency: "What do I owe Maya?" lists her unpaid lots and total; "paid Maya" marks them.

## 10. Next month

> Roll October for Oakridge.

New wave row (Oct 1–31, still under the 59-day cap), same lots, same form, new events. No geocode. Then assign the drive-through again.

## What next

- `README.md` for the full explanation, the management-software / letter / photo-stamp / privacy boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
