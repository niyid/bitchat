# XMR Bridge (wallet-rpc)

Endpoints: /health, /address, /estimate, /transfer, /tx/:txid, /proof, /verify

## Dev
- Set WALLET_RPC_URL (stagenet/local): \http://127.0.0.1:18083/json_rpc\
- Start: \
pm start\

## Quick test (PowerShell)
curl http://127.0.0.1:8787/health
Invoke-RestMethod http://127.0.0.1:8787/address -Method POST -ContentType 'application/json' -Body (@{label='demo'}|ConvertTo-Json)
