-- ZenSched HOA / Strata Inspection Local Database Schema
-- SQLite database for associations (HOA / strata / body-corporate boards),
-- a cache of lots (places), monthly inspection waves, the inspector roster,
-- per-lot visits and Violation Report results, board packs, association
-- invoices, and inspector pay.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, the
-- original form submissions and evidence photos).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my hoa-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 hoa-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT AN HOA MANAGEMENT SYSTEM, A VIOLATION-LETTER / FINE ENGINE,
-- OR A HOMEOWNER / BOARD PORTAL. The kit puts each lot on the inspector's
-- phone for a monthly drive-through, GPS-verifies arrival at the lot, and
-- collects a photo Violation Report. violations_to_export plus form_export
-- give you the photos and GPS times for a board pack you paste into email
-- or the management company's portal. Nothing here sends a courtesy letter,
-- schedules a hearing, or collects a fine.
--
-- PRIVACY: homeowner names, phones, and access notes (gate codes, lockbox)
-- live ONLY in this file on your computer: lots.homeowner_name,
-- lots.homeowner_phone, lots.access_notes. ZenSched receives, per lot, a
-- label made of the lot code and the street ("Lot 14 - Oak Lane"), the
-- street address for the GPS pin, a matching event title, and the Violation
-- Report the inspector fills in on the phone. SKILL.md forbids the agent
-- from putting any local-only column into a ZenSched field.
--
-- TIME CONVENTIONS
--   visits.scheduled_start / scheduled_end are LOT-LOCAL wall-clock times
--   without an offset ('2026-09-10T09:00:00'). Views append the lot's
--   tz_offset to build the ISO strings shift_create needs, so a multi-region
--   inspector (Texas HOA + Colorado HOA) comes out right without the agent
--   doing timezone arithmetic.
--   visits.checkin_at / checkout_at are ISO 8601 WITH an explicit offset, as
--   recorded from ZenSched (any offset is fine; SQLite normalizes to UTC when
--   comparing).

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session.
-- timezone_offset is the DEFAULT for new lots; each lot carries its own
-- tz_offset because an inspector may cover associations in several zones.
-- default_checkin_radius_m is informational: the radius ZenSched enforces is
-- the account POLICY's, set with policy_update(0, {"checkin_radius_m": N}).
-- report_form_id is the one Violation Report form, created once per account.
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My HOA Inspector');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_visit_minutes', '8');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_checkin_radius_m', '150');
INSERT OR IGNORE INTO settings (key, value) VALUES ('report_form_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_inspector_id', NULL);

