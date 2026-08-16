<#
================================================================================
 OneNote  →  PJT 이관 스크립트
================================================================================
 OneNote 'Jimmy' 노트북을 읽어서 PJT (D1 + Google Drive) 로 옮깁니다.
 OneNote 원본은 읽기만 하며 절대 수정하지 않습니다.

 매핑
   섹션명                     → 카테고리
   제목 [In-progress] 등      → 상태 + 날짜 + 제목으로 분해
   페이지 본문                → 진행기록 1건 (유형: 마이그레이션)
   첨부파일 · 붙여넣은 이미지 → Drive PJT-Docs/{코드}/ + v1

 ─────────────────────────────────────────────────────────────────────────────
 실행 전 준비
 ─────────────────────────────────────────────────────────────────────────────
 1) PowerShell 7 (pwsh) 에서 실행하세요. Windows PowerShell 5.1 은 파일 업로드
    (-Form 파라미터) 를 지원하지 않습니다.

 2) Graph 모듈 (최초 1회)
      Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

 3) PJT 세션 토큰
      브라우저에서 PJT 에 로그인한 상태로 F12 → Console 에 입력:
        localStorage.getItem('pjt_token')
      따옴표 안쪽 값을 복사해두세요.

 ─────────────────────────────────────────────────────────────────────────────
 사용법
 ─────────────────────────────────────────────────────────────────────────────
   .\03_MigrateOneNote.ps1                          # 미리보기 (아무것도 안 씀)
   .\03_MigrateOneNote.ps1 -Limit 3 -Execute        # 3건만 시범 이관
   .\03_MigrateOneNote.ps1 -Execute                 # 전체 이관
   .\03_MigrateOneNote.ps1 -Execute -ExcludeSections 'ID-PW','Payment'
================================================================================
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$Execute,
    [int]$Limit = 0,                          # 0 = 제한 없음
    [string[]]$ExcludeSections = @(),
    [switch]$SkipImages,                      # 붙여넣은 이미지 제외 (첨부파일은 유지)
    [string]$NotebookName = 'Jimmy',
    [string]$Api    = 'https://pjt-dashboard-worker.jimmyjib-dev.workers.dev',
    [string]$Token  = '',
    [string]$WorkDir = "$env:TEMP\pjt_migration"
)

$ErrorActionPreference = 'Stop'
$DryRun = -not $Execute
$Stat = [ordered]@{ Projects=0; Updates=0; Files=0; Skipped=0; Errors=0 }

# ─────────────────────────────────────────────── OneNote 섹션 → PJT 카테고리
#  좌변은 OneNote 에 실제로 적힌 이름 그대로입니다.
#  ('PS_Script-Ops_' 의 끝 밑줄, 'Esculation_points' 의 오타 포함)
$SectionMap = @{
    'IT-Infra Project'  = 'IT-Infra Project'
    'IT-Operation'      = 'IT-Operation'
    'IT_Security'       = 'IT_Security'
    'IT-DW_Operations'  = 'IT-DW_Operations'
    'IT RM'             = 'IT RM'
    'IT Core'           = 'IT Core'
    'SAP-Be1'           = 'SAP-Be1'
    'Autofocus'         = 'Autofocus'
    'Vercel'            = 'Vercel'
    'Hiparking'         = 'Hiparking'
    'Network'           = 'Network'
    'PS_Script-Ops_'    = 'PS_Script-Ops'
    'PS_Script-Ops'     = 'PS_Script-Ops'
    'Linux_Script-Ops_' = 'Linux_Script-Ops'
    'Linux_Script-Ops'  = 'Linux_Script-Ops'
    'ADDS_IMS-DMS'      = 'ADDS_IMS-DMS'
    'ID-PW'             = 'ID-PW'
    'To-Do-List'        = 'To-Do-List'
    'OS'                = 'OS'
    'MoM'               = 'MoM'
    'Mail_SYSTEM'       = 'Mail_SYSTEM'
    'Esculation_points' = 'Escalation_points'
    'Escalation_points' = 'Escalation_points'
    'Service-Catalogue' = 'Service-Catalogue'
    'DB'                = 'DB'
    'Common_sense'      = 'Common_sense'
    'Payment'           = 'Payment'
}

