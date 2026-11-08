<#
.SYNOPSIS
    论文引用核验器 —— 把"凭记忆写文献"换成"抓页面取文献"。

.DESCRIPTION
    四种动作：
      search  按标题/主题检索 OpenAlex / CrossRef / arXiv（可选百度中文网页），
              每条结果都带一个可点击的落地页链接，并给出与查询的相似度。
      verify  对给定 DOI / URL / 标题做核验。只有真拿到 DOI 解析记录或页面元数据
              才返回 VERIFIED；否则返回 NOT_FOUND，绝不用相似文献顶替。
      page    抓取任意文献落地页，抽取题名/作者/期刊/年/卷/期/页/DOI。
              优先读 Highwire citation_* meta；知网页面走专门的解析。
      cite    由 DOI 或 URL 生成 GB/T 7714-2015 或 APA 7 引用。

    PowerShell 7。退出码：0 = 至少一条 VERIFIED；2 = 全部未核到。

.EXAMPLE
    pwsh -File refcheck.ps1 search "attention is all you need" -Limit 3

.EXAMPLE
    pwsh -File refcheck.ps1 verify -Doi 10.1038/nature12373

.EXAMPLE
    pwsh -File refcheck.ps1 page -Url https://www.cnki.com.cn/Article/CJFDTotal-WYJY202303003.htm

.EXAMPLE
    pwsh -File refcheck.ps1 search "大语言模型对外语教学与研究的挑战与应对" -Cn
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('search', 'verify', 'page', 'cite', 'doctor', 'toc')]
    [string]$Action = 'search',

    [Parameter(Position = 1)]
    [string]$Query,

    [string]$Doi,
    [string]$Url,

    [int]$Limit = 5,
    [string[]]$Sources = @(),
    [switch]$Cn,
    [switch]$InitConfig,
    [string]$Journal,
    [string]$In,
    [int]$Year = 0,
    [int]$Issue = 0,
    [int]$MaxSeq = 28,
    [switch]$NoCache,
    [string]$Match,
    [ValidateSet('gbt', 'apa', 'both')]
    [string]$Style = 'gbt',
    [double]$Threshold = 0.80,
    [int]$Since = 0,
    [int]$Until = 0,
    [switch]$WithAbstract,
    [int]$TimeoutSec = 25,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$UA = 'paper-citation-guard/1.0 (DSH skill)'
# 最近一次网络失败的原因。用来区分"真的没有"和"根本没连上"——这两件事绝不能混
$Script:LastNetError = $null

# ---------------------------------------------------------------- 基础工具

function Invoke-Text {
    param([string]$Uri)
    try {
        $r = Invoke-WebRequest -Uri $Uri -TimeoutSec $TimeoutSec -UseBasicParsing `
            -Headers @{
                'User-Agent'      = $UA
                'Accept'          = 'application/json, text/html, application/xml;q=0.9, */*;q=0.8'
                'Accept-Language' = 'zh-CN,zh;q=0.9,en;q=0.8'
            }
        return $r.Content
    }
    catch {
        $m = $_.Exception.Message
        # 404 是"这个东西确实不存在"的明确答案，不是网络故障——不能混
        if ($m -match '404') { return $null }
        $Script:LastNetError = ($m -replace '\s+', ' ')
        return $null
    }
}

function Invoke-Json {
    param([string]$Uri)
    $t = Invoke-Text $Uri
    if (-not $t) {
        # 单次抖动（限流、超时）很常见，等一下再试一次再判失败
        Start-Sleep -Milliseconds 900
        $t = Invoke-Text $Uri
    }
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Get-Plain {
    param([string]$s)
    if (-not $s) { return '' }
    return ($s.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '')
}

function Get-Bigrams {
    param([string]$s)
    $p = Get-Plain $s
    if ([string]::IsNullOrEmpty($p)) { return @() }
    if ($p.Length -lt 2) { return @($p) }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($i = 0; $i -lt $p.Length - 1; $i++) { [void]$set.Add($p.Substring($i, 2)) }
    return @($set)
}

# 二元组 Dice 系数：对中英文标题都稳，短标题也不会被长标题带偏
# 注意：参数名不能用 $a/$b —— PowerShell 变量名大小写不敏感，会和局部 $A/$B 撞车，
# 撞车后赋值被参数类型 [string] 强制转换，数组变成字符串，.Count 恒为 1，相似度全错。
function Get-Sim {
    param([string]$TextA, [string]$TextB)
    $setA = Get-Bigrams $TextA
    $setB = Get-Bigrams $TextB
    if ($setA.Count -eq 0 -or $setB.Count -eq 0) { return 0.0 }
    $hit = 0
    foreach ($x in $setA) { if ($setB -contains $x) { $hit++ } }
    return [Math]::Round((2.0 * $hit) / ($setA.Count + $setB.Count), 3)
}

function New-Item {
    param(
        [string]$Source, [string]$Title, [string]$Authors, $Year, [string]$Venue,
        $Volume, $Issue, $Pages, [string]$Doi, [string]$Url, [string]$Type,
        [string]$Status = '', [double]$Score = 0.0, [string]$Note = '', [string]$Abstract = '', [string]$OaUrl = ''
    )
    [pscustomobject]@{
        Status  = $Status
        Score   = $Score
        Title   = $Title
        Authors = $Authors
        Year    = $Year
        Venue   = $Venue
        Volume  = $Volume
        Issue   = $Issue
        Pages   = $Pages
        Doi     = ($Doi -replace '^https?://(dx\.)?doi\.org/', '')
        Url     = $Url
        Source  = $Source
        Type    = $Type
        Note    = $Note
        Abstract = $Abstract
        OaUrl   = $OaUrl
        Citation = ''
    }
}

function Join-Pages {
    param($First, $Last)
    if (-not $First) { return $null }
    if ($Last -and $Last -ne $First) { return "$First-$Last" }
    return [string]$First
}

# ---------------------------------------------------------------- 检索源

# OpenAlex 把摘要存成 "词 -> 位置列表"，这里还原成正常句子
function Get-OaAbstract {
    param($Inv)
    if (-not $Inv) { return '' }
    $max = -1
    foreach ($p in $Inv.PSObject.Properties) { foreach ($i in @($p.Value)) { if ($i -gt $max) { $max = $i } } }
    if ($max -lt 0) { return '' }
    $arr = New-Object string[] ($max + 1)
    foreach ($p in $Inv.PSObject.Properties) { foreach ($i in @($p.Value)) { $arr[$i] = $p.Name } }
    return ((@($arr) | Where-Object { $_ }) -join ' ')
}

function Get-OpenAlex {
    param([string]$Q, [int]$N, [switch]$WithAbs)
    $sel = 'id,doi,display_name,publication_year,type,authorships,primary_location,biblio'
    if ($WithAbs) { $sel += ',abstract_inverted_index' }
    $u = "https://api.openalex.org/works?search=$([uri]::EscapeDataString($Q))&per-page=$N&select=$sel"
    $f = @()
    if ($Since -gt 0) { $f += "from_publication_date:$Since-01-01" }
    if ($Until -gt 0) { $f += "to_publication_date:$Until-12-31" }
    if ($f.Count -gt 0) { $u += "&filter=$($f -join ',')" }
    $j = Invoke-Json $u
    if (-not $j) { return @() }
    $out = @()
    foreach ($w in @($j.results)) {
        if (-not $w -or -not $w.display_name) { continue }
        $venue = $null
        if ($w.primary_location -and $w.primary_location.source) { $venue = $w.primary_location.source.display_name }
        $landing = $null
        if ($w.primary_location) { $landing = $w.primary_location.landing_page_url }
        $pages = $null
        if ($w.biblio) { $pages = Join-Pages $w.biblio.first_page $w.biblio.last_page }
        $vol = $null; $iss = $null
        if ($w.biblio) { $vol = $w.biblio.volume; $iss = $w.biblio.issue }
        $authors = (@($w.authorships | ForEach-Object { $_.author.display_name }) -join ', ')
        $url = $null
        if ($w.doi) { $url = $w.doi } elseif ($landing) { $url = $landing }
        $out += New-Item -Source 'OpenAlex' -Title $w.display_name -Authors $authors -Year $w.publication_year `
            -Venue $venue -Volume $vol -Issue $iss -Pages $pages -Doi $w.doi -Url $url -Type $w.type `
            -Abstract (Get-OaAbstract $w.abstract_inverted_index)
    }
    return $out
}

# CrossRef 作者是 {family, given} 两栏：统一成自然序"名 姓"；中文名不加空格
function Get-CrossRefName {
    param($A)
    if (-not $A) { return '' }
    $fam = [string]$A.family
    $giv = [string]$A.given
    if (-not $fam -and -not $giv) { return [string]$A.name }
    if (($fam -match '[\p{IsCJKUnifiedIdeographs}]') -or ($giv -match '[\p{IsCJKUnifiedIdeographs}]')) {
        return "$fam$giv"
    }
    return ("$giv $fam").Trim()
}

function Get-CrossRef {
    param([string]$Q, [int]$N)
    $sel = 'DOI,title,author,issued,container-title,page,volume,issue,type'
    $u = "https://api.crossref.org/works?query.bibliographic=$([uri]::EscapeDataString($Q))&rows=$N&select=$sel"
    $f = @()
    if ($Since -gt 0) { $f += "from-pub-date:$Since-01-01" }
    if ($Until -gt 0) { $f += "until-pub-date:$Until-12-31" }
    if ($f.Count -gt 0) { $u += "&filter=$($f -join ',')" }
    $j = Invoke-Json $u
    if (-not $j) { return @() }
    $out = @()
    foreach ($it in @($j.message.items)) {
        if (-not $it) { continue }
        $title = ''
        if ($it.title) { $title = ($it.title -join ' ') }
        if (-not $title) { continue }
        $authors = @()
        foreach ($a in @($it.author)) {
            if (-not $a) { continue }
            $nm = Get-CrossRefName $a
            if (-not $nm) { $nm = $a.name }
            if ($nm) { $authors += $nm }
        }
        $year = $null
        if ($it.issued -and $it.issued.'date-parts' -and $it.issued.'date-parts'[0]) { $year = $it.issued.'date-parts'[0][0] }
        $venue = $null
        if ($it.'container-title') { $venue = ($it.'container-title' -join ' ') }
        $url = $null
        if ($it.DOI) { $url = "https://doi.org/$($it.DOI)" }
        $out += New-Item -Source 'CrossRef' -Title $title -Authors ($authors -join ', ') -Year $year `
            -Venue $venue -Volume $it.volume -Issue $it.issue -Pages $it.page -Doi $it.DOI -Url $url -Type $it.type
    }
    return $out
}

