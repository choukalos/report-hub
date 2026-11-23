-- ============================================================
-- Houston Medical 2026 dashboard seed (report-hub)
--
-- Seeds the houston-medical-2026 dashboard into the `reports`
-- database: saved queries (hou_*), the dashboard row, and 10
-- cards (4 KPI labels, notes, group table, monthly chart, pie,
-- all-tagged-transactions table, excluded/ambiguous table).
--
-- Data plane: finance.trips + finance.trip_transactions
-- (data-hub migration 0003_trips.sql); tagging rules live in
-- data-hub scripts/trips/tag_houston_medical_2026.sql (re-run
-- after each bank ingest; idempotent).
--
-- IDEMPOTENT: delete-then-insert per slug/query name; safe to
-- re-run. Apply manually as dh_reports (NOT via the migration
-- runner):
--   mysql -h <mysql-host> -u dh_reports -p reports < seed/v3_houston_medical_2026.sql
--
-- Conventions: spend = SUM of negative (debit) amounts shown as
-- positive; tables present integer cents via the "currency"
-- format; chart values are dollars (divided by 100 in SQL).
-- ============================================================

DELETE FROM dashboards WHERE slug = 'houston-medical-2026';
DELETE FROM queries WHERE name IN ('hou_trip_total', 'hou_trip_total_stay', 'hou_trip_total_medical', 'hou_trip_txn_count', 'hou_trip_group_totals', 'hou_trip_monthly', 'hou_trip_pie', 'hou_trip_txns', 'hou_trip_excluded');

-- 1) saved queries
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_total', 'SELECT COALESCE(SUM(-t.amount_cents), 0)
FROM transactions t
JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
WHERE t.amount_cents < 0', NULL, 'Total Houston Medical 2026 trip spend (cents), all tagged transactions');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_total_stay', 'SELECT COALESCE(SUM(-t.amount_cents), 0)
FROM transactions t
JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
WHERE t.amount_cents < 0
  AND NOT (t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'')', NULL, 'Trip spend (cents) excluding MD Anderson medical bills');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_total_medical', 'SELECT COALESCE(SUM(-t.amount_cents), 0)
FROM transactions t
JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
WHERE t.amount_cents < 0
  AND (t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'')', NULL, 'MD Anderson medical spend (cents): MyChart bills + MDACC pharmacy');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_txn_count', 'SELECT COUNT(*)
FROM transactions t
JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
WHERE t.amount_cents < 0', NULL, 'Count of tagged Houston Medical 2026 transactions');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_group_totals', 'SELECT grp, COUNT(*) txn_count, SUM(cents) total_cents
FROM (
  SELECT CASE
      WHEN t.description LIKE ''%AIRBNB%'' OR (t.description LIKE ''%MARRIOTT%'' AND t.description LIKE ''%HOUSTON%'') THEN ''Lodging (Airbnb / Marriott)''
      WHEN t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'' THEN ''Medical (MD Anderson)''
      WHEN t.payee LIKE ''%Harris County Toll%'' OR t.payee IN (''Shell'', ''Phillips 66'') OR c.name = ''Gas'' OR (c.name = ''Auto & Transport'' AND t.description REGEXP ''GAS/CARWASH'') THEN ''Gas & tolls''
      WHEN c.name IN (''Restaurants'', ''Fast Food'', ''Coffee Shops'', ''Food & Dining'', ''Alcohol & Bars'') THEN ''Dining out''
      WHEN c.name = ''Groceries'' THEN ''Groceries''
      WHEN c.name = ''Parking'' OR t.description LIKE ''%MAYS GARAG%'' THEN ''Parking''
      ELSE ''Other (Houston metro)''
    END grp, -t.amount_cents cents
  FROM transactions t
  LEFT JOIN categories c ON c.id = t.category_id
  JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
  WHERE t.amount_cents < 0
) g
GROUP BY grp
ORDER BY FIELD(grp, ''Lodging (Airbnb / Marriott)'', ''Medical (MD Anderson)'', ''Gas & tolls'', ''Dining out'', ''Groceries'', ''Parking'', ''Other (Houston metro)'')', NULL, 'Tagged trip spend grouped (lodging / medical / gas / dining / groceries / parking / other)');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_monthly', 'WITH RECURSIVE months AS (
  SELECT ''2026-07-01'' mstart, 1 n
  UNION ALL
  SELECT DATE_ADD(mstart, INTERVAL 1 MONTH), n + 1
  FROM months WHERE n < 6
),
tagged AS (
  SELECT t.txn_date, -t.amount_cents cents,
         (t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'') is_med
  FROM transactions t
JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
  WHERE t.amount_cents < 0
)
SELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym, ''Stay & travel'' label,
       ROUND(COALESCE(SUM(CASE WHEN tg.is_med = 0 THEN tg.cents END), 0) / 100, 2) amount
