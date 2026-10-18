CREATE OR REPLACE FUNCTION finance.assign_bill_cycle(p_posting date, p_account_id uuid, p_closing_day integer, p_due_day integer)
RETURNS TABLE(closing_date date, due_date date, bill_id uuid)
LANGUAGE sql STABLE SET search_path=pg_catalog,finance AS $$
 WITH params AS (
  SELECT p_closing_day IS NOT NULL AND p_due_day IS NOT NULL
   AND p_due_day>p_closing_day AND p_closing_day<=10 AS same_month_due
 ), nominal AS (
  SELECT CASE
   WHEN s.same_month_due THEN finance.clamp_month_day(date_trunc('month', p_posting)::date, p_closing_day)
   ELSE finance.posting_closing_date(p_posting, p_closing_day)
  END AS closing_date
  FROM params s
 ), bills AS (
  SELECT b.id, b.closing_date, b.due_date,
   lag(b.closing_date) OVER (ORDER BY b.closing_date, b.id) prev_closing
  FROM finance.credit_card_bills b
  WHERE p_account_id IS NOT NULL AND b.account_id=p_account_id AND b.closing_date IS NOT NULL
 ), official AS (
  SELECT b.id, b.closing_date, b.due_date
  FROM bills b
  CROSS JOIN nominal n
  CROSS JOIN params s
  WHERE p_posting IS NOT NULL AND (
   (s.same_month_due
    AND date_trunc('month', b.closing_date)=date_trunc('month', p_posting)
    AND abs(b.closing_date-n.closing_date)<=4)
   OR (NOT s.same_month_due
    AND p_posting<=b.closing_date
    AND p_posting>coalesce(b.prev_closing, (b.closing_date-40))
    AND (b.prev_closing IS NOT NULL OR n.closing_date IS NULL OR abs(b.closing_date-n.closing_date)<=4))
  )
  ORDER BY b.closing_date, b.id
  LIMIT 1
 )
 SELECT coalesce(o.closing_date, n.closing_date),
  coalesce(o.due_date, finance.cycle_due_date(n.closing_date, p_closing_day, p_due_day)),
  o.id
 FROM nominal n LEFT JOIN official o ON true
 WHERE coalesce(o.closing_date, n.closing_date) IS NOT NULL
$$;
