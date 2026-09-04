# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for the first monthly wave, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the CAM contact, the fees, the homeowners' names, the gate code, QA notes. ZenSched sees `Lot 12 - Oak Lane`, a street address, a Violation Report, and the inspector's account.

The shop is **Ridgeway Inspections**, Austin, Texas, Central time. Today is Tuesday, September 1, 2026.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My HOA Inspector, timezone_offset = -05:00, invoice_due_days = 30,
    invoice_prefix = INV, default_visit_minutes = 8, default_checkin_radius_m = 150,
    report_form_id = NULL, default_inspector_id = NULL
sqlite_query:   SELECT * FROM violations_to_export;                       → (none)
sqlite_query:   SELECT * FROM visits_overdue;                             → (none)
sqlite_query:   SELECT * FROM visits_flagged WHERE qa_status = 'pending'; → (none)
```

## "We're Ridgeway Inspections in Austin, Central time. It's just me, Jordan Hale, jordan@ridgeway.example. Set me up. Check-in radius 150 m, allow 15 minutes early."

```
sqlite_execute: UPDATE settings SET value = 'Ridgeway Inspections' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-05:00' WHERE key = 'timezone_offset';
```

Agent (first metered call this session, rule 13):

> Saved. Since you're the inspector on the phone, I need to invite you to ZenSched as a worker so your lots show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "jordan@ridgeway.example"
  first_name: "Jordan"
  last_name: "Hale"
  idempotency_key: "worker-jordan@ridgeway.example"
  → worker_id: 701, status: "invited", invitation_sent: true

sqlite_execute:
  INSERT INTO inspectors (inspector_name, email, zensched_worker_id, is_owner)
  VALUES ('Jordan Hale', 'jordan@ridgeway.example', 701, 1);
  → lastInsertRowid = 1
sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_inspector_id';

policy_get: policy_id 0
  → settings: { geofence_enabled: true, require_on_site: true, remote_checkin: false, checkin_radius_m: 91, ... }

policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 150, \"checkin_slack_min\": 15, \"checkout_reminder_min_after\": 15}"
  → settings: { checkin_radius_m: 150, checkin_slack_min: 15, ... }

sqlite_execute: UPDATE settings SET value = '150' WHERE key = 'default_checkin_radius_m';

form_create:
  title: "Violation Report"
  idempotency_key: "form-violation-report"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Lot", "identifier": "sec_lot", "text": "Mark every violation you can see from the curb. Choose None if the lot is in compliance. Do not write the homeowner's name, phone, or any gate or lockbox codes here. Photograph evidence only — ZenSched does not burn a date, time, or GPS stamp onto the image."},
  {"type": "multi_select", "label": "Violations", "identifier": "violations", "required": true,
   "options": ["Trash", "Parking", "Paint", "Lawn", "Boat", "Other", "None"]},
  {"type": "photo", "label": "Photo evidence (up to 4)", "identifier": "photo_evidence", "max_images": 4,
   "show_if": {"field": "violations", "op": "not_equals", "value": "none", "action": "show"}},
  {"type": "textarea", "label": "Notes", "identifier": "notes"}
]
```

```
  → form_id: 401, fields: [ ...4 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '401' WHERE key = 'report_form_id';
```

> Saved. You're invited (check jordan@ridgeway.example for the app link). Inspectors must check in within 150 m of the lot pin and may arrive 15 minutes early; GPS verification stays on. The Violation Report is ready: Trash / Parking / Paint / Lawn / Boat / Other / None, photo evidence up to 4, notes. No signature pad. Homeowner names and gate codes will stay on your computer.

## "New wave. Association is Oakridge HOA, CAM Priya Chen, priya@oakridge.example, billing ap@oakridge.example, net 30. Monthly drive-through, weekdays 8 to noon, Sep 1 through Sep 30. $4 a lot to them, $2 to a sub. Lots: 12, 410 Oak Lane, Austin TX 78735, Hale / 18, 418 Oak Lane, Austin TX 78735, Ruiz / 22, 422 Oak Lane, Austin TX 78735, Patel / 7, 407 Maple Court, Austin TX 78735, Nguyen. Gate 4411."

