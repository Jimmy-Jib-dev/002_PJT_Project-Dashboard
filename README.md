# PJT — IT Project Dashboard

OneNote 로 관리하던 IT 프로젝트를 옮겨온 개인용 프로젝트 관리 시스템.

- **화면**: GitHub Pages (`index.html` 단일 파일 SPA)
- **API**: Cloudflare Worker
- **메타 저장**: Cloudflare D1 (SQLite)
- **파일 저장**: Google Drive (`jimmyjibdb@gmail.com`) + 리비전 버전관리

```
https://jimmy-jib-dev.github.io/002_PJT_Project-Dashboard/
```

---

## 폴더 구조

| 경로 | 어디서 도나 | 배포 방법 |
|---|---|---|
| `index.html` | GitHub Pages | `git push` 하면 자동 반영 |
| `worker/worker.js` | Cloudflare Worker | `wrangler deploy` |
| `worker/schema.sql` | Cloudflare D1 | `wrangler d1 execute` (최초 1회) |
| `worker/wrangler.toml` | 설정 | — |

**`git push` 만으로는 Worker 가 안 바뀝니다.** `worker/` 안을 고쳤으면 반드시 `wrangler deploy` 를 따로 돌리세요.

---

## 최초 셋업

### 1. Google Cloud 준비

1. https://console.cloud.google.com 에서 새 프로젝트 생성
2. **API 및 서비스 → 라이브러리** → `Google Drive API` 사용 설정
3. **OAuth 동의 화면** → 외부 → 테스트 사용자에 본인 이메일 추가
4. **사용자 인증 정보 → OAuth 클라이언트 ID (웹 애플리케이션)**
   - 승인된 리디렉션 URI:
     ```
     https://pjt-dashboard-worker.jimmyjib-dev.workers.dev/auth/callback
     https://developers.google.com/oauthplayground
     ```
   - Client ID / Client Secret 을 메모
5. Drive 에 `PJT-Docs` 폴더를 만들고, URL 끝의 폴더 ID 를 메모
   ```
   https://drive.google.com/drive/folders/<이 부분이 폴더 ID>
   ```
6. **Refresh Token 발급** — https://developers.google.com/oauthplayground
   - 우측 톱니바퀴 → *Use your own OAuth credentials* 체크 후 Client ID/Secret 입력
   - Scope 에 `https://www.googleapis.com/auth/drive` 입력 → Authorize
   - *Exchange authorization code for tokens* → Refresh token 복사

### 2. Cloudflare 준비

```bash
cd worker

# D1 생성 → 출력된 database_id 를 wrangler.toml 에 붙여넣기
wrangler d1 create pjt-db

# 스키마 적용 (최초 1회)
wrangler d1 execute pjt-db --file=./schema.sql --remote

# 비밀 값 등록
wrangler secret put GOOGLE_CLIENT_ID
wrangler secret put GOOGLE_CLIENT_SECRET
wrangler secret put DRIVE_REFRESH_TOKEN
wrangler secret put DRIVE_ROOT_FOLDER_ID
wrangler secret put SESSION_SECRET        # 랜덤 32자 이상
wrangler secret put ALLOWED_EMAILS        # 쉼표 구분

# 배포
wrangler deploy
```

### 3. 동작 확인

```
https://pjt-dashboard-worker.jimmyjib-dev.workers.dev/auth/login
```
로그인 후 `/api/me` 가 이메일을 돌려주면 정상.

---

## 이후 작업 흐름

| 고친 곳 | 필요한 조치 |
|---|---|
| `index.html` | `git push` 만 |
| `worker/worker.js` | `git push` + `wrangler deploy` |
| `worker/schema.sql` | `git push` + `wrangler d1 execute --remote` |

---

## 데이터 모델 요약

| 테이블 | 역할 |
|---|---|
| `projects` | 프로젝트 마스터 (OneNote 페이지 1건 = 1행) |
| `tasks` | 하위 작업 체크리스트 |
| `updates` | 진행 기록 타임라인 |
| `files` | 파일 메타 (실물은 Drive) |
| `file_revisions` | **버전 이력 — 누가/언제/왜 올렸는지** |
| `config` | 카테고리·상태·우선순위 마스터 |
| `search_fts` | FTS5 통합 검색 (trigram, 한국어 부분일치) |

### 파일 버전관리 동작

같은 프로젝트에 **같은 파일명**을 올리면 새 파일이 아니라 기존 파일의 새 리비전이 됩니다.
`keepRevisionForever=true` 를 붙이기 때문에 Drive 의 기본 정책(30일 경과 / 100개 초과분 자동 삭제)에 걸리지 않습니다.

---

## 진행 상황

- [x] D1 스키마
- [x] Worker (인증 · CRUD · Drive 업로드/버전/다운로드 프록시)
- [ ] `index.html` — 프로젝트 목록 · 상세 · **파일 버전 히스토리 UI**
- [ ] 대시보드 (상태별 카드 · 카테고리 도넛 · 마감 임박)
- [ ] 통합 검색 화면
- [ ] 칸반 보드
- [ ] OneNote 자동 이관 스크립트

---

## 주의

- 이 시스템은 **개인 전용**입니다. `ALLOWED_EMAILS` 화이트리스트 외에는 접근 불가.
- 파일은 Worker 프록시를 거치므로 Drive 직접 링크가 노출되지 않습니다.
- 회사 자산 관련 민감 문서(계정정보·계약서 등)를 개인 Google 계정에 올릴지는 별도 판단 필요.
