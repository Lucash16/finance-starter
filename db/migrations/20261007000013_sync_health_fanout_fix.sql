CREATE OR REPLACE VIEW finance.sync_health WITH (security_invoker=true) AS
SELECT i.pluggy_id item_pluggy_id,
 i.institution_name,
 i.status item_status,
 i.execution_status,
 i.last_updated_at,
 sr.last_sync_started_at,
 sr.last_sync_finished_at,
 sr.last_sync_status,
 wh.pending_webhooks
FROM finance.items i
LEFT JOIN LATERAL (
 SELECT max(s.started_at) last_sync_started_at,
  max(s.finished_at) last_sync_finished_at,
  (array_agg(s.status ORDER BY s.started_at DESC))[1] last_sync_status
 FROM finance.sync_runs s
 WHERE s.item_id = i.id
) sr ON true
LEFT JOIN LATERAL (
 SELECT count(w.id) FILTER(
  WHERE w.status IN ('received','failed')
   OR (w.status='processing' AND w.updated_at<now()-interval '10 minutes')
 ) pending_webhooks
 FROM finance.webhook_events w
 WHERE w.item_pluggy_id = i.pluggy_id
) wh ON true;


DO $sync_health_grants$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT ON finance.sync_health TO service_role;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.sync_health TO finance_reader;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT SELECT ON finance.sync_health TO supabase_read_only_user;
 END IF;
END $sync_health_grants$;