```
sqlite_query:   SELECT association_id FROM associations WHERE association_name LIKE 'Oakridge%';  → (none)
sqlite_execute:
  INSERT INTO associations (association_name, association_type, contact_name, contact_email, billing_email, payment_terms_days, tz_offset)
  VALUES ('Oakridge HOA', 'hoa', 'Priya Chen', 'priya@oakridge.example', 'ap@oakridge.example', 30, '-05:00');
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO inspection_waves (association_id, wave_name, wave_start, wave_end, window_start_time, window_end_time,
                                allowed_weekdays, quota_per_lot, association_fee, inspector_fee, min_minutes,
                                zensched_form_id, inspector_brief, status)
  VALUES (1, 'Oakridge Monthly - Sep 2026', '2026-09-01', '2026-09-30', '08:00', '12:00',
          '1111100', 1, 4.00, 2.00, 2,
          401,
          'Drive each lot. Mark Trash / Parking / Paint / Lawn / Boat / Other / None. Photograph evidence (up to 4) when it is not None.',
          'draft');
  → lastInsertRowid = 1
```

Lots: normalize, look up, insert. Homeowner names and the gate code stay on the lot row.

```
sqlite_query: SELECT lot_id, zensched_location_id FROM lots WHERE association_id = 1 AND normalized_address = '12 410 oak ln austin tx 78735';  → (none)
sqlite_execute:
  INSERT INTO lots (association_id, lot_code, address, city, region, country, postal, normalized_address, tz_offset, lot_label, homeowner_name, access_notes)
  VALUES (1, '12', '410 Oak Lane', 'Austin', 'TX', 'US', '78735', '12 410 oak ln austin tx 78735', '-05:00', 'Lot 12 - Oak Lane', 'Hale', 'Gate 4411');  → 1
sqlite_execute: INSERT INTO lots (...) VALUES (1, '18', '418 Oak Lane', ..., 'Lot 18 - Oak Lane', 'Ruiz', 'Gate 4411');  → 2
sqlite_execute: INSERT INTO lots (...) VALUES (1, '22', '422 Oak Lane', ..., 'Lot 22 - Oak Lane', 'Patel', 'Gate 4411');  → 3
sqlite_execute: INSERT INTO lots (...) VALUES (1, '7', '407 Maple Court', ..., 'Lot 7 - Maple Court', 'Nguyen', 'Gate 4411');  → 4

sqlite_execute: INSERT INTO wave_lots (wave_id, lot_id, visits_required) VALUES (1, 1, 1);  → 1
sqlite_execute: INSERT INTO wave_lots (wave_id, lot_id, visits_required) VALUES (1, 2, 1);  → 2
sqlite_execute: INSERT INTO wave_lots (wave_id, lot_id, visits_required) VALUES (1, 3, 1);  → 3
sqlite_execute: INSERT INTO wave_lots (wave_id, lot_id, visits_required) VALUES (1, 4, 1);  → 4
```

Agent (rule 13):

> Four new lots cost $0.12 to geocode now. Each completed visit will cost about $0.25 if clean or $0.35 with photos, so about $1.00–$1.40 for the wave. If the account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
location_create:
  name: "Lot 12 - Oak Lane"
  street_address: "410 Oak Lane, Austin, TX 78735"
  checkin_radius_m: 150
  idempotency_key: "loc-lot-1"
  → location_id: 9101, pin_quality: "street",
    billing: { meter: "geocode", units: 1, price: 0.03 }

location_create: name "Lot 18 - Oak Lane",   street_address "418 Oak Lane, Austin, TX 78735",   key "loc-lot-2"  → 9102
location_create: name "Lot 22 - Oak Lane",   street_address "422 Oak Lane, Austin, TX 78735",   key "loc-lot-3"  → 9103
location_create: name "Lot 7 - Maple Court", street_address "407 Maple Court, Austin, TX 78735", key "loc-lot-4"  → 9104

