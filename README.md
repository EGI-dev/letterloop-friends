# Your people, in the loop

An independent Letterloop-inspired private group newsletter for friends. The website runs on GitHub Pages; shared data and email sign-in run on Supabase. Supabase Cron advances rounds and an Edge Function sends opted-in updates through Brevo.

Members join by an expiring invitation, verify their own email, suggest questions, save private drafts, and share answers with their group. Everyone in a group can read submitted answers immediately and browse completed newsletters. Owners manage invitations, contributors/readers, questions, deadlines, cadence and timezone. Members can disable email, export the data available to them and leave a group. There are no seeded users or pretend shared replies.

## Run and verify

Requires Node 22+ for development. The published site has no JavaScript package dependencies.

```sh
npm ci --ignore-scripts
npm run check
npm test
SUPABASE_URL=https://YOUR_PROJECT.supabase.co SUPABASE_ANON_KEY=YOUR_PUBLIC_KEY npm run build
python3 -m http.server 4173 --directory web
```

The database tests run the actual migrations in a local PostgreSQL engine (PGlite), with anonymous, member, outsider and service roles. They exercise private drafts, invitation access, owner permissions, shared replies, stale-save protection, deadlines, pause/resume and email leases. A live Supabase/email smoke test is also required before inviting real mates; see [SETUP.md](SETUP.md).

## Privacy and operation

Group tables live in a private schema with RLS and no direct client table access. Exposed database functions check the signed-in identity and membership for every operation; scheduling functions are service-only. Invite tokens are random, hashed in the database, expire after seven days, and can be revoked. Only public Supabase configuration goes into the Pages build. Brevo keys, service credentials and the scheduler secret stay on Supabase. Email contains a link and deadline, never the group's answers.

The browser stores the sign-in session and an unconsumed invitation locally. Responses and questions are stored in PostgreSQL, not localStorage. Sign out on shared devices. Submitted replies are visible to everyone currently in the group, including members joining later. Drafts are visible only to their author. Owners can see member emails to manage the group. Removing a member stops their access; their previously shared stories remain in the archive.

Rounds default to a first deadline seven days away, then repeat every 7, 14 or 28 days. Owners can change the deadline. Question edits lock once any reply begins. Up to five queued member questions form the next round; otherwise three starter prompts are used. Every issue supports up to ten questions. The scheduler runs every fifteen minutes, so deadlines and reminders may be processed up to fifteen minutes late. Groups are limited to fifty people and each user can own ten groups. The app loads the latest fifty completed issues per group; older data remains in the database.

Email jobs use database uniqueness, leased claims, bounded retries and a stable provider idempotency key. A provider accepting an email does not guarantee inbox delivery, and a network timeout can still produce a duplicate after the provider's idempotency window. Failed jobs and scheduler activity are visible to owners in Settings. The reminder dispatcher caps accepted/active app messages at 260 per UTC day, reserving nominal room within Brevo's 300/day allowance for sign-in emails. Supabase Auth shares the same sender allowance and applies its own rate limits; the reserve is not an absolute total-send guarantee. More than five failed attempts needs operator attention.

## Free tier and maintenance

GitHub Pages supports public repository hosting. Supabase's free plan currently includes a 500 MB database and 50,000 monthly active users, and free projects may pause after inactivity. Brevo currently allows 300 emails/day. This is suitable for a small circle of friends, not a promise of unlimited or uninterrupted free hosting. No card or paid domain is required for the initial setup; a verified free email sender can work but has weaker delivery than an authenticated domain. Check spam folders and the provider's transaction log during setup.

Export important newsletters regularly. Supabase free projects do not include downloadable automatic backups; use PostgreSQL dumps or dashboard exports. Keep email-job and cron logs bounded, watch database storage and provider limits, and apply reviewed migrations rather than exposing tables. The app has no attachments, marketing campaigns or analytics trackers.

Official references: [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits), [Supabase pricing](https://supabase.com/pricing), [Supabase free project pausing](https://supabase.com/docs/guides/platform/free-project-pausing), [Brevo free limits](https://help.brevo.com/hc/en-us/articles/208580669-FAQs-What-are-the-limits-of-the-Free-plan).

This project is independent of Letterloop. The reference visual identity is used for this recreation; choose an original name/logo before presenting it as a separate public product.