-- Associations: the HOA / strata / body-corporate boards (or their management
-- company) that hire you. LOCAL ONLY. Nothing from this table is ever sent
-- to ZenSched.
CREATE TABLE IF NOT EXISTS associations (
  association_id INTEGER PRIMARY KEY AUTOINCREMENT,
  association_name TEXT NOT NULL,                   -- 'Oakridge HOA', '12 Harbour Strata'
  association_type TEXT NOT NULL DEFAULT 'hoa'
    CHECK (association_type IN ('hoa', 'strata', 'condo', 'management_co', 'other')),
  contact_name TEXT,                                -- LOCAL ONLY: board / CAM contact
  contact_email TEXT,
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER DEFAULT 30,
  tz_offset TEXT                                    -- default for new lots in this association
    CHECK (tz_offset IS NULL OR tz_offset GLOB '[+-][0-1][0-9]:[0-5][0-9]'),
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Lots: the cache of physical places (one ZenSched LOCATION each), created
-- once and kept forever (geocoding is metered). Keyed by association +
-- normalized address so the same lot pasted in two CSVs is one row and one
-- geocode. tz_offset is PER LOT. lot_label is the only name that crosses to
-- ZenSched ('Lot 14 - Oak Lane'). homeowner_* and access_notes are LOCAL ONLY.
CREATE TABLE IF NOT EXISTS lots (
  lot_id INTEGER PRIMARY KEY AUTOINCREMENT,
  association_id INTEGER NOT NULL,
  lot_code TEXT,                                    -- the association's lot / unit number ('14', 'A-12')
  address TEXT NOT NULL,                            -- street as the plat / roster wrote it
  city TEXT,
  region TEXT,                                      -- state / province
  country TEXT DEFAULT 'US',
  postal TEXT,
  normalized_address TEXT NOT NULL,                 -- see SKILL.md "Normalize an address"
  tz_offset TEXT NOT NULL                           -- '-05:00'; defaults to association then settings
    CHECK (tz_offset GLOB '[+-][0-1][0-9]:[0-5][0-9]'),
  lot_label TEXT,                                   -- name sent to ZenSched: 'Lot 14 - Oak Lane'
  homeowner_name TEXT,                              -- LOCAL ONLY
  homeowner_phone TEXT,                             -- LOCAL ONLY
  access_notes TEXT,                                -- LOCAL ONLY: gate code, lockbox
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (association_id) REFERENCES associations(association_id) ON DELETE CASCADE,
  UNIQUE (association_id, normalized_address)
);

-- Inspection waves: one MONTHLY (or shorter) drive-through for one
-- association. A wave says which lots, when (wave dates, daily window,
-- allowed weekdays), how many visits per lot, and the money (association
-- fee, inspector fee). A year of monthly inspections is twelve wave rows
-- because a ZenSched event is capped at 60 days and the kit creates one
-- event per lot per wave (the CHECK below enforces the split — never more
-- than 59 days after start). allowed_weekdays is a 7-character 0/1 mask,
-- Monday first: '1111100' = weekdays; '0000010' = Saturday only.
CREATE TABLE IF NOT EXISTS inspection_waves (
  wave_id INTEGER PRIMARY KEY AUTOINCREMENT,
  association_id INTEGER NOT NULL,
  wave_name TEXT NOT NULL,                          -- 'Oakridge Monthly - Sep 2026'
  wave_start TEXT NOT NULL,                         -- ISO date
  wave_end TEXT NOT NULL                            -- ISO date, at most 59 days after wave_start
    CHECK (wave_end >= wave_start AND julianday(wave_end) - julianday(wave_start) <= 59),
  window_start_time TEXT NOT NULL DEFAULT '08:00'   -- earliest local time a visit may start
    CHECK (window_start_time GLOB '[0-2][0-9]:[0-5][0-9]'),
  window_end_time TEXT NOT NULL DEFAULT '12:00'     -- latest local time a visit may END
    CHECK (window_end_time GLOB '[0-2][0-9]:[0-5][0-9]'),
  allowed_weekdays TEXT NOT NULL DEFAULT '1111100'
    CHECK (length(allowed_weekdays) = 7 AND allowed_weekdays NOT GLOB '*[^01]*'),
  quota_per_lot INTEGER NOT NULL DEFAULT 1 CHECK (quota_per_lot >= 1),
  association_fee REAL NOT NULL,                    -- what the association pays per approved visit
  inspector_fee REAL NOT NULL,                      -- what a sub inspector earns per approved visit
  min_minutes INTEGER DEFAULT 2,                    -- visits shorter than this are flagged
  zensched_form_id INTEGER,                         -- Violation Report form id (copied from settings)
  inspector_brief TEXT,                             -- the ONLY text about this wave an inspector may be told
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'closed')),
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (association_id) REFERENCES associations(association_id) ON DELETE CASCADE
);

-- Wave x lot: which lots are in this wave, how many visits each needs, and
-- the ZenSched EVENT for that lot for this wave (start_date = wave_start,
-- end_date = wave_end, never more than 60 days). The Violation Report is
-- assigned to the event so it installs on the inspector's phone at shift_create.
CREATE TABLE IF NOT EXISTS wave_lots (
  wave_lot_id INTEGER PRIMARY KEY AUTOINCREMENT,
  wave_id INTEGER NOT NULL,
  lot_id INTEGER NOT NULL,
  visits_required INTEGER NOT NULL DEFAULT 1 CHECK (visits_required >= 0),
  zensched_event_id INTEGER,                        -- from event_create
  event_valid_until TEXT,                           -- ISO date: last day the event covers (= wave_end)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (wave_id) REFERENCES inspection_waves(wave_id) ON DELETE CASCADE,
  FOREIGN KEY (lot_id) REFERENCES lots(lot_id) ON DELETE CASCADE,
  UNIQUE (wave_id, lot_id)
);

