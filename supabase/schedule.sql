-- Run only after the Edge Function and secrets are configured.
-- Store the SAME random JOB_SECRET in Edge Function Secrets and Vault via the dashboard.
-- Vault names: letterloop_project_url (https://YOUR-PROJECT.supabase.co), letterloop_job_secret.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
select cron.schedule('letterloop-reminders','7,22,37,52 * * * *', $job$
 select net.http_post(
  url:=(select decrypted_secret from vault.decrypted_secrets where name='letterloop_project_url')||'/functions/v1/reminders',
  headers:=jsonb_build_object('Content-Type','application/json','x-job-secret',(select decrypted_secret from vault.decrypted_secrets where name='letterloop_job_secret')),
  body:='{}'::jsonb,
  timeout_milliseconds:=120000
 );
$job$);
-- Bound scheduler log storage; never remove group records or replies.
select cron.schedule('letterloop-cron-history','41 3 * * *', $job$
 delete from cron.job_run_details where end_time < now()-interval '14 days';
$job$);