function Get-ArXiv {
    param([string]$Q, [int]$N)
    $u = "https://export.arxiv.org/api/query?search_query=all:$([uri]::EscapeDataString($Q))&max_results=$N"
    $t = Invoke-Text $u
    if (-not $t) { return @() }
    $out = @()
    try {
        $x = [xml]$t
        foreach ($e in @($x.feed.entry)) {
            if (-not $e) { continue }
            $title = ($e.title -replace '\s+', ' ').Trim()
            if (-not $title) { continue }
            $authors = @($e.author | ForEach-Object { $_.name }) -join ', '
            $year = $null
            if ($e.published) { $year = ([datetime]$e.published).Year }
            $id = [string]$e.id
            $doi = $null
            $m = [regex]::Match($id, 'abs/([^/]+)$')
            if ($m.Success) { $doi = "10.48550/arXiv.$($m.Groups[1].Value)" }
            $out += New-Item -Source 'arXiv' -Title $title -Authors $authors -Year $year `
                -Venue 'arXiv preprint' -Volume $null -Issue $null -Pages $null -Doi $doi -Url $id -Type 'preprint'
        }
    }
    catch { }
    return $out
}

# 中文网页检索：只用来"找到落地页"，本身不算证据。
# 百度会限流，360 兜底（360 的 href 是跳转壳，真地址在 data-mdurl 里）。
function New-CnItem {
    param([string]$Link, [string]$Html, [string]$Source)
    $text = (($Html -replace '(?s)<[^>]+>', ' ') -replace '&nbsp;', ' ')
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
    $hostName = ''
    try { $hostName = ([uri]$Link).Host } catch { return $null }
    return [pscustomobject]@{
        Source = $Source; Title = $text; Authors = $null; Year = $null; Venue = $hostName
        Volume = $null; Issue = $null; Pages = $null; Doi = $null; Url = $Link
        Type = 'lead'; Status = ''; Score = 0.0; Note = ''
    }
}

function Get-CnWeb {
    param([string]$Q, [int]$N)
    $academic = 'cnki\.com\.cn/Article|cnki\.com\.cn|cnki\.net|wanfangdata|cqvip|doi\.org'
    $q = [uri]::EscapeDataString($Q)
    $out = @()

    # 1) 百度：容器 div 的 mu 属性就是真实地址
    $h = Invoke-Text "https://www.baidu.com/s?wd=$q&ie=utf-8"
    if ($h -and $h.Length -gt 20000) {
        foreach ($b in [regex]::Matches($h, '<div[^>]*class="[^"]*c-container[^"]*"[\s\S]{0,6000}?</div>\s*</div>')) {
            $mu = [regex]::Match($b.Value, 'mu="([^"]+)"')
            if (-not $mu.Success) { continue }
            $link = $mu.Groups[1].Value
            if ($link -notmatch $academic) { continue }
            $it = New-CnItem -Link $link -Html $b.Value -Source 'Baidu'
            if ($it) { $out += $it }
        }
    }

    # 2) 360 兜底
    if ($out.Count -lt $N) {
        $h2 = Invoke-Text "https://www.so.com/s?q=$q"
        if (-not $h2 -or $h2.Length -lt 20000) {
            $h2 = Invoke-Text "https://www.so.com/s?q=$([uri]::EscapeDataString("site:cnki.com.cn $Q"))"
        }
        if ($h2 -and $h2.Length -gt 20000) {
            foreach ($a in [regex]::Matches($h2, '<a[^>]*>[\s\S]{0,600}?</a>')) {
                $tag = $a.Value
                $mu = [regex]::Match($tag, 'data-mdurl="([^"]+)"')
                if (-not $mu.Success) { continue }
                $link = $mu.Groups[1].Value
                if ($link -notmatch $academic) { continue }
                $it = New-CnItem -Link $link -Html $tag -Source '360'
                if ($it) { $out += $it }
            }
        }
    }

    # 按 URL 去重
    $seen = @{}
    $uniq = @()
    foreach ($it in $out) {
        $k = $it.Url.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $uniq += $it
    }
    if ($uniq.Count -gt $N) { $uniq = $uniq[0..($N - 1)] }
    return $uniq
}

# ---------------------------------------------------------------- 注册表与配置

$SkillRoot = Split-Path -Parent $PSScriptRoot
$RegistryPath = Join-Path $SkillRoot 'providers.json'
$ConfigPath = Join-Path $SkillRoot 'config.json'

function Get-Registry {
    if (-not (Test-Path $RegistryPath)) { return @() }
    try {
        $j = Get-Content $RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
        return @($j.providers)
    }
    catch { return @() }
}

function Get-Config {
    $empty = [pscustomobject]@{ email = ''; providers = [pscustomobject]@{} }
    if (-not (Test-Path $ConfigPath)) { return $empty }
    try { return (Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $empty }
}

# 支持 "email" 与 "core.apiKey" 两种键
function Get-ConfigValue {
    param([string]$Key)
    if (-not $Key) { return '' }
    $cfg = Get-Config
    if ($Key -eq 'email') { return [string]$cfg.email }
    $parts = $Key -split '\.'
    if ($parts.Count -ne 2) { return '' }
    $p = $cfg.providers.PSObject.Properties[$parts[0]]
    if (-not $p) { return '' }
    $v = $p.Value.PSObject.Properties[$parts[1]]
    if (-not $v) { return '' }
    return [string]$v.Value
}

function Get-AuthHeaders {
    param([string]$ProviderId)
    $h = @{ 'User-Agent' = $UA }
    switch ($ProviderId) {
        'core' { $k = Get-ConfigValue 'core.apiKey'; if ($k) { $h['Authorization'] = "Bearer $k" } }
        'semanticscholar' { $k = Get-ConfigValue 'semanticscholar.apiKey'; if ($k) { $h['x-api-key'] = $k } }
        'scopus' { $k = Get-ConfigValue 'scopus.apiKey'; if ($k) { $h['X-ELS-APIKey'] = $k } }
        'sciencedirect' { $k = Get-ConfigValue 'sciencedirect.apiKey'; if ($k) { $h['X-ELS-APIKey'] = $k } }
        'wos' { $k = Get-ConfigValue 'wos.apiKey'; if ($k) { $h['X-ApiKey'] = $k } }
        'ieee' { $k = Get-ConfigValue 'ieee.apiKey'; if ($k) { $h['x-api-key'] = $k } }
    }
    return $h
}

# 单库探活：返回 状态 + 说明
function Test-Provider {
    param($P)
    if (-not $P.enabled) { return [pscustomobject]@{ Id = $P.id; Name = $P.name; Status = '未启用'; Ms = 0; Hint = $P.note } }

    $auth = [string]$P.auth
    if ($auth -eq 'key') {
        $k = Get-ConfigValue $P.configKey
        if (-not $k) {
            return [pscustomobject]@{ Id = $P.id; Name = $P.name; Status = '缺 API key'; Ms = 0; Hint = "在 config.json 填 $($P.configKey)" }
        }
    }
    if ($auth -eq 'email' -and -not (Get-ConfigValue $P.configKey)) {
        return [pscustomobject]@{ Id = $P.id; Name = $P.name; Status = '缺 email'; Ms = 0; Hint = "在 config.json 填 $($P.configKey)" }
    }

    $probeUrl = [string]$P.probe
    if ($probeUrl -match '\{email\}') {
        $probeUrl = $probeUrl.Replace('{email}', [uri]::EscapeDataString([string](Get-ConfigValue 'email')))
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $h = Get-AuthHeaders $P.id
        Invoke-WebRequest -Uri $probeUrl -TimeoutSec 12 -UseBasicParsing -Headers $h | Out-Null
        $hint = ''
        if ($P.auth -eq 'email-optional' -and -not (Get-ConfigValue 'email')) { $hint = '填 email 可进 polite pool，更稳' }
        return [pscustomobject]@{ Id = $P.id; Name = $P.name; Status = '可连接'; Ms = $sw.ElapsedMilliseconds; Hint = $hint }
    }
    catch {
        $m = ($_.Exception.Message -replace '\s+', ' ')
        $st = '连不上'
        if ($m -match '429') { $st = '限流' }
        elseif ($m -match 'SSL|证书') { $st = '网络不通' }
        elseif ($m -match '401|403') { $st = '需鉴权' }
        elseif ($m -match '404') { $st = '接口变更' }
        return [pscustomobject]@{ Id = $P.id; Name = $P.name; Status = $st; Ms = $sw.ElapsedMilliseconds; Hint = $m.Substring(0, [Math]::Min(60, $m.Length)) }
    }
}

function Invoke-Doctor {
    $reg = Get-Registry
    if (@($reg).Count -eq 0) { Write-Host "❌ 找不到 $RegistryPath" -ForegroundColor Red; exit 2 }

    Write-Host ''
    Write-Host '论文引用核验 · 数据源自检' -ForegroundColor Cyan
    Write-Host "注册表：$RegistryPath"
    $cfgState = if (Test-Path $ConfigPath) { '（已存在）' } else { '（尚未创建）' }
    Write-Host "配置文件：$ConfigPath$cfgState"
    Write-Host ''

    $rows = @()
    foreach ($p in $reg) {
        $row = Test-Provider $p
        if ($p.id -in $Script:NoAdapter -and $row.Status -eq '可连接') { $row.Hint = ('无公开检索接口 · ' + $row.Hint).TrimEnd(' ', '·') }
        $rows += $row
    }

    $fmt = '{0,-22} {1,-8} {2,6}  {3}'
    Write-Host ($fmt -f '数据源', '状态', '耗时', '说明') -ForegroundColor DarkGray
    Write-Host ('─' * 100) -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $color = switch ($r.Status) {
            '可连接' { 'Green' }
            '缺 API key' { 'Yellow' }
            '未启用' { 'DarkGray' }
            default { 'Red' }
        }
        Write-Host ($fmt -f $r.Name, $r.Status, $(if ($r.Ms) { "$($r.Ms)ms" } else { '-' }), $r.Hint) -ForegroundColor $color
    }

    $ok = @($rows | Where-Object { $_.Status -eq '可连接' }).Count
    $need = @($rows | Where-Object { $_.Status -in @('缺 API key', '需鉴权') })
    Write-Host ''
    Write-Host "可连接 $ok / $($rows.Count)" -ForegroundColor Green

    if ($need.Count -gt 0) {
        Write-Host ''
        Write-Host '需要在 config.json 里补的：' -ForegroundColor Yellow
        foreach ($n in $need) {
            $p = $reg | Where-Object { $_.id -eq $n.Id } | Select-Object -First 1
            Write-Host ("  {0,-14} {1}" -f $p.configKey, $p.note)
        }
        if (-not (Test-Path $ConfigPath)) {
            Write-Host ''
            Write-Host '配置文件还不存在。运行下面这条会自动生成模板：' -ForegroundColor Yellow
            Write-Host "  pwsh -File `"$PSCommandPath`" doctor -InitConfig" -ForegroundColor Gray
        }
    }

    if ($Json) { $rows | ConvertTo-Json -Depth 4 }
}

