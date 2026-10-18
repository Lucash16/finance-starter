import "server-only"
import { readOnly } from "@/lib/db"
import { getContext } from "./common"

export async function getSyncHealth() {
  return readOnly(async tx => {
    const context = await getContext(tx)
    const rows = await tx<Record<string, unknown>[]>`select s.item_pluggy_id,s.institution_name,s.item_status,s.execution_status,s.last_updated_at::text,s.last_sync_started_at::text,s.last_sync_finished_at::text,s.last_sync_status,coalesce(w.pending_webhooks_exact,0)::int pending_webhooks_exact from finance.sync_health s left join (select item_pluggy_id,count(*) filter(where status in ('received','failed') or (status='processing' and updated_at<now()-interval '10 minutes')) pending_webhooks_exact from finance.webhook_events group by item_pluggy_id) w using(item_pluggy_id) order by s.institution_name`
    return { context, rows }
  })
}