-- Inspectors: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. Subs are further rows
-- with is_owner = 0. pay_handle (PayPal email, Venmo, bank nickname) is
-- LOCAL ONLY. Reliability is derived from visits (see inspector_reliability).
CREATE TABLE IF NOT EXISTS inspectors (
  inspector_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspector_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  phone TEXT,
  home_city TEXT,
  home_region TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  pay_handle TEXT,                                  -- LOCAL ONLY: how you pay a sub
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Visits: one row per lot visit the wave requires. Created 'open' from the
-- quota, becomes 'assigned' when an inspector and a date/time slot are
-- chosen (one ZenSched shift), then 'completed' / 'no_show' / 'rejected' /
-- 'cancelled'. scheduled_* are lot-local wall-clock ('YYYY-MM-DDTHH:MM:SS',
-- no offset); checkin_at / checkout_at are ISO with offset as recorded from
-- ZenSched. duration_minutes is filled by trigger from the punches when left
-- NULL. violations is a JSON array of Violation Report option keys; the
-- fill_has_violation trigger sets has_violation when the agent leaves it
-- NULL. Never reuse a row that has a zensched_shift_id.
CREATE TABLE IF NOT EXISTS visits (
  visit_id INTEGER PRIMARY KEY AUTOINCREMENT,
  wave_lot_id INTEGER NOT NULL,
  inspector_id INTEGER,                             -- NULL until assigned; NULL → settings.default_inspector_id on assign
  scheduled_start TEXT                              -- lot-local, no offset
    CHECK (scheduled_start IS NULL OR scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'),
  scheduled_end TEXT
    CHECK (scheduled_end IS NULL OR scheduled_end GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'),
  zensched_shift_id INTEGER UNIQUE,                 -- from shift_create
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'assigned', 'completed', 'no_show', 'rejected', 'cancelled')),
  submission_dc_id INTEGER,                         -- Violation Report submission_id
  checkin_at TEXT,                                  -- ISO with offset, from shift_status
  checkout_at TEXT,
  duration_minutes INTEGER,                         -- trigger fills from punches if NULL
  violations TEXT,                                  -- JSON array of option keys: ["trash","parking"]
  has_violation INTEGER,                            -- trigger fills if NULL: 0 when empty / ["none"] / none
  photo_count INTEGER,
  notes TEXT,                                       -- copied from the form textarea
  qa_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (qa_status IN ('pending', 'approved', 'rejected')),
  qa_notes TEXT,                                    -- LOCAL ONLY
  association_invoiced INTEGER DEFAULT 0,
  inspector_paid INTEGER DEFAULT 0,
  exported_at TEXT,                                 -- when the board pack line was produced
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (wave_lot_id) REFERENCES wave_lots(wave_lot_id) ON DELETE CASCADE,
  FOREIGN KEY (inspector_id) REFERENCES inspectors(inspector_id) ON DELETE SET NULL
);

-- Invoices to associations. invoice_number is filled by trigger if left NULL.
-- line_items is a JSON array with one object per visit.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  association_id INTEGER NOT NULL,
  wave_id INTEGER,                                  -- NULL when one invoice spans waves
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  visit_count INTEGER,
  violation_count INTEGER,
  fees_amount REAL,                                 -- SUM(association_fee)
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array: one object per visit
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (association_id) REFERENCES associations(association_id) ON DELETE CASCADE,
  FOREIGN KEY (wave_id) REFERENCES inspection_waves(wave_id) ON DELETE SET NULL
);

