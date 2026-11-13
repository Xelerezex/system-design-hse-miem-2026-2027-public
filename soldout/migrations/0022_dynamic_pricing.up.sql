-- V2: catalog owns sector pricing, booking owns immutable hold prices and sector identity.
CREATE TABLE sector_prices (
    event_id uuid NOT NULL REFERENCES events (id),
    sector_id uuid NOT NULL REFERENCES sectors (id),
    base_price_minor bigint NOT NULL CHECK (base_price_minor > 0),
    step_seats integer NOT NULL CHECK (step_seats > 0),
    step_percent integer NOT NULL CHECK (step_percent BETWEEN 0 AND 100),
    PRIMARY KEY (event_id, sector_id)
);
COMMENT ON TABLE sector_prices IS 'catalog: rules for dynamic pricing for an event sector';

-- Existing events are migrated as well as events created after this migration.
INSERT INTO sector_prices (event_id, sector_id, base_price_minor, step_seats, step_percent)
SELECT e.id, s.id, 500000, 100, 10 FROM events e JOIN sectors s ON s.venue_id = e.venue_id;

CREATE FUNCTION catalog_create_sector_prices() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO sector_prices (event_id, sector_id, base_price_minor, step_seats, step_percent)
    SELECT NEW.id, s.id, 500000, 100, 10 FROM sectors s WHERE s.venue_id = NEW.venue_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER events_create_sector_prices
AFTER INSERT ON events FOR EACH ROW EXECUTE FUNCTION catalog_create_sector_prices();

ALTER TABLE holds ADD COLUMN sector_id uuid;
ALTER TABLE holds ADD COLUMN price_minor bigint;
ALTER TABLE holds ADD COLUMN sold_count_at_hold integer NOT NULL DEFAULT 0;

-- Existing hold/paid orders must remain valid. Source sector is stable even for released holds.
UPDATE holds h SET sector_id = s.sector_id FROM seats s WHERE h.seat_id = s.id;

-- Historical orders used one fixed ticket price. Recover it from the actual order amount
-- instead of guessing the value of TICKET_PRICE_MINOR at the time of sale.
WITH historic AS (
    SELECT oi.hold_id, round(o.amount * 100 / count(*) OVER (PARTITION BY o.id))::bigint AS price_minor
    FROM order_items oi JOIN orders o ON o.id = oi.order_id
)
UPDATE holds h SET price_minor = historic.price_minor FROM historic WHERE historic.hold_id = h.id;
UPDATE holds SET price_minor = 500000 WHERE price_minor IS NULL;
ALTER TABLE holds ALTER COLUMN sector_id SET NOT NULL;
ALTER TABLE holds ALTER COLUMN price_minor SET NOT NULL;
ALTER TABLE holds ADD CONSTRAINT holds_price_minor_positive CHECK (price_minor > 0);