function New-ConfigTemplate {
    $tpl = [ordered]@{
        '_说明'   = 'email 填你的邮箱（CrossRef/Unpaywall 用）；providers 下面按需填 apiKey，留空即不使用该库'
        'email'   = ''
        'providers' = [ordered]@{}
    }
    foreach ($p in (Get-Registry)) {
        if ($p.configKey -and $p.configKey -ne 'email') {
            $tpl.providers[$p.id] = [ordered]@{ apiKey = '' }
        }
    }
    $json = $tpl | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已生成模板：$ConfigPath" -ForegroundColor Green
}

# ---------------------------------------------------------------- 各库适配器

function Get-EuPMC {
    param([string]$Q, [int]$N)
    $u = "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=$([uri]::EscapeDataString($Q))&format=json&pageSize=$N&resultType=core"
    $j = Invoke-Json $u
    if (-not $j) { return @() }
    $out = @()
    foreach ($x in @($j.resultList.result)) {
        if (-not $x -or -not $x.title) { continue }
        $doi = [string]$x.doi
        $link = if ($doi) { "https://doi.org/$doi" } else { "https://europepmc.org/article/$($x.source)/$($x.id)" }
        $out += New-Item -Source 'EuropePMC' -Title $x.title -Authors $x.authorString -Year $x.pubYear `
            -Venue $x.journalTitle -Volume $x.journalVolume -Issue $x.issue -Pages $x.pageInfo `
            -Doi $doi -Url $link -Type 'journal-article'
    }
    return $out
}

function Get-DOAJ {
    param([string]$Q, [int]$N)
    $u = "https://doaj.org/api/search/articles/$([uri]::EscapeDataString($Q))?pageSize=$N"
    $j = Invoke-Json $u
    if (-not $j) { return @() }
    $out = @()
    foreach ($r in @($j.results)) {
        if (-not $r.bibjson -or -not $r.bibjson.title) { continue }
        $b = $r.bibjson
        $doi = $null
        foreach ($id in @($b.identifier)) {
            if ($id.type -eq 'doi') { $doi = ($id.id -replace '^https?://(dx\.)?doi\.org/', ''); break }
        }
        $names = @($b.author | ForEach-Object { $_.name })
        $link = if ($doi) { "https://doi.org/$doi" } elseif ($r.id) { "https://doaj.org/article/$($r.id)" } else { $null }
        $out += New-Item -Source 'DOAJ' -Title $b.title -Authors ($names -join ', ') -Year $b.year `
            -Venue $b.journal.title -Volume $b.journal.volume -Issue $b.journal.number `
            -Pages (Join-Pages $b.start_page $b.end_page) -Doi $doi -Url $link -Type 'journal-article'
    }
    return $out
}

function Get-DataCite {
    param([string]$Q, [int]$N)
    $u = "https://api.datacite.org/dois?query=$([uri]::EscapeDataString($Q))&page[size]=$N"
    $j = Invoke-Json $u
    if (-not $j) { return @() }
    $out = @()
    foreach ($d in @($j.data)) {
        if (-not $d.attributes) { continue }
        $a = $d.attributes
        $t = $null
        if ($a.titles -and $a.titles.Count -gt 0) { $t = [string]$a.titles[0].title }
        if (-not $t) { continue }
        if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '…' }
        $out += New-Item -Source 'DataCite' -Title $t -Authors $null -Year $a.publicationYear `
            -Venue $a.publisher -Volume $null -Issue $null -Pages $null -Doi $a.doi `
            -Url "https://doi.org/$($a.doi)" -Type 'dataset'
    }
    return $out
}

