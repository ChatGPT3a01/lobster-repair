[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

$ErrorActionPreference = "Stop"

$OPENCLAW_DIR = Join-Path $env:USERPROFILE ".openclaw"
$CONFIG_PATH = Join-Path $OPENCLAW_DIR "openclaw.json"
$CREDENTIALS_MEMO = Join-Path $OPENCLAW_DIR "my-credentials.json"
$GATEWAY_PORT = 18789
$GATEWAY_URL = "http://127.0.0.1:$GATEWAY_PORT"
$WEBHOOK_PATH = "/line/webhook"
$NGROK_API = "http://127.0.0.1:4040/api/tunnels"
$DEFAULT_MODEL = "openai/gpt-4.1"

function Write-Title($Text) {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    $Text" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step($Text) { Write-Host "  [步驟] $Text" -ForegroundColor Yellow }
function Write-Ok($Text) { Write-Host "  [完成] $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host "  [警告] $Text" -ForegroundColor DarkYellow }
function Write-Err($Text) { Write-Host "  [錯誤] $Text" -ForegroundColor Red }
function Write-Info($Text) { Write-Host "  [資訊] $Text" -ForegroundColor Gray }

function Test-Command($Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFail
    )

    & $FilePath @Arguments
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw "命令失敗：$FilePath $($Arguments -join ' ')"
    }
}

function Get-CredentialsMemo {
    if (-not (Test-Path $CREDENTIALS_MEMO)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $CREDENTIALS_MEMO -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-OpenClawConfig {
    if (-not (Test-Path $CONFIG_PATH)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $CONFIG_PATH -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current) { return $null }
        if (-not ($current.PSObject.Properties.Name -contains $segment)) { return $null }
        $current = $current.$segment
    }
    return $current
}

function Get-EndpointStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Uri
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 8
        return [pscustomobject]@{
            Ok         = $true
            StatusCode = [int]$response.StatusCode
            Error      = $null
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        $ok = $statusCode -eq 405
        return [pscustomobject]@{
            Ok         = $ok
            StatusCode = $statusCode
            Error      = $_.Exception.Message
        }
    }
}

function Get-NgrokPublicUrl {
    try {
        $result = Invoke-RestMethod -Uri $NGROK_API -TimeoutSec 5
        return ($result.tunnels | Where-Object { $_.proto -eq "https" } | Select-Object -First 1).public_url
    } catch {
        return $null
    }
}

function Test-GatewayHome {
    return Get-EndpointStatus -Uri "$GATEWAY_URL/"
}

function Test-WebhookLocal {
    return Get-EndpointStatus -Uri "$GATEWAY_URL$WEBHOOK_PATH"
}

function Show-QuickStatus {
    Write-Title "狀態儀表板"

    $gateway = Test-GatewayHome
    $webhook = Test-WebhookLocal
    $port = Get-NetTCPConnection -LocalPort $GATEWAY_PORT -ErrorAction SilentlyContinue
    $ngrokUrl = Get-NgrokPublicUrl
    $config = Get-OpenClawConfig

    Write-Host "  OpenClaw : $(if (Test-Command 'openclaw') { openclaw --version } else { '未安裝' })" -ForegroundColor White
    Write-Host "  Node.js  : $(if (Test-Command 'node') { node --version } else { '未安裝' })" -ForegroundColor White
    Write-Host "  ngrok    : $(if (Test-Command 'ngrok') { ngrok version } else { '未安裝或不在 PATH' })" -ForegroundColor White
    Write-Host ""
    Write-Host "  Gateway /           : $(if ($gateway.StatusCode) { $gateway.StatusCode } else { '失敗' })" -ForegroundColor White
    Write-Host "  Local /line/webhook : $(if ($webhook.StatusCode) { $webhook.StatusCode } else { '失敗' })" -ForegroundColor White
    Write-Host "  Port $GATEWAY_PORT       : $(if ($port) { '已監聽' } else { '未監聽' })" -ForegroundColor White
    Write-Host "  ngrok URL           : $(if ($ngrokUrl) { $ngrokUrl } else { '未啟動' })" -ForegroundColor White
    if ($ngrokUrl) {
        Write-Host "  Webhook URL         : $ngrokUrl$WEBHOOK_PATH" -ForegroundColor White
    }
    Write-Host ""

    if ($config) {
        Write-Host "  model.primary       : $(Get-ConfigValue -Object $config -Path @('agents','defaults','model','primary'))" -ForegroundColor White
        Write-Host "  gateway.port        : $(Get-ConfigValue -Object $config -Path @('gateway','port'))" -ForegroundColor White
        Write-Host "  line.enabled        : $(Get-ConfigValue -Object $config -Path @('channels','line','enabled'))" -ForegroundColor White
        Write-Host "  line.channelId      : $(Get-ConfigValue -Object $config -Path @('channels','line','channelId'))" -ForegroundColor White
    } else {
        Write-Warn "openclaw.json 不存在或格式錯誤"
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Repair-ConfigFromMemo {
    $memo = Get-CredentialsMemo
    if (-not $memo) {
        Write-Warn "找不到 my-credentials.json，無法自動回補設定"
        return $false
    }

    Write-Step "修正 openclaw.json"
    $config = Get-OpenClawConfig
    if (-not $config) {
        $config = [pscustomobject]@{}
    }

    if (-not ($config.PSObject.Properties.Name -contains "apiKeys") -or -not $config.apiKeys) {
        $config | Add-Member -NotePropertyName "apiKeys" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($memo.openai_api_key)) {
        $config.apiKeys | Add-Member -NotePropertyName "openai" -NotePropertyValue $memo.openai_api_key -Force
        [System.Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $memo.openai_api_key, "User")
    }

    if (-not ($config.PSObject.Properties.Name -contains "agents") -or -not $config.agents) {
        $config | Add-Member -NotePropertyName "agents" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($config.agents.PSObject.Properties.Name -contains "defaults") -or -not $config.agents.defaults) {
        $config.agents | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($config.agents.defaults.PSObject.Properties.Name -contains "model") -or -not $config.agents.defaults.model) {
        $config.agents.defaults | Add-Member -NotePropertyName "model" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $config.agents.defaults.model | Add-Member -NotePropertyName "primary" -NotePropertyValue $DEFAULT_MODEL -Force

    if (-not ($config.PSObject.Properties.Name -contains "gateway") -or -not $config.gateway) {
        $config | Add-Member -NotePropertyName "gateway" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $config.gateway | Add-Member -NotePropertyName "port" -NotePropertyValue $GATEWAY_PORT -Force

    if (-not ($config.PSObject.Properties.Name -contains "channels") -or -not $config.channels) {
        $config | Add-Member -NotePropertyName "channels" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $allowFrom = @()
    if (-not [string]::IsNullOrWhiteSpace($memo.line_user_id)) {
        $allowFrom = @($memo.line_user_id)
    }

    $lineObject = [pscustomobject]@{
        enabled            = $true
        channelId          = $memo.line_channel_id
        channelSecret      = $memo.line_channel_secret
        channelAccessToken = $memo.line_access_token
        dmPolicy           = "allowlist"
        allowFrom          = $allowFrom
    }
    $config.channels | Add-Member -NotePropertyName "line" -NotePropertyValue $lineObject -Force

    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CONFIG_PATH -Encoding UTF8

    $agentsDir = Join-Path $OPENCLAW_DIR "agents"
    if (Test-Path $agentsDir) {
        Remove-Item -LiteralPath $agentsDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "已清除 agent 快取"
    }

    return $true
}

function Restart-Gateway {
    Write-Step "重啟 Gateway"
    Invoke-External -FilePath "openclaw" -Arguments @("gateway", "stop") -AllowFail
    Start-Sleep -Seconds 2
    Invoke-External -FilePath "openclaw" -Arguments @("gateway", "start") -AllowFail
    Start-Sleep -Seconds 8
    return Test-GatewayHome
}

function Start-NgrokIfPossible {
    if (-not (Test-Command "ngrok")) {
        Write-Warn "找不到 ngrok，略過通道啟動"
        return
    }

    Write-Step "重啟 ngrok"
    Get-Process ngrok -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process -FilePath "ngrok" -ArgumentList @("http", "$GATEWAY_PORT", "--region=ap") -WindowStyle Minimized | Out-Null
    Start-Sleep -Seconds 6
}

function Invoke-FullRepair {
    Write-Title "一鍵修復"

    $results = @()

    try {
        if (-not (Test-Command "node")) {
            throw "未安裝 Node.js"
        }
        $results += "[OK] Node.js：$(node --version)"
    } catch {
        $results += "[FAIL] Node.js：$($_.Exception.Message)"
    }

    try {
        if (-not (Test-Command "openclaw")) {
            throw "未安裝 OpenClaw"
        }
        $results += "[OK] OpenClaw：$(openclaw --version)"
    } catch {
        $results += "[FAIL] OpenClaw：$($_.Exception.Message)"
    }

    try {
        Invoke-External -FilePath "openclaw" -Arguments @("plugins", "install", "@openclaw/line") -AllowFail
        $results += "[OK] LINE plugin：已檢查"
    } catch {
        $results += "[FAIL] LINE plugin：$($_.Exception.Message)"
    }

    try {
        $configOk = Repair-ConfigFromMemo
        if ($configOk) {
            $results += "[OK] openclaw.json：已同步 port 18789 與 LINE 設定"
        } else {
            $results += "[FAIL] openclaw.json：缺少 my-credentials.json"
        }
    } catch {
        $results += "[FAIL] openclaw.json：$($_.Exception.Message)"
    }

    try {
        $gateway = Restart-Gateway
        if ($gateway.Ok) {
            $results += "[OK] Gateway：HTTP $($gateway.StatusCode)"
        } else {
            $results += "[FAIL] Gateway：$($gateway.Error)"
        }
    } catch {
        $results += "[FAIL] Gateway：$($_.Exception.Message)"
    }

    try {
        Start-NgrokIfPossible
        $ngrokUrl = Get-NgrokPublicUrl
        if ($ngrokUrl) {
            $results += "[OK] ngrok：$ngrokUrl$WEBHOOK_PATH"
        } else {
            $results += "[FAIL] ngrok：未取得公開網址"
        }
    } catch {
        $results += "[FAIL] ngrok：$($_.Exception.Message)"
    }

    try {
        $localWebhook = Test-WebhookLocal
        if ($localWebhook.Ok) {
            $results += "[OK] Local Webhook：HTTP $($localWebhook.StatusCode)"
        } else {
            $results += "[FAIL] Local Webhook：$($localWebhook.StatusCode) $($localWebhook.Error)"
        }
    } catch {
        $results += "[FAIL] Local Webhook：$($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "  ===== 修復結果 =====" -ForegroundColor Cyan
    foreach ($line in $results) {
        if ($line.StartsWith("[OK]")) {
            Write-Host "  $line" -ForegroundColor Green
        } else {
            Write-Host "  $line" -ForegroundColor Red
        }
    }

    $ngrokUrl = Get-NgrokPublicUrl
    if ($ngrokUrl) {
        Write-Host ""
        Write-Host "  請到 LINE Developers 貼上：" -ForegroundColor Cyan
        Write-Host "  $ngrokUrl$WEBHOOK_PATH" -ForegroundColor White
        Write-Host "  並確認 Use webhook 已開，Auto-reply message 已關。" -ForegroundColor Gray
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Invoke-WebhookDiagnosis {
    Write-Title "Webhook 深度診斷"

    $gateway = Test-GatewayHome
    $localWebhook = Test-WebhookLocal
    $ngrokUrl = Get-NgrokPublicUrl
    $publicRoot = $null
    $publicWebhook = $null

    Write-Host "  1. 本機 Gateway /" -ForegroundColor Cyan
    if ($gateway.Ok) {
        Write-Host "     OK：HTTP $($gateway.StatusCode)" -ForegroundColor Green
    } else {
        Write-Host "     FAIL：$($gateway.Error)" -ForegroundColor Red
    }

    Write-Host "  2. 本機 /line/webhook" -ForegroundColor Cyan
    if ($localWebhook.Ok) {
        Write-Host "     OK：HTTP $($localWebhook.StatusCode)" -ForegroundColor Green
    } else {
        Write-Host "     FAIL：HTTP $($localWebhook.StatusCode) $($localWebhook.Error)" -ForegroundColor Red
    }

    Write-Host "  3. ngrok 公開網址" -ForegroundColor Cyan
    if ($ngrokUrl) {
        Write-Host "     $ngrokUrl" -ForegroundColor White
        $publicRoot = Get-EndpointStatus -Uri $ngrokUrl
        $publicWebhook = Get-EndpointStatus -Uri "$ngrokUrl$WEBHOOK_PATH"
        Write-Host "     Public /            : $(if ($publicRoot.StatusCode) { $publicRoot.StatusCode } else { '失敗' })" -ForegroundColor White
        Write-Host "     Public /line/webhook: $(if ($publicWebhook.StatusCode) { $publicWebhook.StatusCode } else { '失敗' })" -ForegroundColor White
    } else {
        Write-Host "     未取得 ngrok URL" -ForegroundColor DarkYellow
    }

    Write-Host ""
    Write-Host "  ===== 研判 =====" -ForegroundColor Cyan
    if (-not $gateway.Ok) {
        Write-Host "  本機 Gateway 沒起來，先修 OpenClaw / port 18789。" -ForegroundColor Red
    } elseif ($localWebhook.StatusCode -eq 404) {
        Write-Host "  /line/webhook 不存在，通常是 LINE plugin 或 openclaw.json 有問題。" -ForegroundColor Red
    } elseif (-not $ngrokUrl) {
        Write-Host "  ngrok 沒正常啟動或沒有授權。" -ForegroundColor Red
    } elseif ($publicWebhook.StatusCode -eq 404) {
        Write-Host "  公開網址有了，但路徑錯。Webhook 一定要填 /line/webhook。" -ForegroundColor Red
    } elseif ($publicRoot -and -not $publicRoot.Ok -and $null -eq $publicRoot.StatusCode) {
        Write-Host "  本機正常、公開網址不通，偏向網路 / 防火牆 / IPv4 IPv6 問題。" -ForegroundColor Red
        Write-Host "  先換手機 hotspot 測；還不穩就改用 Cloudflare Tunnel。" -ForegroundColor Yellow
    } elseif ($publicWebhook.Ok) {
        Write-Host "  Webhook 路徑正常。去 LINE Developers 更新最新網址並按 Verify。" -ForegroundColor Green
    } else {
        Write-Host "  問題可能在 LINE 後台仍用舊網址，或通道還沒完全就緒。" -ForegroundColor DarkYellow
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Start-AllServices {
    Write-Title "一鍵啟動"

    try {
        $gateway = Restart-Gateway
        if ($gateway.Ok) {
            Write-Ok "Gateway 正常"
        } else {
            Write-Warn "Gateway 異常：$($gateway.Error)"
        }
    } catch {
        Write-Err $_.Exception.Message
    }

    try {
        Start-NgrokIfPossible
        $ngrokUrl = Get-NgrokPublicUrl
        if ($ngrokUrl) {
            Write-Ok "ngrok 已啟動"
            Write-Host "  Webhook URL：$ngrokUrl$WEBHOOK_PATH" -ForegroundColor White
        }
    } catch {
        Write-Err $_.Exception.Message
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Invoke-LinePairing {
    Write-Title "LINE 配對"
    Write-Host "  如果 LINE 顯示 access not configured，請把配對碼貼在下面。" -ForegroundColor White
    Write-Host ""
    $pairCode = Read-Host "  配對碼（直接 Enter 跳過）"
    if (-not [string]::IsNullOrWhiteSpace($pairCode)) {
        Invoke-External -FilePath "openclaw" -Arguments @("pairing", "approve", "line", $pairCode) -AllowFail
        Write-Ok "配對指令已送出"
    } else {
        Write-Info "已跳過配對"
    }
    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Show-Guide {
    Write-Title "操作導航"
    Write-Host "  日常使用：" -ForegroundColor Cyan
    Write-Host "  1. 先選『一鍵啟動』" -ForegroundColor White
    Write-Host "  2. 把最新 ngrok 網址 + /line/webhook 貼到 LINE Developers" -ForegroundColor White
    Write-Host "  3. 傳 LINE 訊息測試" -ForegroundColor White
    Write-Host ""
    Write-Host "  Verify 失敗時：" -ForegroundColor Cyan
    Write-Host "  1. 先跑『Webhook 深度診斷』" -ForegroundColor White
    Write-Host "  2. 確認不是舊網址" -ForegroundColor White
    Write-Host "  3. 確認不是少了 /line/webhook" -ForegroundColor White
    Write-Host "  4. 確認 Use webhook 有開、Auto-reply message 有關" -ForegroundColor White
    Write-Host ""
    Write-Host "  如果本機正常但外網失敗：" -ForegroundColor Cyan
    Write-Host "  先換手機 hotspot，再考慮改 Cloudflare Tunnel。" -ForegroundColor White
    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Show-HelpCommands {
    Write-Title "常用指令"
    Write-Host "  openclaw gateway start" -ForegroundColor White
    Write-Host "  openclaw gateway restart" -ForegroundColor White
    Write-Host "  openclaw doctor" -ForegroundColor White
    Write-Host "  openclaw plugins install @openclaw/line" -ForegroundColor White
    Write-Host "  openclaw pairing approve line <配對碼>" -ForegroundColor White
    Write-Host "  ngrok http 18789 --region=ap" -ForegroundColor White
    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Switch-ToGoogleModel {
    Write-Title "切換主模型"

    if (-not (Test-Path $CONFIG_PATH)) {
        Write-Err "找不到 $CONFIG_PATH"
        Read-Host "  按 Enter 返回選單"
        return
    }

    $config = Get-OpenClawConfig
    if (-not $config) {
        Write-Err "無法解析 openclaw.json"
        Read-Host "  按 Enter 返回選單"
        return
    }

    Write-Host "  目前主模型：$(Get-ConfigValue -Object $config -Path @('agents','defaults','model','primary'))" -ForegroundColor White
    Write-Host ""
    Write-Host "  可選模型：" -ForegroundColor Cyan
    Write-Host "    === Google Gemini ===" -ForegroundColor DarkGray
    Write-Host "    1. google/gemini-3-flash-preview（推薦，快速）"
    Write-Host "    2. google/gemini-3-pro-preview（最強預覽）"
    Write-Host "    === OpenAI ===" -ForegroundColor DarkGray
    Write-Host "    3. openai/gpt-5.4（推薦，最新）"
    Write-Host "    4. openai/gpt-5.4-pro（最強）"
    Write-Host "    5. openai/gpt-5.3-chat-latest（快速）"
    Write-Host "    === 免費/低價 ===" -ForegroundColor DarkGray
    Write-Host "    6. groq/llama-3.3-70b-versatile（免費）"
    Write-Host "    7. 取消"
    Write-Host ""
    $pick = Read-Host "  請選擇 1-7"

    $newModel = switch ($pick) {
        "1" { "google/gemini-3-flash-preview" }
        "2" { "google/gemini-3-pro-preview" }
        "3" { "openai/gpt-5.4" }
        "4" { "openai/gpt-5.4-pro" }
        "5" { "openai/gpt-5.3-chat-latest" }
        "6" { "groq/llama-3.3-70b-versatile" }
        default { $null }
    }

    if (-not $newModel) {
        Write-Info "已取消"
        Read-Host "  按 Enter 返回選單"
        return
    }

    $model = Get-ConfigValue -Object $config -Path @('agents','defaults','model')
    if (-not $model) {
        Write-Err "openclaw.json 缺少 agents.defaults.model"
        Read-Host "  按 Enter 返回選單"
        return
    }

    $model | Add-Member -NotePropertyName "primary" -NotePropertyValue $newModel -Force
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CONFIG_PATH -Encoding UTF8

    Write-Ok "已切換主模型為 $newModel"
    Write-Info "建議重啟 Gateway 使設定生效"
    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Show-RecentLogs {
    Write-Title "最近日誌"

    $logDir = Join-Path $env:TEMP "openclaw"
    if (-not (Test-Path $logDir)) {
        Write-Warn "找不到日誌目錄 $logDir"
        Read-Host "  按 Enter 返回選單"
        return
    }

    $log = Get-ChildItem $logDir -Filter "openclaw-*.log" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($log) {
        Write-Host "  檔案：$($log.FullName)" -ForegroundColor Gray
        Write-Host "  大小：$([math]::Round($log.Length / 1024, 1)) KB" -ForegroundColor Gray
        Write-Host "  修改：$($log.LastWriteTime)" -ForegroundColor Gray
        Write-Host ""
        Get-Content -LiteralPath $log.FullName -Tail 60
    } else {
        Write-Warn "找不到 OpenClaw 日誌檔"
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Invoke-LogAnalysis {
    Write-Title "日誌智慧分析"

    $logDir = Join-Path $env:TEMP "openclaw"
    if (-not (Test-Path $logDir)) {
        Write-Warn "找不到日誌目錄 $logDir"
        Read-Host "  按 Enter 返回選單"
        return
    }

    $log = Get-ChildItem $logDir -Filter "openclaw-*.log" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $log) {
        Write-Warn "找不到 OpenClaw 日誌檔"
        Read-Host "  按 Enter 返回選單"
        return
    }

    Write-Info "分析檔案：$($log.FullName)"
    Write-Info "大小：$([math]::Round($log.Length / 1024, 1)) KB｜修改：$($log.LastWriteTime)"
    Write-Host ""

    $logContent = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($logContent)) {
        Write-Warn "日誌檔案為空"
        Read-Host "  按 Enter 返回選單"
        return
    }

    $issueCount = 0

    # 1. Unknown model
    if ($logContent -match "(?i)Unknown model") {
        $issueCount++
        Write-Err "偵測到：Unknown model（模型未註冊）"
        Write-Host "    原因：OpenClaw 找不到設定的模型" -ForegroundColor Gray
        Write-Host "    修復：確認 openclaw.json 的 model.primary 名稱正確" -ForegroundColor Yellow
        Write-Host "    　　　若用 Ollama，確認環境變數有 OLLAMA_API_KEY" -ForegroundColor Yellow
        Write-Host ""
    }

    # 2. Model fallback activating
    if ($logContent -match "(?i)(model_not_found|fallback.*decision.*candidate_failed)") {
        $issueCount++
        Write-Err "偵測到：模型備援持續觸發"
        Write-Host "    原因：主模型失敗，正在使用備援模型" -ForegroundColor Gray
        Write-Host "    檢查：Ollama 是否正常運作？API Key 是否有效？" -ForegroundColor Yellow
        Write-Host "    檢查：模型是否支援 tool calling？" -ForegroundColor Yellow
        Write-Host ""
    }

    # 3. Invalid model config
    if ($logContent -match "(?i)agents\.defaults\.model.*Invalid input") {
        $issueCount++
        Write-Err "偵測到：模型設定格式錯誤"
        Write-Host "    原因：openclaw.json 中 model 區塊的 schema 有誤" -ForegroundColor Gray
        Write-Host "    修復：fallback 必須寫成 'fallbacks'（複數）且為陣列" -ForegroundColor Yellow
        Write-Host '    範例："model": { "primary": "openai/gpt-4.1", "fallbacks": ["openai/gpt-4o-mini"] }' -ForegroundColor Yellow
        Write-Host ""
    }

    # 4. Missing API key
    if ($logContent -match "(?i)At least one AI provider API key") {
        $issueCount++
        Write-Err "偵測到：缺少 API Key"
        Write-Host "    原因：OpenClaw 至少需要一個 API Key 才能啟動" -ForegroundColor Gray
        Write-Host "    修復：設定環境變數 OPENAI_API_KEY 或在 openclaw.json 中填入" -ForegroundColor Yellow
        Write-Host "    　　　可用一鍵修復自動從 my-credentials.json 回補" -ForegroundColor Yellow
        Write-Host ""
    }

    # 5. Connection refused (Ollama / external service)
    if ($logContent -match "(?i)(ECONNREFUSED|host\.docker\.internal)") {
        $issueCount++
        Write-Err "偵測到：連線被拒絕"
        Write-Host "    原因：無法連線到 Ollama 或外部服務" -ForegroundColor Gray
        Write-Host "    修復：確認目標服務正在執行中" -ForegroundColor Yellow
        Write-Host "    　　　若用 Docker，改用實際 IP 而非 host.docker.internal" -ForegroundColor Yellow
        Write-Host ""
    }

    # 6. Tool calling not supported
    if ($logContent -match "(?i)does not support tools") {
        $issueCount++
        Write-Err "偵測到：模型不支援工具呼叫"
        Write-Host "    原因：所選模型沒有 tool calling 能力" -ForegroundColor Gray
        Write-Host "    修復：切換到支援工具呼叫的模型" -ForegroundColor Yellow
        Write-Host "    　　　推薦：Qwen 2.5、Llama 3.1+、GPT-4o 系列" -ForegroundColor Yellow
        Write-Host ""
    }

    # 7. Rate limit / quota exceeded
    if ($logContent -match "(?i)(rate.?limit|quota.*exceeded|429)") {
        $issueCount++
        Write-Warn "偵測到：API 速率限制或配額超出"
        Write-Host "    原因：API 呼叫太頻繁或已超出月度額度" -ForegroundColor Gray
        Write-Host "    修復：稍等幾分鐘後重試，或檢查 API 帳戶的用量上限" -ForegroundColor Yellow
        Write-Host ""
    }

    # 8. SSL / certificate errors
    if ($logContent -match "(?i)(SSL|certificate|CERT_|self.signed|UNABLE_TO_VERIFY)") {
        $issueCount++
        Write-Warn "偵測到：SSL 憑證問題"
        Write-Host "    原因：自簽憑證或憑證驗證失敗" -ForegroundColor Gray
        Write-Host "    修復：若為開發環境，可設定 NODE_TLS_REJECT_UNAUTHORIZED=0" -ForegroundColor Yellow
        Write-Host "    　　　正式環境建議使用有效憑證" -ForegroundColor Yellow
        Write-Host ""
    }

    # 9. Port already in use
    if ($logContent -match "(?i)(EADDRINUSE|address already in use)") {
        $issueCount++
        Write-Err "偵測到：Port 被佔用"
        Write-Host "    原因：Gateway 要使用的端口已被其他程式佔用" -ForegroundColor Gray
        Write-Host "    修復：關閉佔用端口的程式，或更換 Gateway 端口" -ForegroundColor Yellow
        Write-Host ""
    }

    # 10. Out of memory
    if ($logContent -match "(?i)(out of memory|heap|ENOMEM|JavaScript heap)") {
        $issueCount++
        Write-Err "偵測到：記憶體不足"
        Write-Host "    原因：Node.js 或模型耗盡可用記憶體" -ForegroundColor Gray
        Write-Host "    修復：關閉不必要的程式，或增加 Node.js 記憶體上限" -ForegroundColor Yellow
        Write-Host '    　　　set NODE_OPTIONS=--max-old-space-size=4096' -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Host "  ===== 分析結果 =====" -ForegroundColor Cyan
    if ($issueCount -eq 0) {
        Write-Ok "未偵測到已知問題模式，日誌看起來正常"
    } else {
        Write-Warn "共偵測到 $issueCount 個已知問題"
        Write-Host "  建議先用『一鍵修復』嘗試自動修正，若仍有問題再逐項排查" -ForegroundColor Gray
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Invoke-EnvironmentCheck {
    Write-Title "環境健檢"

    $results = @()

    # 1. OS 版本
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($osInfo) {
        $results += "[OK] 作業系統：$($osInfo.Caption) ($($osInfo.Version))"
    } else {
        $results += "[WARN] 作業系統：無法偵測"
    }

    # 2. Node.js
    if (Test-Command "node") {
        $nodeVer = node --version 2>$null
        $majorVer = 0
        if ($nodeVer -match "v(\d+)") { $majorVer = [int]$Matches[1] }
        if ($majorVer -ge 18) {
            $results += "[OK] Node.js：$nodeVer"
        } else {
            $results += "[WARN] Node.js：$nodeVer（建議 v18 以上）"
        }
    } else {
        $results += "[FAIL] Node.js：未安裝"
    }

    # 3. OpenClaw
    if (Test-Command "openclaw") {
        $clawVer = openclaw --version 2>$null
        $results += "[OK] OpenClaw：$clawVer"
    } else {
        $results += "[FAIL] OpenClaw：未安裝"
    }

    # 4. ngrok
    if (Test-Command "ngrok") {
        $ngrokVer = ngrok version 2>$null
        $results += "[OK] ngrok：$ngrokVer"
    } else {
        $results += "[WARN] ngrok：未安裝或不在 PATH"
    }

    # 5. 記憶體
    if ($osInfo) {
        $totalGB = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
        $freeGB = [math]::Round($osInfo.FreePhysicalMemory / 1MB, 1)
        $usedPct = [math]::Round((1 - $osInfo.FreePhysicalMemory / $osInfo.TotalVisibleMemorySize) * 100, 0)
        if ($freeGB -lt 1) {
            $results += "[WARN] 記憶體：${totalGB} GB 總計，剩餘 ${freeGB} GB（使用率 ${usedPct}%，偏高）"
        } else {
            $results += "[OK] 記憶體：${totalGB} GB 總計，剩餘 ${freeGB} GB（使用率 ${usedPct}%）"
        }
    }

    # 6. 磁碟空間
    try {
        $disk = Get-PSDrive -Name C -ErrorAction SilentlyContinue
        if ($disk) {
            $freeDiskGB = [math]::Round($disk.Free / 1GB, 1)
            if ($freeDiskGB -lt 5) {
                $results += "[WARN] 磁碟 C：剩餘 ${freeDiskGB} GB（空間不足，建議至少 5 GB）"
            } else {
                $results += "[OK] 磁碟 C：剩餘 ${freeDiskGB} GB"
            }
        }
    } catch {
        $results += "[WARN] 磁碟：無法偵測"
    }

    # 7. GPU（嘗試偵測）
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gpu) {
            $vramMB = [math]::Round($gpu.AdapterRAM / 1MB, 0)
            if ($vramMB -gt 0) {
                $results += "[OK] GPU：$($gpu.Name)（VRAM 約 ${vramMB} MB）"
            } else {
                $results += "[OK] GPU：$($gpu.Name)"
            }
        } else {
            $results += "[WARN] GPU：無法偵測"
        }
    } catch {
        $results += "[WARN] GPU：無法偵測"
    }

    # 8. 設定檔
    if (Test-Path $CONFIG_PATH) {
        $configSize = [math]::Round((Get-Item $CONFIG_PATH).Length / 1024, 1)
        $results += "[OK] openclaw.json：存在（${configSize} KB）"
    } else {
        $results += "[FAIL] openclaw.json：不存在"
    }

    if (Test-Path $CREDENTIALS_MEMO) {
        $results += "[OK] my-credentials.json：存在"
    } else {
        $results += "[WARN] my-credentials.json：不存在（一鍵修復將無法自動回補）"
    }

    # 9. 環境變數
    $envKey = [System.Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "User")
    if (-not [string]::IsNullOrWhiteSpace($envKey)) {
        $masked = $envKey.Substring(0, [math]::Min(8, $envKey.Length)) + "..."
        $results += "[OK] OPENAI_API_KEY：已設定（${masked}）"
    } else {
        $results += "[WARN] OPENAI_API_KEY：未設定（使用者環境變數）"
    }

    # 10. Gateway port
    $portInUse = Get-NetTCPConnection -LocalPort $GATEWAY_PORT -ErrorAction SilentlyContinue
    if ($portInUse) {
        $results += "[OK] Port ${GATEWAY_PORT}：已有程式監聽（Gateway 可能已啟動）"
    } else {
        $results += "[INFO] Port ${GATEWAY_PORT}：未監聽（Gateway 尚未啟動）"
    }

    Write-Host "  ===== 環境健檢報告 =====" -ForegroundColor Cyan
    Write-Host ""
    foreach ($line in $results) {
        if ($line.StartsWith("[OK]")) {
            Write-Host "  $line" -ForegroundColor Green
        } elseif ($line.StartsWith("[FAIL]")) {
            Write-Host "  $line" -ForegroundColor Red
        } elseif ($line.StartsWith("[WARN]")) {
            Write-Host "  $line" -ForegroundColor DarkYellow
        } else {
            Write-Host "  $line" -ForegroundColor Gray
        }
    }

    $failCount = ($results | Where-Object { $_.StartsWith("[FAIL]") }).Count
    $warnCount = ($results | Where-Object { $_.StartsWith("[WARN]") }).Count
    Write-Host ""
    if ($failCount -gt 0) {
        Write-Err "有 $failCount 個關鍵項目缺失，請先處理再使用 OpenClaw"
    } elseif ($warnCount -gt 0) {
        Write-Warn "有 $warnCount 個警告，建議檢查但不影響基本運作"
    } else {
        Write-Ok "所有項目正常，環境就緒"
    }

    Write-Host ""
    Read-Host "  按 Enter 返回選單"
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Cyan
        Write-Host "    龍蝦 AI 修復工具" -ForegroundColor Cyan
        Write-Host "  ============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    --- 診斷與修復 ---" -ForegroundColor DarkGray
        Write-Host "    1. 狀態儀表板"
        Write-Host "    2. 一鍵修復"
        Write-Host "    3. Webhook 深度診斷"
        Write-Host "    4. 日誌智慧分析"
        Write-Host "    5. 環境健檢"
        Write-Host ""
        Write-Host "    --- 啟動與設定 ---" -ForegroundColor DarkGray
        Write-Host "    6. 一鍵啟動龍蝦 + ngrok"
        Write-Host "    7. LINE 配對"
        Write-Host "    8. 切換主模型"
        Write-Host ""
        Write-Host "    --- 參考資訊 ---" -ForegroundColor DarkGray
        Write-Host "    9. 最近日誌"
        Write-Host "    A. 操作導航"
        Write-Host "    B. 常用指令"
        Write-Host "    0. 離開"
        Write-Host ""

        $choice = Read-Host "  請輸入選項"
        switch ($choice) {
            "1" { Show-QuickStatus }
            "2" { Invoke-FullRepair }
            "3" { Invoke-WebhookDiagnosis }
            "4" { Invoke-LogAnalysis }
            "5" { Invoke-EnvironmentCheck }
            "6" { Start-AllServices }
            "7" { Invoke-LinePairing }
            "8" { Switch-ToGoogleModel }
            "9" { Show-RecentLogs }
            "A" { Show-Guide }
            "a" { Show-Guide }
            "B" { Show-HelpCommands }
            "b" { Show-HelpCommands }
            "0" { return }
            default {
                Write-Warn "無效選項"
                Start-Sleep -Seconds 1
            }
        }
    }
}

Show-Menu