-- Inspector payouts: one row per sub inspector per pay run. The owner
-- (is_owner = 1) never appears here. The owner pays outside the kit
-- (PayPal, Venmo, bank); this is the record. visit_ids is a JSON array.
CREATE TABLE IF NOT EXISTS inspector_payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspector_id INTEGER NOT NULL,
  period_start TEXT,
  period_end TEXT,
  visit_count INTEGER,
  fees_amount REAL,                                 -- SUM(inspector_fee)
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  visit_ids TEXT,                                   -- JSON array of visit_id
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (inspector_id) REFERENCES inspectors(inspector_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_lots_association ON lots(association_id);
CREATE INDEX IF NOT EXISTS idx_lots_zensched_location ON lots(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_waves_association ON inspection_waves(association_id, status);
CREATE INDEX IF NOT EXISTS idx_wave_lots_wave ON wave_lots(wave_id);
CREATE INDEX IF NOT EXISTS idx_wave_lots_lot ON wave_lots(lot_id);
CREATE INDEX IF NOT EXISTS idx_wave_lots_event ON wave_lots(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_visits_wave_lot ON visits(wave_lot_id, status);
CREATE INDEX IF NOT EXISTS idx_visits_inspector ON visits(inspector_id, status);
CREATE INDEX IF NOT EXISTS idx_visits_scheduled ON visits(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_visits_qa ON visits(qa_status, association_invoiced, inspector_paid);
CREATE INDEX IF NOT EXISTS idx_visits_export ON visits(status, has_violation, exported_at);
CREATE INDEX IF NOT EXISTS idx_invoices_association ON invoices(association_id, paid);
CREATE INDEX IF NOT EXISTS idx_payouts_inspector ON inspector_payouts(inspector_id, paid);

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_association_timestamp
AFTER UPDATE ON associations
BEGIN
  UPDATE associations SET updated_at = datetime('now') WHERE association_id = NEW.association_id;
END;

CREATE TRIGGER IF NOT EXISTS update_lot_timestamp
AFTER UPDATE ON lots
BEGIN
  UPDATE lots SET updated_at = datetime('now') WHERE lot_id = NEW.lot_id;
END;

CREATE TRIGGER IF NOT EXISTS update_wave_timestamp
AFTER UPDATE ON inspection_waves
BEGIN
  UPDATE inspection_waves SET updated_at = datetime('now') WHERE wave_id = NEW.wave_id;
END;

CREATE TRIGGER IF NOT EXISTS update_inspector_timestamp
AFTER UPDATE ON inspectors
BEGIN
  UPDATE inspectors SET updated_at = datetime('now') WHERE inspector_id = NEW.inspector_id;
END;

CREATE TRIGGER IF NOT EXISTS update_visit_timestamp
AFTER UPDATE ON visits
BEGIN
  UPDATE visits SET updated_at = datetime('now') WHERE visit_id = NEW.visit_id;
END;

-- Fill duration_minutes from the punches when the agent leaves it NULL, on
-- insert and whenever the punch columns change. Both stamps carry an offset,
-- so julianday arithmetic is exact even across midnight or time zones.
CREATE TRIGGER IF NOT EXISTS fill_visit_duration_insert
AFTER INSERT ON visits
WHEN NEW.duration_minutes IS NULL AND NEW.checkin_at IS NOT NULL AND NEW.checkout_at IS NOT NULL
BEGIN
  UPDATE visits
  SET duration_minutes = CAST(round((julianday(NEW.checkout_at) - julianday(NEW.checkin_at)) * 1440.0) AS INTEGER)
  WHERE visit_id = NEW.visit_id;
END;

CREATE TRIGGER IF NOT EXISTS fill_visit_duration_update
AFTER UPDATE OF checkin_at, checkout_at ON visits
WHEN NEW.duration_minutes IS NULL AND NEW.checkin_at IS NOT NULL AND NEW.checkout_at IS NOT NULL
BEGIN
  UPDATE visits
  SET duration_minutes = CAST(round((julianday(NEW.checkout_at) - julianday(NEW.checkin_at)) * 1440.0) AS INTEGER)
  WHERE visit_id = NEW.visit_id;
END;

-- Fill has_violation from the stored option-key JSON when the agent leaves
-- it NULL. Clean lots are empty, '[]', 'none', or '["none"]'. Anything else
-- (including '["trash","none"]') is a violation.
CREATE TRIGGER IF NOT EXISTS fill_has_violation_insert
AFTER INSERT ON visits
WHEN NEW.has_violation IS NULL AND NEW.violations IS NOT NULL
BEGIN
  UPDATE visits
  SET has_violation = CASE
    WHEN trim(NEW.violations) IN ('', '[]', 'none', '["none"]') THEN 0
    ELSE 1
  END
  WHERE visit_id = NEW.visit_id;
END;

CREATE TRIGGER IF NOT EXISTS fill_has_violation_update
AFTER UPDATE OF violations ON visits
WHEN NEW.has_violation IS NULL AND NEW.violations IS NOT NULL
BEGIN
  UPDATE visits
  SET has_violation = CASE
    WHEN trim(NEW.violations) IN ('', '[]', 'none', '["none"]') THEN 0
    ELSE 1
  END
  WHERE visit_id = NEW.visit_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Unassigned visits in active waves, with everything the agent needs to
-- propose an assignment: lot, city, tz, the daily window, allowed weekdays,
-- and how many days remain in the wave. Sorted by urgency.
CREATE VIEW IF NOT EXISTS visits_open AS
SELECT
  v.visit_id,
  w.wave_id,
  w.wave_name,
  a.association_id,
  a.association_name,
  l.lot_id,
  l.lot_code,
  l.address,
  l.city,
  l.region,
  l.tz_offset,
  l.lot_label,
  l.homeowner_name,
  l.access_notes,
  l.zensched_location_id,
  wl.wave_lot_id,
  wl.zensched_event_id,
  w.wave_start,
  w.wave_end,
  w.window_start_time,
  w.window_end_time,
  w.allowed_weekdays,
  w.min_minutes,
  w.inspector_fee,
  w.inspector_brief,
  CAST(julianday(w.wave_end) - julianday(date('now')) AS INTEGER) AS days_until_wave_end
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN lots l               ON l.lot_id = wl.lot_id
JOIN associations a       ON a.association_id = w.association_id
WHERE v.status = 'open'
  AND w.status = 'active'
  AND wl.is_active = 1
ORDER BY w.wave_end, l.city, l.lot_code, l.address;

-- Assigned visits in the next 7 days (today + 6, by lot-local date). One
-- row = one shift_create call (if zensched_shift_id is NULL) or one shift to
-- watch. start_iso / end_iso use the LOT's tz_offset. needs_location /
-- needs_event mean the lot or the wave-lot row has not been set up on
-- ZenSched yet.
CREATE VIEW IF NOT EXISTS visits_upcoming AS
SELECT
  v.visit_id,
  v.status,
  w.wave_id,
  w.wave_name,
  a.association_name,
  l.lot_id,
  l.lot_code,
  l.address,
  l.city,
  l.tz_offset,
  l.lot_label,
  l.zensched_location_id,
  wl.wave_lot_id,
  wl.zensched_event_id,
  wl.event_valid_until,
  k.inspector_id,
  k.inspector_name,
  k.zensched_worker_id                               AS worker_id,
  v.scheduled_start,
  v.scheduled_end,
  v.scheduled_start || l.tz_offset                   AS start_iso,
  v.scheduled_end   || l.tz_offset                   AS end_iso,
  'shift-visit-' || v.visit_id                       AS idempotency_key,
  v.zensched_shift_id,
  CASE WHEN l.zensched_location_id IS NULL THEN 1 ELSE 0 END AS needs_location,
  CASE WHEN wl.zensched_event_id IS NULL
         OR wl.event_valid_until IS NULL
         OR wl.event_valid_until < date(v.scheduled_start) THEN 1 ELSE 0 END AS needs_event,
  w.inspector_brief
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN lots l               ON l.lot_id = wl.lot_id
JOIN associations a       ON a.association_id = w.association_id
LEFT JOIN inspectors k    ON k.inspector_id = v.inspector_id
WHERE v.status = 'assigned'
  AND date(v.scheduled_start) BETWEEN date('now') AND date('now', '+6 days')
ORDER BY v.scheduled_start, l.city, l.lot_code;

-- Assigned visits whose slot has already ended (lot-local, compared in UTC)
-- with no result recorded. Either the inspector did it and results have
-- not been pulled, or it is a no-show.
CREATE VIEW IF NOT EXISTS visits_overdue AS
SELECT
  v.visit_id,
  w.wave_id,
  w.wave_name,
  a.association_name,
  l.lot_code,
  l.address,
  l.city,
  l.tz_offset,
  l.lot_label,
  wl.zensched_event_id,
  k.inspector_id,
  k.inspector_name,
  k.zensched_worker_id                               AS worker_id,
  v.scheduled_start,
  v.scheduled_end,
  v.zensched_shift_id,
  CAST((julianday('now') - julianday(v.scheduled_end || l.tz_offset)) * 24 AS INTEGER) AS hours_overdue
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN lots l               ON l.lot_id = wl.lot_id
JOIN associations a       ON a.association_id = w.association_id
LEFT JOIN inspectors k    ON k.inspector_id = v.inspector_id
WHERE v.status = 'assigned'
  AND v.scheduled_end IS NOT NULL
  AND julianday(v.scheduled_end || l.tz_offset) < julianday('now')
ORDER BY v.scheduled_end;

-- Completed visits with a quality signal, for QA to look at first:
--   checkin_late         check-in after the assigned slot ended
--   checkin_early        check-in more than 15 minutes before the slot started
--   no_checkin           completed (form in) but no GPS check-in recorded
--   short_visit          duration below the wave's min_minutes
--   violation_no_photo   has_violation = 1 and photo_count is 0 or NULL
-- On-time clean lots with a normal duration do not appear here.
CREATE VIEW IF NOT EXISTS visits_flagged AS
SELECT
  v.visit_id,
  w.wave_id,
  w.wave_name,
  a.association_name,
  l.lot_code,
  l.address,
  l.city,
  l.tz_offset,
  l.lot_label,
  k.inspector_id,
  k.inspector_name,
  v.scheduled_start,
  v.scheduled_end,
  v.checkin_at,
  v.checkout_at,
  v.duration_minutes,
  w.min_minutes,
  v.violations,
  v.has_violation,
  v.photo_count,
  v.submission_dc_id,
  v.zensched_shift_id,
  v.qa_status,
  CASE WHEN v.checkin_at IS NOT NULL
        AND julianday(v.checkin_at) > julianday(v.scheduled_end || l.tz_offset) THEN 1 ELSE 0 END AS checkin_late,
  CASE WHEN v.checkin_at IS NOT NULL
        AND julianday(v.checkin_at) < julianday(v.scheduled_start || l.tz_offset, '-15 minutes') THEN 1 ELSE 0 END AS checkin_early,
  CASE WHEN v.checkin_at IS NULL THEN 1 ELSE 0 END AS no_checkin,
  CASE WHEN v.duration_minutes IS NOT NULL AND v.duration_minutes < COALESCE(w.min_minutes, 0) THEN 1 ELSE 0 END AS short_visit,
  CASE WHEN COALESCE(v.has_violation, 0) = 1 AND COALESCE(v.photo_count, 0) = 0 THEN 1 ELSE 0 END AS violation_no_photo,
  CAST(round((julianday(v.checkin_at) - julianday(v.scheduled_end || l.tz_offset)) * 1440.0) AS INTEGER) AS minutes_after_slot_end
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN lots l               ON l.lot_id = wl.lot_id
JOIN associations a       ON a.association_id = w.association_id
LEFT JOIN inspectors k    ON k.inspector_id = v.inspector_id
WHERE v.status = 'completed'
  AND (
       v.checkin_at IS NULL
    OR julianday(v.checkin_at) > julianday(v.scheduled_end || l.tz_offset)
    OR julianday(v.checkin_at) < julianday(v.scheduled_start || l.tz_offset, '-15 minutes')
    OR (v.duration_minutes IS NOT NULL AND v.duration_minutes < COALESCE(w.min_minutes, 0))
    OR (COALESCE(v.has_violation, 0) = 1 AND COALESCE(v.photo_count, 0) = 0)
  )
ORDER BY CASE v.qa_status WHEN 'pending' THEN 0 ELSE 1 END, v.scheduled_start;

-- One row per wave: how many visits are required, assigned, completed,
-- approved, how many found a violation, percent complete (approved / required),
-- and days left in the wave.
CREATE VIEW IF NOT EXISTS wave_progress AS
SELECT
  w.wave_id,
  w.wave_name,
  a.association_id,
  a.association_name,
  w.status,
  w.wave_start,
  w.wave_end,
  CAST(julianday(w.wave_end) - julianday(date('now')) AS INTEGER)            AS days_left,
  (SELECT COUNT(*) FROM wave_lots wl WHERE wl.wave_id = w.wave_id AND wl.is_active = 1) AS lot_count,
  (SELECT COALESCE(SUM(wl.visits_required), 0) FROM wave_lots wl WHERE wl.wave_id = w.wave_id AND wl.is_active = 1) AS visits_required,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'open')                    AS visits_open,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'assigned')                AS visits_assigned,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'completed')               AS visits_completed,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'completed' AND v.qa_status = 'approved') AS visits_approved,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'completed' AND COALESCE(v.has_violation, 0) = 1) AS violations_found,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'no_show')                 AS visits_no_show,
  (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
     WHERE wl.wave_id = w.wave_id AND v.status = 'completed' AND v.qa_status = 'pending') AS visits_qa_pending,
  CASE WHEN (SELECT COALESCE(SUM(wl.visits_required), 0) FROM wave_lots wl WHERE wl.wave_id = w.wave_id AND wl.is_active = 1) = 0 THEN 0
       ELSE round(100.0 *
            (SELECT COUNT(*) FROM visits v JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
               WHERE wl.wave_id = w.wave_id AND v.status = 'completed' AND v.qa_status = 'approved')
            / (SELECT SUM(wl.visits_required) FROM wave_lots wl WHERE wl.wave_id = w.wave_id AND wl.is_active = 1), 1)
  END AS pct_complete
