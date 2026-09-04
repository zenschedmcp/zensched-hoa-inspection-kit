# ZenSched HOA / Strata Inspection Reference Kit

A copy-pasteable setup for a solo US / AU / CA HOA, strata, or body-corporate inspector, or a 2–4 person shop that dispatches subcontracted inspectors, that wants an AI assistant to run monthly drive-throughs, GPS-verified arrival at each lot, a photo Violation Report (Trash / Parking / Paint / Lawn / Boat / Other / None), a board pack you can paste into email or the management company's portal, receivables from associations, and sub payouts. ZenSched handles the phone app, the GPS check-in at each lot, one event per lot per monthly wave, and the Violation Report. A small local database on your computer holds your associations, the lots you inspect (with the homeowners' names and the gate codes), each visit's status and result, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste a lot roster into your AI assistant ("Oakridge sent this, book September"), ask "what's today", "close out Oakridge", "export the Oakridge board pack", "invoice Oakridge", "roll October", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not an HOA management system — read this first

**What this kit is:** a way for an inspector to get every lot of a monthly drive-through onto their phone, prove GPS-verified arrival at the curb, record a photo Violation Report, and turn those records into a board pack, invoices, receivables follow-up, and sub payouts, with an AI assistant doing the clerical work.

**What it is not:**

- **It is not Smartwebs, TownSq, AppFolio, or any other HOA / strata management system.** It does not keep a homeowner ledger, does not mail a courtesy or hearing notice, does not schedule a board hearing, and does not collect a fine. `violations_to_export` plus a `form_export` give you the photos and the GPS-verified times; you (or the CAM) paste that into *their* system and process violations however you process them today.
- **It is not a branded PDF violation report generator.** The Violation Report on the phone is an operational photo form; the "export" is plain text plus photo links.
- **It does not watermark photos.** ZenSched records the GPS punch coordinates and the upload time server-side, and the Violation Report's evidence photos are stored with the submission, but the exported image is **not** stamped with the date, time, and coordinates. The punch record is your corroboration that the inspector was at the pin when the photos were taken. If a board or a lawyer later wants a *readable* stamp on the image itself, shoot with your phone camera's timestamp / GPS overlay turned on and upload *that* image.
- **It does not store CC&Rs, architectural applications, or hearing outcomes.** Those belong in the association's file. The local database stores the lot roster and the wave so invoices match the contract.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof of arrival at each lot, a photo report per visit, and receivables you can actually chase, read on.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per lot, cached locally so next month reuses the pin; the check-in radius is a policy setting)
- Workers (you, in solo mode; you plus your subs in agency mode, each with the mobile app)
- Events (one per lot per monthly wave, at most 59 days)
- Shifts (one per visit: the curb-stop window, 8 minutes by default, with a push notification)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Violation Report form (categories, photo evidence max 4, notes) and every submission with its photos

**Local SQLite database (`hoa-ops.db`, on your computer):**

