# Portfolio Tracker

A cloud-hosted personal investment dashboard. Paste or upload brokerage data (Fidelity, Robinhood, Morgan Stanley); the system builds an immutable historical record, enriches it with LLM-powered ticker intelligence fed through a Telegram bot, and surfaces a sector-tagged, account-aware view of the full portfolio with conviction scores and target-price intelligence.

**Deployed publicly on Cloudflare** — accessible from any browser, single-user, always-on.

## Status

Early-stage. The full specification lives in [`spec.md`](./spec.md). Visual design references are in [`overview.html`](./overview.html) and [`user-flows-design.html`](./user-flows-design.html). No application code has been committed yet.

## Stack (planned)

- **Frontend:** React SPA on Cloudflare Pages
- **API:** Cloudflare Worker (TypeScript + Hono)
- **DB:** Cloudflare D1 (SQLite)
- **Object storage:** Cloudflare R2 (raw brokerage files)
- **Async work:** Cloudflare Queues + Cron
- **LLM:** Anthropic API (Sonnet + Opus)
- **Market data:** Polygon.io
- **Bot:** Telegram (webhook → Worker)

See [`spec.md`](./spec.md) for the full architecture, page-by-page UX, database schema, ingestion pipeline, and rebalance logic.

## Layout

```
.
├── spec.md                       # full specification — source of truth
├── overview.html                 # dashboard visual reference
├── user-flows-design.html        # user-flow visual reference
├── autopilot-preflight.sh        # bootstrap / preflight script
├── .env.autopilot.example        # env vars required by the autopilot
└── README.md                     # this file
```

## Next steps

1. Scaffold the Worker + React app per `spec.md` §Architecture.
2. Provision Cloudflare D1, R2, Queue resources.
3. Wire Telegram webhook → Worker `/webhooks/telegram`.
4. Implement ingestion endpoints (`/api/ingest/{fidelity,robinhood,morgan_stanley}`).
5. Build dashboard, ingest, ticker, sector, rebalance, targets pages.
