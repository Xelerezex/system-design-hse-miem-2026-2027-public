-- Booking-owned paid seat counter, backfilled from confirmed holds.
-- All later updates happen inside the same transaction that confirms the holds.
CREATE TABLE booking_sector_sales (
    event_id uuid NOT NULL,
    sector_id uuid NOT NULL,
    sold_count bigint NOT NULL DEFAULT 0 CHECK (sold_count >= 0),
    PRIMARY KEY (event_id, sector_id)
);

INSERT INTO booking_sector_sales (event_id, sector_id, sold_count)
SELECT event_id, sector_id, count(*)
FROM holds WHERE status = 'confirmed'
GROUP BY event_id, sector_id;
