# Finance Tracker — Specification

A cloud-hosted personal investment dashboard. You paste or upload brokerage data, the system builds an immutable historical record, enriches it with LLM-powered ticker intelligence fed through your Telegram bot, and surfaces a sector-tagged, account-aware view of your full portfolio with conviction scores and target-price intelligence.

**Deployed publicly on Cloudflare** — accessible from any browser, single-user, always-on.

**Repository:** https://github.com/bhaskarkotakonda/portfolio-tracker

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Browser (React SPA — Cloudflare Pages)              │
│  Dashboard · Ingest · Tickers · Sectors · Rebalance  │
└──────────────────────┬──────────────────────────────┘
                       │ HTTPS (Cloudflare Access gate)
                       ▼
┌─────────────────────────────────────────────────────┐
│  Cloudflare Worker (TypeScript · Hono)               │
│  /api/*  authenticated app routes                    │
│  /webhooks/telegram  public, secret-validated        │
│  Cron handler  (daily price + fundamentals refresh)  │
│  Queue consumer  (async LLM jobs)                    │
└──────┬─────────────┬──────────────┬─────────────────┘
       │             │              │
       ▼             ▼              ▼
  ┌─────────┐  ┌──────────┐  ┌───────────────────┐
  │   D1    │  │    R2    │  │  Cloudflare Queue  │
  │ SQLite  │  │  Object  │  │  LLM research jobs │
  │   DB    │  │  Store   │  │  tweet processing  │
  └─────────┘  └──────────┘  └────────┬──────────┘
                                       ▼
                              ┌─────────────────┐
                              │  Anthropic API  │
                              │  Sonnet · Opus  │
                              └─────────────────┘
                       ▲
                       │ webhook POST
              ┌────────────────┐      ┌──────────────────┐
              │  Telegram Bot  │      │  Polygon.io API  │
              │  (your phone)  │      │  prices + funds  │
              └────────────────┘      └──────────────────┘
```

**Cloudflare limits (free → $5/mo paid plan):**

| Resource | Free | Paid |
|---|---|---|
| D1 storage | 5 GB | 10 GB |
| D1 reads | 5M rows/day | 25B rows/month |
| D1 writes | 100K rows/day | 50M rows/month |
| R2 storage | 10 GB | per GB |
| R2 ops | 1M Class A / 10M Class B /mo | more |
| Worker requests | 100K/day | 10M/month |
| Queues messages | 1M/month | more |
| Cron triggers | 3 | 250 |

For personal single-user use, free tier is sufficient; paid ($5/mo) removes daily write caps.

---

## Pages & UX

### `/` — Dashboard
- **Header bar:** Total portfolio value · day change pill (`▲ 1.9% / +$747`) · as-of timestamp
- **Scorecard row:** Portfolio Score (A–F / 0–100) · Conviction-weighted P&L · Portfolio Resilience Index (0–1)
- **30-day chart:** line chart, markers on dates where a rebalance or ingest was recorded
- **View tabs:** Overview · Sectors · Accounts · Watchlist

### `/ingest` — Data Ingestion
Three-tab layout. See **Data Ingestion** section for per-source UX.

### `/tickers/[SYMBOL]` — Per-Ticker Page
- Position block: shares · cost basis · current price · market value · account split · LTCG/STCG status · days to LTCG
- Conviction score (1–10) + confidence
- Thesis (current version, authored\_by, last updated)
- Catalysts & Risks
- Target prices: buy / sell / alert targets with current gap %
- Custom tags + GICS sector + theme links
- Source tweets (backlinked from `tweet_ingests`)
- Change log (all thesis versions)

### `/sectors` — Sector & Tag View
- Tag matrix: rows = tags (custom + GICS + themes), columns per tag = tickers, weight %, conviction, price vs target
- Tag filter bar (multi-select): semis · AI infra · cloud · memory · fintech · etc.
- Liquidity overlay: shows which account holds each position (Fidelity free to trade vs RH LTCG-locked)

### `/rebalance` — Rebalance Intelligence
- Deterministic engine computes: overweight/underweight vs targets, LTCG/STCG lot status, account routing
- LLM adds: narrative rationale, thesis-aware context
- Output table: `account | ticker | action | shares | tax impact | conviction | rationale`
- Advisory only — no trades executed

### `/targets` — Price Targets
- All active buy/sell/alert targets across tickers
- Current price vs target gap %
- "Near trigger" alerts (within 5%)

---

## Data Ingestion

### Fidelity (Excel or CSV)

**UX:**
1. Tab shows a drag-and-drop zone + "Browse" button. Accepts `.xlsx` or `.csv`.
2. File selected → client parses XLSX in-browser (using `SheetJS`) → renders a preview table: Ticker | Shares | Cost Basis | Market Value | Account.
3. Reconciliation strip below preview: file total vs parsed total, unknown tickers, cash rows detected.
4. User clicks **Confirm & Save** → browser sends `multipart/form-data` (raw file + parsed rows JSON) to `POST /api/ingest/fidelity`.
5. Server re-parses authoritatively, SHA-256 dedup check, writes to D1 + uploads raw file to R2.
6. Response: snapshot summary toast + dashboard refresh.

**Server parse:**
- `pandas`-equivalent column mapping in TypeScript: detect Fidelity header row, map columns to `{ticker, shares, cost_basis, current_price, market_value}`.
- Cash rows (`SPAXX`, `Pending Activity`, etc.) → `cash_balances`, not `positions`.
- Options rows → stored with `position_type='option'`, excluded from portfolio math in v1.

---

### Robinhood (Paste)

**UX:**
1. Tab shows a large textarea: *"Open Robinhood → Portfolio → copy all positions text, then paste here."*
2. On `paste` event → client-side regex parse → renders preview table immediately (no button needed).
3. Reconciliation strip: parsed total vs any detected total line, flagged unknowns.
4. User clicks **Confirm & Save** → sends `{raw_text, parsed_rows}` to `POST /api/ingest/robinhood`.
5. Server re-parses authoritatively, SHA-256 dedup, writes to D1. Raw text saved to R2 (`raw/robinhood/YYYYMMDD_HHmmss.txt`).

---

### Morgan Stanley (Paste or Share Count)

**UX:**
1. Tab shows **two options** (toggle):
   - **"I know my share count"** → single number input for MSFT shares. Server fetches live price from Polygon → generates synthetic snapshot.
   - **"Paste statement text"** → textarea, parses for MSFT share count.
2. Either path → preview shows: `MSFT | {shares} shares | ${live_price} | ${value}`.
3. Confirm → `POST /api/ingest/morgan_stanley`.

---

### Ingest pipeline (all sources)

```
raw input (file / text)
  → R2 upload (immutable archive)
  → authoritative server parse
  → SHA-256 content_hash + UNIQUE(account_id, content_hash) dedup check
  → INSERT raw_snapshots
  → INSERT positions (one row per ticker per snapshot)
  → INSERT / UPSERT tax_lots (acquire date from source if present, else snapshot_date)
  → INSERT cash_balances
  → price enrich: Polygon.io for any ticker missing a fresh price
  → UPSERT tickers (sector, industry from Polygon)
  → recompute portfolio_snapshots (today's aggregate)
  → notify: snapshot_id + summary
```

---

## Database Schema

### `accounts`
| Column | Type | Notes |
|---|---|---|
| id | TEXT PK | `fidelity`, `robinhood`, `morgan_stanley` |
| display_name | TEXT | |
| account_type | TEXT | `roth_ira`, `taxable`, `employer` |
| tax_treatment | TEXT | `tax_free`, `taxable`, `tax_deferred` |
| trade_freely | BOOLEAN | true for Fidelity (Roth IRA) |

### `raw_snapshots` — immutable ledger
| Column | Type | Notes |
|---|---|---|
| id | INTEGER PK | |
| account_id | TEXT FK | |
| source_type | TEXT | `xlsx`, `csv`, `paste`, `synthetic` |
| content_hash | TEXT | SHA-256 dedup key |
| holdings_fingerprint | TEXT | SHA-256 of normalized holdings (`ticker+shares+cost`) for semantic dedup |
| r2_key | TEXT | path to raw file in R2 |
| as_of_date | DATE | parsed from content |
| parser_version | TEXT | semver — for re-parse on schema changes |
| status | TEXT | `confirmed`, `superseded` |
| uploaded_at | DATETIME | |
| UNIQUE | | (account_id, content_hash) |

**Semantic dedup guardrail:** if a new upload has a new `content_hash` but the same
`holdings_fingerprint` as the latest confirmed snapshot for that account, treat as
"no holdings change" (do not create new positions rows; keep an audit log event).

### `positions` — derived from snapshots
| Column | Type | Notes |
|---|---|---|
| snapshot_id | INTEGER FK | |
| account_id | TEXT FK | |
| ticker | TEXT | |
| shares | REAL | |
| avg_cost_basis | REAL | per share |
| current_price | REAL | at time of snapshot |
| market_value | REAL | shares × current_price |
| position_type | TEXT | `equity`, `etf`, `cash`, `option` |
| snapshot_date | DATE | |

### `tax_lots` — LTCG/STCG tracking
| Column | Type | Notes |
|---|---|---|
| account_id | TEXT FK | |
| ticker | TEXT | |
| shares | REAL | |
| cost_basis | REAL | per share |
| acquired_date | DATE | determines LTCG (>365 days) |
| lot_type | TEXT | `LTCG` or `STCG` (computed) |
| source_snapshot_id | INTEGER FK | |

### `cash_balances`
| Column | Type | Notes |
|---|---|---|
| account_id | TEXT FK | |
| snapshot_id | INTEGER FK | |
| amount | REAL | |
| instrument | TEXT | e.g. `SPAXX`, `USD` |
| snapshot_date | DATE | |

### `tickers` — master catalog
| Column | Notes |
|---|---|
| symbol | PK |
| name | display name |
| sector | GICS from Polygon |
| industry | GICS industry |
| custom_tags | TEXT JSON array — user-defined tags (e.g. `["semis","AI infra"]`) |
| conviction | INTEGER 1–10 |
| last_enriched_at | price/sector refresh timestamp |

### `price_history`
| Column | Notes |
|---|---|
| UNIQUE(ticker, price_date) | prevents duplicate fetches |
| market_session | `regular`, `pre`, `post` |
| is_realtime | BOOLEAN |
| price_age_seconds | age at read time for downstream confidence checks |
| close | adjusted close |
| source | `polygon`, `synthetic` |
| fetched_at | |

### `price_targets`
| Column | Notes |
|---|---|
| ticker | |
| target_price | REAL |
| target_type | `buy`, `sell`, `alert` |
| account_id | NULL = all accounts |
| triggered_at | set when condition fires |
| created_at | |

### `portfolio_snapshots` — time series
| Column | Notes |
|---|---|
| UNIQUE(snapshot_date, account_id) | NULL account_id = total portfolio |
| total_value | REAL |
| day_change_pct | REAL |

### `ticker_intel` — versioned LLM wiki per ticker
| Column | Notes |
|---|---|
| ticker | |
| version | monotonically increasing |
| thesis | markdown |
| catalysts | JSON array |
| risks | JSON array |
| conviction | INTEGER 1–10 |
| authored_by | `llm` or `human` |
| llm_model | which Claude model |
| prompt_version | semver |
| source_tweet_ids | JSON array |
| content_hash | skip write if unchanged |
| change_summary | what changed |

FTS5 virtual table `ticker_intel_fts` for full-text search.

### `tweet_ingests` — raw tweet store
| Column | Notes |
|---|---|
| raw_text | verbatim |
| r2_key | archived .md file path in R2 |
| tickers | JSON array |
| intent | LLM-extracted author intent |
| thesis | LLM-extracted thesis (null if absent) |
| context | LLM-extracted macro/sector context |
| extraction_json | strict validated JSON payload (schema_versioned) |
| extraction_schema_version | semver for parser contract |
| evidence_tier | `social`, `news`, `filing`, `transcript`, `manual` |
| ingested_at | |

### `themes` — thematic ground truth
| Column | Notes |
|---|---|
| theme_name | UNIQUE (e.g. "AI Capex Cycle") |
| ground_truth | LLM-synthesized markdown summary |
| related_tickers | JSON array |
| source_tweet_ids | JSON array |
| evidence_mix | JSON object counts by tier (`social/news/filing/...`) |
| confidence_score | REAL 0.0–1.0 derived from evidence weighting |
| version | monotonically increasing |
| llm_model | |
| last_updated_at | |

FTS5 virtual table `themes_fts` for full-text search.

### `rebalance_history` — logged suggestions
| Column | Notes |
|---|---|
| generated_at | |
| account_id | |
| ticker | |
| action | `buy`, `sell`, `hold` |
| shares_suggested | REAL |
| tax_impact_est | REAL (deterministic engine) |
| conviction | INTEGER 1–10 |
| rationale | LLM narrative text |
| llm_model | |
| was_acted_on | BOOLEAN (user marks) |

### `alert_log`
| Column | Notes |
|---|---|
| alert_type | `price_target_hit`, `digest`, `briefing` |
| telegram_chat_id | |
| message_text | |
| sent_at | |

---

## Ticker Intelligence Pipeline

```
You → Telegram: forward a tweet
  │
  ▼
Worker: POST /webhooks/telegram
  → validate X-Telegram-Bot-Api-Secret-Token header
  → dedup by update_id (D1 check)
  → archive raw tweet text to R2 (tweets/YYYYMMDD_HHmmss.md)
  → enqueue job: { type: "tweet_ingest", raw_text, update_id }
  ▼
Queue Consumer Worker:
  → Anthropic Sonnet: extract structured payload
      { tickers[], intent, thesis (null if absent), context }
  → validate against strict JSON schema (reject/queue retry on invalid shape)
  → assign evidence_tier='social' for tweet-origin assertions
  → INSERT tweet_ingests
  → for each new ticker:
      → INSERT research_jobs (status='pending')
      → enqueue: { type: "deep_research", ticker }
  → theme_accumulator: Sonnet clusters tweet into theme(s)
      → UPSERT themes (versioned ground_truth summary)
  → Telegram reply: "📥 Got it. Tickers: NVDA, TSLA. Intent: bullish AI capex.
                     Thesis: [preview if extracted]. Themes: AI Capex Cycle."
  ▼
Queue Consumer Worker (deep_research job):
  → Anthropic Opus: research per ticker
      sources: SEC EDGAR (free API) + Polygon.io + NewsAPI
      prompt caching on large context blocks
  → INSERT research_results (raw_llm_output verbatim, validated=false)
  → evidence promotion pass:
      filing/transcript-backed claims get higher weight than tweet-only claims
  → cross-validate sector vs Polygon
  → UPDATE ticker_intel (new version, increment version #)
  → Telegram reply: "🔬 NVDA research complete (v3). [500 char preview]"
```

**LLM output safety:**
- All LLM outputs stored verbatim with `validated=false` until cross-checked
- LLM never owns deterministic fields (tax impact, account routing, lot math)
- Prompt injection defense: tweet text never interpolated into system prompt; always treated as structured `user_content` argument
- Human override flag on every `ticker_intel` row

---

## Design Principles

1. **Immutable raw data** — `raw_snapshots` + R2 archives are append-only. Re-parsing from original content is always possible.
2. **Idempotent ingestion** — `UNIQUE(account_id, content_hash)` at DB level. Uploading same file twice is always a no-op.
   Also enforce semantic dedup via `holdings_fingerprint` to prevent duplicate snapshots
   when export format/timestamps change but holdings are identical.
3. **Server-authoritative parsing** — Client-side parse is UX preview only. Server re-parses on confirm and is the source of truth.
4. **Deterministic engine for tax/math** — LTCG/STCG classification, lot ordering, account routing, tax impact are computed deterministically from lots. LLM adds narrative, never the math.
5. **LLM as enrichment layer** — All LLM outputs stored verbatim, versioned, with model + prompt version. Never discarded.
   Extraction writes must pass strict schema validation before persistence.
6. **Tax-aware everywhere** — `tax_treatment` is first-class on `accounts`. Every rebalance suggestion names the account and states the tax consequence.
7. **Sector tags are multi-layered** — GICS (auto) + custom user tags + theme tags from LLM. Dashboard can filter by any.
8. **Separation of concerns** — Worker routes call service modules. Modules have no knowledge of HTTP or Telegram.
9. **Prompt caching** — Thesis text + SEC filings passed with `cache_control: ephemeral` — up to 90% cost reduction on follow-up research.
10. **Backups from day one** — D1 daily export to R2. Data is personal financial history; treat accordingly.
11. **Source-weighted truth** — Theme and thesis updates are weighted by evidence tier
    (`filing/transcript` > `news` > `social`) to avoid tweet-only overfitting.
12. **Price freshness awareness** — Every decision includes market session and price age;
    stale/after-hours data lowers confidence and is explicitly labeled.

---

## Tech Stack

| Purpose | Tool |
|---|---|
| Frontend | React + Vite + TypeScript + Tailwind CSS |
| API / Workers | TypeScript · Hono framework |
| Database | Cloudflare D1 (SQLite) |
| File storage | Cloudflare R2 |
| Background jobs | Cloudflare Queues |
| Scheduled tasks | Cloudflare Cron Triggers |
| Auth | Cloudflare Access (single-user; gates entire app by email) |
| Deployment | Cloudflare Pages (frontend) + Workers (API + bot) |
| CI/CD | Wrangler CLI + GitHub Actions |
| XLSX parsing | SheetJS (client-side browser parse for preview) |
| Market data | yfinance (free default) · Polygon.io (optional paid upgrade) |
| LLM | Free mode: deterministic/rule-based + manual Copilot analysis · Anthropic (optional paid upgrade) |
| Telegram | Direct Bot API (httpx-style fetch calls, webhook mode) |
| News | none/RSS (free default) · NewsAPI (optional paid upgrade) |

---

## Environment & Autopilot Prep

Use the repo-level template:

- `.env.autopilot.example` — all integration keys/settings with **free-only defaults** and inline instructions for optional paid upgrades.
- `autopilot-preflight.sh` — validates required env vars and local tooling (`wrangler`, `node`) before running scaffold/deploy automation.

Bootstrap:

```bash
cp .env.autopilot.example .env
# fill values
./autopilot-preflight.sh .env
```

Free-only defaults in `.env`:

- `USE_FREE_ONLY=true`
- `MARKET_DATA_PROVIDER=yfinance`
- `LLM_PROVIDER=none` and `ENABLE_LLM_PIPELINE=false`
- `NEWS_PROVIDER=none`

Set `USE_FREE_ONLY=false` only when you intentionally add paid APIs.

**Autopilot gate:** do not start automated build/deploy runs until preflight passes.

---

## Build Phases

| Phase | Scope | Milestone |
|---|---|---|
| 1 — Scaffold | Cloudflare project, Wrangler config, D1 schema, R2 buckets, Cloudflare Access, Pages + Worker skeleton, CI/CD | Deploy hello-world dashboard behind Access |
| 2 — Ingest | Fidelity, Robinhood, Morgan Stanley ingest UX (preview + confirm), server parse, D1 write, R2 archive | All 3 sources ingested; snapshots + positions in D1 |
| 3 — Market Data | Polygon.io integration, daily price + fundamentals Cron Trigger, `price_history` + `tickers` populated | Prices refresh automatically; tickers have sector/name |
| 4 — Portfolio Dashboard | Combined portfolio view, per-account breakdown, 30-day chart, sector/tag matrix, liquidity overlay, LTCG/STCG flags | Full portfolio visible with sector filtering |
| 5 — Ticker Pages | `/tickers/[SYMBOL]`: position block, custom tags, target price CRUD, thesis placeholder | Can view + annotate each holding |
| 6 — Telegram + LLM Pipeline | Webhook Worker, tweet ingest queue, Sonnet extraction, Opus deep research, `ticker_intel` versioning, `themes` accumulation | Tweet → structured intel stored; Telegram replies |
| 7 — Rebalance Engine | Deterministic tax/lot engine, account routing, LLM narrative layer, rebalance table UI | Advisory rebalance table with tax impact |
| 8 — Intelligence Surface | Conviction scoring in UI, targets dashboard, "near trigger" alerts, sector positioning gaps | Full intelligence layer visible in dashboard |
| 9 — Hardening | D1 backup Cron to R2, error monitoring, retry/dead-letter strategy, tests, README runbook | Production-grade; data safe |

---

## Verification Checklist

- [ ] Dashboard loads behind Cloudflare Access; unauthorized user sees login, not app
- [ ] Fidelity XLSX upload → parsed preview matches file totals → confirm → `raw_snapshots` row in D1, raw file in R2
- [ ] Same Fidelity file uploaded twice → second upload shows "already ingested" toast, no duplicate row
- [ ] Same holdings with a different export timestamp/format → semantic dedup identifies no holdings change
- [ ] Fidelity CSV works identically to XLSX
- [ ] Robinhood paste → auto-parses on paste → preview table appears → confirm → D1 updated
- [ ] Morgan Stanley share count → live MSFT price fetched → value displayed
- [ ] AAPL in both RH + Fidelity → combined view shows merged shares with per-account split
- [ ] RH position `acquired_date` > 365 days ago → classified LTCG, badge shown on ticker page
- [ ] RH position < 365 days → STCG warning shown on rebalance suggestion
- [ ] Custom tag "semis" added to NVDA → Sectors view shows NVDA under "semis" row
- [ ] Price target set → `/targets` shows gap % to current price
- [ ] Price within 5% of target → "near trigger" badge appears
- [ ] Rebalance run during pre/post market marks pricing as after-hours and lowers confidence
- [ ] Tweet forwarded to Telegram → `tweet_ingests` row created with intent + thesis + context
- [ ] Invalid LLM extraction JSON fails schema validation and is retried (not persisted as malformed)
- [ ] Tweet with explicit thesis → `thesis` field non-null in `tweet_ingests`
- [ ] Two tweets mentioning AI capex → `themes` row created/updated with versioned ground_truth
- [ ] Filing-backed AI capex evidence increases theme confidence more than tweet-only evidence
- [ ] Deep research completes → `ticker_intel` version incremented, Telegram reply sent
- [ ] Rebalance suggestion for new buy → recommends Fidelity (Roth IRA) before Robinhood
- [ ] Rebalance sell suggestion on RH STCG lot → STCG tax impact shown in rationale
- [ ] D1 daily backup Cron → backup object visible in R2 bucket
- [ ] `context_for` equivalent: all ticker intel + themes bundled correctly for LLM prompts