- Associations: HOA / strata / condo boards or the management company that pays you, with payment terms
- Lots: every address on the roster, normalized, with its ZenSched location id, lot code, and access notes (gate, lockbox) — **homeowner names and access notes never leave your computer**
- Inspection waves: monthly (or shorter) drive-through dates, daily window, allowed weekdays, association fee, inspector fee, which ZenSched form
- Wave × lot rows with the ZenSched event for that month
- Inspectors: you (and your subs); pay handle per sub
- Visits: one row per lot visit, open → assigned → completed / no-show / rejected / cancelled, with the check-in and check-out stamps, violation keys, photo count, QA status, invoiced / paid / exported flags
- Association invoices with aging; payouts per sub per pay run
- Your settings (timezone, default inspector, default visit length, invoice terms and prefix, Violation Report form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on time", "export Oakridge", and "who owes me" without paying to re-read records.

### Privacy note

Everything that identifies a homeowner lives only in the local database: `lots.homeowner_name`, `homeowner_phone`, and `access_notes`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (subs see those). Location name and event title are the lot label — `Lot 14 - Oak Lane` — never the homeowner. The Violation Report form itself tells the inspector not to write names or codes in it. You are still responsible for your own privacy obligations; this kit narrows what a third party sees, it does not make you compliant by itself.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, `form_export`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `hoa-ops.db` on your computer.

When you paste a lot roster, the AI extracts the association, lot codes, addresses, and homeowners; adds the association if new; looks each address up in your `lots` cache (a lot you inspected last month is reused, a new address is geocoded once); saves a monthly wave (dates ≤ 59 days); creates one event per lot with the Violation Report attached; and confirms in one line. You say "I'll take Oakridge Tuesday morning" and the AI sequences 8-minute curb stops, creates one shift per lot, and confirms. You see the lots on your phone, check in at the curb (GPS-verified), mark None or the violation(s), photograph evidence, and check out. In the evening you say "close out Oakridge" and the AI pulls your verified times and the reports, updates each visit, and leads with flags. "Export the Oakridge board pack" writes the violation list (GPS times + photo links). "Invoice Oakridge" produces a plain-text invoice under their terms; "roll October" opens next month's wave on the same lots with no new geocode. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\hoa-ops`
- Mac: `/Users/yourname/hoa-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain homeowner names and gate codes; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\hoa-ops.db` (Windows) or `/hoa-ops.db` (Mac):

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

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\hoa-ops\\hoa-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My HOA Inspector" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my hoa-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 52 statements and confirm the tables exist. The `hoa-ops.db` file now exists in your folder with default settings (8-minute curb stops, net 30, US Central `-05:00`) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 hoa-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Ridgeway Inspections in Austin, Central time. It's just me, Jordan Hale, jordan@ridgeway.example. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the inspector on the phone; $0.25, one time), creates the Violation Report form on ZenSched (free), and saves the form id so every wave gets it automatically. In agency mode you then say "add my sub Maya Ortiz, maya@example.com, I pay her $2 a lot" for each inspector you dispatch.

**Check-in radius.** ZenSched enforces the radius through the account's policy, not per lot, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its front yard are covered as is. For gated communities and visitor lots where you park a long way from the pin, ask the AI to "set the check-in radius to 200 m" or 300 m (`policy_update`), or to move the pin onto the driveway for a repeat lot (`location_update`, free; the `lots` cache keeps it). Never ask it to "widen the radius on that location" — that field is informational only. Inspectors arrive early on a drive-through: ask for "allow check-in 15 minutes before the shift" (`checkin_slack_min`). `remote_checkin` turns GPS verification off for every visit and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** Ask the AI to "remind me to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat lot), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Violation Report ($0.05, or $0.15 when it has photos; each record is billed once, ever; replays are free). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

A visit at a new lot costs $0.03 + $0.20 + $0.05 = **~$0.28** if the lot is clean, or **~$0.38** with evidence photos. A repeat lot skips the geocode (**~$0.25 / ~$0.35**). A 200-lot monthly drive-through is about $6 the first month to pin the community, then about $50–$70 a month as you close lots (most are clean, so most form reads are $0.05). The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste a lot roster) "Book September."
- "I'll take Oakridge Tuesday morning." / "Give Maya the Maple Court lots."
- "What's today?" / "How's the Oakridge wave?"
- "Close out Oakridge."
- "Export the Oakridge board pack."
- "The 8 o'clock moved to 10." / "Cancel Lot 22, they have a dumpster permit."
- "Invoice Oakridge." / "Invoice everyone."
- "Who owes me money?"
- "Oakridge paid INV-2026-0001."
- "Roll October for Oakridge."
- Agency: "Add my sub Maya Ortiz, maya@example.com, $2 a lot." / "What do I owe Maya?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Invoice Oakridge" records the invoice in your database (number, date, due date under that association's terms, total, which lots with clean / violation keys) and the AI writes out a plain-text invoice you can paste into an email or the CAM's payables portal, with a line per lot. It does **not** generate a PDF, submit it for you, or collect payment. Invoices never carry a homeowner's name; the lot code and the street identify the file to them. Clean lots bill the same as violation lots — the association paid for the sweep. When they pay, tell the AI ("Oakridge paid INV-2026-0001") and it marks it paid. "Who owes me money" ages what is open into current / 1–30 / 31–60 / 61–90 / 90+ days past due.

### What "payouts" means here (agency mode)

Subs are paid per lot, not by the hour. Each sub has a fee on the wave. When a sub's visit is approved, it flows to `inspector_pay_due`; "what do I owe Maya" lists her unpaid lots and the total, and "paid Maya" marks them. Your own visits never generate payouts. The kit does not calculate taxes or pay anyone.

## Mobile app for inspectors

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your lots appear as they are assigned. Each one shows the address and time; you check in on arrival (GPS-verified), fill in the Violation Report, and check out. Subs get the same email when you add them. There is no signature step; you submit the report yourself.

A 200-lot wave is 200 shifts. The app will list them; work them in lot-code order the way the AI sequenced the morning.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `hoa-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| Denver lot created at the wrong hour | Lot has the wrong `tz_offset` | "Set the Pinecrest lots to Mountain time (-06:00)"; the AI fixes the lots and updates the shifts |
| Shifts an hour off after the clocks changed | `tz_offset` is a fixed offset (`-05:00`), not a zone name, and was not updated for daylight saving | Tell the AI "clocks changed, Oakridge is now -06:00"; it updates the lots and re-times any shifts already created. `SKILL.md` checks this when it rolls a new month |
| AI refuses a wave longer than 60 days | Working as intended; ZenSched events are capped at 60 days | Ask for monthly waves; the AI creates one wave row and one set of events per month (≤ 59 days) |
| Check-in not GPS-verified at a gated community | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update`), or "move Lot 14's pin onto the driveway" (`location_update`, free; the cached lot keeps it), or `location_refine` ($0.10). Do not ask to widen the radius "on that location" |
| App would not let me check in 10 minutes early | Early check-in window too small | "Allow check-in 15 minutes before the shift" (`checkin_slack_min`) |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; ask for a 15-minute check-out reminder |
| Violation Report not on the phone | Form not assigned to that lot's event before the shift was created | "Attach the Violation Report to Lot 14" (`form_assign`), then cancel and recreate the shift |
| "Photo evidence" shows even when I marked None | Conditional fields are web-only on ZenSched | Harmless; leave it empty on a clean lot |
| Photos have no date/GPS printed on them | Working as intended | ZenSched does not burn a stamp onto the image. The punch record holds the GPS/time. Use a camera overlay if you need pixels stamped. |
| AI refuses to put the homeowner's name or the gate code on ZenSched | Working as intended | Homeowner PII and access codes stay on your computer |
| Same lot geocoded twice | Address typed differently ("Lane" vs "Ln") | Tell the AI it is the same place; it merges the `lots` rows and keeps one location |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (locations, events, shifts, punches, forms, submissions); SQLite is authoritative for the commercial model (associations, waves, fees, lot cache, inspector roster, visit lifecycle, QA, billing, payouts) and for all homeowner PII; each side stores only the other's IDs plus the few per-visit values billing and the board pack need (`submission_dc_id`, punch stamps, violation keys, photo count). The PII / confidentiality boundary is enforced by data placement (homeowner and fee columns exist only locally, and `lot_label` is the only string sent to ZenSched) and by `SKILL.md` rules 2–4; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **Lots are a cache, not a per-wave list.** `lots` is `UNIQUE (association_id, normalized_address)`; `SKILL.md` gives the normalization recipe. One `location_create(name=<lot_label>, street_address=..., checkin_radius_m=<settings default>, idempotency_key="loc-lot-{lot_id}")` per lot, ever ($0.03), stored on `lots.zensched_location_id`. `checkin_radius_m` on `location_create` is informational; the enforced radius is `policy_update(0, '{"checkin_radius_m": N}')`, and with geofencing on the platform raises values under 100 m to 300 ft.
- **Per-lot time zone.** `lots.tz_offset` is `CHECK`-constrained to `[+-]HH:MM`; `associations.tz_offset` then `settings.timezone_offset` are the defaults for new lots. `visits.scheduled_start` / `scheduled_end` are lot-local wall-clock strings (`YYYY-MM-DDTHH:MM:SS`, `CHECK`-constrained to have no offset) and `visits_upcoming` builds `start_iso` / `end_iso` as `scheduled_start || tz_offset`. `checkin_at` / `checkout_at` carry an explicit offset.
- **One event per lot per wave.** `inspection_waves.wave_start` / `wave_end` are the event dates; a `CHECK` rejects `wave_end` more than 59 days after `wave_start`, which forces a year of monthly drive-throughs into twelve wave rows (the kit's answer to the 60-day event cap; there is no rolling `event_needs_roll` machinery because a wave never outlives its events). `wave_lots` (`UNIQUE (wave_id, lot_id)`) holds `zensched_event_id` and `event_valid_until`; `event_create(location_id, title=<lot_label>, start_date=wave_start, end_date=wave_end, idempotency_key="event-wl-{wave_lot_id}-{YYYYMMDD}")`, then `form_assign(form_id, event_id=...)`. `visits_upcoming.needs_event` flips when the row has no event or `event_valid_until` is before the visit date; `needs_location` when the lot was never geocoded.
- **One Violation Report for the account**, id on `settings.report_form_id` and copied onto each wave, created with `form_create(title, fields_json, idempotency_key="form-violation-report")`. `SKILL.md` contains the exact 4-field payload validated against ZenSched's `_validate_fields`. Every field, including the section, carries an explicit `identifier`. Option keys: `trash`, `parking`, `paint`, `lawn`, `boat`, `other`, `none` (all under 30 characters). One `show_if` (`photo_evidence` shown when `violations not_equals none`); conditionals are documented as web-only. **No `signature` field**: on ZenSched a signature replaces the Submit button, which is wrong for an inspector submitting alone at the curb. Photo is not required so a clean lot (None) can submit without images; a violation with `photo_count` 0 is flagged (`violation_no_photo`).
- **`has_violation` is computed in a trigger, not typed by the agent.** Store `visits.violations` as a JSON array of option keys. The trigger treats empty / `[]` / `none` / `["none"]` as 0 and everything else (including `["trash","none"]`) as 1. `violations_to_export` and `wave_progress.violations_found` read that flag.
- **Visit lifecycle.** `visits.status` is `open | assigned | completed | no_show | rejected | cancelled`; `qa_status` is `pending | approved | rejected`; both `CHECK`-constrained. `zensched_shift_id` is `UNIQUE`, and the rule is never to reuse a row that has one. `wave_progress` counts approved visits against `SUM(wave_lots.visits_required)`, not against row counts. Clean lots and violation lots both bill.
- **Fraud / quality flags are a view, not a status.** `visits_flagged` returns completed visits with `checkin_late`, `checkin_early` (> 15 minutes before start), `no_checkin`, `short_visit` (`duration_minutes < min_minutes`), `violation_no_photo`, and `minutes_after_slot_end`. A flag is information for QA.
- `duration_minutes` is filled by two triggers (`AFTER INSERT`, `AFTER UPDATE OF checkin_at, checkout_at`) as `round((julianday(out) − julianday(in)) × 1440)` whenever it is NULL and both stamps exist; an explicit value is never overwritten.
- **Money.** `visits_to_invoice` groups approved, uninvoiced visits per association with `SUM(association_fee)` and a `violation_count`; `inspector_pay_due` does the same per sub (`is_owner = 0`) with `SUM(inspector_fee)` and a JSON `visit_ids` array. Fees are read from the wave at query time, not snapshotted. `invoices.invoice_number` is auto-assigned by trigger as `{prefix}-{YYYY}-{0001}`; `invoices_outstanding` adds `days_overdue` and an `aging_bucket` (`current | 1-30 | 31-60 | 61-90 | 90+`).
- **Solo mode is the default; agency mode is additive.** The owner is invited as a ZenSched worker and stored on `inspectors` with `is_owner = 1`; `settings.default_inspector_id` points at that row. `inspector_pay_due` excludes `is_owner = 1`.
- **`exported_at`** gates `violations_to_export`. The agent sets it after writing the board pack so the same violations do not keep appearing at session start.
- **Recurring monthly waves.** "Roll October" inserts a new `inspection_waves` row (month start..end, always ≤ 31 days), copies `wave_lots` (reuse `lot_id` / `zensched_location_id`), and creates new events. Last month's events expired with `wave_end`.
- `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session; SQLite does not persist it. Deleting an association cascades to lots, waves, wave-lot rows, visits, and invoices; deleting an inspector sets `visits.inspector_id` NULL and cascades payouts.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-lot-{lot_id}`
- event: `event-wl-{wave_lot_id}-{YYYYMMDD wave start}`
- shift: `shift-visit-{visit_id}` (a redo is a new row)
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-violation-report`; assignment: `assign-form-{wave_id}-{event_id}` (`form_assign` and `shift_cancel` accept `idempotency_key` on the live server)

ZenSched caches idempotent responses for 24 hours. `visits_upcoming` emits `idempotency_key`; `lots_needs_location` emits `loc_idempotency_key`.

**Timestamps.** `shift_create` takes `start` and `end` in ISO 8601 with an explicit offset, never `Z`. The offset is the **lot's** (`lots.tz_offset`), which is why `visits_upcoming` builds the strings and the agent is told not to. `tz_offset` is a fixed `[+-]HH:MM`, not an IANA zone, so it does not follow daylight saving by itself; `SKILL.md` rule 10 and the "Roll next month" step update it when a wave crosses a DST change (US / CA November and March, AU October and April).

**Metered reads.** `form_submissions` and `form_export` bill $0.05 per submission read ($0.15 with media), once per submission ever; replays, including the board-pack export after the JSON pull for QA, are free. `form_export(format="json")` for a wave is the intended pull; `form_submissions(form_id, event_id=...)` for one lot. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`. The kit's example sets 150 m / 15 min slack / 15 min check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `inspector_reliability` uses `FILTER` clauses (SQLite ≥ 3.30); `better-sqlite3` bundles a current SQLite. Any SQLite MCP server with read and write tools will work; adjust the tool names in `SKILL.md`.

**Schema test.** The schema was verified by splitting the file into its 52 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 9 tables, 11 views, and 10 triggers present; every view on an empty database; `UNIQUE (association_id, normalized_address)` (and the same address allowed for a different association), `UNIQUE (wave_id, lot_id)`, `UNIQUE` on `zensched_shift_id`, `inspectors.email`, and `inspectors.zensched_worker_id`; `visits_upcoming` building `start_iso` / `end_iso` from a `-05:00` and a `-06:00` lot, the `shift-visit-{id}` key, `needs_location`, and `needs_event` flipping on a stale `event_valid_until`; `visits_open` days-left math; `visits_overdue`; `visits_flagged` catching a 40-minute-late check-in, a short visit, an early check-in, a completed visit with no punch, and a violation with no photo while ignoring on-time clean lots and a 10-minute-early one; the duration trigger on insert and update, across mixed offsets, refilling after NULL, and never overwriting an explicit value; the `has_violation` trigger for `["none"]`, `[]`, `none`, `["trash"]`, and `["trash","none"]`; `wave_progress` counts and percentage before and after QA; `violations_to_export` (empty without a violation, includes a trash flag, empty after `exported_at`); `visits_to_invoice`, `inspector_pay_due` (owner excluded), and `inspector_reliability` math including an inspector with no visits; invoice numbering with prefix and year and an explicit number kept; all five aging buckets and `days_overdue`; every `CHECK` (wave length both ways, window times, weekday mask length and characters, quota, wave status, association type, `tz_offset` format including rejecting `Z`, `scheduled_*` format rejecting an offset and a space separator, visit status, QA status); the five `updated_at` triggers; foreign keys, cascade from association and wave-lot, and set-null from inspector. The Violation Report form in `SKILL.md` was run through ZenSched's `_validate_fields` and accepted with the option keys listed there. 131 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