FROM months mo
LEFT JOIN tagged tg ON tg.txn_date >= mo.mstart AND tg.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)
GROUP BY mo.mstart
UNION ALL
SELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym, ''Medical (MD Anderson)'' label,
       ROUND(COALESCE(SUM(CASE WHEN tg.is_med = 1 THEN tg.cents END), 0) / 100, 2) amount
FROM months mo
LEFT JOIN tagged tg ON tg.txn_date >= mo.mstart AND tg.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)
GROUP BY mo.mstart
ORDER BY FIELD(label, ''Stay & travel'', ''Medical (MD Anderson)''), ym', NULL, 'Monthly tagged trip spend Jul-Dec 2026, dollars, stay/travel vs medical series');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_pie', 'SELECT grp, ROUND(SUM(cents) / 100, 2) amount
FROM (
  SELECT CASE
      WHEN t.description LIKE ''%AIRBNB%'' OR (t.description LIKE ''%MARRIOTT%'' AND t.description LIKE ''%HOUSTON%'') THEN ''Lodging (Airbnb / Marriott)''
      WHEN t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'' THEN ''Medical (MD Anderson)''
      WHEN t.payee LIKE ''%Harris County Toll%'' OR t.payee IN (''Shell'', ''Phillips 66'') OR c.name = ''Gas'' OR (c.name = ''Auto & Transport'' AND t.description REGEXP ''GAS/CARWASH'') THEN ''Gas & tolls''
      WHEN c.name IN (''Restaurants'', ''Fast Food'', ''Coffee Shops'', ''Food & Dining'', ''Alcohol & Bars'') THEN ''Dining out''
      WHEN c.name = ''Groceries'' THEN ''Groceries''
      WHEN c.name = ''Parking'' OR t.description LIKE ''%MAYS GARAG%'' THEN ''Parking''
      ELSE ''Other (Houston metro)''
    END grp, -t.amount_cents cents
  FROM transactions t
  LEFT JOIN categories c ON c.id = t.category_id
  JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
  WHERE t.amount_cents < 0
) g
GROUP BY grp
ORDER BY FIELD(grp, ''Lodging (Airbnb / Marriott)'', ''Medical (MD Anderson)'', ''Gas & tolls'', ''Dining out'', ''Groceries'', ''Parking'', ''Other (Houston metro)'')', NULL, 'Tagged trip spend by group, dollars (pie)');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_txns', 'SELECT t.txn_date date, t.payee, t.description,
       CASE
      WHEN t.description LIKE ''%AIRBNB%'' OR (t.description LIKE ''%MARRIOTT%'' AND t.description LIKE ''%HOUSTON%'') THEN ''Lodging (Airbnb / Marriott)''
      WHEN t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'' THEN ''Medical (MD Anderson)''
      WHEN t.payee LIKE ''%Harris County Toll%'' OR t.payee IN (''Shell'', ''Phillips 66'') OR c.name = ''Gas'' OR (c.name = ''Auto & Transport'' AND t.description REGEXP ''GAS/CARWASH'') THEN ''Gas & tolls''
      WHEN c.name IN (''Restaurants'', ''Fast Food'', ''Coffee Shops'', ''Food & Dining'', ''Alcohol & Bars'') THEN ''Dining out''
      WHEN c.name = ''Groceries'' THEN ''Groceries''
      WHEN c.name = ''Parking'' OR t.description LIKE ''%MAYS GARAG%'' THEN ''Parking''
      ELSE ''Other (Houston metro)''
    END group_name,
       tt.tag_reason,
       -t.amount_cents amount
