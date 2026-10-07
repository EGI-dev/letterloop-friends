# Verification record — 7 October 2026

- Local JavaScript syntax checks passed.
- 13 PostgreSQL/reminder tests passed, including outsider rejection, private drafts, owner permissions, stale saves, pause/resume, overdue rounds, leased jobs, unauthorised dispatch and provider failures.
- Browser acceptance used the actual database functions through the local PGlite harness, with synthetic email-code verification and no outgoing email. An owner created a group and invitation; a mate joined and proposed a question. The mate could not read the owner’s private draft. Both submitted stories appeared in the shared newsletter. Compilation archived both stories and placed the mate’s custom question in the next round. The owner’s draft survived sign-out and sign-in.
- Desktop layout was inspected. The browser viewport override did not take effect, so a phone viewport was not verified in this session.
- GitHub Pages is published at https://egi-dev.github.io/letterloop-friends/ and connected to the live Supabase project. The deployment workflow passed.
- Both database migrations were installed in Supabase. Anonymous calls to `ll_state`, `ll_tick`, and `ll_claim_email` returned HTTP 401 with permission denied.
- Custom Brevo SMTP and both sign-up/sign-in code templates were saved. The initial sign-in attempt was blocked by Brevo's SMTP IP allowlist; the owner approved adding the single observed Supabase server address. A subsequent sign-in request succeeded. Inbox receipt and completed sign-in are still awaiting owner verification.
- The `reminders` Edge Function is deployed with private server secrets. Requests without the scheduler secret return 401; authenticated requests return 200. A database `pg_net` request using Vault secrets also returned 200 with no failed jobs.
- The 15-minute reminder cron job and daily log cleanup are installed and active. A naturally scheduled execution and an actual reminder delivery are still awaiting verification.
- Two real identities, completed live sign-in, and reminder inbox delivery remain unverified before inviting mates.

No real group data or live email was created by the local acceptance harness. Credentials belong only in the ignored local configuration and Supabase server settings.