FROM inspection_waves w
JOIN associations a ON a.association_id = w.association_id
ORDER BY w.status = 'active' DESC, w.wave_end;

-- Completed visits with a violation whose board-pack line has not been
-- written yet. "Export the Oakridge board pack" reads this, calls form_export
-- + shift_status, then sets exported_at.
CREATE VIEW IF NOT EXISTS violations_to_export AS
SELECT
  v.visit_id,
  w.wave_id,
  w.wave_name,
  a.association_id,
  a.association_name,
  a.billing_email,
  l.lot_id,
  l.lot_code,
  l.lot_label,
  l.address || COALESCE(', ' || l.city, '') || COALESCE(' ' || l.postal, '') AS street_address,
  v.scheduled_start,
  v.checkin_at,
  v.checkout_at,
  v.violations,
  v.has_violation,
  v.photo_count,
  v.notes,
  v.submission_dc_id,
  v.zensched_shift_id,
  wl.zensched_event_id,
  k.inspector_name
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN lots l               ON l.lot_id = wl.lot_id
JOIN associations a       ON a.association_id = w.association_id
LEFT JOIN inspectors k    ON k.inspector_id = v.inspector_id
WHERE v.status = 'completed'
  AND COALESCE(v.has_violation, 0) = 1
  AND v.exported_at IS NULL
