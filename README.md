# bank-refresh

A macOS menu bar app that automatically refreshes [MoneyMoney](https://moneymoney-app.com/) bank accounts and syncs new transactions to a self-hosted [Sure](https://github.com/we-promise/sure) instance via `sure-monmon`.

> **Actual Budget retired (2026-10-04).** The Actual Budget server was decommissioned
> (cluster commit `ac7bf0e0`). The menu-bar app no longer runs the `actual-monmon import`
> stage or the Actual-only AI categorizer (`categorize-transactions.mjs`); with no server
> left, the import failed every cycle and, because it ran first, blocked the Sure sync.
> The Actual sections below, `categorize-transactions.mjs`, `run-categorize.sh`,
> `~/.actually/config.toml` and the global `actual-moneymoney` npm package are kept for
> history but are **unused**.

## What it does

```
MoneyMoney (macOS banking app)
  │
  │  1. Refresh All Accounts (on timer or manual)
  ▼
Sure (self-hosted finance app)
  │
  │  2. Import new transactions via sure-monmon
  ▼
Done — transactions appear in Sure (Sure does its own categorization)
```

The menu bar app manages the full pipeline automatically. You can also trigger each step individually.

### Menu bar features

- Refresh intervals: 15 min, 2 h, 6 h, 12 h
- Manual "Refresh now" and "Sync to Sure now" buttons
- Status icon changes color: idle (gray), refreshing (blue), syncing to Sure (orange), success (green), failure (red)
- Shows last refresh time, last sync time, next scheduled refresh

## Requirements

- macOS 13+
- [MoneyMoney](https://moneymoney-app.com/) installed (English UI)
- [Actual Budget](https://actualbudget.org/) server (self-hosted)
- [Ollama](https://ollama.com/) running with a loaded model (default: `gemma4:26b-mlx`)
- [mise](https://mise.jdx.dev/) (for Node.js version management)
- Xcode Command Line Tools (`xcode-select --install`)

## Setup

### 1. Clone and install tools

```sh
git clone git@github.com:nachtschatt3n/bank-refresh.git
cd bank-refresh
mise install        # installs Node.js 22
npm install         # installs @actual-app/api
```

### 2. Configure credentials

Copy the example environment file and fill in your values:

```sh
cp .env.example .env
```

Edit `.env`:

```sh
# Actual Budget — get these from your server
ACTUAL_URL=https://actual.example.com
ACTUAL_PASSWORD=your-server-password
ACTUAL_SYNC_ID=from-actual-settings-advanced
ACTUAL_ACCOUNT_ID=from-the-account-url

# Ollama — where your LLM runs
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=gemma4:26b-mlx

# Optional: custom DNS server for internal domains
DNS_SERVER=
```

**Where to find the Actual Budget values:**

- `ACTUAL_URL`: Your Actual Budget server URL
- `ACTUAL_PASSWORD`: The password you use to log in
- `ACTUAL_SYNC_ID`: Settings > Show advanced settings > Sync ID
- `ACTUAL_ACCOUNT_ID`: Open the account in Actual Budget, copy the UUID from the URL

### 3. Configure MoneyMoney sync

Install the [actual-moneymoney](https://github.com/NikxDa/actual-moneymoney) CLI:

```sh
npm install -g actual-moneymoney
```

Run `actual-monmon validate` to generate the config file, then edit it (`~/.actually/config.toml`) with your Actual Budget server details and account mappings. See the [actual-moneymoney docs](https://github.com/NikxDa/actual-moneymoney#readme) for configuration details.

Test the sync:

```sh
actual-monmon validate
actual-monmon import --from=2024-01-01  # initial import
```

### 3b. Configure Sure sync (optional)

To also mirror transactions into a [Sure](https://github.com/we-promise/sure) instance, install the sibling CLI:

```sh
npm install -g /path/to/sure-moneymoney   # or: npm install -g sure-moneymoney once published
```

One-time Sure setup:

1. In Sure UI → **Accounts**: create one account per MoneyMoney account, matching the name exactly, with the same currency and starting balance.
2. In Sure UI → **Settings → API Keys**: generate a key with `read_write` scope.
3. Run `sure-monmon validate` and enter the URL + API key. It will auto-map accounts by name and write `~/.sure/config.toml`.

Test the sync:

```sh
sure-monmon validate
sure-monmon import --dry-run   # preview
sure-monmon import             # live
```

The menu-bar app invokes `sure-monmon import` automatically after each successful MoneyMoney refresh. A Sure failure is reported on its own metric (`bank_refresh_sure_sync_state`, alerts `BankRefreshSureSync{Failing,Stale}`) and does not flip `bank_refresh_state`. If `sure-monmon` is not installed the stage is skipped.

### 4. Build and install the app

```sh
./build-native-app.sh
cp -R RefreshMoneyMoney.app /Applications/
open /Applications/RefreshMoneyMoney.app
```

Grant Accessibility permission when prompted:
`System Settings > Privacy & Security > Accessibility` — add and enable `RefreshMoneyMoney.app`.

## AI Categorization

The categorizer uses a local Ollama model to classify transactions into budget categories. See [CATEGORIZE.md](./CATEGORIZE.md) for full details.

### Quick start

```sh
# Let AI suggest categories based on your transaction data
mise run categorize:suggest

# Categorize all uncategorized transactions + create rules
mise run categorize

# Monitor progress
mise run categorize:status
mise run categorize:log

# Stop a running job
mise run categorize:stop
```

Or use the shell script directly:

```sh
./run-categorize.sh suggest          # suggest categories
./run-categorize.sh start --rules    # categorize + create rules
./run-categorize.sh start --dry-run  # preview without changes
./run-categorize.sh status           # check progress
./run-categorize.sh stop             # stop running job
```

### How it works

- Fetches uncategorized transactions from Actual Budget via `@actual-app/api`
- Sends them in batches of 25 to Ollama (with `think: false` for speed)
- Uses short IDs (`t1`, `c1`) in prompts to avoid UUID hallucination
- Falls back to JSON schema constrained decoding if fast mode fails
- Creates Actual Budget rules for recurring payees (3+ occurrences)
- Idempotent: only processes transactions without a category

### Performance

With thinking disabled: ~4 seconds per batch of 25 transactions.

## Usage

### Menu bar

Click the icon in the menu bar:

- **Refresh now** (r) — refresh MoneyMoney + sync to Sure
- **Sync to Sure now** (s) — sync to Sure only (skip bank refresh)
- **Refresh interval** — choose auto-refresh schedule

### mise tasks

```sh
mise run build                # build the macOS app
mise run categorize           # run AI categorization
mise run categorize:suggest   # suggest new categories
mise run categorize:status    # show progress
mise run categorize:log       # tail log
mise run categorize:stop      # stop running job
```

## Project layout

```
native-wrapper/
  main.swift                  # macOS menu bar app (Swift/AppKit)
  Info.plist                  # app bundle metadata
refresh-moneymoney.applescript # AppleScript for MoneyMoney UI automation
categorize-transactions.mjs   # AI transaction categorizer (Node.js)
run-categorize.sh             # categorizer wrapper (start/stop/status)
build-native-app.sh           # build script
.env.example                  # credential template
.mise.toml                    # Node.js version + task definitions
package.json                  # Node.js dependencies
CATEGORIZE.md                 # detailed categorizer documentation
tests/smoke-test.sh           # bundle smoke test
```

### Runtime files (gitignored)

```
.env                          # your credentials
.categorizer/                 # logs, status, failed transactions
node_modules/                 # npm dependencies
RefreshMoneyMoney.app/        # built app bundle
```

## Metrics endpoint

The app serves Prometheus metrics on `METRICS_PORT` (default `9100`):

| Path | Purpose |
|---|---|
| `/metrics` | Prometheus exposition — five gauges (see below) |
| `/health` | plain `ok` liveness probe |

Exported gauges:

| Metric | Meaning |
|---|---|
| `bank_refresh_up` | always `1` while the app is running |
| `bank_refresh_last_success_timestamp_seconds` | last fully successful cycle (`0` until one completes) |
| `bank_refresh_last_refresh_timestamp_seconds` | last refresh attempt |
| `bank_refresh_duration_seconds` | duration of the last cycle |
| `bank_refresh_state{state="idle\|refreshing\|syncing\|success\|failure"}` | pipeline state, one-hot |
| `bank_refresh_sure_sync_state{state="unknown\|syncing\|ok\|failed\|not_configured\|not_installed"}` | Sure sync stage, one-hot |
| `bank_refresh_sure_sync_last_success_timestamp_seconds` | last successful Sure sync (`0` until one completes) |

The Sure sync stage is **isolated by design**: a Sure failure does not stop the
Actual Budget sync or categorization, and deliberately does not appear in
`bank_refresh_state`. It therefore gets its own state set, so that isolated does
not also mean invisible. The two steady states are modelled separately from a
real fault:

- `not_installed` — `sure-monmon` is not present. Expected if you skipped the
  optional Sure setup; not an incident.
- `not_configured` — `sure-monmon` exits 2. Needs a one-off `sure-monmon
  validate`; not an incident.
- `failed` — retried and still broken. This is the one worth alerting on.
- `unknown` — has not run yet this session (e.g. just after a restart).

Both timestamp gauges start at `0`, so any staleness rule must guard with
`> 0` or it will fire against a freshly restarted app.

### The listener binds all interfaces, unauthenticated — deliberately

This is a documented choice, not an oversight:

- **It must be remotely reachable.** A Prometheus instance on another host scrapes
  it across the LAN. Binding to loopback would silently break that scrape target,
  which is worse than the exposure — the alerting would go quiet rather than fire.
- **The payload carries nothing sensitive.** Five gauges: timestamps, a duration,
  and a state enum. No credentials, no account identifiers, no balances, no
  transaction data. Anything sensitive stays in `.env` and `.categorizer/`, both
  gitignored.
- **The surface is small.** `GET /metrics` and `GET /health` only; every other
  request gets 404/405. There are no shell invocations anywhere in the app
  (`Process` is always given an argument array), so there is no injection path.

Run it only on a trusted network segment. If you need it locked down further, put
it behind a firewall rule scoped to your Prometheus host rather than changing the
bind address.

### Refresh-failure handling

Sync stages retry with backoff before reporting failure, so a transient backend
outage (a Kubernetes node roll, an ingress restart) does not latch a failure state
that lasts until the next refresh cycle:

- **Actual Budget sync** — 6 attempts over 275s. Its failure latches the exported
  `failure` state, so it is worth waiting out a backend that is coming back.
- **Sure sync** — 4 attempts over 65s. This stage is isolated by design (a Sure
  failure does not stop the Actual sync or categorization, and does not reach the
  exported state), so it retries only long enough to cover an ingress restart.
- **Config errors are never retried** — `sure-monmon` exit 2 ("not configured")
  fails immediately rather than after a minute of pointless waiting.

Failing stages log their exit code and stderr to `.categorizer/swift-debug.log`.

## Language limitation

The AppleScript clicks English menu items (`File` > `Refresh All Accounts`). For other languages, update [`refresh-moneymoney.applescript`](./refresh-moneymoney.applescript).

## macOS security

The app uses System Events to control MoneyMoney, requiring Accessibility permission. If refreshes fail:

1. System Settings > Privacy & Security > Accessibility
2. Remove and re-add `RefreshMoneyMoney.app`
3. Enable the toggle
4. Restart the app

> **Rebuilding the app revokes this permission.** The bundle is ad-hoc signed
> (no Team ID), so its code identity changes on every `./build-native-app.sh`.
> macOS then treats the replacement as a different app and the Accessibility
> grant no longer applies. The only symptom is `runAppleScript` failing, which
> latches the exported `failure` state and fires `BankRefreshFailing`.
>
> **Re-approve after every install.** The app logs its status on startup, so
> check before waiting for a cycle:
>
> ```sh
> grep "permissions:" .categorizer/swift-debug.log | tail -2
> ```
>
> `Accessibility (AXIsProcessTrusted) = DENIED` means step 1-4 above are needed.
> AppleScript failures also log the error number and a plain-language hint
> (`-1743` Automation denied, `-1728` menu item not found, `-1712` timeout).

## Test

```sh
./tests/smoke-test.sh
```

## License

GPL-2.0. See [`LICENSE`](./LICENSE).
