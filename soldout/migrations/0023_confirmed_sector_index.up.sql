-- Support a paid-seat count within one event sector without scanning unrelated holds.
CREATE INDEX CONCURRENTLY IF NOT EXISTS holds_confirmed_sector_idx
    ON holds (event_id, sector_id) WHERE status = 'confirmed';
