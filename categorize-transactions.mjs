#!/usr/bin/env node
import * as api from '@actual-app/api';
import http from 'http';
import dns from 'dns';
import fs from 'fs';
import path from 'path';

// Catch unhandled promise rejections from @actual-app/api internal sync
// (the library fires background sync promises that can reject on network errors)
process.on('unhandledRejection', (reason, promise) => {
  const msg = reason?.message || reason?.reason || String(reason);
  // Log but don't crash — these are non-fatal background sync failures
  const ts = new Date().toISOString();
  const line = `[${ts}] [WARN] Unhandled rejection (non-fatal): ${msg}\n`;
  try { fs.appendFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), '.categorizer', 'categorize.log'), line); } catch { /* ignore if log dir doesn't exist yet */ }
});

// ─── Load .env ───────────────────────────────────────────────────────────────

const SCRIPT_DIR = path.dirname(new URL(import.meta.url).pathname);
const envFile = path.join(SCRIPT_DIR, '.env');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf-8').split('\n')) {
    const match = line.match(/^\s*([A-Z_]+)\s*=\s*(.+?)\s*$/);
    if (match && !process.env[match[1]]) process.env[match[1]] = match[2];
  }
}

// ─── Custom DNS (optional, for internal domains) ─────────────────────────────

if (process.env.DNS_SERVER) {
  dns.setServers([process.env.DNS_SERVER]);
  const _origLookup = dns.lookup.bind(dns);
  dns.lookup = function(hostname, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    if (typeof options === 'number') options = { family: options };
    dns.resolve4(hostname, (err, addresses) => {
      if (!err && addresses?.length) {
        if (options?.all) return callback(null, addresses.map(a => ({ address: a, family: 4 })));
        return callback(null, addresses[0], 4);
      }
      _origLookup(hostname, options, callback);
    });
  };
}

// ─── Config ──────────────────────────────────────────────────────────────────

const CONFIG = {
  serverURL: process.env.ACTUAL_URL,
  password: process.env.ACTUAL_PASSWORD,
  syncId: process.env.ACTUAL_SYNC_ID,
  accountId: process.env.ACTUAL_ACCOUNT_ID,
  ollamaURL: process.env.OLLAMA_URL || 'http://localhost:11434',
  model: process.env.OLLAMA_MODEL || 'gemma4:26b-mlx',
  batchSize: 25,
  syncEveryNBatches: 50,
  ollamaTimeoutMs: 120_000,
  connectRetries: 5,
  connectRetryDelayMs: 10_000,
  ollamaRetries: 3,
  ollamaRetryDelayMs: 3_000,
  dataDir: `/tmp/actual-categorizer-${process.pid}`,
};

// Validate required config
for (const key of ['serverURL', 'password', 'syncId', 'accountId']) {
  if (!CONFIG[key]) {
    console.error(`Missing required config: ${key}. Set it in .env or as an environment variable.`);
    console.error('See .env.example for reference.');
    process.exit(1);
  }
}

const STATE_DIR = path.join(SCRIPT_DIR, '.categorizer');
const LOG_FILE = path.join(STATE_DIR, 'categorize.log');
const STATUS_FILE = path.join(STATE_DIR, 'status.json');
const FAILED_FILE = path.join(STATE_DIR, 'failed.json');

// ─── CLI args ────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const SUGGEST = args.includes('--suggest');
const RULES = args.includes('--rules');
const STATUS = args.includes('--status');

// ─── Logging ─────────────────────────────────────────────────────────────────

fs.mkdirSync(STATE_DIR, { recursive: true });

const logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });

function log(level, msg) {
  const ts = new Date().toISOString();
  const line = `[${ts}] [${level}] ${msg}`;
  // Only write to console if interactive (not redirected via nohup)
  if (process.stdout.isTTY) console.log(line);
  logStream.write(line + '\n');
}

function logInfo(msg) { log('INFO', msg); }
function logWarn(msg) { log('WARN', msg); }
function logError(msg) { log('ERROR', msg); }
function logDebug(msg) { log('DEBUG', msg); }

// ─── Status file ─────────────────────────────────────────────────────────────

let status = {
  state: 'idle',
  startedAt: null,
  batchesDone: 0,
  batchesTotal: 0,
  categorized: 0,
  failed: 0,
  skipped: 0,
  rulesCreated: 0,
  lastBatchAt: null,
  lastError: null,
  avgBatchMs: 0,
  etaMinutes: null,
};

