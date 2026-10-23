# 코스피200 ELS 모니터 - 시장 데이터 수집
# 출처: 네이버 증권(국내 지수·종목 일봉/현재가, 시총 상위, 투자자별 매매동향), Yahoo Finance chart API(해외지표)
# 결과: 같은 폴더의 data\*.json (대시보드에 업로드되는 파일)
param(
  [string]$BaseDate = '2026-10-07',    # ELS 기준일
  [string]$HistoryFrom = '2026-07-01', # 지수 차트 시작일
  [string]$OutDir = (Join-Path $PSScriptRoot 'data')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$headers = @{ 'User-Agent' = 'Mozilla/5.0' }
$outDir = $OutDir
New-Item -ItemType Directory -Force $outDir | Out-Null
# GitHub Actions(UTC)에서도 한국 시각으로 기록
$kst = [TimeSpan]::FromHours(9)
$asOf = [DateTimeOffset]::UtcNow.ToOffset($kst).ToString('yyyy-MM-ddTHH:mm:sszzz')

# 네이버 시각 문자열(PowerShell 7은 날짜로 자동 변환함) -> 한국 시각
function To-Kst($v) {
  if ($v -is [datetime]) { return ([DateTimeOffset]$v).ToOffset($kst) }
  return [DateTimeOffset]::Parse([string]$v).ToOffset($kst)
}

function Get-Json($url) {
  $r = Invoke-WebRequest -UseBasicParsing -Headers $headers $url
  $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  return $text | ConvertFrom-Json
}

function To-Num($s) {
  if ($null -eq $s) { return $null }
  $t = ([string]$s) -replace '[,+%]', ''
  if ($t -eq '' -or $t -eq 'N/A') { return $null }
  return [double]$t
}

# Yahoo 일봉: 날짜(현지) -> 종가
function Get-Daily($symbol, $from) {
  $p1 = [int][double]::Parse(((Get-Date $from).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)
  $p2 = [int][double]::Parse(((Get-Date).ToUniversalTime().AddDays(1) - [datetime]'1970-01-01').TotalSeconds)
  $enc = [uri]::EscapeDataString($symbol)
  $j = Get-Json "https://query1.finance.yahoo.com/v8/finance/chart/$($enc)?period1=$p1&period2=$p2&interval=1d"
  $res = $j.chart.result[0]
  $off = [int]$res.meta.gmtoffset
  $closes = $res.indicators.quote[0].close
  $rows = @()
  for ($i = 0; $i -lt $res.timestamp.Count; $i++) {
    if ($null -eq $closes[$i]) { continue }
    $d = ([datetime]'1970-01-01').AddSeconds([double]$res.timestamp[$i] + $off).ToString('yyyy-MM-dd')
    $rows += [pscustomobject]@{ date = $d; close = [math]::Round([double]$closes[$i], 4) }
  }
  # 같은 날짜가 두 번 오면(장중 마지막 봉) 마지막 값만 남김
  $rows = $rows | Group-Object date | ForEach-Object { $_.Group[-1] }
  return [pscustomobject]@{ meta = $res.meta; rows = @($rows) }
}

# 네이버 일봉(fchart): 날짜 -> 시가/고가/저가/종가 (국내 지수·종목)
function Get-NaverDaily($symbol, $count) {
  $r = Invoke-WebRequest -UseBasicParsing -Headers $headers "https://fchart.stock.naver.com/sise.nhn?symbol=$symbol&timeframe=day&count=$count&requestType=0"
  # 응답은 EUC-KR이지만 쓰는 값은 숫자뿐이라 ASCII로 읽음(PowerShell 7 호환)
  $text = [Text.Encoding]::ASCII.GetString($r.RawContentStream.ToArray())
  $rows = @()
  foreach ($m in [regex]::Matches($text, 'data="([^"]+)"')) {
    $f = $m.Groups[1].Value.Split('|')
    $rows += [pscustomobject]@{
      date = '{0}-{1}-{2}' -f $f[0].Substring(0, 4), $f[0].Substring(4, 2), $f[0].Substring(6, 2)
      open = [double]$f[1]; high = [double]$f[2]; low = [double]$f[3]; close = [double]$f[4]
    }
  }
  return @($rows)
}

function Get-BaseClose($rows, $date) {
  $hit = $rows | Where-Object { $_.date -le $date } | Select-Object -Last 1
  if ($hit) { return $hit } else { return $null }
}

function Pct($a, $b) { if ($a -and $b) { return [math]::Round(($a / $b - 1) * 100, 2) } else { return $null } }

# 1) 지수: 코스피200, 코스피, 코스닥
$indices = @(
  @{ symbol = 'KPI200'; key = 'KOSPI200'; name = '코스피200' },
  @{ symbol = 'KOSPI';  key = 'KOSPI';    name = '코스피' },
  @{ symbol = 'KOSDAQ'; key = 'KOSDAQ';   name = '코스닥' }
)
$indexDaily = @(); $indexSummary = @()
foreach ($ix in $indices) {
  $all = Get-NaverDaily $ix.symbol 260
  $live = Get-Json "https://m.stock.naver.com/api/index/$($ix.symbol)/basic"
  $price = To-Num $live.closePrice
  $liveAt = To-Kst $live.localTradedAt
  $today = $liveAt.ToString('yyyy-MM-dd')
  # 장중에는 fchart 마지막 봉을 실시간 값으로 덮어씀
  if ($all[-1].date -eq $today) { $all[-1].close = $price }
  foreach ($r in ($all | Where-Object { $_.date -ge $HistoryFrom })) {
    $indexDaily += [pscustomobject]@{ index = $ix.key; name = $ix.name; date = $r.date; close = $r.close }
  }
  $base = Get-BaseClose $all $BaseDate
  $last = $all[-1]
  $indexSummary += [pscustomobject]@{
    index = $ix.key; name = $ix.name; price = $price
    change = (To-Num $live.compareToPreviousClosePrice); changePct = (To-Num $live.fluctuationsRatio)
    baseDate = $base.date; baseClose = $base.close; sinceBasePct = (Pct $price $base.close)
    dayHigh = $last.high; dayLow = $last.low
    high52 = ($all | Measure-Object high -Maximum).Maximum; low52 = ($all | Measure-Object low -Minimum).Minimum
    marketStatus = $live.marketStatus
    tradedAt = $liveAt.ToString('yyyy-MM-dd HH:mm'); asOf = $asOf
  }
}

# 2) 코스피 시가총액 상위 10 (우선주·ETF 제외: 코스피200 구성종목은 보통주)
$mv = Get-Json 'https://m.stock.naver.com/api/stocks/marketValue/KOSPI?page=1&pageSize=30'
$picked = @($mv.stocks | Where-Object { $_.stockEndType -eq 'stock' -and $_.stockName -notmatch '우$|우B$|우\(전환\)$' } | Select-Object -First 10)
$top10 = @(); $top10Daily = @(); $rank = 0
foreach ($s in $picked) {
  $rank++
  $rows = Get-NaverDaily $s.itemCode 60
  $base = Get-BaseClose $rows $BaseDate
  $price = To-Num $s.closePrice
  $stockAt = To-Kst $s.localTradedAt
  if ($rows[-1].date -eq $stockAt.ToString('yyyy-MM-dd')) { $rows[-1].close = $price }
  foreach ($r in ($rows | Where-Object { $_.date -ge $base.date })) {
    $top10Daily += [pscustomobject]@{ code = $s.itemCode; name = $s.stockName; date = $r.date; close = $r.close }
  }
  $top10 += [pscustomobject]@{
    rank = $rank; code = $s.itemCode; name = $s.stockName; price = $price
    change = (To-Num $s.compareToPreviousClosePrice); changePct = (To-Num $s.fluctuationsRatio)
    marketCapTrillion = [math]::Round((To-Num $s.marketValue) / 10000, 1)  # 억원 -> 조원
    tradingValueBillion = [math]::Round((To-Num $s.accumulatedTradingValue) / 100, 0)  # 백만원 -> 억원
    baseDate = $base.date; baseClose = $base.close; sinceBasePct = (Pct $price $base.close)
    tradedAt = $stockAt.ToString('yyyy-MM-dd HH:mm'); asOf = $asOf
  }
}

# 3) 지수에 영향을 주는 대외 변수
$drivers = @(
  @{ symbol = 'KRW=X';     key = 'USDKRW'; name = '원/달러 환율'; group = '환율·금리' },
  @{ symbol = 'DX-Y.NYB';  key = 'DXY';    name = '달러인덱스';   group = '환율·금리' },
  @{ symbol = '^TNX';      key = 'US10Y';  name = '미 국채 10년 금리(%)'; group = '환율·금리' },
  @{ symbol = '^GSPC';     key = 'SPX';    name = 'S&P 500';      group = '미국 증시' },
  @{ symbol = '^IXIC';     key = 'NASDAQ'; name = '나스닥 종합';   group = '미국 증시' },
  @{ symbol = '^SOX';      key = 'SOX';    name = '필라델피아 반도체'; group = '미국 증시' },
  @{ symbol = '^N225';     key = 'NIKKEI'; name = '닛케이 225';    group = '아시아 증시' },
  @{ symbol = 'CL=F';      key = 'WTI';    name = 'WTI 유가($)';  group = '원자재' }
)
$driverRows = @()
foreach ($dv in $drivers) {
  try {
    $d = Get-Daily $dv.symbol (Get-Date $BaseDate).AddDays(-14).ToString('yyyy-MM-dd')
    $m = $d.meta
    $price = [double]$m.regularMarketPrice
    $prev = $d.rows | Where-Object { $_.date -lt ($d.rows[-1].date) } | Select-Object -Last 1
    $base = Get-BaseClose $d.rows $BaseDate
    $driverRows += [pscustomobject]@{
      key = $dv.key; name = $dv.name; group = $dv.group; price = [math]::Round($price, 2)
      changePct = (Pct $price $prev.close); baseClose = $base.close; sinceBasePct = (Pct $price $base.close)
      tradedAt = ([datetime]'1970-01-01').AddSeconds([double]$m.regularMarketTime + [int]$m.gmtoffset).ToString('yyyy-MM-dd HH:mm')
      asOf = $asOf
    }
  } catch { Write-Warning "$($dv.symbol): $_" }
}

# 4) 투자자별 순매수(억원)와 등락 종목 수
$flows = @()
foreach ($mk in @(@{ code = 'KOSPI'; name = '코스피' }, @{ code = 'KOSDAQ'; name = '코스닥' })) {
  $j = Get-Json "https://m.stock.naver.com/api/index/$($mk.code)/integration"
  $t = $j.dealTrendInfo; $u = $j.upDownStockInfo; $p = $j.programTrendInfo
  $flows += [pscustomobject]@{
    market = $mk.code; name = $mk.name; bizdate = $t.bizdate
    individual = (To-Num $t.personalValue); foreign = (To-Num $t.foreignValue); institution = (To-Num $t.institutionalValue)
    program = (To-Num $p.indexTotalReal)
    rise = ((To-Num $u.riseCount) + (To-Num $u.upperCount)); fall = ((To-Num $u.fallCount) + (To-Num $u.lowerCount)); steady = (To-Num $u.steadyCount)
    asOf = $asOf
  }
}

$sets = @{
  'index_daily' = $indexDaily; 'index_summary' = $indexSummary
  'top10' = $top10; 'top10_daily' = $top10Daily
  'drivers' = $driverRows; 'flows' = $flows
}
foreach ($k in $sets.Keys) {
  $json = ConvertTo-Json -InputObject @($sets[$k]) -Depth 5 -Compress
  [IO.File]::WriteAllText((Join-Path $outDir "$k.json"), $json, (New-Object Text.UTF8Encoding $false))
  "{0}: {1} rows" -f $k, @($sets[$k]).Count
}
