# MangoIDE accounts

Sign in with GitHub, MangoIDE Pro (monthly subscription) and prepaid AI credits.

- Card payments happen on Stripe's hosted checkout. Card details never reach this server or the app.
- Session tokens are stored only as SHA-256 hashes; GitHub tokens are encrypted (AES-256-GCM).
- Stripe webhooks are signature-verified, and credits use a ledger keyed by the Stripe event so nothing counts twice.

## Variables (set in Railway)

| Name | What |
| --- | --- |
| `DATABASE_URL` | From the Railway Postgres service |
| `PUBLIC_URL` | This service's https URL |
| `TOKEN_ENC_KEY` | 32 random bytes, base64 (encrypts GitHub tokens) |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | From your GitHub OAuth app |
| `STRIPE_SECRET_KEY` | `sk_test_…` while testing, `sk_live_…` when ready |
| `STRIPE_WEBHOOK_SECRET` | `whsec_…` from the Stripe webhook for `/stripe/webhook` |
| `ANTHROPIC_API_KEY` | Your key, used only for customers paying with credits |
| `PRO_PRICE_CENTS` | Pro price per month (default 499) |
| `AI_MARKUP` | Credit price multiplier over Anthropic's cost (default 1.5) |
| `TOPUP_OPTIONS` | Top-up amounts in cents (default `500,1000,2000`) |