function writeStatus() {
  fs.writeFileSync(STATUS_FILE, JSON.stringify(status, null, 2) + '\n');
}

function printStatus() {
  if (!fs.existsSync(STATUS_FILE)) {
    console.log('No status file found. Run the categorizer first.');
    return;
  }
  const s = JSON.parse(fs.readFileSync(STATUS_FILE, 'utf-8'));
  const pct = s.batchesTotal > 0 ? ((s.batchesDone / s.batchesTotal) * 100).toFixed(1) : 0;
  let failedInfo = '';
  if (fs.existsSync(FAILED_FILE)) {
    try {
      const f = JSON.parse(fs.readFileSync(FAILED_FILE, 'utf-8'));
      failedInfo = `\nFailed file:  ${FAILED_FILE} (${f.count} transactions)\n  Breakdown:  ${Object.entries(f.summary).map(([k, v]) => `${k}=${v}`).join(', ')}`;
    } catch {}
  }

  console.log(`
State:        ${s.state}
Started:      ${s.startedAt || 'n/a'}
Progress:     ${s.batchesDone}/${s.batchesTotal} batches (${pct}%)
Categorized:  ${s.categorized} transactions
Failed:       ${s.failed} transactions
Skipped:      ${s.skipped} (no JSON match from LLM)
Rules:        ${s.rulesCreated}
Avg batch:    ${s.avgBatchMs ? (s.avgBatchMs / 1000).toFixed(1) + 's' : 'n/a'}
ETA:          ${s.etaMinutes ? s.etaMinutes.toFixed(0) + ' min' : 'n/a'}
Last batch:   ${s.lastBatchAt || 'n/a'}
Last error:   ${s.lastError || 'none'}${failedInfo}
  `.trim());
}

// ─── Health checks ───────────────────────────────────────────────────────────

function getJSON(url, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

// /api/tags lists what is *installed*; /api/ps lists what is *resident* in memory.
// Only the latter means "no model load on first call" — keep them apart so the
// pre-flight line cannot claim a cold model is ready to go.
async function checkOllama() {
  const tags = await getJSON(`${CONFIG.ollamaURL}/api/tags`);
  if (!tags) return { ok: false, installed: false, resident: false };

  const installed = !!tags.models?.some(m => m.name === CONFIG.model);
  const ps = await getJSON(`${CONFIG.ollamaURL}/api/ps`);
  const resident = !!ps?.models?.some(m => m.name === CONFIG.model);

  return { ok: true, installed, resident };
}

async function checkActualBudget() {
  // Use child_process since Node's DNS can't resolve internal k8s-gateway domains
  const { execSync } = await import('child_process');
  try {
    const result = execSync(`curl -sf --connect-timeout 5 ${CONFIG.serverURL}/info 2>/dev/null`, { encoding: 'utf-8' });
    return { ok: true, body: result };
  } catch {
    return { ok: false, error: 'curl health check failed' };
  }
}

// ─── Ollama client ───────────────────────────────────────────────────────────

function ollamaChatRaw(messages, jsonSchema = null) {
  const body = {
    model: CONFIG.model,
    messages,
    stream: false,
    options: { temperature: 0.1 },
  };
  // think=false is 8x faster but breaks format/schema (ollama#15260)
  // Schema mode: omit think to allow constrained decoding
  // Fast mode: set think=false for speed, parse JSON from text
  if (jsonSchema) {
    body.format = jsonSchema;
    // do NOT set think:false — it silently disables format constraint
  } else {
    body.think = false;
  }
  const data = JSON.stringify(body);
  const url = new URL(CONFIG.ollamaURL);

  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: url.hostname,
      port: url.port,
      path: '/api/chat',
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
      timeout: CONFIG.ollamaTimeoutMs,
    }, res => {
      let chunks = '';
      res.on('data', chunk => chunks += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(chunks);
          resolve(parsed.message.content);
        } catch (e) {
          reject(new Error(`Bad Ollama response: ${chunks.substring(0, 200)}`));
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Ollama timeout')); });
    req.write(data);
    req.end();
  });
}