ORDER BY w.wave_end, l.lot_code, l.address;

-- Lots that still need a ZenSched pin, limited to ones with an open visit
-- so a leftover empty row does not clutter the list.
CREATE VIEW IF NOT EXISTS lots_needs_location AS
SELECT
  l.lot_id,
  l.lot_code,
  l.lot_label,
  l.address,
  l.city,
  l.postal,
  l.address || COALESCE(', ' || l.city, '') || COALESCE(', ' || l.region, '') || COALESCE(' ' || l.postal, '') AS street_address,
  l.access_notes,
  l.zensched_location_id,
  'loc-lot-' || l.lot_id                                                  AS loc_idempotency_key,
  COUNT(v.visit_id)                                                       AS open_visit_count,
  MIN(w.wave_end)                                                         AS first_wave_end
FROM lots l
JOIN wave_lots wl         ON wl.lot_id = l.lot_id AND wl.is_active = 1
JOIN inspection_waves w   ON w.wave_id = wl.wave_id AND w.status IN ('draft', 'active')
JOIN visits v             ON v.wave_lot_id = wl.wave_lot_id AND v.status IN ('open', 'assigned')
WHERE l.zensched_location_id IS NULL
GROUP BY l.lot_id
ORDER BY first_wave_end;

-- Approved visits not yet invoiced, grouped by association.
CREATE VIEW IF NOT EXISTS visits_to_invoice AS
SELECT
  a.association_id,
  a.association_name,
  a.billing_email,
  a.payment_terms_days,
  COUNT(v.visit_id)                                   AS visit_count,
  SUM(CASE WHEN COALESCE(v.has_violation, 0) = 1 THEN 1 ELSE 0 END) AS violation_count,
  COUNT(DISTINCT w.wave_id)                           AS wave_count,
  SUM(w.association_fee)                              AS fees_amount,
  SUM(w.association_fee)                              AS total_amount,
  MIN(date(v.scheduled_start))                        AS first_visit_date,
  MAX(date(v.scheduled_start))                        AS last_visit_date
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN associations a       ON a.association_id = w.association_id
WHERE v.status = 'completed'
  AND v.qa_status = 'approved'
  AND v.association_invoiced = 0
