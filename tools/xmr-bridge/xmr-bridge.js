#!/usr/bin/env node
// Minimal Monero bridge (Express + wallet-rpc)
// Node 18+ (has global fetch). If not, `npm i node-fetch` and: const fetch = require('node-fetch');

const express = require('express');
const app = express();
app.use(express.json());

// Config
const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || '127.0.0.1';
const WALLET_RPC =
  process.env.WALLET_RPC ||
  process.env.WALLET_RPC_URL ||
  'http://127.0.0.1:18083/json_rpc';
const API_KEY = process.env.XMR_BRIDGE_KEY || ''; // optional

// Simple API key (send header: x-api-key: <key>)
app.use((req, res, next) => {
  if (!API_KEY) return next();
  if (req.get('x-api-key') === API_KEY) return next();
  return res.status(401).json({ error: 'unauthorized' });
});

const HEX64 = /^[0-9a-f]{64}$/i;
const toAtomic = (xmr) => Math.round(Number(xmr) * 1e12);
const toXMR = (n) => Number(n) / 1e12;

async function rpc(method, params = {}) {
  const rsp = await fetch(WALLET_RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: '0', method, params })
  });
  const j = await rsp.json();
  if (j && j.error) {
    const e = new Error(j.error.message);
    e.code = j.error.code;
    throw e;
  }
  return j.result;
}

// ---- routes ----

app.get('/health', async (req, res) => {
  try {
    const v = await rpc('get_version', {});
    res.json({ ok: true, version: v.version, release: !!v.release });
  } catch (e) {
    res.status(502).json({ ok: false, error: String(e.message || e) });
  }
});

// Create a receive subaddress
app.post('/address', async (req, res) => {
  const account_index = Number(req.body?.account_index ?? 0);
  const label = String(req.body?.label ?? '').slice(0, 64);
  try {
    const out = await rpc('create_address', { account_index, label });
    res.json({
      ok: true,
      address: out.address,
      address_index: out.address_index,
      account_index
    });
  } catch (e) {
    console.error('[address]', e);
    res.status(502).json({ ok: false, error: String(e.message || e) });
  }
});

// Estimate fee (does not relay)
app.post('/estimate', async (req, res) => {
  try {
    const address = String(req.body.address || '').trim();
    const amount = Number(req.body.amount);
    if (!address) return res.status(400).json({ error: 'missing address' });
    if (!Number.isFinite(amount) || amount <= 0)
      return res.status(400).json({ error: 'bad amount' });

    const r = await rpc('transfer', {
      destinations: [{ address, amount: toAtomic(amount) }],
      priority: 1,
      do_not_relay: true,
      get_tx_key: false
    });

    res.json({ fee_xmr: toXMR(r.fee), tx_metadata: r.tx_metadata });
  } catch (e) {
    res.status(502).json({ error: String(e.message || e) });
  }
});

// Send XMR (relays). Also supports relaying a provided tx_metadata.
app.post('/transfer', async (req, res) => {
  // If client passed prebuilt metadata, just relay it.
  if (req.body && req.body.tx_metadata) {
    try {
      const rel = await rpc('relay_tx', { hex: String(req.body.tx_metadata) });
      return res.json({ ok: true, txid: rel.tx_hash, tx_hash: rel.tx_hash, fee_xmr: null });
    } catch (e) {
      return res.status(502).json({ error: String(e.message || e) });
    }
  }

  try {
    const address = String(req.body.address || '').trim();
    const amount = Number(req.body.amount);
    if (!address) return res.status(400).json({ error: 'missing address' });
    if (!Number.isFinite(amount) || amount <= 0)
      return res.status(400).json({ error: 'bad amount' });

    const r = await rpc('transfer', {
      destinations: [{ address, amount: toAtomic(amount) }],
      priority: 1,
      do_not_relay: false,
      get_tx_key: true
    });

    const tx_hash = r.tx_hash || (Array.isArray(r.tx_hash_list) && r.tx_hash_list[0]) || null;
    res.json({ ok: true, txid: tx_hash, tx_hash, fee_xmr: toXMR(r.fee) });
  } catch (e) {
    res.status(502).json({ error: String(e.message || e) });
  }
});

// Tx lookup
app.get('/tx/:txid', async (req, res) => {
  const txid = String(req.params.txid || '').trim();
  if (!HEX64.test(txid)) return res.status(400).json({ error: 'bad txid' });
  try {
    const { transfer: t } = await rpc('get_transfer_by_txid', { txid, account_index: 0 });
    if (!t) return res.status(404).json({ error: 'tx not found' });
    res.json({
      ok: true,
      txid,
      in_pool: !!t.in_pool,
      confirmations: t.confirmations ?? 0,
      amount_xmr: toXMR(t.amount ?? 0),
      fee_xmr: toXMR(t.fee ?? 0),
      timestamp: t.timestamp ?? null,
      address: t.address ?? null
    });
  } catch (e) {
    console.error('[tx]', txid, e);
    res.status(502).json({ error: String(e.message || e) });
  }
});

// Create a payment proof (sender)
app.post('/proof', async (req, res) => {
  try {
    const txid = String(req.body?.txid || '').trim();
    const address = String(req.body?.address || '').trim();
    const message = String(req.body?.message || '').slice(0, 140);
    if (!HEX64.test(txid)) return res.status(400).json({ error: 'bad txid' });
    if (!address) return res.status(400).json({ error: 'bad address' });

    const out = await rpc('get_tx_proof', { txid, address, message });
    res.json({ ok: true, txid, address, message, signature: out.signature });
  } catch (e) {
    console.error('[proof]', e);
    res.status(502).json({ error: String(e.message || e) });
  }
});

// Verify a payment proof (recipient)
app.post('/verify', async (req, res) => {
  try {
    const txid = String(req.body?.txid || '').trim();
    const address = String(req.body?.address || '').trim();
    const message = String(req.body?.message || '');
    const signature = String(req.body?.signature || '').trim();

    if (!HEX64.test(txid)) return res.status(400).json({ error: 'bad txid' });
    if (!signature) return res.status(400).json({ error: 'missing signature' });

    const out = await rpc('check_tx_proof', { txid, address, message, signature });
    res.json({
      ok: true,
      good: !!out.good,
      in_pool: !!out.in_pool,
      received_xmr: toXMR(out.received || 0)
    });
  } catch (e) {
    console.error('[verify]', e);
    res.status(502).json({ error: String(e.message || e) });
  }
});

// --- serve ---
if (require.main === module) {
  const arg = process.argv[2];
  if (!arg || arg === 'serve') {
    app.listen(PORT, HOST, () => {
      console.log(`xmr-bridge on http://${HOST}:${PORT}`);
      console.log(`RPC → ${WALLET_RPC}`);
      if (API_KEY) console.log('API key required');
    });
  }
}

module.exports = app;
