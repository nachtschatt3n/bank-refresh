# AI Transaction Categorizer

Categorizes uncategorized transactions in Actual Budget using a local Ollama LLM (gemma4:26b-mlx).

## How it works

1. Connects to Actual Budget at `your-actual-server` via `@actual-app/api`
2. Fetches all uncategorized transactions
3. Sends them in batches of 25 to Ollama (gemma4:26b-mlx with thinking disabled)
4. Updates each transaction with the AI-assigned category
5. Optionally creates Actual Budget rules for recurring payees

## Prerequisites

- Node.js via mise (`mise exec node -- node --version`)
- `@actual-app/api` installed (`npm install` in this directory)
- Ollama running on the Mac Mini with `gemma4:26b-mlx` loaded (`ollama serve` (or your Ollama launch script))
- Actual Budget reachable at `your-actual-server`

> Use the **`-mlx`** build, not the GGUF `gemma4:26b`. The mini keeps an all-MLX set
> resident; the GGUF reserves 27.1 GiB on load, which does not fit alongside it in
> 48 GB. Requesting it makes Ollama OOM and evict *every* model, taking unrelated
> apps down with it. Merchant recognition is character-identical between the two.

## Usage

```bash
# First time: let AI suggest categories based on your transactions
./run-categorize.sh suggest

# Preview categorization without making changes
./run-categorize.sh start --dry-run

# Run full categorization + create rules for recurring payees
./run-categorize.sh start --rules

# Monitor progress
./run-categorize.sh status
./run-categorize.sh log

# Stop a running job
./run-categorize.sh stop
```

## Commands

| Command | Description |
|---------|-------------|
| `suggest` | Sample transactions, ask AI for category taxonomy, create them in Actual Budget |
| `suggest --dry-run` | Same but only print suggestions, don't create |
| `start` | Categorize all uncategorized transactions |
| `start --rules` | Categorize + create rules for payees seen 3+ times |
| `start --dry-run` | Preview without writing to Actual Budget |
| `status` | Show progress (batches done, ETA, errors) |
| `log` | Tail the live log |
| `stop` | Kill a running categorization |

## Files

| Path | Description |
|------|-------------|
| `categorize-transactions.mjs` | Main Node.js script |
| `run-categorize.sh` | Wrapper script with start/stop/status |
| `.categorizer/status.json` | Machine-readable progress file |
| `.categorizer/categorize.log` | Full log with timestamps |
| `.categorizer/failed.json` | Failed transactions with reasons (for retry) |

## Config

All config is at the top of `categorize-transactions.mjs`:

| Setting | Default | Description |
|---------|---------|-------------|
| `model` | `gemma4:26b-mlx` | Ollama model (must be pre-loaded) |
| `batchSize` | 25 | Transactions per LLM call |
| `syncEveryNBatches` | 50 | How often to sync to Actual Budget server |
| `ollamaTimeoutMs` | 120,000 | Max time per Ollama request |
| `ollamaRetries` | 3 | Retries per failed Ollama call |
| `connectRetries` | 5 | Retries connecting to Actual Budget |

## Performance

With `think: false`:
- ~2-5 seconds per batch of 25 transactions
- ~14,000 transactions in ~1 hour
- Idempotent: only processes transactions with no category set

## Troubleshooting

**"Ollama not reachable"** — Start Ollama: `ollama serve` (or your Ollama launch script)

**"Actual Budget not reachable"** — Check pod: `kubectl get pods -n office | grep actual`

**"Ollama timeout"** — Model may be swapped out. Check `curl http://your-ollama-host:11434/api/ps` to see if gemma4:26b-mlx is resident.

**Batches failing with "no JSON"** — The LLM occasionally returns malformed output. These batches are skipped and logged. Rerun the script to pick them up (only uncategorized transactions are processed).

## Failed transactions

After a run, `.categorizer/failed.json` contains all transactions that couldn't be categorized, with reasons:

| Reason | Description |
|--------|-------------|
| `id_mismatch` | LLM didn't return this transaction's ID in its response |
| `bad_category` | LLM returned a category ID that doesn't exist |
| `no_json` | LLM response had no parseable JSON |
| `batch_error` | Entire batch failed (timeout, network error) |

Rerunning the script automatically retries all failed transactions since it only processes uncategorized ones.
