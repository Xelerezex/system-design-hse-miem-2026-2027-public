DROP TRIGGER IF EXISTS events_create_sector_prices ON events;
DROP FUNCTION IF EXISTS catalog_create_sector_prices();
DROP TABLE IF EXISTS sector_prices;
ALTER TABLE holds DROP COLUMN IF EXISTS sold_count_at_hold;
ALTER TABLE holds DROP COLUMN IF EXISTS price_minor;
ALTER TABLE holds DROP COLUMN IF EXISTS sector_id;
