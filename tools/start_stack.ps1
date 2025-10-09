<#
Start the full local Monero stagenet stack on Windows:
- monerod.exe (stagenet)
- monero-wallet-rpc.exe (stagenet)
- Node bridge (tools\xmr-bridge)

Creates logs in .\logs\ and verifies health endpoints.
#>

[CmdletBinding()]
param(
  [string]$DaemonHost = "127.0.0.1",
  [int]$DaemonPort = 38081,
  [string]$WalletRpcHost = "127.0.0.1",
  [int]$WalletRpcPort = 18083,
  [string]$WalletFile = ".\demo",
  [string]$WalletPassword = "XMRm4x!2025secure",
  [string]$BridgeDir = ".\tools\xmr-bridge",
  [int]$BridgePort = 8787
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path .).Path
$logs = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

function Start-Proc {
  param([string]$Name, [string]$Exe, [string]$Args, [string]$Log)
  Write-Host "▶ Starting $Name..." -ForegroundColor Cyan
  $si = New-Object System.Diagnostics.ProcessStartInfo
  $si.FileName = $Exe
  $si.Arguments = $Args
  $si.WorkingDirectory = Split-Path $Exe
  $si.RedirectStandardOutput = $true
  $si.RedirectStandardError  = $true
  $si.UseShellExecute = $false
  $si.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $si
  $null = $p.Start()
  $p.StandardOutput.BeginReadLine()
  $p.StandardError.BeginReadLine()
  $outLog = Join-Path $logs $Log
  Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action {
    if ($EventArgs.Data) { Add-Content -Path $args[0] -Value $EventArgs.Data }
  } -MessageData $outLog | Out-Null
  Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action {
    if ($EventArgs.Data) { Add-Content -Path $args[0] -Value $EventArgs.Data }
  } -MessageData $outLog | Out-Null
  return $p
}

function Wait-HttpOk {
  param([string]$Url, [int]$TimeoutSec = 60)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
      $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
    } catch { Start-Sleep 1 }
  }
  return $false
}

# Locate executables (assumes they’re in repo root; tweak if different)
$monerod = Join-Path $root "monerod.exe"
$wallet  = Join-Path $root "monero-wallet-rpc.exe"

if (!(Test-Path $monerod)) { throw "monerod.exe not found at $monerod" }
if (!(Test-Path $wallet))  { throw "monero-wallet-rpc.exe not found at $wallet" }
if (!(Test-Path $BridgeDir)) { throw "Bridge dir not found: $BridgeDir" }

# 1) monerod (stagenet)
$daemonArgs = @(
  "--stagenet",
  "--rpc-bind-ip", $DaemonHost,
  "--rpc-bind-port", $DaemonPort,
  "--prune-blockchain",
  "--db-sync-mode", "fast:async:1000000",
  "--max-concurrency", "2"
) -join " "
$procDaemon = Start-Proc -Name "monerod" -Exe $monerod -Args $daemonArgs -Log "daemon.log"

# 2) wallet-rpc (stagenet)
$walletArgs = @(
  "--stagenet",
  "--daemon-address", "http://$DaemonHost`:$DaemonPort",
  "--trusted-daemon",
  "--rpc-bind-ip", $WalletRpcHost,
  "--rpc-bind-port", $WalletRpcPort,
  "--disable-rpc-login",
  "--wallet-file", $WalletFile,
  "--password", $WalletPassword,
  "--log-level", "1"
) -join " "
$procWallet = Start-Proc -Name "wallet-rpc" -Exe $wallet -Args $walletArgs -Log "wallet-rpc.log"

# 3) Node bridge
Push-Location $BridgeDir
$env:WALLET_RPC_URL = "http://$WalletRpcHost`:$WalletRpcPort/json_rpc"
$procBridge = Start-Proc -Name "bridge" -Exe "npm.cmd" -Args "start" -Log "bridge.log"
Pop-Location

# Health checks
Write-Host "⏳ Waiting for daemon / wallet / bridge to respond..." -ForegroundColor Yellow

$okDaemon = Wait-HttpOk -Url "http://$DaemonHost`:$DaemonPort/get_info"
$okWallet = $false
try {
  $body = @{ jsonrpc="2.0"; id=0; method="get_version" } | ConvertTo-Json
  $r = Invoke-WebRequest -Uri "http://$WalletRpcHost`:$WalletRpcPort/json_rpc" -Method POST -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 5
  if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { $okWallet = $true }
} catch { }

$okBridge = Wait-HttpOk -Url "http://127.0.0.1:$BridgePort/health"

# Status output without ternary (compatible PS5/PS7)
$daemonStatus = if ($okDaemon) { "OK" } else { "FAIL" }
$walletStatus = if ($okWallet) { "OK" } else { "FAIL" }
$bridgeStatus = if ($okBridge) { "OK" } else { "FAIL" }

Write-Host "daemon: $daemonStatus"
Write-Host "wallet-rpc: $walletStatus"
Write-Host "bridge: $bridgeStatus"

if (-not $okBridge) {
  Write-Warning "Bridge not healthy yet. Tail logs in .\logs\bridge.log"
} else {
  try { Start-Process "http://127.0.0.1:$BridgePort/health" } catch { }
}

Write-Host "✅ Stack started. Logs in: $logs" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop (or kill processes manually)." -ForegroundColor Yellow

