# Connect the live services

Do not post secret values in chat, issues, commits, or the browser configuration. Dashboard entry of a new database password or new API credential is completed by the account owner.

## 1. Supabase database

Create a **Free** organization/project in a nearby European region. Keep Data API enabled, disable automatic table grants, and enable automatic RLS. Choose and retain your database password privately.

In the project's SQL Editor, run these files in order, once on the new database:

1. `supabase/migrations/202610070001_core.sql`
2. `supabase/migrations/202610070002_jobs.sql`

Keep the `private` schema out of Data API exposed schemas. Only the `public.ll_*` functions are exposed. Do not grant clients direct table access or change these functions to unrestricted security definers.

## 2. GitHub Pages

The repository is public. Under Settings → Pages select **GitHub Actions** as the deployment source. Under Settings → Secrets and variables → Actions → Variables add:

- `SUPABASE_URL`: the project's HTTPS URL
- `SUPABASE_ANON_KEY`: its publishable key (or legacy `anon` key)

These two values are public by design. Never use an `sb_secret_*` or `service_role` key here. Run the Validate and publish workflow. The group database stays private even though the application source is public.

## 3. Email sign-in with Brevo

Finish any Brevo phone/account verification and verify a sender address under Settings → Senders. Use the free plan. Configure Supabase Auth → Email → SMTP with Brevo's SMTP server details shown in Settings → SMTP & API:

- host: `smtp-relay.brevo.com`
- port: `587`
- username: the SMTP login shown by Brevo
- password: a **Brevo SMTP key**, not its HTTP API key
- sender email: the verified sender
- sender name: `Your people`

Credentials go directly into Supabase, never into the Pages repository. Enable email sign-in and new-user signup. Set Auth URL configuration to the final GitHub Pages URL. Configure the **Magic Link** email template to include `{{ .Token }}` as a visible one-time code (the app uses codes, not callback links). Use the template under `supabase/templates/magic-link.html`. Retain a short OTP expiry and sensible Auth rate limits; six-digit code verification must stay throttled. Supabase's default mail service is restricted to project-team addresses and cannot serve mates reliably, so custom SMTP is required.

Official guides: [email OTP](https://supabase.com/docs/guides/auth/auth-email-passwordless), [SMTP limitations and setup](https://supabase.com/docs/guides/auth/auth-smtp), [verified senders](https://help.brevo.com/hc/en-us/articles/208836149-Create-a-new-sender-From-name-and-From-email).

## 4. Scheduled updates

Deploy `supabase/functions/reminders/index.ts` as a Supabase Edge Function named `reminders`. Disable the built-in legacy JWT verification **only for this function**; the code independently requires a matching `x-job-secret` header. Without it every request is rejected. `supabase/config.toml` contains this setting for CLI deployments.

Set these **server secrets** in Supabase Edge Function Secrets:

- `BREVO_API_KEY`: Brevo transactional HTTP API key
- `BREVO_SENDER_EMAIL`: verified sender
- `BREVO_SENDER_NAME`: `Your people`
- `APP_URL`: final GitHub Pages URL including its repository path and trailing slash
- `JOB_SECRET`: a long cryptographically random secret, used only by this scheduler

Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the function itself. Do not publish or manually copy those to the frontend.

Under Supabase Vault add `letterloop_project_url` (the public project URL) and `letterloop_job_secret` (the **same JOB_SECRET**). Then run `supabase/schedule.sql`. It enables pg_cron/pg_net, invokes the function hourly and removes old cron logs. Restrict Vault access to database administrators. Enabling a scheduler without secrets/SMTP is not a working reminder service.

The function is deliberately self-contained, so it can also be deployed through the Supabase dashboard's function editor. The CLI alternative is `supabase functions deploy reminders --project-ref YOUR_REF --no-verify-jwt` after authorized login.

## 5. Live acceptance check

1. Request an email code at the published URL; verify it reaches the owner's real inbox and signs in.
2. Create a real group and copy an invitation. Open it in a second session; sign in with a different email and join. Verify outsiders see no group data.
3. Suggest a question from the second member. Save a private draft; verify the owner cannot see it. Submit all answers; verify both sessions see them. Check stale edits are rejected.
4. Compile the round. Both members must see its archive and the next round must use the proposed question.
5. Invoke the reminder function with its scheduler header, verify HTTP success, accepted jobs in database status, and actual update delivery in Brevo and the recipient inbox. Observe the cron job history for a successful scheduled invocation.
6. Turn off updates, revoke the test invite, and verify no new access or queued mail for opted-out members. Do not expose synthetic test users in the real group.

If sign-in, delivery, scheduler or privacy checks fail, the service is not ready to share. Check logs privately; redact tokens and recipient details before sharing diagnostics.
