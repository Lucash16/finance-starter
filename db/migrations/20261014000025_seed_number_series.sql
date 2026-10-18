-- Shared projection indices, not personal configuration.
INSERT INTO finance.number_series (n)
SELECT generate_series(1, 60)
ON CONFLICT (n) DO NOTHING;
