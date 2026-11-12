# BhoomiSetu — Farmer Procurement Slot Booking & Queue Management

A responsive React + TypeScript application prepared for Netlify deployment. It includes a farmer portal, procurement centre operations, administration screens, booking workflow, queue tracking, notifications, CSV/PDF exports and a Supabase PostgreSQL schema.

## Important: demo mode vs live mode

- **Demo mode (default):** works immediately without credentials. It uses fictional seed data and browser storage so you can explore the experience. The header visibly labels this as Demo mode. Demo data is local to that browser and is not shared between people or devices. Do not use it for real procurement operations.
- **Live cloud mode:** requires a Supabase project, the SQL schema in `supabase/schema.sql`, and environment variables. The SQL includes a transaction-safe `create_booking` RPC that locks the selected slot before checking capacity, preventing two concurrent users from taking the last place. The supplied UI is a front-end starter; see the production checklist below before accepting real bookings.

## Run locally

1. Install Node.js 20 or newer.
2. In this folder run `npm install`.
3. Run `npm run dev` and open the local URL shown in the terminal.
4. Run `npm run build` to create the production bundle in `dist/`.

## Deploy to Netlify

1. Create a GitHub repository and push this project folder.
2. In Netlify choose **Add new site → Import an existing project** and select the repository.
3. Build command: `npm run build`; publish directory: `dist`. `netlify.toml` already contains these settings.
4. Deploy. Netlify will provide a public `https://…netlify.app` URL. You can set a custom domain later.

### Connect Supabase

1. Create a Supabase project.
2. Open **SQL Editor** and run `supabase/schema.sql`.
3. In Supabase Authentication, enable Phone authentication and configure an SMS OTP provider if you want real phone verification. For a production app, prefer verified phone OTP rather than password-only phone sign-in.
4. In Netlify → Site configuration → Environment variables, add:
   - `VITE_SUPABASE_URL` = your project URL
   - `VITE_SUPABASE_ANON_KEY` = your public anon key
5. Trigger a new deploy.
6. Promote trusted staff/admin accounts and assign centre access from the Supabase SQL editor. Never let a public registration form choose staff/admin roles.

## Production checklist before real use

This package is a deployable demonstration starter, not a certified government procurement system. Before live operations, complete and independently test the following:

- Connect every dashboard query and mutation to Supabase tables/RPCs; the booking RPC and RLS schema are supplied as the backend foundation.
- Configure verified phone authentication, password recovery, rate limiting, email/SMS provider and account lifecycle.
- Seed verified centres, crops, operating days and dated time slots. The public demo centre data is fictional.
- Add server-side role provisioning and staff-centre assignment workflows. Do not grant roles from client-supplied metadata.
- Add real-time subscriptions for bookings, queue changes and announcements, and server-calculated wait estimates.
- Complete staff/admin CRUD, audit logging, report reconciliation, data retention and privacy notices.
- Review all RLS policies with a Supabase security advisor and penetration test before handling farmer personal data.

## Demo access

Choose Farmer / Staff / Admin on the login screen. For the seeded farmer accounts, use mobile `9876543210` (or `9876543211` etc.) and any password of at least 6 characters. Staff and Admin are demonstration role previews. This demo login is not authentication and must not be used as production access control.