sqlite_execute: UPDATE lots SET zensched_location_id = 9101 WHERE lot_id = 1;
sqlite_execute: UPDATE lots SET zensched_location_id = 9102 WHERE lot_id = 2;
sqlite_execute: UPDATE lots SET zensched_location_id = 9103 WHERE lot_id = 3;
sqlite_execute: UPDATE lots SET zensched_location_id = 9104 WHERE lot_id = 4;
```

Nothing about Priya, Hale, Ruiz, Patel, Nguyen, the fees, or Gate 4411 is in `name` or `notes`. One event per lot for the wave, the form attached to each:

```
event_create:
  location_id: 9101
  title: "Lot 12 - Oak Lane"
  start_date: "2026-09-01"
  end_date:   "2026-09-30"          ← the wave (29 days; the cap is 60)
  idempotency_key: "event-wl-1-20260901"
  → event_id: 7101

form_assign:
  form_id: 401
  event_id: 7101
  → status: "assigned", form_id: 401, event_id: 7101, policy_id: 0

sqlite_execute: UPDATE wave_lots SET zensched_event_id = 7101, event_valid_until = '2026-09-30' WHERE wave_lot_id = 1;

event_create: location_id 9102, title "Lot 18 - Oak Lane",   2026-09-01..2026-09-30, key "event-wl-2-20260901"  → 7102;  form_assign 401 → 7102
event_create: location_id 9103, title "Lot 22 - Oak Lane",   2026-09-01..2026-09-30, key "event-wl-3-20260901"  → 7103;  form_assign 401 → 7103
event_create: location_id 9104, title "Lot 7 - Maple Court", 2026-09-01..2026-09-30, key "event-wl-4-20260901"  → 7104;  form_assign 401 → 7104

sqlite_execute: INSERT INTO visits (wave_lot_id) VALUES (1);
sqlite_execute: INSERT INTO visits (wave_lot_id) VALUES (2);
sqlite_execute: INSERT INTO visits (wave_lot_id) VALUES (3);
sqlite_execute: INSERT INTO visits (wave_lot_id) VALUES (4);

sqlite_execute: UPDATE inspection_waves SET status = 'active' WHERE wave_id = 1;
```

> Oakridge Monthly - Sep 2026: 4 lots, weekdays 08:00–12:00 through Sep 30, $4 per lot to the association. Violation Report attached. Ready to assign. Hale / Ruiz / Patel / Nguyen and the gate code are only on your computer; ZenSched just sees "Lot 12 - Oak Lane".

## "I'll take the four Oakridge lots Tuesday morning."

Today is Tuesday Sep 1, so "Tuesday" is today — too tight for a same-morning book; the agent picks **Tuesday Sep 8** (next weekday inside the wave).

```
sqlite_query: SELECT * FROM visits_open WHERE association_name LIKE 'Oakridge%';
  → 4 rows, window 08:00–12:00, tz_offset -05:00, days_until_wave_end 29
sqlite_query: SELECT inspector_id, zensched_worker_id FROM inspectors WHERE inspector_id = 1;
  → inspector 1, worker 701

sqlite_execute: UPDATE visits SET inspector_id = 1, scheduled_start = '2026-09-08T08:00:00', scheduled_end = '2026-09-08T08:08:00', status = 'assigned' WHERE visit_id = 1;
sqlite_execute: UPDATE visits SET inspector_id = 1, scheduled_start = '2026-09-08T08:08:00', scheduled_end = '2026-09-08T08:16:00', status = 'assigned' WHERE visit_id = 2;
sqlite_execute: UPDATE visits SET inspector_id = 1, scheduled_start = '2026-09-08T08:16:00', scheduled_end = '2026-09-08T08:24:00', status = 'assigned' WHERE visit_id = 3;
sqlite_execute: UPDATE visits SET inspector_id = 1, scheduled_start = '2026-09-08T08:24:00', scheduled_end = '2026-09-08T08:32:00', status = 'assigned' WHERE visit_id = 4;

sqlite_query: SELECT * FROM visits_upcoming WHERE zensched_shift_id IS NULL;
  → 4 rows, needs_location 0, needs_event 0,
    start_iso 2026-09-08T08:00:00-05:00, idempotency_key shift-visit-1, ...

shift_create:
  event_id: 7101
  worker_id: 701
  start: "2026-09-08T08:00:00-05:00"
  end:   "2026-09-08T08:08:00-05:00"
  idempotency_key: "shift-visit-1"
  → shift_id: 8101, forms_installed: [401]