function Get-SemanticScholar {
    param([string]$Q, [int]$N)
    $k = Get-ConfigValue 'semanticscholar.apiKey'
    $h = @{ 'User-Agent' = $UA }
    if ($k) { $h['x-api-key'] = $k }
    $u = "https://api.semanticscholar.org/graph/v1/paper/search?query=$([uri]::EscapeDataString($Q))&limit=$N&fields=title,year,venue,externalIds,authors,abstract"
    try { $t = (Invoke-WebRequest -Uri $u -TimeoutSec $TimeoutSec -UseBasicParsing -Headers $h).Content } catch { return @() }
    try { $j = $t | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($p in @($j.data)) {
        if (-not $p.title) { continue }
        $doi = $null
        if ($p.externalIds -and $p.externalIds.DOI) { $doi = $p.externalIds.DOI }
        $names = @($p.authors | ForEach-Object { $_.name })
        $link = if ($doi) { "https://doi.org/$doi" } elseif ($p.paperId) { "https://www.semanticscholar.org/paper/$($p.paperId)" } else { $null }
        $out += New-Item -Source 'SemanticScholar' -Title $p.title -Authors ($names -join ', ') -Year $p.year `
            -Venue $p.venue -Volume $null -Issue $null -Pages $null -Doi $doi -Url $link -Type 'journal-article' `
            -Abstract ([string]$p.abstract)
    }
    return $out
}

function Get-CORE {
    param([string]$Q, [int]$N)
    $h = Get-AuthHeaders 'core'
    if (-not $h['Authorization']) { return @() }
    $u = "https://api.core.ac.uk/v3/search/works?q=$([uri]::EscapeDataString($Q))&limit=$N"
    try { $t = (Invoke-WebRequest -Uri $u -TimeoutSec $TimeoutSec -UseBasicParsing -Headers $h).Content } catch { return @() }
    try { $j = $t | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($w in @($j.results)) {
        if (-not $w.title) { continue }
        $doi = $null
        if ($w.doi) { $doi = $w.doi }
        $link = if ($doi) { "https://doi.org/$doi" } elseif ($w.downloadUrl) { $w.downloadUrl } else { $null }
        $out += New-Item -Source 'CORE' -Title $w.title -Authors ($w.authors -join ', ') -Year $w.yearPublished `
            -Venue $w.publisher -Volume $null -Issue $null -Pages $null -Doi $doi -Url $link -Type 'work' `
            -Abstract ([string]$w.abstract)
    }
    return $out
}

function Get-PubMed {
    param([string]$Q, [int]$N)
    $k = Get-ConfigValue 'pubmed.apiKey'
    $kq = if ($k) { "&api_key=$k" } else { '' }
    $s = Invoke-Json "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=$([uri]::EscapeDataString($Q))&retmode=json&retmax=$N$kq"
    if (-not $s -or -not $s.esearchresult.idlist) { return @() }
    $ids = @($s.esearchresult.idlist) -join ','
    $d = Invoke-Json "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=$ids&retmode=json$kq"
    if (-not $d) { return @() }
    $out = @()
    foreach ($id in @($s.esearchresult.idlist)) {
        $r = $d.result.$id
        if (-not $r) { continue }
        $doi = $null
        foreach ($a in @($r.articleids)) { if ($a.idtype -eq 'doi') { $doi = $a.value; break } }
        $link = if ($doi) { "https://doi.org/$doi" } else { "https://pubmed.ncbi.nlm.nih.gov/$id/" }
        $out += New-Item -Source 'PubMed' -Title $r.title -Authors (($r.authors | ForEach-Object { $_.name }) -join ', ') `
            -Year $r.pubdate -Venue $r.fulljournalname -Volume $r.volume -Issue $r.issue -Pages $r.pages `
            -Doi $doi -Url $link -Type 'journal-article'
    }
    return $out
}

# ---------------------------------------------------------------- 商业库 / 聚合库适配器
# 说明：Scopus、ScienceDirect、Springer、WoS 没有 key 时直接返回空，不会拖慢检索。
# 这几家的字段名带冒号（dc:title / prism:doi），PowerShell 里必须用引号取。

function Get-OpenAIRE {
    param([string]$Q, [int]$N)
    $u = "https://api.openaire.eu/graph/v1/researchProducts?search=$([uri]::EscapeDataString($Q))&type=publication&pageSize=$N"
    $j = Invoke-Json $u
    if (-not $j -or -not $j.results) { return @() }
    $out = @()
    foreach ($x in @($j.results)) {
        if (-not $x.mainTitle) { continue }
        $doi = $null
        foreach ($p in @($x.pids)) { if ($p.scheme -eq 'doi') { $doi = [string]$p.value; break } }
        $year = $null
        if ($x.publicationDate) {
            $m = [regex]::Match([string]$x.publicationDate, '(\d{4})')
            if ($m.Success) { $year = [int]$m.Groups[1].Value }
        }
        $names = @($x.authors | ForEach-Object {
                if ($_.fullName) { $_.fullName } else { ("$($_.name) $($_.surname)").Trim() }
            })
        $c = $x.container
        $venue = $null; $vol = $null; $iss = $null; $pages = $null
        if ($c) { $venue = $c.name; $vol = $c.vol; $iss = $c.iss; $pages = Join-Pages $c.sp $c.ep }
        $link = if ($doi) { "https://doi.org/$doi" } elseif ($x.id) { "https://explore.openaire.eu/search/publication?articleId=$($x.id)" } else { $null }
        $out += New-Item -Source 'OpenAIRE' -Title $x.mainTitle -Authors ($names -join ', ') -Year $year `
            -Venue $venue -Volume $vol -Issue $iss -Pages $pages -Doi $doi -Url $link -Type 'publication'
    }
    return $out
}

function Get-Scopus {
    param([string]$Q, [int]$N)
    $k = Get-ConfigValue 'scopus.apiKey'
    if (-not $k) { return @() }
    $h = @{ 'User-Agent' = $UA; 'X-ELS-APIKey' = $k; 'Accept' = 'application/json' }
    $u = "https://api.elsevier.com/content/search/scopus?query=TITLE-ABS-KEY($([uri]::EscapeDataString($Q)))&count=$N"
    try { $t = (Invoke-WebRequest -Uri $u -TimeoutSec $TimeoutSec -UseBasicParsing -Headers $h).Content } catch { return @() }
    try { $j = $t | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($e in @($j.'search-results'.entry)) {
        if (-not $e) { continue }
        $title = [string]$e.'dc:title'
        if (-not $title) { continue }
        $doi = [string]$e.'prism:doi'
        $year = $null
        $m = [regex]::Match([string]$e.'prism:coverDate', '(\d{4})')
        if ($m.Success) { $year = [int]$m.Groups[1].Value }
        $out += New-Item -Source 'Scopus' -Title $title -Authors ([string]$e.'dc:creator') -Year $year `
            -Venue ([string]$e.'prism:publicationName') -Volume $e.'prism:volume' -Issue $e.'prism:issueIdentifier' `
            -Pages $e.'prism:pageRange' -Doi $doi -Url $(if ($doi) { "https://doi.org/$doi" } else { $null }) -Type 'journal-article'
    }
    return $out
}

function Get-ScienceDirect {
    param([string]$Q, [int]$N)
    $k = Get-ConfigValue 'sciencedirect.apiKey'
    if (-not $k) { return @() }
    $h = @{ 'User-Agent' = $UA; 'X-ELS-APIKey' = $k; 'Accept' = 'application/json' }
    $u = "https://api.elsevier.com/content/search/sciencedirect?query=$([uri]::EscapeDataString($Q))&count=$N"
    try { $t = (Invoke-WebRequest -Uri $u -TimeoutSec $TimeoutSec -UseBasicParsing -Headers $h).Content } catch { return @() }
    try { $j = $t | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($e in @($j.'search-results'.entry)) {
        if (-not $e) { continue }
        $title = [string]$e.'dc:title'
        if (-not $title) { continue }
        $doi = [string]$e.'prism:doi'
        $year = $null
        $m = [regex]::Match([string]$e.'prism:coverDate', '(\d{4})')
        if ($m.Success) { $year = [int]$m.Groups[1].Value }
        $out += New-Item -Source 'ScienceDirect' -Title $title -Year $year `
            -Venue ([string]$e.'prism:publicationName') -Volume $e.'prism:volume' `
            -Pages $e.'prism:pageRange' -Doi $doi -Url $(if ($doi) { "https://doi.org/$doi" } else { $null }) -Type 'journal-article'
    }
    return $out
}

function Get-Springer {
    param([string]$Q, [int]$N)
    $k = Get-ConfigValue 'springer.apiKey'
    if (-not $k) { return @() }
    $u = "https://api.springernature.com/meta/v2/json?q=$([uri]::EscapeDataString($Q))&p=$N&api_key=$k"
    $j = Invoke-Json $u
    if (-not $j -or -not $j.records) { return @() }
    $out = @()
    foreach ($r in @($j.records)) {
        if (-not $r.title) { continue }
        $names = @($r.creators | ForEach-Object { $_.creator })
        $year = $null
        $m = [regex]::Match([string]$r.publicationDate, '(\d{4})')
        if ($m.Success) { $year = [int]$m.Groups[1].Value }
        $doi = [string]$r.doi
        $out += New-Item -Source 'Springer' -Title $r.title -Authors ($names -join ', ') -Year $year `
            -Venue ([string]$r.publicationName) -Volume $r.volume -Issue $r.number `
            -Pages (Join-Pages $r.startingPage $r.endingPage) -Doi $doi `
            -Url $(if ($doi) { "https://doi.org/$doi" } else { $null }) -Type 'journal-article'
    }
    return $out
}

function Get-WoS {
    param([string]$Q, [int]$N)
    $k = Get-ConfigValue 'wos.apiKey'
    if (-not $k) { return @() }
    $h = @{ 'User-Agent' = $UA; 'X-ApiKey' = $k; 'Accept' = 'application/json' }
    $u = "https://api.clarivate.com/apis/wos-starter/v1/documents?q=$([uri]::EscapeDataString($Q))&db=WOS&limit=$N&page=1"
    try { $t = (Invoke-WebRequest -Uri $u -TimeoutSec $TimeoutSec -UseBasicParsing -Headers $h).Content } catch { return @() }
    try { $j = $t | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($d in @($j.hits)) {
        if (-not $d -or -not $d.title) { continue }
        $names = @($d.names.authors | ForEach-Object { $_.displayName })
        $doi = $null
        if ($d.identifiers) { $doi = [string]$d.identifiers.doi }
        $out += New-Item -Source 'WoS' -Title $d.title -Authors ($names -join ', ') -Year $d.publishYear `
            -Venue ([string]$d.source.title) -Volume $d.source.volume -Issue $d.source.issue `
            -Pages (Join-Pages $d.source.pageStart $d.source.pageEnd) -Doi $doi `
            -Url $(if ($doi) { "https://doi.org/$doi" } else { $null }) -Type 'journal-article'
    }
    return $out
}

# Unpaywall 不是检索源，是「这个 DOI 有没有免费全文」的查询器
function Get-OaLocation {
    param([string]$Doi)
    $email = Get-ConfigValue 'email'
    if (-not $email -or -not $Doi) { return $null }
    # 注意：$Doi 后面紧跟 ? 时必须写 ${Doi}，否则 PowerShell 会把 "Doi?email" 当成变量名，DOI 被吞掉
    $j = Invoke-Json "https://api.unpaywall.org/v2/${Doi}?email=$([uri]::EscapeDataString($email))"
    if (-not $j) { return $null }
    $best = $j.best_oa_location
    $url = $null
    if ($best) { $url = if ($best.url_for_pdf) { $best.url_for_pdf } else { $best.url } }
    return [pscustomobject]@{ IsOa = [bool]$j.is_oa; Url = $url; Host = $(if ($best) { $best.host_type } else { $null }) }
}

# 调度：id -> 适配器
function Invoke-SearchProvider {
    param([string]$Id, [string]$Q, [int]$N)
    switch ($Id) {
        'openalex' { return Get-OpenAlex -Q $Q -N $N -WithAbs:$WithAbstract }
        'crossref' { return Get-CrossRef -Q $Q -N $N }
        'arxiv' { return Get-ArXiv -Q $Q -N $N }
        'europepmc' { return Get-EuPMC -Q $Q -N $N }
        'doaj' { return Get-DOAJ -Q $Q -N $N }
        'datacite' { return Get-DataCite -Q $Q -N $N }
        'semanticscholar' { return Get-SemanticScholar -Q $Q -N $N }
        'core' { return Get-CORE -Q $Q -N $N }
        'pubmed' { return Get-PubMed -Q $Q -N $N }
        'openaire' { return Get-OpenAIRE -Q $Q -N $N }
        'scopus' { return Get-Scopus -Q $Q -N $N }
        'sciencedirect' { return Get-ScienceDirect -Q $Q -N $N }
        'springer' { return Get-Springer -Q $Q -N $N }
        'wos' { return Get-WoS -Q $Q -N $N }
        'cnki' { return Get-CnWeb -Q $Q -N $N }
        default { return @() }
    }
}

# 确实没有可用检索接口的库：不是"没写解析"，是对方根本不提供检索 API
$Script:NoAdapter = @('ieee', 'jstor', 'wanfang', 'cqvip', 'ncpssd', 'biorxiv', 'unpaywall')

function Get-CoverageLine {
    param([string[]]$Tried, [string[]]$Failed)
    $ok = @($Tried | Where-Object { $_ -notin $Failed })
    $parts = @()
    if ($ok.Count -gt 0) { $parts += "已检索：$($ok -join '、')" }
    if ($Failed.Count -gt 0) { $parts += "未成功：$($Failed -join '、')" }
    $skipped = @((Get-Registry) | Where-Object { $_.enabled -and ($_.id -notin ($Tried + $Failed)) })
    if ($skipped.Count -gt 0) { $parts += "未启用/未配置：$(($skipped | ForEach-Object { $_.name }) -join '、')" }
    return ($parts -join '；')
}

# ---------------------------------------------------------------- 页面解析

function Get-MetaMap {
    param([string]$Html)
    $map = @{}
    $authors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($m in [regex]::Matches($Html, '<meta\s[^>]*>', 'IgnoreCase')) {
        $tag = $m.Value
        $nm = [regex]::Match($tag, '(?:name|property)\s*=\s*["'']([^"'']+)["'']', 'IgnoreCase')
        $ct = [regex]::Match($tag, 'content\s*=\s*["'']([^"'']*)["'']', 'IgnoreCase')
        if ($nm.Success -and $ct.Success) {
            $k = $nm.Groups[1].Value.ToLowerInvariant()
            $v = [System.Net.WebUtility]::HtmlDecode($ct.Groups[1].Value)
            if ($k -eq 'citation_author' -or $k -eq 'dc.creator') { $authors.Add($v) }
            if (-not $map.ContainsKey($k)) { $map[$k] = $v }
        }
    }
    return [pscustomobject]@{ Map = $map; Authors = @($authors) }
}

function Get-CnkiMeta {
    param([string]$Html)
    $title = $null; $venue = $null; $year = $null; $issue = $null; $authors = $null

    # <title>题名--《刊名》2023年03期</title>
    $t = [regex]::Match($Html, '<title>([\s\S]*?)</title>', 'IgnoreCase')
    if ($t.Success) {
        $raw = [System.Net.WebUtility]::HtmlDecode($t.Groups[1].Value) -replace '\s+', ' '
        $parts = $raw -split '--'
        $title = $parts[0].Trim()
        if ($parts.Count -gt 1) {
            $j = [regex]::Match($parts[1], '《([^》]+)》\s*(\d{4})年\s*(\d{1,2})期')
            if ($j.Success) {
                $venue = $j.Groups[1].Value
                $year = [int]$j.Groups[2].Value
                $issue = [int]$j.Groups[3].Value
            }
        }
    }

    # 作者：页面正文里 "论文排版" 之后、摘要之前那几行
    $plain = $Html -replace '(?s)<script.*?</script>', ' ' -replace '(?s)<style.*?</style>', ' ' -replace '<[^>]+>', "`n"
    $plain = [System.Net.WebUtility]::HtmlDecode($plain)
    $lines = @($plain -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^论文排版$') { $idx = $i; break } }
    if ($idx -ge 0) {
        $names = @()
        for ($k = $idx + 2; $k -lt [Math]::Min($idx + 10, $lines.Count); $k++) {
            $ln = $lines[$k]
            if ($ln -match '^(开通知|【摘要】|摘要|下载|关键词)') { break }
            # 姓名行：短、不含标点、至少有一个汉字或字母
            if ($ln.Length -le 20 -and $ln -match '[\p{L}]' -and $ln -notmatch '[，。；：、,.?！!？]') { $names += $ln } else { break }
        }
        if ($names.Count -gt 0) { $authors = ($names -join ', ') }
    }
    # 摘要：从 "【摘要】：" 到 "下载/关键词" 之间
    $abs = $null
    $ai = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^【摘要】') { $ai = $i; break } }
    if ($ai -ge 0) {
        $buf = $lines[$ai] -replace '^【摘要】[：:]?', ''
        for ($k = $ai + 1; $k -lt [Math]::Min($ai + 14, $lines.Count); $k++) {
            $ln = $lines[$k]
            if ($ln -match '^(下载App|下载全文|关键词|【关键词】|更多同类|「?摘要」?$)') { break }
            $buf += $ln
        }
        $abs = ($buf -replace '\s+', ' ').Trim()
        if ($abs.Length -gt 600) { $abs = $abs.Substring(0, 600) }
    }

    return [pscustomobject]@{ Title = $title; Authors = $authors; Venue = $venue; Year = $year; Issue = $issue; Volume = $null; Pages = $null; Doi = $null; Abstract = $abs }
}

function Get-PageMeta {
    param([string]$Link)
    $h = Invoke-Text $Link
    if (-not $h) { return $null }
    $hostName = ''
    try { $hostName = ([uri]$Link).Host } catch { }

    if ($hostName -match 'cnki\.com\.cn|cnki\.net') {
        $c = Get-CnkiMeta $h
        if ($c.Title) {
            $note = ''
            if (-not $c.Pages) { $note = '知网页面未显示页码：引用时省略页码，不要自行补全' }
            $o = New-Item -Source 'CNKI' -Title $c.Title -Authors $c.Authors -Year $c.Year -Venue $c.Venue `
                -Volume $c.Volume -Issue $c.Issue -Pages $c.Pages -Doi $null -Url $Link -Type 'journal-article' -Note $note -Abstract $c.Abstract
            return $o
        }
    }

    $mm = Get-MetaMap $h
    $map = $mm.Map
    $title = $map['citation_title']
    if (-not $title) { $title = $map['dc.title'] }
    if (-not $title) { $title = $map['og:title'] }
    if (-not $title) {
        $t = [regex]::Match($h, '<title>([\s\S]*?)</title>', 'IgnoreCase')
        if ($t.Success) { $title = ([System.Net.WebUtility]::HtmlDecode($t.Groups[1].Value) -replace '\s+', ' ').Trim() }
    }
    if (-not $title) { return $null }

    $authors = @($mm.Authors | Where-Object { $_ } | ForEach-Object { ConvertTo-NaturalName $_ } | Select-Object -Unique)

    $year = $null
    foreach ($k in @('citation_publication_date', 'citation_date', 'citation_year', 'dc.date')) {
        if ($map[$k]) { $y = [regex]::Match($map[$k], '(\d{4})'); if ($y.Success) { $year = [int]$y.Groups[1].Value; break } }
    }

    $doi = $map['citation_doi']
    if (-not $doi) { $doi = $map['dc.identifier'] }
    if (-not $doi) { $doi = $map['prism.doi'] }

    $venue = $map['citation_journal_title']
    if (-not $venue) { $venue = $map['citation_conference_title'] }
    $type = 'webpage'
    if ($venue) { $type = 'journal-article' }
    if ($hostName -match 'arxiv\.org') {
        if (-not $venue) { $venue = 'arXiv preprint' }
        $type = 'preprint'
        if (-not $doi) {
            $am = [regex]::Match($Link, 'abs/([^/?#]+)')
            if ($am.Success) { $doi = "10.48550/arXiv.$($am.Groups[1].Value)" }
        }
    }

    return New-Item -Source 'Web' -Title $title -Authors ($authors -join ', ') -Year $year `
        -Venue $venue -Volume $map['citation_volume'] -Issue $map['citation_issue'] `
        -Pages (Join-Pages $map['citation_firstpage'] $map['citation_lastpage']) -Doi $doi -Url $Link -Type $type
}

# ---------------------------------------------------------------- 核验

function Confirm-Doi {
    param([string]$D)
    if (-not $D) { return $null }
    $url = "https://doi.org/$D"

    # 1) CrossRef 是权威元数据
    $cr = Invoke-Json "https://api.crossref.org/works/$D"
    if ($cr -and $cr.message) {
        $msg = $cr.message
        $title = ''
        if ($msg.title) { $title = ($msg.title -join ' ') }
        $authors = @()
        foreach ($a in @($msg.author)) {
            if (-not $a) { continue }
            $nm = Get-CrossRefName $a; if (-not $nm) { $nm = $a.name }
            if ($nm) { $authors += $nm }
        }
        $year = $null
        if ($msg.issued -and $msg.issued.'date-parts' -and $msg.issued.'date-parts'[0]) { $year = $msg.issued.'date-parts'[0][0] }
        $venue = $null
        if ($msg.'container-title') { $venue = ($msg.'container-title' -join ' ') }
        $o = New-Item -Source 'CrossRef' -Title $title -Authors ($authors -join ', ') -Year $year -Venue $venue `
            -Volume $msg.volume -Issue $msg.issue -Pages $msg.page -Doi $D -Url $url -Type $msg.type
        # 顺手查一下有没有免费全文（配了 email 才生效）
        $oa = Get-OaLocation $D
        if ($oa -and $oa.Url) { $o.OaUrl = $oa.Url }
        return $o
    }

    # 2) 退一步：DOI handle 解析，能解析就说明这篇真实存在；再尽量从落地页把题名捞回来
    $hd = Invoke-Json "https://doi.org/api/handles/$D"
    if ($hd -and $hd.responseCode -eq 1) {
        $target = $null
        foreach ($v in @($hd.values)) { if ($v.type -eq 'URL') { $target = $v.data.value; break } }
        if ($target -and $target -notmatch '^https?://(dx\.)?doi\.org') {
            $o = Get-PageMeta $target
            if ($o -and $o.Title) {
                $o.Doi = $D
                $o.Url = $url
                return $o
            }
        }
        return New-Item -Source 'DOI' -Title '(仅查到 DOI 解析记录，题名未取到)' -Authors $null -Year $null `
            -Venue $null -Volume $null -Issue $null -Pages $null -Doi $D -Url $url -Type 'record' `
            -Note "解析目标: $target"
    }
    return $null
}

# 把"姓, 名"翻成自然序"名 姓"；中文名原样返回
function ConvertTo-NaturalName {
    param([string]$Name)
    $Name = $Name.Trim()
    if (-not $Name) { return '' }
    if ($Name -match '[\p{IsCJKUnifiedIdeographs}]') { return $Name }
    if ($Name -match ',') {
        $p = @($Name -split '\s*,\s*' | Where-Object { $_ })
        if ($p.Count -ge 2) { return (($p[1..($p.Count - 1)] -join ' ') + ' ' + $p[0]).Trim() }
    }
    return $Name
}

# GB/T 7714 的西文作者写法：姓在前 + 名缩写（Vaswani A）
function ConvertTo-GbtAuthor {
    param([string]$Name)
    $Name = $Name.Trim()
    if (-not $Name) { return '' }
    if ($Name -match '[\p{IsCJKUnifiedIdeographs}]') { return $Name }
    $parts = @($Name -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $Name }
    $family = $parts[-1]
    $ini = @($parts[0..($parts.Count - 2)] | Where-Object { $_ } |
        ForEach-Object { $_.TrimStart('(').Substring(0, 1).ToUpperInvariant() })
    return (@($family) + $ini) -join ' '
}

function Format-Gbt {
    param($it)
    $tag = '[J]'
    $t = [string]$it.Type
    if ($t -match 'preprint|arxiv') { $tag = '[EB/OL]' }
    elseif ($t -match 'conference|proceedings') { $tag = '[C]' }
    elseif ($t -match 'book|monograph') { $tag = '[M]' }
    elseif ($t -match 'dissertation') { $tag = '[D]' }
    elseif ($t -match 'report') { $tag = '[R]' }
    elseif (-not $it.Venue) { $tag = '[EB/OL]' }

    $a = ''
    if ($it.Authors) {
        $a = (@($it.Authors -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object { ConvertTo-GbtAuthor $_ }) -join ', ')
    }
    $s = ''
    if ($a) { $s += "$a. " }
    $s += "$($it.Title)$tag. "
    if ($it.Venue) { $s += $it.Venue }
    if ($it.Year) { if ($it.Venue) { $s += ', ' } ; $s += $it.Year }
    # 预印本/电子资源只保留版本与链接，不套会议的卷期页
    if ($tag -ne '[EB/OL]') {
        if ($it.Volume) { $s += ", $($it.Volume)" }
        if ($it.Issue) { $s += "($($it.Issue))" }
        if ($it.Pages) { $s += ": $($it.Pages)" }
    }
    $s = $s.TrimEnd() + '.'
    if ($it.Doi) { $s += " https://doi.org/$($it.Doi)." }
    elseif ($it.Url) { $s += " $($it.Url)." }
    return ($s -replace '\s+', ' ' -replace '\.\.', '.')
}

function ConvertTo-ApaAuthor {
    param([string]$Name)
    $Name = $Name.Trim()
    if (-not $Name) { return '' }
    if ($Name -match '[\p{IsCJKUnifiedIdeographs}]') { return $Name }

    # "Kucsko G." / "Noh H. J." 这类已经是"姓 + 缩写"的写法，直接认（-cmatch：大小写必须真的对）
    if ($Name -cmatch '^(.+?)\s+([A-Z][A-Z\.\s]*)$') {
        $family = $Matches[1]
        $given = $Matches[2]
    }
    else {
        $parts = @($Name -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 2) { return $Name }
        $family = $parts[-1]
        $given = ($parts[0..($parts.Count - 2)] -join ' ')
    }

    $ini = @($given -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + '.' })
    return "$family, $($ini -join ' ')"
}

function Format-Apa {
    param($it)
    $a = ''
    if ($it.Authors) {
        $list = @($it.Authors -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object { ConvertTo-ApaAuthor $_ })
        if ($list.Count -eq 1) { $a = $list[0] }
        elseif ($list.Count -eq 2) { $a = "$($list[0]), & $($list[1])" }
        elseif ($list.Count -gt 2) { $a = (($list[0..($list.Count - 2)]) -join ', ') + ", & " + $list[-1] }
    }
    $s = ''
    if ($a) { $s += "$a " }
    if ($it.Year) { $s += "($($it.Year)). " } else { $s += "(n.d.). " }
    $s += "$($it.Title). "
    if ($it.Venue) { $s += "$($it.Venue)" }
    if ($it.Volume) { $s += ", $($it.Volume)" }
    if ($it.Issue) { $s += "($($it.Issue))" }
    if ($it.Pages) { $s += ", $($it.Pages)" }
    $s = $s.TrimEnd() + '.'
    if ($it.Doi) { $s += " https://doi.org/$($it.Doi)" }
    elseif ($it.Url) { $s += " $($it.Url)" }
    return ($s -replace '\s+', ' ')
}

# ---------------------------------------------------------------- 展示

function Show-Item {
    param($it, [int]$Index)
    $mark = switch ($it.Status) {
        'VERIFIED' { '✔' }
        'LEAD' { '→' }
        'WEAK' { '?' }
        'MISMATCH' { '≠' }
        'UNREACHABLE' { '!' }
        default { '✘' }
    }
    Write-Host ''
    Write-Host ('─' * 78) -ForegroundColor DarkGray
    $head = "[$Index] $mark $($it.Status)"
    if ($it.Score) { $head += "  sim=$($it.Score)" }
    if ($it.Source) { $head += "  · $($it.Source)" }
    Write-Host $head -ForegroundColor $(if ($it.Status -eq 'VERIFIED') { 'Green' } else { 'Yellow' })
    if ($it.Title) { Write-Host "  题名  $($it.Title)" }
    if ($it.Authors) { Write-Host "  作者  $($it.Authors)" }
    $venue = @($it.Venue, $it.Year, $(if ($it.Volume) { "第 $($it.Volume) 卷" }), $(if ($it.Issue) { "第 $($it.Issue) 期" }), $it.Pages) | Where-Object { $_ }
    if ($venue.Count -gt 0) { Write-Host "  来源  $($venue -join ' · ')" }
    if ($it.Url) { Write-Host "  链接  $($it.Url)" -ForegroundColor Cyan }
    if ($it.Abstract) {
        $ab = $it.Abstract
        if ($ab.Length -gt 240) { $ab = $ab.Substring(0, 240) + '…' }
        Write-Host "  摘要  $ab" -ForegroundColor DarkGray
    }
    if ($it.OaUrl) { Write-Host "  免费全文  $($it.OaUrl)" -ForegroundColor Green }
    if ($it.Note) { Write-Host "  备注  $($it.Note)" -ForegroundColor DarkGray }
    if ($it.Citation) { Write-Host "  引用  $($it.Citation)" -ForegroundColor Gray }
}

# ---------------------------------------------------------------- 知网目录枚举（TOC）
# 中文库没有检索接口，但有个稳定规律：文章地址 = CJFDTotal-<刊号><年><期:00><序号:000>.htm
# 于是一期就是一个连续的 ID 段，逐号探过去就能把整期目录扒出来。
# 代价是请求多，所以要节流 + 落盘缓存。

$Script:JournalMap = @{
    '外语界'          = 'WYJY'
    '外语电化教学'    = 'WYDH'
    '现代外语'        = 'XDWY'
    '解放军外国语学院学报' = 'JFJW'
    '齐鲁师范学院学报' = 'SDJX'
    '成都师范学院学报' = 'SJXB'
}

function Resolve-JournalCode {
    param([string]$J)
    if (-not $J) { return $null }
    $k = $J.Trim()
    if ($Script:JournalMap.ContainsKey($k)) { return $Script:JournalMap[$k] }
    return $k.ToUpperInvariant()
}

function Get-CnkiArticleHtml {
    param([string]$Id)
    $u = "https://www.cnki.com.cn/Article/CJFDTotal-$Id.htm"
    try {
        return (Invoke-WebRequest -Uri $u -TimeoutSec 15 -UseBasicParsing -Headers @{ 'User-Agent' = $UA }).Content
    }
    catch {
        $m = $_.Exception.Message
        if ($m -match '404') { return 'MISS' }        # 号段到头了，正常
        if ($m -match '403') {
            # 限流：歇一下再来一次，还不行就是硬失败
            Start-Sleep -Seconds 5
            try { return (Invoke-WebRequest -Uri $u -TimeoutSec 15 -UseBasicParsing -Headers @{ 'User-Agent' = $UA }).Content }
            catch { return $null }
        }
        return $null
    }
}

function Get-CnkiToc {
    param([string]$Code, [int]$Year, [int]$Issue, [int]$MaxSeq = 28, [switch]$NoCache)

    $cacheDir = Join-Path $SkillRoot 'cache'
    if (-not (Test-Path $cacheDir)) { [void][System.IO.Directory]::CreateDirectory($cacheDir) }
    $cacheFile = Join-Path $cacheDir ("{0}-{1}-{2:00}.json" -f $Code, $Year, $Issue)

    $Script:LastTocFailed = $false
    if (-not $NoCache -and (Test-Path $cacheFile)) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalDays -lt 30) {
            try {
                $cached = @(Get-Content $cacheFile -Raw -Encoding utf8 | ConvertFrom-Json)
                if ($cached.Count -gt 0) { return $cached }
            }
            catch { }
        }
    }

    $items = @()
    $miss = 0
    $hardFail = 0
    if (-not $Script:TocDelayMs) { $Script:TocDelayMs = 1100 }
    for ($seq = 1; $seq -le $MaxSeq; $seq++) {
        $id = "{0}{1}{2:00}{3:000}" -f $Code, $Year, $Issue, $seq
        $html = Get-CnkiArticleHtml $id
        if ($html -eq 'MISS') {
            $miss++
            if ($miss -ge 3) { break }   # 连续三个空号，说明这一期到头了
            Start-Sleep -Milliseconds 1600
            continue
        }
        if (-not $html) {
            $hardFail++                  # 403/超时：不是"没这篇"，是没抓到
            $miss++
            # 自适应降速：撞墙一次就把后续间隔拉长，避免整轮扫下来全是 403
            $Script:TocDelayMs = [Math]::Min(4000, [int]($Script:TocDelayMs * 1.8))
            if ($miss -ge 4) { break }
            Start-Sleep -Seconds 6
            continue
        }
        $meta = Get-CnkiMeta $html
        if (-not $meta.Title) {
            # 200 但没有标题 = 知网的空壳页，说明这个号段不存在（期号到头了）
            $miss++
            if ($miss -ge 3) { break }
            Start-Sleep -Milliseconds 800
            continue
        }
        $miss = 0
        $items += [pscustomobject]@{
            Seq     = $seq
            Title   = $meta.Title
            Authors = $meta.Authors
            Venue   = $meta.Venue
            Year    = $meta.Year
            Issue   = $meta.Issue
            Url     = "https://www.cnki.com.cn/Article/CJFDTotal-$id.htm"
        }
        Start-Sleep -Milliseconds $Script:TocDelayMs
    }

    # 用脚本级标志告诉调用方：这一期的"空"到底是"没这期"还是"没抓到"
    $Script:LastTocFailed = ($hardFail -gt 0)

    # 只有完整抓完才落缓存：被限流打断的半截数据一旦写进去，30 天内都会悄悄少几篇
    if ($items.Count -gt 0 -and $hardFail -eq 0 -and -not $NoCache) {
        try { $items | ConvertTo-Json -Depth 4 | Set-Content $cacheFile -Encoding utf8 } catch { }
    }
    if ($hardFail -gt 0) {
        Write-Host ("  ⚠ 第 {0} 期有 {1} 次抓取失败（限流），本次结果不完整且未缓存，稍后重跑即可" -f $Issue, $hardFail) -ForegroundColor Yellow
    }
    elseif ($items.Count -ge $MaxSeq) {
        Write-Host ("  ⚠ 第 {0} 期探到序号上限 {1}，可能还有后续条目，用 -MaxSeq 加大" -f $Issue, $MaxSeq) -ForegroundColor Yellow
    }
    return $items
}

# 在某一本刊的若干年里按关键词找 —— 先吃缓存，没有才去抓
function Search-InJournal {
    param([string]$JournalName, [string]$Keywords, [int]$FromYear, [int]$ToYear, [int]$MaxSeq = 28, [switch]$NoCache)

    $code = Resolve-JournalCode $JournalName
    if (-not $code) { Write-Host "无法识别期刊：$JournalName" -ForegroundColor Red; return }

    if ($ToYear -le 0) { $ToYear = (Get-Date).Year }
    if ($FromYear -le 0) { $FromYear = $ToYear - 4 }

    $stop = @('或', '和', '与', '及', '、', 'and', 'or', 'AND', 'OR')
    $terms = @($Keywords -split '[\s、]+' | Where-Object { $_ -and $_ -notin $stop })
    if ($terms.Count -eq 0) { Write-Host '需要关键词' -ForegroundColor Red; return }

    Write-Host ("  在《{0}》({1}) {2}–{3} 年目录中找：{4}" -f $JournalName, $code, $FromYear, $ToYear, ($terms -join ' / ')) -ForegroundColor DarkGray

    $found = @()
    $failedIssues = 0
    for ($y = $FromYear; $y -le $ToYear; $y++) {
        $emptyRun = 0
        for ($iss = 1; $iss -le 12; $iss++) {
            $rows = @(Get-CnkiToc -Code $code -Year $y -Issue $iss -MaxSeq $MaxSeq -NoCache:$NoCache)
            # 抓取失败 ≠ 没这期。不能让它计入"连续空期"，否则会被限流悄悄截断半年
            if ($Script:LastTocFailed) {
                $failedIssues++
                Write-Host ("  ⚠ {0} 年第 {1} 期抓取失败（限流），已跳过，结果可能不全" -f $y, $iss) -ForegroundColor Yellow
                continue
            }
            if ($rows.Count -eq 0) {
                $emptyRun++
                if ($emptyRun -ge 2) { break }      # 连着两期没有，这一年到头了
                continue
            }
            $emptyRun = 0
            foreach ($r in $rows) {
                $hay = "$($r.Title) $($r.Authors)"
                foreach ($t in $terms) {
                    if ($hay -match $t) { $found += $r; break }
                }
            }
        }
        if (@($found).Count -gt 0) { Write-Host ("    {0} 年累计命中 {1} 篇" -f $y, @($found).Count) -ForegroundColor DarkGray }
    }
    if ($failedIssues -gt 0) {
        Write-Host ("  ⚠ 共 {0} 期没抓到，上面结果不完整；过几分钟重跑，已缓存的期不会重复抓" -f $failedIssues) -ForegroundColor Yellow
    }

    foreach ($r in $found) {
        $it = New-Item -Source 'CNKI-TOC' -Title $r.Title -Authors $r.Authors -Year $r.Year -Venue $r.Venue `
            -Issue $r.Issue -Url $r.Url -Type 'journal-article'
        $it.Status = 'VERIFIED'
        $it.Note = '知网目录关键词命中（题名/作者），已核到页面'
        $it.Citation = if ($Style -eq 'apa') { Format-Apa $it } else { Format-Gbt $it }
        $script:results += $it
    }
}

# ---------------------------------------------------------------- 主流程

$results = @()
$Script:CoverageTried = @()
$Script:CoverageFailed = @()

switch ($Action) {

    'doctor' {
        if ($InitConfig) { New-ConfigTemplate }
        Invoke-Doctor
        exit 0
    }

    'toc' {
        $code = Resolve-JournalCode $Journal
        if (-not $code) { Write-Error 'toc 需要 -Journal（刊号如 WYJY，或刊名如 外语界）'; exit 2 }
        $y = if ($Year -gt 0) { $Year } else { (Get-Date).Year }
        $issues = if ($Issue -gt 0) { @($Issue) } else { 1..12 }

        $all = @()
        $emptyRun = 0
        foreach ($iss in $issues) {
            $rows = @(Get-CnkiToc -Code $code -Year $y -Issue $iss -MaxSeq $MaxSeq -NoCache:$NoCache)
            if ($rows.Count -eq 0) {
                $emptyRun++
                if ($Issue -le 0 -and $emptyRun -ge 2) { break }   # 连着两期掏空，说明这一年到头了
                continue
            }
            $emptyRun = 0
            foreach ($r in $rows) {
                $r | Add-Member -NotePropertyName Issue -NotePropertyValue $iss -Force
                $all += $r
            }
            if ($Issue -le 0) { Write-Host ("  {0} 年第 {1} 期：{2} 篇" -f $y, $iss, $rows.Count) -ForegroundColor DarkGray }
        }

        if (@($all).Count -eq 0) {
            Write-Host "没有枚举到内容，确认刊号对不对：$code" -ForegroundColor Yellow
            exit 2
        }

        if ($Match) {
            $all = @($all | Where-Object { $_.Title -match $Match -or ($_.Authors -and $_.Authors -match $Match) })
            if (@($all).Count -eq 0) {
                Write-Host "这一期/这一年里没有匹配「$Match」的条目" -ForegroundColor Yellow
                exit 2
            }
        }

        if ($Json) {
            $all | ConvertTo-Json -Depth 4
        }
        else {
            $venue = $all[0].Venue
            Write-Host ''
            Write-Host ("《{0}》{1} 年 · 共 {2} 篇" -f $venue, $y, @($all).Count) -ForegroundColor Cyan
            Write-Host ('─' * 92) -ForegroundColor DarkGray
            foreach ($r in $all) {
                $au = if ($r.Authors) { $r.Authors } else { '（作者未取到）' }
                Write-Host ("[第{0}期-{1,2}] {2}" -f $r.Issue, $r.Seq, $r.Title)
                Write-Host ("             {0}" -f $au) -ForegroundColor DarkGray
                Write-Host ("             {0}" -f $r.Url) -ForegroundColor Cyan
            }
            Write-Host ''
            Write-Host ("共 {0} 条，题名与作者均取自知网页面，可直接引用" -f @($all).Count) -ForegroundColor Green
        }
        exit 0
    }

    'search' {
        if (-not $Query) { Write-Error 'search 需要 -Query'; exit 2 }

        if ($In) {
            Search-InJournal -JournalName $In -Keywords $Query -FromYear $Since -ToYear $Until -MaxSeq $MaxSeq -NoCache:$NoCache
            $Script:CoverageTried += "《$In》目录（知网）"
        }
        else {

        # 不给 -Sources 就走默认组合：英文五大库，中文另加知网
        if (@($Sources).Count -eq 0) {
            $Sources = @('openalex', 'crossref', 'europepmc', 'doaj', 'arxiv')
            if ($Cn) { $Sources += 'cnki' }
        }
        # 允许 -Sources a,b,c 和 -Sources a b c 两种写法
        $Sources = @($Sources | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        $all = @()
        foreach ($sid in $Sources) {
            $reg = (Get-Registry) | Where-Object { $_.id -eq $sid } | Select-Object -First 1
            if (-not $reg) { $Script:CoverageFailed += "$sid（未注册）"; continue }
            if ($sid -in $Script:NoAdapter) { $Script:CoverageFailed += "$($reg.name)（无公开检索接口）"; continue }
            if ($reg.auth -eq 'key' -and -not (Get-ConfigValue $reg.configKey)) {
                $Script:CoverageFailed += "$($reg.name)（缺 key）"
                continue
            }
            $n = if ($sid -eq 'cnki') { [Math]::Max(3, $Limit) } else { $Limit }
            $Script:LastNetError = $null
            try {
                $got = @(Invoke-SearchProvider -Id $sid -Q $Query -N $n)
                # 一条没返回、而且刚才是网络错误 → 这是"没连上"，不是"没有这篇"
                if ($got.Count -eq 0 -and $Script:LastNetError) {
                    $Script:CoverageFailed += "$($reg.name)（网络失败）"
                }
                else {
                    $all += $got
                    $Script:CoverageTried += $reg.name
                }
            }
            catch {
                $Script:CoverageFailed += "$($reg.name)（报错）"
            }
        }

        # 去重 + 按相似度排序
        $seen = @{}
        foreach ($it in $all) {
            $key = if ($it.Doi) { $it.Doi.ToLowerInvariant() } else { (Get-Plain $it.Title) }
            if (-not $key -or $seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $it.Score = Get-Sim $Query $it.Title
            if ($it.Source -in @('Baidu', '360')) { $it.Status = 'LEAD' }
            elseif ($it.Score -ge $Threshold) { $it.Status = 'VERIFIED' }
            else { $it.Status = 'WEAK' }
            $it.Citation = if ($Style -eq 'apa') { Format-Apa $it } else { Format-Gbt $it }
            $results += $it
        }
        # 网页线索不参与相似度排序（片段和标题没法比），单独排在后面
        $cnLeads = @($results | Where-Object { $_.Source -in @('Baidu', '360') })
        $apiHits = @($results | Where-Object { $_.Source -notin @('Baidu', '360') } |
            Sort-Object -Property @{ Expression = 'Score'; Descending = $true } | Select-Object -First $Limit)
        $results = @($apiHits) + @($cnLeads | Select-Object -First ([Math]::Max(3, $Limit)))
        }
    }

    'verify' {
        if (-not $Doi -and -not $Url -and -not $Query) { Write-Error 'verify 需要 -Doi / -Url / -Query 之一'; exit 2 }

        if ($Doi) {
            $Script:LastNetError = $null
            $it = Confirm-Doi $Doi
            if ($it) {
                $it.Status = 'VERIFIED'
                if ($Query) {
                    $it.Score = Get-Sim $Query $it.Title
                    if ($it.Score -lt $Threshold -and $it.Title -notmatch 'DOI 解析成功') { $it.Status = 'MISMATCH' }
                }
                $it.Citation = if ($Style -eq 'apa') { Format-Apa $it } else { Format-Gbt $it }
                $results += $it
            }
            else {
                # 网络断了 ≠ 这篇不存在。这两种结论对用户的意义完全不同
                $st = if ($Script:LastNetError) { 'UNREACHABLE' } else { 'NOT_FOUND' }
                $title = if ($st -eq 'UNREACHABLE') { '(网络不通，未能核验)' } else { '(DOI 无法解析)' }
                $note = if ($st -eq 'UNREACHABLE') { $Script:LastNetError } else { '' }
                $results += New-Item -Source 'DOI' -Title $title -Authors $null -Year $null -Venue $null `
                    -Volume $null -Issue $null -Pages $null -Doi $Doi -Url "https://doi.org/$Doi" -Type 'unknown' -Status $st -Note $note
            }
        }

        if ($Url) {
            $it = Get-PageMeta $Url
            if ($it) {
                $it.Status = 'VERIFIED'
                if ($Query) {
                    $it.Score = Get-Sim $Query $it.Title
                    if ($it.Score -lt $Threshold) { $it.Status = 'MISMATCH' }
                }
                $it.Citation = if ($Style -eq 'apa') { Format-Apa $it } else { Format-Gbt $it }
                $results += $it
            }
            else {
                $results += New-Item -Source 'Web' -Title '(页面打不开或取不到题名)' -Authors $null -Year $null -Venue $null `
                    -Volume $null -Issue $null -Pages $null -Doi $null -Url $Url -Type 'unknown' -Status 'UNREACHABLE'
            }
        }

        if ($Query -and -not $Doi -and -not $Url) {
            $cand = @()
            $cand += Get-OpenAlex -Q $Query -N 5 -WithAbs:$WithAbstract
            $cand += Get-CrossRef -Q $Query -N 5
            $cand += Get-ArXiv -Q $Query -N 3
            if ($Cn) { $cand += Get-CnWeb -Q $Query -N 5 }

            $best = $null; $bestScore = 0.0
            foreach ($c in $cand) {
                $s = Get-Sim $Query $c.Title
                if ($s -gt $bestScore) { $bestScore = $s; $best = $c }
            }
            if ($best -and $bestScore -ge $Threshold) {
                if ($best.Doi) {
                    $c = Confirm-Doi $best.Doi
                    # 只有拿到更完整、且不是占位题名的记录才替换，别把好数据换成 stub
                    if ($c -and $c.Title -and $c.Title -notmatch '^\(仅查到') { $best = $c }
                    elseif ($c) { $best.Note = (($best.Note + ' ' + $c.Note).Trim()) }
                }
                $best.Status = 'VERIFIED'
                $best.Score = $bestScore
                $best.Citation = if ($Style -eq 'apa') { Format-Apa $best } else { Format-Gbt $best }
                $results += $best
            }
            else {
                $results += New-Item -Source '-' -Title "(未检索到匹配文献)" -Authors $null -Year $null -Venue $null `
                    -Volume $null -Issue $null -Pages $null -Doi $null -Url $null -Type 'unknown' -Status 'NOT_FOUND' `
                    -Score $bestScore -Note "最高相似度 $bestScore < 阈值 $Threshold"
            }
        }
    }

    'page' {
        if (-not $Url) { Write-Error 'page 需要 -Url'; exit 2 }
        $it = Get-PageMeta $Url
        if (-not $it) { Write-Error "取不到页面元数据: $Url"; exit 2 }
        $it.Status = 'VERIFIED'
        $it.Citation = if ($Style -eq 'apa') { Format-Apa $it } else { Format-Gbt $it }
        $results += $it
    }

    'cite' {
        if (-not $Doi -and -not $Url) { Write-Error 'cite 需要 -Doi 或 -Url'; exit 2 }
        $it = if ($Doi) { Confirm-Doi $Doi } else { Get-PageMeta $Url }
        if (-not $it) { Write-Error '无法解析该 DOI/URL'; exit 2 }
        $it.Status = 'VERIFIED'
        if ($Style -eq 'both') {
            $g = Format-Gbt $it; $a = Format-Apa $it
            $it | Add-Member -NotePropertyName Gbt -NotePropertyValue $g -Force
            $it | Add-Member -NotePropertyName Apa -NotePropertyValue $a -Force
            $it.Citation = "GB/T: $g`n        APA: $a"
        }
        elseif ($Style -eq 'apa') { $it.Citation = Format-Apa $it }
        else { $it.Citation = Format-Gbt $it }
        $results += $it
    }
}

# ---------------------------------------------------------------- 输出

if ($Json) {
    $results | ConvertTo-Json -Depth 5
}
else {
    $i = 0
    foreach ($r in $results) { $i++; Show-Item -it $r -Index $i }
    $ok = @($results | Where-Object { $_.Status -eq 'VERIFIED' }).Count
    $bad = $results.Count - $ok
    Write-Host ''
    Write-Host ('─' * 78) -ForegroundColor DarkGray
    Write-Host "SUMMARY: verified=$ok  未核到=$bad" -ForegroundColor $(if ($ok -gt 0) { 'Green' } else { 'Yellow' })
    if ($Action -eq 'search' -and $ok -eq 0) {
        Write-Host '提示：没有一条达到相似度阈值。不要凭记忆补一篇——要么换关键词再检索，要么如实说"查不到"。' -ForegroundColor Yellow
    }
    if ($Action -eq 'search' -and ($Script:CoverageTried.Count -gt 0 -or $Script:CoverageFailed.Count -gt 0)) {
        $cov = "覆盖："
        if ($Script:CoverageTried.Count -gt 0) { $cov += "已查 $($Script:CoverageTried -join '、')" }
        if ($Script:CoverageFailed.Count -gt 0) {
            if ($Script:CoverageTried.Count -gt 0) { $cov += "；" }
            $cov += "未查 $($Script:CoverageFailed -join '、')"
        }
        Write-Host $cov -ForegroundColor DarkGray
    }
    # 全部扑空且有网络错误：用户看到的"没结果"其实是"没连上"，必须点明
    if ($ok -eq 0 -and $Script:LastNetError) {
        Write-Host '⚠ 本次有网络错误，结果不可信；先跑 doctor 确认连通性，不要据此判断文献不存在。' -ForegroundColor Red
        Write-Host "  最近错误：$($Script:LastNetError)" -ForegroundColor DarkGray
    }
}

if (@($results | Where-Object { $_.Status -eq 'VERIFIED' }).Count -gt 0) { exit 0 } else { exit 2 }