# ─────────────────────────────────────────────── 제목 파싱
function Resolve-Title {
    param([string]$Raw)

    $status = 'In-Progress'      # 접두어가 없으면 진행중으로 간주
    $title  = $Raw.Trim()
    $date   = $null

    if ($title -match '^\s*\[([^\]]+)\]\s*[_\-]?\s*(.*)$') {
        $prefix = $Matches[1].Trim()
        $rest   = $Matches[2].Trim()

        switch -Regex ($prefix) {
            '(?i)^completed$'                { $status = 'Completed'   }
            '(?i)^in[\s_\-]?progress$'       { $status = 'In-Progress' }
            '(?i)^discussion'                { $status = 'Discussion'  }
            '(?i)^(on[\s_\-]?)?hold$'        { $status = 'On-Hold'     }
            '(?i)^(drop|cancel|중단)'        { $status = 'Dropped'     }
            default                          { $status = 'In-Progress' }
        }
        if ($rest) { $title = $rest }
    }

    # 남은 제목 앞의 날짜 (2025-05-11 / 20250518 / 2024-12-22)
    if ($title -match '^(\d{4})[-_]?(\d{2})[-_]?(\d{2})\s*[_\-]?\s*(.*)$') {
        try {
            $date = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3]
            if ($Matches[4].Trim()) { $title = $Matches[4].Trim() }
        } catch { $date = $null }
    }

    if (-not $title) { $title = $Raw.Trim() }
    if ($title.Length -gt 250) { $title = $title.Substring(0,250) }

    [pscustomobject]@{ Status=$status; Title=$title; StartDate=$date }
}