async function ollamaChat(messages, jsonSchema = null) {
  for (let attempt = 1; attempt <= CONFIG.ollamaRetries; attempt++) {
    try {
      return await ollamaChatRaw(messages, jsonSchema);
    } catch (err) {
      logError(`Ollama attempt ${attempt}/${CONFIG.ollamaRetries}: ${err.message}`);
      if (attempt < CONFIG.ollamaRetries) {
        await sleep(CONFIG.ollamaRetryDelayMs);
      } else {
        throw err;
      }
    }
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function formatTxn(t) {
  const amount = (t.amount / 100).toFixed(2);
  const payee = t.imported_payee || t.payee_name || 'Unknown';
  return `"${payee}" ${amount} EUR ${t.date}${t.notes ? ` [${t.notes.substring(0, 50)}]` : ''}`;
}

// ─── Connect with retries ────────────────────────────────────────────────────

async function connectActual() {
  // Always start clean to avoid stale budget state
  fs.rmSync(CONFIG.dataDir, { recursive: true, force: true });
  fs.mkdirSync(CONFIG.dataDir, { recursive: true });

  for (let attempt = 1; attempt <= CONFIG.connectRetries; attempt++) {
    try {
      logInfo(`Connecting to Actual Budget (attempt ${attempt}/${CONFIG.connectRetries})...`);
      await api.init({
        serverURL: CONFIG.serverURL,
        password: CONFIG.password,
        dataDir: CONFIG.dataDir,
      });
      await api.downloadBudget(CONFIG.syncId);
      // Give the budget a moment to fully initialize internally
      await sleep(1000);
      // Verify the budget is actually open by trying a simple query
      const testCats = await api.getCategories();
      logInfo(`Connected to Actual Budget (${testCats.length} categories loaded)`);
      return;
    } catch (err) {
      logError(`Connect failed: ${err.message}`);
      if (attempt < CONFIG.connectRetries) {
        logInfo(`Retrying in ${CONFIG.connectRetryDelayMs / 1000}s...`);
        try { await api.shutdown(); } catch {}
        await sleep(CONFIG.connectRetryDelayMs);
        // Clear stale state
        fs.rmSync(CONFIG.dataDir, { recursive: true, force: true });
        fs.mkdirSync(CONFIG.dataDir, { recursive: true });
      } else {
        throw new Error(`Failed to connect after ${CONFIG.connectRetries} attempts: ${err.message}`);
      }
    }
  }
}

// ─── Phase A: Suggest categories ─────────────────────────────────────────────

async function suggestCategories(uncategorized) {
  logInfo(`Phase A: Sampling ${uncategorized.length} transactions for category suggestions...`);

  const step = Math.max(1, Math.floor(uncategorized.length / 100));
  const sample = uncategorized.filter((_, i) => i % step === 0).slice(0, 100);
  const txnList = sample.map((t, i) => `${i + 1}. ${formatTxn(t)}`).join('\n');

  const prompt = `You are a personal finance expert. Analyze these ${sample.length} real bank transactions from a German household and suggest a practical set of budget categories.

Rules:
- Suggest 10-20 categories organized into 3-5 groups
- Use English category names
- Include both expense and income categories
- Be practical, not overly granular
- Output valid JSON with this structure:
{
  "groups": [
    { "name": "Group Name", "categories": ["Category 1", "Category 2"] }
  ]
}

Transactions:
${txnList}`;

  logInfo(`Sending ${sample.length} transactions to Ollama...`);
  const result = await ollamaChat([{ role: 'user', content: prompt }]);

  const jsonMatch = result.match(/\{[\s\S]*\}/);
  if (!jsonMatch) throw new Error('No JSON in LLM response');

  const parsed = JSON.parse(jsonMatch[0]);
  if (parsed.groups) return parsed;
  if (Array.isArray(parsed)) return { groups: parsed };
  for (const key of Object.keys(parsed)) {
    if (Array.isArray(parsed[key])) return { groups: parsed[key] };
  }
  throw new Error('Unexpected taxonomy format');
}

async function createCategories(taxonomy) {
  const existingCats = await api.getCategories();
  const existingNames = new Set(existingCats.filter(c => c.name).map(c => c.name.toLowerCase()));
  let created = 0;

  for (const group of taxonomy.groups) {
    const existingGroup = existingCats.find(c => c.is_income !== undefined && c.name?.toLowerCase() === group.name.toLowerCase());
    let groupId;
    if (existingGroup) {
      groupId = existingGroup.id;
      logInfo(`  Group "${group.name}" exists`);
    } else {
      groupId = await api.createCategoryGroup({ name: group.name, is_income: group.name.toLowerCase().includes('income') });
      logInfo(`  Created group "${group.name}"`);
    }

    for (const catName of group.categories) {
      if (existingNames.has(catName.toLowerCase())) continue;
      await api.createCategory({ name: catName, group_id: groupId });
      logInfo(`    + ${catName}`);
      created++;
    }
  }
  return created;
}

// ─── Phase B: Categorize ─────────────────────────────────────────────────────

async function categorizeAll(uncategorized) {
  const categories = await api.getCategories();
  const groups = categories.filter(c => !c.group_id && c.id);
  const incomeGroupIds = new Set(groups.filter(g => g.is_income).map(g => g.id));

  const expenseCats = categories.filter(c => c.name && c.group_id && !incomeGroupIds.has(c.group_id));
  const incomeCats = categories.filter(c => c.name && c.group_id && incomeGroupIds.has(c.group_id));

  // Build short-ID lookup maps to avoid LLM hallucinating UUIDs
  const allCats = [...expenseCats, ...incomeCats];
  const catShortIdMap = new Map(); // shortId -> real UUID
  const catNameById = new Map();   // real UUID -> name
  const allCatLines = [];
  allCatLines.push('Expense categories:');
  expenseCats.forEach((c, i) => {
    const sid = `c${i + 1}`;
    catShortIdMap.set(sid, c.id);
    catNameById.set(c.id, c.name);
    allCatLines.push(`- "${c.name}" (${sid})`);
  });
  allCatLines.push('', 'Income categories:');
  incomeCats.forEach((c, i) => {
    const sid = `i${i + 1}`;
    catShortIdMap.set(sid, c.id);
    catNameById.set(c.id, c.name);
    allCatLines.push(`- "${c.name}" (${sid})`);
  });
  const allCatList = allCatLines.join('\n');

  const totalBatches = Math.ceil(uncategorized.length / CONFIG.batchSize);

  logInfo(`Phase B: ${uncategorized.length} transactions, ${totalBatches} batches of ${CONFIG.batchSize}`);
  logInfo(`Categories: ${expenseCats.length} expense, ${incomeCats.length} income`);

  status.batchesTotal = totalBatches;
  status.state = 'categorizing';
  writeStatus();

  // JSON schema for constrained decoding — Ollama guarantees valid output
  const CATEGORIZE_SCHEMA = {
    type: 'object',
    properties: {
      results: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            id: { type: 'string' },
            category: { type: 'string' },
          },
          required: ['id', 'category'],
        },
      },
    },
    required: ['results'],
  };

  const batchTimes = [];
  const payeeCategoryMap = new Map();
  const failedTransactions = []; // collect for retry later

  for (let i = 0; i < uncategorized.length; i += CONFIG.batchSize) {
    const batch = uncategorized.slice(i, i + CONFIG.batchSize);
    const batchNum = Math.floor(i / CONFIG.batchSize) + 1;
    const batchStart = Date.now();

    // Use short numeric IDs for transactions too (t1, t2, ...)
    const txnShortIdMap = new Map(); // "t1" -> real transaction object
    const txnList = batch.map((t, j) => {
      const sid = `t${j + 1}`;
      txnShortIdMap.set(sid, t);
      return `${j + 1}. [${sid}] ${formatTxn(t)}`;
    }).join('\n');

    const promptFast = `Categorize each transaction into one category. Reply ONLY with JSON, no other text.
Use the short IDs (t1, t2, ...) for transactions and (c1, c2, ... or i1, i2, ...) for categories.
Format: {"results":[{"id":"t1","category":"c3"}]}

${allCatList}

Transactions:
${txnList}`;

    const promptSchema = `/no_think
Categorize each transaction into one category.
Use the short IDs (t1, t2, ...) for transactions and (c1, c2, ... or i1, i2, ...) for categories.

${allCatList}

Transactions:
${txnList}`;

    try {
      // Fast path: think=false, no schema (~4s per batch)
      let raw = await ollamaChat([{ role: 'user', content: promptFast }]);
      let parsed;
      let jsonMatch = raw.match(/\{[\s\S]*\}/);

      if (jsonMatch) {
        try { parsed = JSON.parse(jsonMatch[0]); } catch { jsonMatch = null; }
      }

      // Slow fallback: schema-constrained (~35s) — guaranteed valid JSON
      if (!jsonMatch || !parsed?.results) {
        logInfo(`  Batch ${batchNum}: fast mode failed, retrying with schema constraint...`);
        raw = await ollamaChat([{ role: 'user', content: promptSchema }], CATEGORIZE_SCHEMA);
        try {
          parsed = JSON.parse(raw);
        } catch {
          logError(`Batch ${batchNum}/${totalBatches}: no JSON even with schema`);
          for (const t of batch) failedTransactions.push({ id: t.id, payee: t.imported_payee || t.payee_name, amount: t.amount, date: t.date, reason: 'no_json' });
          status.skipped += batch.length;
          status.lastError = 'no JSON in LLM response';
          writeStatus();
          continue;
        }
      }
      const results = parsed.results || [];
      let batchCategorized = 0;

      // Track which transactions got matched
      const matchedIds = new Set();

      for (const r of results) {
        // Resolve short IDs back to real objects
        const txn = txnShortIdMap.get(r.id);
        const realCatId = catShortIdMap.get(r.category);

        if (!txn || !realCatId) {
          // Try to find transaction by short ID pattern
          if (txn && !realCatId) {
            failedTransactions.push({ id: txn.id, payee: txn.imported_payee || txn.payee_name, amount: txn.amount, date: txn.date, reason: 'bad_category', llmCategory: r.category });
            status.failed++;
            matchedIds.add(r.id);
          }
          continue;
        }
        matchedIds.add(r.id);

        if (!DRY_RUN) {
          await api.updateTransaction(txn.id, { category: realCatId });
        }
        status.categorized++;
        batchCategorized++;

        const catName = catNameById.get(realCatId) || r.category;
        const payeeKey = txn.imported_payee || txn.payee_name || '';
        if (payeeKey) {
          const existing = payeeCategoryMap.get(payeeKey);
          if (existing && existing.categoryId === realCatId) existing.count++;
          else if (!existing) payeeCategoryMap.set(payeeKey, { categoryId: realCatId, categoryName: catName, count: 1 });
        }
      }

      // Collect unmatched transactions from this batch
      for (const [sid, t] of txnShortIdMap) {
        if (!matchedIds.has(sid)) {
          failedTransactions.push({ id: t.id, payee: t.imported_payee || t.payee_name, amount: t.amount, date: t.date, reason: 'id_mismatch' });
          status.failed++;
        }
      }

      const batchMs = Date.now() - batchStart;
      batchTimes.push(batchMs);
      status.batchesDone = batchNum;
      status.lastBatchAt = new Date().toISOString();
      status.avgBatchMs = Math.round(batchTimes.reduce((a, b) => a + b, 0) / batchTimes.length);
      status.etaMinutes = ((totalBatches - batchNum) * status.avgBatchMs) / 60_000;
      status.lastError = null;
      writeStatus();

      logInfo(`Batch ${batchNum}/${totalBatches}: ${batchCategorized}/${batch.length} categorized (${(batchMs / 1000).toFixed(1)}s) ETA ${status.etaMinutes.toFixed(0)}min`);

      // Write status periodically (sync only at the end to avoid mid-run crashes)
      if (batchNum % 10 === 0) {
        logInfo(`Progress: ${status.categorized} categorized, ${status.failed} failed so far`);
      }

    } catch (err) {
      const batchMs = Date.now() - batchStart;
      logError(`Batch ${batchNum}/${totalBatches}: ${err.message} (${(batchMs / 1000).toFixed(1)}s)`);
      for (const t of batch) failedTransactions.push({ id: t.id, payee: t.imported_payee || t.payee_name, amount: t.amount, date: t.date, reason: 'batch_error', error: err.message });
      status.failed += batch.length;
      status.lastError = err.message;
      writeStatus();
      await sleep(5000);
    }
  }

  // Write failed transactions for retry
  if (failedTransactions.length > 0) {
    const summary = {};
    for (const f of failedTransactions) summary[f.reason] = (summary[f.reason] || 0) + 1;
    logInfo(`Failed breakdown: ${JSON.stringify(summary)}`);
    fs.writeFileSync(FAILED_FILE, JSON.stringify({ exported: new Date().toISOString(), count: failedTransactions.length, summary, transactions: failedTransactions }, null, 2) + '\n');
    logInfo(`Wrote ${failedTransactions.length} failed transactions to ${FAILED_FILE}`);
  }

  logInfo(`Done: ${status.categorized} categorized, ${status.failed} failed, ${status.skipped} skipped`);
  return payeeCategoryMap;
}

