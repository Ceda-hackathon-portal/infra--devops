-- Demo programme for the CEDA hackathon prototype. Fictional configuration, not CEDA-approved rules.
-- backend-api exposes no endpoint to create programmes, so an operator seeds one directly.
-- The fixed IDs are what the front-end build needs:
--   VITE_CEDA_PROGRAMME_ID=6f1c2a10-0d1e-4c6a-9b51-ced400000001
--   VITE_CEDA_PROGRAMME_VERSION_ID=6f1c2a10-0d1e-4c6a-9b51-ced400000002
-- Safe to re-run. programme_versions rows are immutable (trigger), so a change means a new version row.

BEGIN;

INSERT INTO programmes (id, code, name)
VALUES ('6f1c2a10-0d1e-4c6a-9b51-ced400000001', 'CEDA-INNOVATION-2026', 'CEDA Innovation Challenge 2026')
ON CONFLICT (id) DO NOTHING;

INSERT INTO programme_versions (id, programme_id, version, published_at, opens_at, closes_at, config)
VALUES (
  '6f1c2a10-0d1e-4c6a-9b51-ced400000002',
  '6f1c2a10-0d1e-4c6a-9b51-ced400000001',
  1,
  '2026-11-01T00:00:00+02:00',  -- published
  '2026-11-01T00:00:00+02:00',  -- intake opens
  '2027-03-31T23:59:59+02:00',  -- intake closes (exclusive); covers judging on 3 Dec 2026
  '{"themes": ["digital", "sustainable", "inclusive"]}'::jsonb  -- must match front-end src/data/portal.js theme ids
)
ON CONFLICT (id) DO NOTHING;

COMMIT;