GROUP BY a.association_id
ORDER BY a.association_name;

-- Approved visits not yet paid to a sub inspector, grouped by inspector.
-- Owner rows (is_owner = 1) never appear.
CREATE VIEW IF NOT EXISTS inspector_pay_due AS
SELECT
  k.inspector_id,
  k.inspector_name,
  k.email,
  k.pay_handle,
  COUNT(v.visit_id)                                   AS visit_count,
  SUM(w.inspector_fee)                                AS fees_amount,
  SUM(w.inspector_fee)                                AS total_due,
  MIN(date(v.scheduled_start))                        AS first_visit_date,
  MAX(date(v.scheduled_start))                        AS last_visit_date,
  json_group_array(v.visit_id)                        AS visit_ids
FROM visits v
JOIN wave_lots wl         ON wl.wave_lot_id = v.wave_lot_id
JOIN inspection_waves w   ON w.wave_id = wl.wave_id
JOIN inspectors k         ON k.inspector_id = v.inspector_id
WHERE v.status = 'completed'
  AND v.qa_status = 'approved'
  AND v.inspector_paid = 0
  AND k.is_owner = 0
GROUP BY k.inspector_id
ORDER BY k.inspector_name;

-- Per inspector: how many visits they were given, completed, no-showed,
-- had rejected, and what share of their visits (completed or rejected) had
-- an on-time check-in (within 15 minutes before the slot start and before
-- the slot end). Use this when deciding who gets the next assignment.
CREATE VIEW IF NOT EXISTS inspector_reliability AS
SELECT
  k.inspector_id,
  k.inspector_name,
  k.home_city,
  k.is_owner,
  k.is_active,
  COUNT(v.visit_id) FILTER (WHERE v.status IN ('assigned', 'completed', 'no_show', 'rejected')) AS visits_given,
  COUNT(v.visit_id) FILTER (WHERE v.status = 'completed')                                        AS completed,
  COUNT(v.visit_id) FILTER (WHERE v.status = 'completed' AND v.qa_status = 'approved')           AS approved,
  COUNT(v.visit_id) FILTER (WHERE v.status = 'completed' AND COALESCE(v.has_violation, 0) = 1)   AS violations_found,
  COUNT(v.visit_id) FILTER (WHERE v.status = 'no_show')                                          AS no_shows,
  COUNT(v.visit_id) FILTER (WHERE v.status = 'rejected' OR (v.status = 'completed' AND v.qa_status = 'rejected')) AS rejected,
  COUNT(v.visit_id) FILTER (WHERE v.status = 'assigned')                                         AS upcoming,
  CASE WHEN COUNT(v.visit_id) FILTER (WHERE v.status IN ('completed', 'rejected') AND v.checkin_at IS NOT NULL) = 0 THEN NULL
       ELSE round(100.0 *
            COUNT(v.visit_id) FILTER (WHERE v.status IN ('completed', 'rejected') AND v.checkin_at IS NOT NULL
                                        AND julianday(v.checkin_at) >= julianday(v.scheduled_start || l.tz_offset, '-15 minutes')
                                        AND julianday(v.checkin_at) <= julianday(v.scheduled_end || l.tz_offset))
            / COUNT(v.visit_id) FILTER (WHERE v.status IN ('completed', 'rejected') AND v.checkin_at IS NOT NULL), 1)
  END AS on_time_pct,
  MAX(date(v.scheduled_start)) FILTER (WHERE v.status = 'completed')                             AS last_completed_date