FROM transactions t
LEFT JOIN categories c ON c.id = t.category_id
JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''
WHERE t.amount_cents < 0
ORDER BY t.txn_date DESC, t.id DESC', NULL, 'All tagged Houston Medical 2026 transactions (newest first)');
INSERT INTO queries (name, sql_text, params, description) VALUES ('hou_trip_excluded', 'SELECT t.txn_date date, t.payee, t.description,
       CASE
         WHEN t.payee IN (''Allegiant Airlines'', ''Delta Airlines'', ''Delta'') THEN ''Flight (destination not in data - possibly trip-related)''
         WHEN t.description REGEXP ''BASTROP|WALLER|SEALY'' THEN ''Gas en route (I-10 corridor, ambiguous)''
         WHEN t.description LIKE ''HEB CURBSIDE 800-432-3113%'' THEN ''H-E-B curbside (no store location in data)''
         WHEN t.description LIKE ''%MD Anderson bills%'' THEN ''MD Anderson funding transfer (not spend)''
       END note,
       -t.amount_cents amount
FROM transactions t
LEFT JOIN categories c ON c.id = t.category_id
WHERE t.txn_date BETWEEN ''2026-07-15'' AND ''2026-12-31''
  AND t.amount_cents < 0
  AND (
        t.payee IN (''Allegiant Airlines'', ''Delta Airlines'', ''Delta'')
     OR (t.description REGEXP ''BASTROP|WALLER|SEALY'' AND c.name = ''Gas'')
     OR (t.description LIKE ''HEB CURBSIDE 800-432-3113%'' AND t.txn_date >= ''2026-10-01'')
     OR (t.description LIKE ''%MD Anderson bills%'' AND c.bucket = ''Transfer'')
  )
  AND NOT EXISTS (SELECT 1 FROM trip_transactions tt WHERE tt.transaction_id = t.id)
ORDER BY t.txn_date', NULL, 'Ambiguous trip-window items NOT tagged (flights, en-route gas, location-less curbside, MD Anderson funding transfer) - review list');

-- 2) dashboard
INSERT INTO dashboards (slug, title, description, section, sort_order, is_active) VALUES ('houston-medical-2026', 'Houston Medical 2026', 'Expenses tagged to the 2026 Houston medical stay (MD Anderson treatment; home base Round Rock, TX), kept separate from normal spending. Data through 2026-11-13 - re-run the tag script after each ingest. Rules: see notes card.', 'finance', 80, 1);

