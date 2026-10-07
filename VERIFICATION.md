# Verification record — 7 October 2026

- Local JavaScript syntax checks passed.
- 13 PostgreSQL/reminder tests passed, including outsider rejection, private drafts, owner permissions, stale saves, pause/resume, overdue rounds, leased jobs, unauthorised dispatch and provider failures.
- Browser acceptance used the actual database functions through the local PGlite harness, with synthetic email-code verification and no outgoing email. An owner created a group and invitation; a mate joined and proposed a question. The mate could not read the owner’s private draft. Both submitted stories appeared in the shared newsletter. Compilation archived both stories and placed the mate’s custom question in the next round. The owner’s draft survived sign-out and sign-in.
- Desktop layout was inspected. The browser viewport override did not take effect, so a phone viewport was not verified in this session.
- GitHub Pages was enabled; the workflow passed and published the setup-status landing page. Public Supabase configuration remains empty until the real project is connected.
- Live Supabase authentication, two real identities, SMTP delivery, Edge deployment and scheduled delivery remain unverified and are required before inviting mates.

No real group data or live email was created by the local acceptance harness. Credentials belong only in the ignored local configuration and Supabase server settings.