shift_create: event 7102, 2026-09-08T08:08:00-05:00 .. 08:16, key "shift-visit-2"  → 8102
shift_create: event 7103, 2026-09-08T08:16:00-05:00 .. 08:24, key "shift-visit-3"  → 8103
shift_create: event 7104, 2026-09-08T08:24:00-05:00 .. 08:32, key "shift-visit-4"  → 8104

sqlite_execute: UPDATE visits SET zensched_shift_id = 8101 WHERE visit_id = 1;
sqlite_execute: UPDATE visits SET zensched_shift_id = 8102 WHERE visit_id = 2;
sqlite_execute: UPDATE visits SET zensched_shift_id = 8103 WHERE visit_id = 3;
sqlite_execute: UPDATE visits SET zensched_shift_id = 8104 WHERE visit_id = 4;
```

> Assigned you four Oakridge lots Tuesday Sep 8: Lot 12 Oak Lane 08:00–08:08, Lot 18 Oak Lane 08:08–08:16, Lot 22 Oak Lane 08:16–08:24, Lot 7 Maple Court 08:24–08:32. They're on your phone with the Violation Report. Mark None on a clean lot; photograph evidence (up to 4) when you flag Trash, Parking, Paint, Lawn, Boat, or Other.

## "Close out Oakridge."

```
shift_list: date_from "2026-09-08", date_to "2026-09-08", status "checked_out"
  → shifts 8101, 8102, 8103, 8104 (all checked_out)

shift_status: shift_id 8101  → actual_in 2026-09-08T08:01:12-05:00, actual_out 2026-09-08T08:07:40-05:00, gps_verified true
shift_status: 8102  → 08:09:05 .. 08:15:10, gps_verified true
shift_status: 8103  → 08:17:02 .. 08:23:50, gps_verified true
shift_status: 8104  → 08:25:11 .. 08:30:44, gps_verified true
```

Agent: "Reading 4 reports. Two look like they have photos (~$0.15) and two are clean (~$0.05), about $0.40. Go ahead?" Owner: *"yes"*

```
form_export:
  form_id: 401
  since: "2026-09-01"
  until: "2026-09-08"
  format: "json"
  → 4 submissions
    lot 12 / event 7101: violations=["none"], media=[]
    lot 18 / event 7102: violations=["parking"], media=[2 photos]
    lot 22 / event 7103: violations=["trash","boat"], media=[]          ← flag
    lot 7  / event 7104: violations=["none"], media=[]

sqlite_execute: UPDATE visits SET status='completed', submission_dc_id=9001, checkin_at='2026-09-08T08:01:12-05:00', checkout_at='2026-09-08T08:07:40-05:00', violations='["none"]', photo_count=0, qa_status='pending' WHERE visit_id=1;
sqlite_execute: UPDATE visits SET status='completed', submission_dc_id=9002, checkin_at='2026-09-08T08:09:05-05:00', checkout_at='2026-09-08T08:15:10-05:00', violations='["parking"]', photo_count=2, notes='White pickup on the lawn', qa_status='pending' WHERE visit_id=2;
sqlite_execute: UPDATE visits SET status='completed', submission_dc_id=9003, checkin_at='2026-09-08T08:17:02-05:00', checkout_at='2026-09-08T08:23:50-05:00', violations='["trash","boat"]', photo_count=0, notes='Cans at curb + boat on trailer', qa_status='pending' WHERE visit_id=3;
sqlite_execute: UPDATE visits SET status='completed', submission_dc_id=9004, checkin_at='2026-09-08T08:25:11-05:00', checkout_at='2026-09-08T08:30:44-05:00', violations='["none"]', photo_count=0, qa_status='pending' WHERE visit_id=4;

sqlite_query: SELECT * FROM visits_flagged WHERE qa_status = 'pending';
  → visit 3, Lot 22, violation_no_photo = 1, violations ["trash","boat"]