// ─── Phase C: Rules ──────────────────────────────────────────────────────────

async function createRules(payeeCategoryMap) {
  logInfo('Phase C: Creating rules for recurring payees...');

  const payees = await api.getPayees();
  let created = 0;

  for (const [payeeName, { categoryId, categoryName, count }] of payeeCategoryMap) {
    if (count < 3) continue;

    if (DRY_RUN) {
      logInfo(`  [DRY] Rule: "${payeeName}" (${count}x) → ${categoryName}`);
      created++;
      continue;
    }

    try {
      await api.createRule({
        stage: null,
        conditionsOp: 'and',
        conditions: [{ field: 'imported_payee', op: 'is', value: payeeName }],
        actions: [{ op: 'set', field: 'category', value: categoryId }],
      });
      logInfo(`  Rule: "${payeeName}" (${count}x) → ${categoryName}`);
      created++;
    } catch (err) {
      logError(`  Rule for "${payeeName}": ${err.message}`);
    }
  }

  status.rulesCreated = created;
  writeStatus();
  logInfo(`${created} rules created`);
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  // --status: just print status and exit
  if (STATUS) {
    printStatus();
    process.exit(0);
  }

  logInfo('='.repeat(60));
  logInfo(`Starting categorizer${DRY_RUN ? ' (DRY RUN)' : ''}${SUGGEST ? ' (SUGGEST)' : ''}${RULES ? ' (RULES)' : ''}`);

  // Pre-flight checks
  logInfo('Pre-flight: checking Ollama...');
  const ollama = await checkOllama();
  if (!ollama.ok) {
    logError(`Ollama not reachable at ${CONFIG.ollamaURL}`);
    process.exit(1);
  }
  if (!ollama.installed) {
    logWarn(`Model ${CONFIG.model} is not installed on ${CONFIG.ollamaURL} — check OLLAMA_MODEL; calls will likely fail`);
  } else if (!ollama.resident) {
    logInfo(`Ollama OK, model ${CONFIG.model} installed but not resident — it will load on first call (may be slow)`);
  } else {
    logInfo(`Ollama OK, model ${CONFIG.model} resident — no load needed`);
  }

  logDebug(`CWD: ${process.cwd()}, scriptDir: ${SCRIPT_DIR}`);
  logDebug(`NODE: ${process.execPath}, version: ${process.version}`);
  logDebug(`envFile exists: ${fs.existsSync(path.join(SCRIPT_DIR, '.env'))}`);
  logDebug(`ACTUAL_URL=${CONFIG.serverURL}, syncId=${CONFIG.syncId ? '***' : 'MISSING'}, accountId=${CONFIG.accountId ? '***' : 'MISSING'}`);
  logInfo('Pre-flight: Actual Budget will be checked during connect (with retries)');

  status.state = 'connecting';
  status.startedAt = new Date().toISOString();
  writeStatus();

  try {
    await connectActual();

    const uncategorized = await getUncategorizedTransactions();
    logInfo(`Found ${uncategorized.length} uncategorized transactions`);

    if (uncategorized.length === 0) {
      logInfo('Nothing to do!');
      status.state = 'done';
      writeStatus();
      await api.shutdown();
      return;
    }

    if (SUGGEST) {
      status.state = 'suggesting';
      writeStatus();

      const taxonomy = await suggestCategories(uncategorized);
      logInfo('Suggested taxonomy:');
      for (const g of taxonomy.groups) {
        logInfo(`  ${g.name}: ${g.categories.join(', ')}`);
      }

      if (!DRY_RUN) {
        logInfo('Creating categories...');
        const n = await createCategories(taxonomy);
        logInfo(`Created ${n} new categories`);
        try { await api.sync(); } catch (e) { logError(`Sync: ${e.message?.substring(0, 100)}`); }
      }

      status.state = 'done';
      writeStatus();
      await api.shutdown();
      return;
    }

    // Phase B
    const payeeCategoryMap = await categorizeAll(uncategorized);

    // Phase C
    if (RULES && payeeCategoryMap.size > 0) {
      status.state = 'creating_rules';
      writeStatus();
      await createRules(payeeCategoryMap);
    }

    if (!DRY_RUN) {
      logInfo('Final sync...');
      try { await api.sync(); } catch (e) { logError(`Final sync: ${e.message?.substring(0, 100)}`); }
    }

    status.state = 'done';
    writeStatus();
    await api.shutdown();
    fs.rmSync(CONFIG.dataDir, { recursive: true, force: true });
    logInfo('All done.');

  } catch (err) {
    logError(`Fatal: ${err.message}`);
    logError(err.stack);
    status.state = 'error';
    status.lastError = err.message;
    writeStatus();
    try { await api.shutdown(); } catch {}
    fs.rmSync(CONFIG.dataDir, { recursive: true, force: true });
    process.exit(1);
  }
}

async function getUncategorizedTransactions() {
  const txns = await api.getTransactions(CONFIG.accountId, '2020-01-01', '2026-12-31');
  return txns.filter(t => !t.category && !t.is_parent);
}

main();