# ─────────────────────────────────────────────── HTML → 읽을 수 있는 텍스트
function ConvertTo-PlainText {
    param([string]$Html)
    if (-not $Html) { return '' }

    $t = $Html
    $t = [regex]::Replace($t, '(?is)<script.*?</script>', '')
    $t = [regex]::Replace($t, '(?is)<style.*?</style>',   '')
    $t = [regex]::Replace($t, '(?is)<object[^>]*data-attachment="([^"]*)"[^>]*>.*?</object>', "`n[첨부: `$1]`n")
    $t = [regex]::Replace($t, '(?is)<img[^>]*>', "`n[이미지]`n")
    $t = [regex]::Replace($t, '(?i)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?i)</(p|div|tr|li|h[1-6])>', "`n")
    $t = [regex]::Replace($t, '(?i)</t[dh]>', "`t")
    $t = [regex]::Replace($t, '(?s)<[^>]+>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, '(\r?\n[ \t]*){3,}', "`n`n")
    $t.Trim()
}

# ─────────────────────────────────────────────── Graph 호출 (429 재시도)
function Invoke-Graph {
    param([string]$Uri, [string]$OutFile)

    for ($i = 1; $i -le 5; $i++) {
        try {
            if ($OutFile) {
                Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputFilePath $OutFile
                return $true
            }
            return Invoke-MgGraphRequest -Method GET -Uri $Uri
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -in 429, 503, 504) {
                $wait = [Math]::Pow(2, $i) * 2
                Write-Host "        요청이 제한됐습니다 ($code). ${wait}초 후 재시도" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
    throw "Graph 호출 실패 (재시도 초과): $Uri"
}

# ─────────────────────────────────────────────── PJT API
function Invoke-Pjt {
    param([string]$Path, [string]$Method = 'GET', $Body)

    $p = @{
        Uri     = "$Api$Path"
        Method  = $Method
        Headers = @{ Authorization = "Bearer $Token" }
    }
    if ($Body) {
        $p.Body        = ($Body | ConvertTo-Json -Depth 6 -Compress)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    Invoke-RestMethod @p
}

function Send-PjtFile {
    param([int]$ProjectId, [string]$LocalPath, [string]$DocType = '기타', [string]$Note = '')

    Invoke-RestMethod -Uri "$Api/api/files/upload" -Method Post `
        -Headers @{ Authorization = "Bearer $Token" } `
        -Form @{
            file        = Get-Item -LiteralPath $LocalPath
            project_id  = "$ProjectId"
            doc_type    = $DocType
            change_note = $Note
        }
}

# ═══════════════════════════════════════════════ 시작
Write-Host ''
Write-Host '══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ' OneNote → PJT 이관' -ForegroundColor Cyan
Write-Host '══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host " 노트북 : $NotebookName"
Write-Host " 대상   : $Api"
if ($Limit)           { Write-Host " 제한   : $Limit 건" -ForegroundColor Yellow }
if ($ExcludeSections) { Write-Host " 제외   : $($ExcludeSections -join ', ')" -ForegroundColor Yellow }
if ($DryRun) {
    Write-Host ' 모드   : 미리보기 — 아무것도 저장하지 않습니다' -ForegroundColor Yellow
} else {
    Write-Host ' 모드   : 실제 이관' -ForegroundColor Red
    if ((Read-Host " 계속하려면 MIGRATE 를 입력하세요") -ne 'MIGRATE') {
        Write-Host ' 중단했습니다.' -ForegroundColor Yellow; exit
    }
}
Write-Host ''

if (-not $DryRun -and -not $Token) {
    Write-Host 'PJT 세션 토큰이 필요합니다.' -ForegroundColor Yellow
    Write-Host "브라우저에서 PJT 에 로그인한 뒤 F12 → Console 에 입력하세요:"
    Write-Host "  localStorage.getItem('pjt_token')" -ForegroundColor Cyan
    $Token = (Read-Host '토큰').Trim().Trim('"')
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# ─── Graph 로그인
Write-Host 'Microsoft 계정으로 로그인합니다 (브라우저 창이 열립니다)…' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'Notes.Read' -NoWelcome

# ─── 이미 옮긴 페이지 확인 (재실행해도 중복되지 않도록)
$done = @{}
if (-not $DryRun) {
    try {
        foreach ($p in (Invoke-Pjt '/api/projects').projects) {
            if ($p.source_page_id) { $done[$p.source_page_id] = $p.code }
        }
        Write-Host "이미 옮긴 항목 $($done.Count)건은 건너뜁니다.`n" -ForegroundColor DarkGray
    } catch {
        throw "PJT API 연결 실패: $($_.Exception.Message)`n토큰이 만료됐을 수 있습니다. 다시 로그인해서 새 토큰을 받아주세요."
    }
}

# ─── 노트북 → 섹션
$nb = (Invoke-Graph 'https://graph.microsoft.com/v1.0/me/onenote/notebooks').value |
      Where-Object displayName -eq $NotebookName | Select-Object -First 1
if (-not $nb) { throw "'$NotebookName' 노트북을 찾을 수 없습니다." }

$sections = (Invoke-Graph "https://graph.microsoft.com/v1.0/me/onenote/notebooks/$($nb.id)/sections").value
Write-Host "섹션 $($sections.Count)개를 찾았습니다.`n" -ForegroundColor Green

$processed = 0

foreach ($sec in $sections) {

    $secName = $sec.displayName
    if ($ExcludeSections -contains $secName) {
        Write-Host "── [$secName] 제외됨" -ForegroundColor DarkGray; continue
    }
    $category = if ($SectionMap.ContainsKey($secName)) { $SectionMap[$secName] } else { '기타' }
    Write-Host "── [$secName] → $category" -ForegroundColor Cyan

    # 페이지 (nextLink 페이징)
    $pages = @()
    $uri = "https://graph.microsoft.com/v1.0/me/onenote/sections/$($sec.id)/pages?`$top=100&`$orderby=createdDateTime"
    while ($uri) {
        $r = Invoke-Graph $uri
        $pages += $r.value
        $uri = $r.'@odata.nextLink'
    }
    if (-not $pages) { Write-Host '   (페이지 없음)' -ForegroundColor DarkGray; Write-Host ''; continue }

    foreach ($page in $pages) {

        if ($Limit -and $processed -ge $Limit) { break }

        try {
            if ($done.ContainsKey($page.id)) {
                Write-Host "   · $($page.title)  (이미 이관됨)" -ForegroundColor DarkGray
                $Stat.Skipped++; continue
            }

            $parsed = Resolve-Title $page.title
            $start  = if ($parsed.StartDate) { $parsed.StartDate }
                      else { ([datetime]$page.createdDateTime).ToString('yyyy-MM-dd') }

            Write-Host "   + [$($parsed.Status)] $($parsed.Title)" -ForegroundColor Green

            # ── 본문
            $html = ''
            try {
                $raw = Invoke-Graph "https://graph.microsoft.com/v1.0/me/onenote/pages/$($page.id)/content?includeIDs=true"
                $html = if ($raw -is [string]) { $raw }
                        elseif ($raw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($raw) }
                        else { "$raw" }
            } catch {
                Write-Host "      본문을 읽지 못했습니다: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
            $body = ConvertTo-PlainText $html

            if ($DryRun) {
                $preview = if ($body.Length -gt 60) { $body.Substring(0,60) -replace '\s+',' ' } else { $body -replace '\s+',' ' }
                Write-Host "      시작일 $start / 본문 $($body.Length)자 / $preview…" -ForegroundColor DarkGray
            }

            $projectId = $null
            if (-not $DryRun) {
                $created = Invoke-Pjt '/api/projects' 'POST' @{
                    title          = $parsed.Title
                    category       = $category
                    status         = $parsed.Status
                    priority       = 'Medium'
                    start_date     = $start
                    progress       = $(if ($parsed.Status -eq 'Completed') { 100 } else { 0 })
                    summary        = $(if ($body.Length -gt 240) { $body.Substring(0,240) + '…' } else { $body })
                    source_page_id = $page.id
                }
                $projectId = $created.id
                Write-Host "      $($created.code)" -ForegroundColor DarkGray

                if ($body) {
                    Invoke-Pjt '/api/updates' 'POST' @{
                        project_id  = $projectId
                        update_date = ([datetime]$page.lastModifiedDateTime).ToString('yyyy-MM-dd')
                        update_type = '마이그레이션'
                        title       = 'OneNote 원본 내용'
                        content     = $(if ($body.Length -gt 60000) { $body.Substring(0,60000) } else { $body })
                    } | Out-Null
                    $Stat.Updates++
                }
            }
            $Stat.Projects++

            # ── 첨부파일
            $items = @()
            foreach ($m in [regex]::Matches($html, '<object[^>]*data-attachment="(?<n>[^"]+)"[^>]*data="(?<u>[^"]+)"')) {
                $items += [pscustomobject]@{ Name = $m.Groups['n'].Value; Url = $m.Groups['u'].Value }
            }
            # ── 붙여넣은 이미지
            if (-not $SkipImages) {
                $i = 0
                foreach ($m in [regex]::Matches($html, '<img[^>]*?(?:data-fullres-src|src)="(?<u>[^"]+)"')) {
                    $i++
                    $items += [pscustomobject]@{ Name = ('image_{0:D2}.png' -f $i); Url = $m.Groups['u'].Value }
                }
            }

            foreach ($it in $items) {
                $safe  = [regex]::Replace($it.Name, '[\\/:*?"<>|]', '_')
                $local = Join-Path $WorkDir $safe
                Write-Host "      · $safe" -ForegroundColor DarkCyan

                if ($DryRun) { $Stat.Files++; continue }

                try {
                    Invoke-Graph $it.Url -OutFile $local | Out-Null
                    Send-PjtFile -ProjectId $projectId -LocalPath $local -Note 'OneNote 이관' | Out-Null
                    Remove-Item $local -Force -ErrorAction SilentlyContinue
                    $Stat.Files++
                    Start-Sleep -Milliseconds 250
                } catch {
                    Write-Host "      ! 첨부 실패 ($safe): $($_.Exception.Message)" -ForegroundColor Yellow
                    $Stat.Errors++
                }
            }

            $processed++
            Start-Sleep -Milliseconds 700      # OneNote API 요청 제한 회피
        }
        catch {
            Write-Host "   ! 실패 ($($page.title)): $($_.Exception.Message)" -ForegroundColor Red
            $Stat.Errors++
        }
    }

    if ($Limit -and $processed -ge $Limit) { break }
    Write-Host ''
}

# ═══════════════════════════════════════════════ 결과
Write-Host ''
Write-Host '══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ' 결과' -ForegroundColor Cyan
Write-Host '══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  프로젝트 : $($Stat.Projects)"
Write-Host "  진행기록 : $($Stat.Updates)"
Write-Host "  파일     : $($Stat.Files)"
Write-Host "  건너뜀   : $($Stat.Skipped)"
Write-Host ("  오류     : {0}" -f $Stat.Errors) -ForegroundColor $(if ($Stat.Errors) { 'Yellow' } else { 'Gray' })
Write-Host ''

if ($DryRun) {
    Write-Host '미리보기였습니다. 제목 파싱 결과가 맞으면:' -ForegroundColor Yellow
    Write-Host '  .\03_MigrateOneNote.ps1 -Limit 3 -Execute    (3건 시범)' -ForegroundColor Cyan
    Write-Host '  .\03_MigrateOneNote.ps1 -Execute             (전체)' -ForegroundColor Cyan
}

Disconnect-MgGraph | Out-Null