```

> Pulled 4 lots. **Flag:** Lot 22 — trash + boat, no photo. Lot 18 parking, GPS-verified, 2 photos (white pickup on the lawn). Lots 12 and 7 clean. Want me to approve 12, 18, and 7 and reject 22 so it reopens?

Owner: *"Approve 12, 18, and 7. Reject 22, reopen it."*

```
sqlite_execute: UPDATE visits SET qa_status='approved' WHERE visit_id IN (1, 2, 4);
sqlite_execute: UPDATE visits SET qa_status='rejected', status='rejected', qa_notes='violation with no photo' WHERE visit_id=3;
sqlite_execute: INSERT INTO visits (wave_lot_id) VALUES (3);
```

> Approved three. Lot 22 is open again — say when you want it back on your phone.

## "Export the Oakridge board pack."

```
sqlite_query: SELECT * FROM violations_to_export WHERE association_name LIKE '%Oakridge%';
  → visit 2, Lot 18, parking, 2 photos, GPS in/out
sqlite_query: SELECT * FROM wave_progress WHERE wave_id = 1;
  → lot_count 4, visits_approved 3, violations_found 1 (the approved parking), visits_open 1

form_export: form_id 401, since 2026-09-01, until 2026-09-30, format "json"
  → replay of already-read submissions, free

sqlite_execute: UPDATE visits SET exported_at = datetime('now', 'localtime') WHERE visit_id = 2;
```

Board pack (plain text the owner pastes):

```
Oakridge HOA — Monthly inspection Sep 1–30, 2026
Ridgeway Inspections
Lots inspected (approved): 3    Clean: 2    Violations: 1    Still open: Lot 22

Lot 18 — 418 Oak Lane
  GPS-verified 08:09–08:15, 8 Sep 2026
  Violations: parking
  Notes: White pickup on the lawn
  Photos: https://cdn.example/…/1.jpg  https://cdn.example/…/2.jpg
  Photos have no burned-in GPS stamp; the punch record is the location/time proof.

This is not a courtesy letter and not a fine. Paste into your CAM portal however you file today.
```

## "Invoice Oakridge HOA."

```
sqlite_query: SELECT * FROM visits_to_invoice;
  → Oakridge HOA, visit_count 3, violation_count 1, fees_amount 12.00

sqlite_execute:
  INSERT INTO invoices (association_id, wave_id, invoice_date, due_date, visit_count, violation_count, fees_amount, total_amount, line_items)
  SELECT ... ;     → invoice_id 1, invoice_number INV-2026-0001
sqlite_execute: UPDATE visits SET association_invoiced = 1 WHERE visit_id IN (1, 2, 4);
```

Plain-text invoice: INV-2026-0001, Oakridge HOA, due Oct 1 (net 30), three lines (Lot 12 clean $4, Lot 18 parking $4, Lot 7 clean $4), total $12. No homeowner names. No inspector names.

## "Roll October for Oakridge."

```
sqlite_query: SELECT * FROM inspection_waves WHERE association_id = 1 ORDER BY wave_start DESC LIMIT 1;
  → wave 1, Sep 1–30, fees 4 / 2, form 401

sqlite_execute:
  INSERT INTO inspection_waves (association_id, wave_name, wave_start, wave_end, window_start_time, window_end_time,
                                allowed_weekdays, quota_per_lot, association_fee, inspector_fee, min_minutes,
                                zensched_form_id, inspector_brief, status)
  VALUES (1, 'Oakridge Monthly - Oct 2026', '2026-10-01', '2026-10-31', '08:00', '12:00',
          '1111100', 1, 4.00, 2.00, 2, 401, '<same brief>', 'draft');
  → wave_id 2

sqlite_execute: INSERT INTO wave_lots (wave_id, lot_id, visits_required) SELECT 2, lot_id, visits_required FROM wave_lots WHERE wave_id = 1 AND is_active = 1;
  → wave_lot_ids 5–8 (lots 1–4 reused; zensched_location_id already set — no geocode)

event_create: location 9101, title "Lot 12 - Oak Lane", 2026-10-01..2026-10-31, key "event-wl-5-20261001"  → 7201
form_assign: form 401, event 7201
… (lots 18, 22, 7)

sqlite_execute: INSERT INTO visits (wave_lot_id) VALUES (5);
… (6, 7, 8)
sqlite_execute: UPDATE inspection_waves SET status = 'active' WHERE wave_id = 2;
```

> Rolled **Oakridge Monthly - Oct 2026**: 4 lots, Oct 1–31, same window and fees. No new geocodes. Ready to assign.