FROM inspectors k
LEFT JOIN visits v    ON v.inspector_id = k.inspector_id
LEFT JOIN wave_lots wl ON wl.wave_lot_id = v.wave_lot_id
LEFT JOIN lots l      ON l.lot_id = wl.lot_id
GROUP BY k.inspector_id
ORDER BY k.is_active DESC, no_shows, k.inspector_name;

-- Unpaid association invoices with aging.
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  a.association_name,
  a.billing_email,
  i.invoice_date,
  i.due_date,
  i.visit_count,
  i.violation_count,
  i.total_amount,
  i.sent_date,
  CASE WHEN i.due_date < date('now') THEN 1 ELSE 0 END AS overdue,
  CASE WHEN i.due_date >= date('now') THEN 0
       ELSE CAST(julianday(date('now')) - julianday(i.due_date) AS INTEGER) END AS days_overdue,
  CASE WHEN i.due_date >= date('now') THEN 'current'
       WHEN julianday(date('now')) - julianday(i.due_date) <= 30 THEN '1-30'
       WHEN julianday(date('now')) - julianday(i.due_date) <= 60 THEN '31-60'
       WHEN julianday(date('now')) - julianday(i.due_date) <= 90 THEN '61-90'
       ELSE '90+' END AS aging_bucket
FROM invoices i
JOIN associations a ON a.association_id = i.association_id
WHERE i.paid = 0
ORDER BY i.due_date;