-- 3) cards
INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 1, 'label', 'Total - trip & stay (all tagged spend)', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(-t.amount_cents), 0)\\nFROM transactions t\\nJOIN trip_transactions tt ON tt.transaction_id = t.id\\nJOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''\\nWHERE t.amount_cents < 0", "format": "currency"}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 2, 'label', 'Stay & travel (excl. medical bills)', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(-t.amount_cents), 0)\\nFROM transactions t\\nJOIN trip_transactions tt ON tt.transaction_id = t.id\\nJOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''\\nWHERE t.amount_cents < 0\\n  AND NOT (t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'')", "format": "currency"}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 3, 'label', 'Medical (MD Anderson bills + pharmacy)', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(-t.amount_cents), 0)\\nFROM transactions t\\nJOIN trip_transactions tt ON tt.transaction_id = t.id\\nJOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''\\nWHERE t.amount_cents < 0\\n  AND (t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'')", "format": "currency"}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 4, 'label', 'Tagged transactions', NULL, '{"level": 2, "value_query": "SELECT COUNT(*)\\nFROM transactions t\\nJOIN trip_transactions tt ON tt.transaction_id = t.id\\nJOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''\\nWHERE t.amount_cents < 0", "format": "number"}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 5, 'label', 'How this is tagged', NULL, '{"level": 3, "text": "Window 2026-07-15 to 2026-12-17 (final audiology follow-up). Tagged = spend (debits) matching any rule: Houston-metro merchant location (Houston, Katy, La Grange, Cypress, Brookshire + other metro cities), MD Anderson payees (MDACC / MyChart / pharmacy), Airbnb, Harris County EZ-Tag tolls. Home (Round Rock/Austin) spending stays out. Airbnb: two bookings Oct 25 - Nov 7 and Nov 8 - Dec 11 (~$11k total per the family; the dog held the Saturday checkout). Bill 1 ($8,622.18, charged Oct 20) is in the data; bill 2 lands in the next export. Data through 2026-11-13 - re-run scripts/trips/tag_houston_medical_2026.sql (data-hub repo) after each ingest to pick up new rows."}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 6, 'table', 'Spend by group', (SELECT id FROM queries WHERE name = 'hou_trip_group_totals'), '{"formats": {"total_cents": "currency", "txn_count": "number"}, "page_size": 250}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 7, 'chart', 'Monthly trip spend (Jul - Dec 2026)', (SELECT id FROM queries WHERE name = 'hou_trip_monthly'), '{"data_query": "WITH RECURSIVE months AS (\\n  SELECT ''2026-07-01'' mstart, 1 n\\n  UNION ALL\\n  SELECT DATE_ADD(mstart, INTERVAL 1 MONTH), n + 1\\n  FROM months WHERE n < 6\\n),\\ntagged AS (\\n  SELECT t.txn_date, -t.amount_cents cents,\\n         (t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'') is_med\\n  FROM transactions t\\nJOIN trip_transactions tt ON tt.transaction_id = t.id\\nJOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''\\n  WHERE t.amount_cents < 0\\n)\\nSELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym, ''Stay & travel'' label,\\n       ROUND(COALESCE(SUM(CASE WHEN tg.is_med = 0 THEN tg.cents END), 0) / 100, 2) amount\\nFROM months mo\\nLEFT JOIN tagged tg ON tg.txn_date >= mo.mstart AND tg.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\nGROUP BY mo.mstart\\nUNION ALL\\nSELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym, ''Medical (MD Anderson)'' label,\\n       ROUND(COALESCE(SUM(CASE WHEN tg.is_med = 1 THEN tg.cents END), 0) / 100, 2) amount\\nFROM months mo\\nLEFT JOIN tagged tg ON tg.txn_date >= mo.mstart AND tg.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\nGROUP BY mo.mstart\\nORDER BY FIELD(label, ''Stay & travel'', ''Medical (MD Anderson)''), ym", "data_map": {"x": "ym", "value": "amount", "series": "label"}, "option": {"tooltip": {"trigger": "axis"}, "legend": {"data": ["Stay & travel", "Medical (MD Anderson)"]}, "grid": {"left": 70, "right": 20, "top": 40, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Stay & travel", "type": "bar", "stack": "trip", "itemStyle": {"color": "#4f8ef7"}, "data": []}, {"name": "Medical (MD Anderson)", "type": "bar", "stack": "trip", "itemStyle": {"color": "#f76f6f"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 8, 'chart', 'Group mix', (SELECT id FROM queries WHERE name = 'hou_trip_pie'), '{"data_query": "SELECT grp, ROUND(SUM(cents) / 100, 2) amount\\nFROM (\\n  SELECT CASE\\n      WHEN t.description LIKE ''%AIRBNB%'' OR (t.description LIKE ''%MARRIOTT%'' AND t.description LIKE ''%HOUSTON%'') THEN ''Lodging (Airbnb / Marriott)''\\n      WHEN t.description LIKE ''%MYCHART%'' OR t.description LIKE ''%MDACC PHARMACY%'' THEN ''Medical (MD Anderson)''\\n      WHEN t.payee LIKE ''%Harris County Toll%'' OR t.payee IN (''Shell'', ''Phillips 66'') OR c.name = ''Gas'' OR (c.name = ''Auto & Transport'' AND t.description REGEXP ''GAS/CARWASH'') THEN ''Gas & tolls''\\n      WHEN c.name IN (''Restaurants'', ''Fast Food'', ''Coffee Shops'', ''Food & Dining'', ''Alcohol & Bars'') THEN ''Dining out''\\n      WHEN c.name = ''Groceries'' THEN ''Groceries''\\n      WHEN c.name = ''Parking'' OR t.description LIKE ''%MAYS GARAG%'' THEN ''Parking''\\n      ELSE ''Other (Houston metro)''\\n    END grp, -t.amount_cents cents\\n  FROM transactions t\\n  LEFT JOIN categories c ON c.id = t.category_id\\n  JOIN trip_transactions tt ON tt.transaction_id = t.id\\nJOIN trips tr ON tr.id = tt.trip_id AND tr.slug = ''houston-medical-2026''\\n  WHERE t.amount_cents < 0\\n) g\\nGROUP BY grp\\nORDER BY FIELD(grp, ''Lodging (Airbnb / Marriott)'', ''Medical (MD Anderson)'', ''Gas & tolls'', ''Dining out'', ''Groceries'', ''Parking'', ''Other (Houston metro)'')", "data_map": {"x": "grp", "value": "amount"}, "option": {"tooltip": {"trigger": "item"}, "legend": {"orient": "vertical", "left": "left", "top": "middle"}, "series": [{"name": "Spend", "type": "pie", "radius": ["28%", "62%"], "center": ["62%", "50%"], "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 9, 'table', 'All tagged transactions', (SELECT id FROM queries WHERE name = 'hou_trip_txns'), '{"formats": {"date": "date", "amount": "currency"}, "page_size": 250}'),
  ((SELECT id FROM dashboards WHERE slug = 'houston-medical-2026'), 10, 'table', 'Excluded - ambiguous (review)', (SELECT id FROM queries WHERE name = 'hou_trip_excluded'), '{"formats": {"date": "date", "amount": "currency"}, "page_size": 250}');
