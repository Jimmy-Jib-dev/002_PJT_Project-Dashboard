/**
 * =============================================================================
 *  PJT (IT Project Management) - Cloudflare Worker
 * =============================================================================
 *  GitHub Pages SPA  →  이 Worker  →  D1 (메타) + Google Drive (실물 파일)
 *
 *  wrangler secret put GOOGLE_CLIENT_ID
 *  wrangler secret put GOOGLE_CLIENT_SECRET
 *  wrangler secret put DRIVE_REFRESH_TOKEN      // jimmyjibdb@gmail.com 전용 계정
 *  wrangler secret put SESSION_SECRET           // 아무 랜덤 문자열 32자 이상
 *  wrangler secret put ALLOWED_EMAILS           // 쉼표 구분
 *  wrangler secret put DRIVE_ROOT_FOLDER_ID     // Drive 의 PJT-Docs 폴더 ID
 * =============================================================================
 */

const SESSION_COOKIE = 'pjt_session';
const SESSION_TTL    = 60 * 60 * 24 * 14;   // 14일

// ---------------------------------------------------------------- 유틸
const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...headers },
  });

const err = (msg, status = 400) => json({ error: msg }, status);

function corsHeaders(env) {
  return {
    'Access-Control-Allow-Origin': env.ALLOWED_ORIGIN || '*',
    'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Allow-Credentials': 'true',
  };
}

/** 로컬 기준 YYYY-MM-DD. toISOString() 은 UTC 라 한국 새벽에 하루 밀립니다. (RCD 때 겪은 버그) */
function todayKST() {
  const d = new Date(Date.now() + 9 * 3600 * 1000);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

// ---------------------------------------------------------------- 세션 (HMAC 서명 쿠키)
async function hmac(secret, data) {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

async function createSession(env, email, name) {
  const payload = btoa(JSON.stringify({ email, name, exp: Date.now() + SESSION_TTL * 1000 }))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  return `${payload}.${await hmac(env.SESSION_SECRET, payload)}`;
}

/**
 * 세션 검증.
 *  1순위: Authorization: Bearer <token>
 *  2순위: 쿠키
 *
 * Bearer 를 먼저 보는 이유 — SPA(github.io)와 Worker(workers.dev)는 서로 다른
 * 사이트라 쿠키가 "서드파티 쿠키"가 됩니다. 크롬 시크릿 모드는 이를 기본
 * 차단하고 일반 모드에서도 점차 없어지는 중이라, 헤더 방식이 안전합니다.
 */
async function verifySession(env, request) {
  let raw = null;

  const auth = request.headers.get('Authorization') || '';
  if (auth.startsWith('Bearer ')) {
    raw = auth.slice(7).trim();
  } else {
    const cookie = request.headers.get('Cookie') || '';
    const m = cookie.match(new RegExp(`${SESSION_COOKIE}=([^;]+)`));
    if (m) raw = m[1];
  }
  if (!raw) return null;

  const [payload, sig] = raw.split('.');
  if (!payload || !sig) return null;
  if (sig !== await hmac(env.SESSION_SECRET, payload)) return null;

  try {
    const data = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
    if (data.exp < Date.now()) return null;
    return data;
  } catch { return null; }
}

// ---------------------------------------------------------------- Google Drive
/** 전용 계정의 refresh token 으로 access token 발급 (짧게 캐시) */
let _tokenCache = { token: null, exp: 0 };

async function driveToken(env) {
  if (_tokenCache.token && Date.now() < _tokenCache.exp) return _tokenCache.token;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id:     env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      refresh_token: env.DRIVE_REFRESH_TOKEN,
      grant_type:    'refresh_token',
    }),
  });
  if (!res.ok) throw new Error(`Drive token 실패: ${await res.text()}`);

  const d = await res.json();
  _tokenCache = { token: d.access_token, exp: Date.now() + (d.expires_in - 60) * 1000 };
  return d.access_token;
}

async function driveFetch(env, path, init = {}) {
  const token = await driveToken(env);
  const res = await fetch(`https://www.googleapis.com${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers || {}) },
  });
  return res;
}

/** 프로젝트 코드별 폴더를 찾거나 만듭니다. */
async function ensureProjectFolder(env, code) {
  const q = encodeURIComponent(
    `name='${code}' and '${env.DRIVE_ROOT_FOLDER_ID}' in parents ` +
    `and mimeType='application/vnd.google-apps.folder' and trashed=false`
  );
  const found = await (await driveFetch(env, `/drive/v3/files?q=${q}&fields=files(id)`)).json();
  if (found.files?.length) return found.files[0].id;

  const created = await (await driveFetch(env, '/drive/v3/files?fields=id', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name: code,
      mimeType: 'application/vnd.google-apps.folder',
      parents: [env.DRIVE_ROOT_FOLDER_ID],
    }),
  })).json();
  return created.id;
}

/** 새 파일 생성 (multipart) */
async function driveCreate(env, folderId, name, mimeType, bytes) {
  const boundary = '----pjt' + crypto.randomUUID();
  const meta = JSON.stringify({ name, parents: [folderId] });

  const head = new TextEncoder().encode(
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n` +
    `--${boundary}\r\nContent-Type: ${mimeType || 'application/octet-stream'}\r\n\r\n`
  );
  const tail = new TextEncoder().encode(`\r\n--${boundary}--\r\n`);
  const body = new Uint8Array(head.length + bytes.length + tail.length);
  body.set(head, 0); body.set(bytes, head.length); body.set(tail, head.length + bytes.length);

  const res = await driveFetch(env, '/upload/drive/v3/files?uploadType=multipart&fields=id,size,mimeType', {
    method: 'POST',
    headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
    body,
  });
  if (!res.ok) throw new Error(`Drive 업로드 실패: ${await res.text()}`);
  return res.json();
}

/**
 * 기존 파일에 새 버전 덮어쓰기.
 * ★ keepRevisionForever=true 가 핵심입니다.
 *   이걸 빼면 Drive 가 30일 경과 또는 100개 초과분 구버전을 자동 삭제합니다.
 */
async function driveUpdateContent(env, fileId, mimeType, bytes) {
  const res = await driveFetch(
    env,
    `/upload/drive/v3/files/${fileId}?uploadType=media&keepRevisionForever=true&fields=id,size,headRevisionId`,
    {
      method: 'PATCH',
      headers: { 'Content-Type': mimeType || 'application/octet-stream' },
      body: bytes,
    }
  );
  if (!res.ok) throw new Error(`Drive 버전 갱신 실패: ${await res.text()}`);
  return res.json();
}

// ---------------------------------------------------------------- 라우터
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const cors = corsHeaders(env);

    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });

    try {
      // ---------------------------------------------------- 인증
      if (path === '/auth/login') {
        const p = new URLSearchParams({
          client_id: env.GOOGLE_CLIENT_ID,
          redirect_uri: `${url.origin}/auth/callback`,
          response_type: 'code',
          scope: 'openid email profile',
          access_type: 'online',
          prompt: 'select_account',
        });
        return Response.redirect(`https://accounts.google.com/o/oauth2/v2/auth?${p}`, 302);
      }

      if (path === '/auth/callback') {
        const code = url.searchParams.get('code');
        if (!code) return err('code 없음', 400);

        const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            code,
            client_id: env.GOOGLE_CLIENT_ID,
            client_secret: env.GOOGLE_CLIENT_SECRET,
            redirect_uri: `${url.origin}/auth/callback`,
            grant_type: 'authorization_code',
          }),
        });
        const tk = await tokenRes.json();
        if (!tk.id_token) return err('토큰 발급 실패', 401);

        const claims = JSON.parse(atob(tk.id_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
        const allowed = (env.ALLOWED_EMAILS || '').split(',').map(s => s.trim().toLowerCase());

        if (!allowed.includes((claims.email || '').toLowerCase())) {
          return new Response('접근 권한이 없는 계정입니다.', { status: 403 });
        }

        const session = await createSession(env, claims.email, claims.name || claims.email);

        // 토큰은 URL 프래그먼트(#)로 전달합니다. 프래그먼트는 서버로 전송되지
        // 않으므로 로그에 남지 않고, SPA 가 읽은 뒤 즉시 주소창에서 지웁니다.
        // 쿠키도 같이 심어두지만 서드파티 차단 환경에서는 무시됩니다.
        return new Response(null, {
          status: 302,
          headers: {
            Location: `${env.APP_URL}#t=${encodeURIComponent(session)}`,
            'Set-Cookie': `${SESSION_COOKIE}=${session}; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=${SESSION_TTL}`,
          },
        });
      }

      if (path === '/auth/logout') {
        return new Response(null, {
          status: 302,
          headers: {
            Location: env.APP_URL,
            'Set-Cookie': `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=0`,
            ...cors,
          },
        });
      }

      // ---------------------------------------------------- 이하 전부 로그인 필요
      const user = await verifySession(env, request);
      if (!user) return json({ error: '로그인 필요' }, 401, cors);

      if (path === '/api/me') return json({ user }, 200, cors);

      const db = env.DB;

      // ---------------------------------------------------- 마스터 값
      if (path === '/api/config' && request.method === 'GET') {
        const { results } = await db.prepare(
          `SELECT group_name, value, label, color, sort_order
             FROM config WHERE is_active = 1 ORDER BY group_name, sort_order`
        ).all();
        return json({ config: results }, 200, cors);
      }

      // ---------------------------------------------------- 대시보드 통계
      if (path === '/api/stats' && request.method === 'GET') {
        const byStatus = await db.prepare(
          `SELECT status, COUNT(*) n FROM projects WHERE is_archived = 0 GROUP BY status`
        ).all();
        const byCategory = await db.prepare(
          `SELECT category, COUNT(*) n FROM projects WHERE is_archived = 0 GROUP BY category ORDER BY n DESC`
        ).all();
        const overdue = await db.prepare(
          `SELECT id, code, title, target_date FROM projects
            WHERE is_archived = 0 AND status NOT IN ('Completed','Dropped')
              AND target_date IS NOT NULL AND target_date < ?
            ORDER BY target_date`
        ).bind(todayKST()).all();
        const recent = await db.prepare(
          `SELECT u.id, u.update_date, u.title, u.update_type, p.code, p.title AS project_title
             FROM updates u JOIN projects p ON p.id = u.project_id
            ORDER BY u.update_date DESC LIMIT 15`
        ).all();

        return json({
          byStatus: byStatus.results,
          byCategory: byCategory.results,
          overdue: overdue.results,
          recentUpdates: recent.results,
        }, 200, cors);
      }

      // ---------------------------------------------------- 통합 검색
      if (path === '/api/search' && request.method === 'GET') {
        const q = (url.searchParams.get('q') || '').trim();
        if (q.length < 2) return json({ results: [] }, 200, cors);

        const { results } = await db.prepare(
          `SELECT entity_type, entity_id, project_id, project_code, title,
                  snippet(search_fts, 5, '<mark>', '</mark>', '…', 20) AS excerpt
             FROM search_fts WHERE search_fts MATCH ?
             ORDER BY rank LIMIT 50`
        ).bind(q.replace(/"/g, '')).all();

        return json({ results }, 200, cors);
      }

      // ---------------------------------------------------- 프로젝트 목록
      if (path === '/api/projects' && request.method === 'GET') {
        const conds = ['is_archived = 0'];
        const binds = [];
        for (const [param, col] of [['status','status'], ['category','category'], ['priority','priority']]) {
          const v = url.searchParams.get(param);
          if (v) { conds.push(`${col} = ?`); binds.push(v); }
        }
        const { results } = await db.prepare(
          `SELECT * FROM projects WHERE ${conds.join(' AND ')}
            ORDER BY CASE status WHEN 'In-Progress' THEN 1 WHEN 'Discussion' THEN 2
                                 WHEN 'On-Hold' THEN 3 ELSE 4 END,
                     COALESCE(target_date, '9999-12-31')`
        ).bind(...binds).all();
        return json({ projects: results }, 200, cors);
      }

      // ---------------------------------------------------- 프로젝트 생성
      if (path === '/api/projects' && request.method === 'POST') {
        const b = await request.json();
        if (!b.title || !b.category) return json({ error: '제목과 카테고리는 필수입니다' }, 400, cors);

        const code = b.code || await nextCode(db, b.category);
        const r = await db.prepare(
          `INSERT INTO projects (code,title,category,sub_category,status,priority,owner,vendor,
                                 start_date,target_date,progress,budget,summary,tags,related_systems,source_page_id)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`
        ).bind(
          code, b.title, b.category, b.sub_category ?? null,
          b.status ?? 'In-Progress', b.priority ?? 'Medium',
          b.owner ?? user.name, b.vendor ?? null,
          b.start_date ?? todayKST(), b.target_date ?? null,
          b.progress ?? 0, b.budget ?? null, b.summary ?? null,
          b.tags ?? null, b.related_systems ?? null, b.source_page_id ?? null
        ).run();

        return json({ id: r.meta.last_row_id, code }, 201, cors);
      }

      // ---------------------------------------------------- 프로젝트 상세 / 수정 / 삭제
      let m;
      if ((m = path.match(/^\/api\/projects\/(\d+)$/))) {
        const pid = Number(m[1]);

        if (request.method === 'GET') {
          const project = await db.prepare(`SELECT * FROM projects WHERE id = ?`).bind(pid).first();
          if (!project) return json({ error: '없는 프로젝트' }, 404, cors);

          const tasks   = await db.prepare(`SELECT * FROM tasks WHERE project_id=? ORDER BY sort_order, id`).bind(pid).all();
          const updates = await db.prepare(`SELECT * FROM updates WHERE project_id=? ORDER BY update_date DESC, id DESC`).bind(pid).all();
          const files   = await db.prepare(`SELECT * FROM files WHERE project_id=? AND is_deleted=0 ORDER BY file_name`).bind(pid).all();

          return json({
            project,
            tasks: tasks.results,
            updates: updates.results,
            files: files.results,
          }, 200, cors);
        }

        if (request.method === 'PATCH') {
          const b = await request.json();
          const allow = ['title','category','sub_category','status','priority','owner','vendor',
                         'start_date','target_date','actual_end_date','progress','budget',
                         'summary','tags','related_systems','is_archived'];
          const sets = [], binds = [];
          for (const k of allow) if (k in b) { sets.push(`${k} = ?`); binds.push(b[k]); }
          if (!sets.length) return json({ error: '변경할 항목 없음' }, 400, cors);

          // 완료로 바뀌면 완료일·진행률 자동 정리
          if (b.status === 'Completed') {
            sets.push('actual_end_date = COALESCE(actual_end_date, ?)', 'progress = 100');
            binds.push(todayKST());
          }
          sets.push(`updated_at = datetime('now')`);
          binds.push(pid);

          await db.prepare(`UPDATE projects SET ${sets.join(', ')} WHERE id = ?`).bind(...binds).run();
          return json({ ok: true }, 200, cors);
        }

        if (request.method === 'DELETE') {
          await db.prepare(`UPDATE projects SET is_archived = 1 WHERE id = ?`).bind(pid).run();
          return json({ ok: true }, 200, cors);
        }
      }

      // ---------------------------------------------------- 진행 기록 추가
      if (path === '/api/updates' && request.method === 'POST') {
        const b = await request.json();
        if (!b.project_id) return json({ error: 'project_id 필요' }, 400, cors);

        const r = await db.prepare(
          `INSERT INTO updates (project_id, update_date, author, update_type, title, content, next_action, source_page_id)
           VALUES (?,?,?,?,?,?,?,?)`
        ).bind(
          b.project_id, b.update_date ?? todayKST(), b.author ?? user.name,
          b.update_type ?? '일반', b.title ?? null, b.content ?? null,
          b.next_action ?? null, b.source_page_id ?? null
        ).run();

        return json({ id: r.meta.last_row_id }, 201, cors);
      }

      // ---------------------------------------------------- 작업 추가 / 수정
      if (path === '/api/tasks' && request.method === 'POST') {
        const b = await request.json();
        const r = await db.prepare(
          `INSERT INTO tasks (project_id,title,status,assignee,due_date,sort_order,note)
           VALUES (?,?,?,?,?,?,?)`
        ).bind(
          b.project_id, b.title, b.status ?? 'To Do', b.assignee ?? user.name,
          b.due_date ?? null, b.sort_order ?? 0, b.note ?? null
        ).run();
        return json({ id: r.meta.last_row_id }, 201, cors);
      }

      if ((m = path.match(/^\/api\/tasks\/(\d+)$/)) && request.method === 'PATCH') {
        const b = await request.json();
        const allow = ['title','status','assignee','due_date','sort_order','note'];
        const sets = [], binds = [];
        for (const k of allow) if (k in b) { sets.push(`${k} = ?`); binds.push(b[k]); }
        sets.push(`updated_at = datetime('now')`);
        binds.push(Number(m[1]));
        await db.prepare(`UPDATE tasks SET ${sets.join(', ')} WHERE id = ?`).bind(...binds).run();
        return json({ ok: true }, 200, cors);
      }

      // ==================================================== 파일 업로드 (버전관리)
      if (path === '/api/files/upload' && request.method === 'POST') {
        const form = await request.formData();
        const file      = form.get('file');
        const projectId = Number(form.get('project_id'));
        const docType   = form.get('doc_type') || '기타';
        const changeNote = form.get('change_note') || '';

        if (!file || !projectId) return json({ error: 'file 과 project_id 필요' }, 400, cors);

        const project = await db.prepare(`SELECT id, code FROM projects WHERE id = ?`).bind(projectId).first();
        if (!project) return json({ error: '없는 프로젝트' }, 404, cors);

        const bytes  = new Uint8Array(await file.arrayBuffer());
        const sizeKb = Math.round(bytes.length / 1024);
        const folder = await ensureProjectFolder(env, project.code);

        // 같은 프로젝트에 같은 이름이 이미 있으면 → 새 리비전으로
        const existing = await db.prepare(
          `SELECT * FROM files WHERE project_id = ? AND file_name = ?`
        ).bind(projectId, file.name).first();

        let fileId, driveFileId, versionNo, revisionId;

        if (existing && !existing.is_deleted) {
          const updated = await driveUpdateContent(env, existing.drive_file_id, file.type, bytes);
          driveFileId = existing.drive_file_id;
          fileId      = existing.id;
          versionNo   = existing.version_no + 1;
          revisionId  = updated.headRevisionId;

          await db.prepare(
            `UPDATE files SET version_no = ?, size_kb = ?, doc_type = ?,
                    uploaded_by = ?, is_deleted = 0, updated_at = datetime('now')
              WHERE id = ?`
          ).bind(versionNo, sizeKb, docType, user.name, fileId).run();
        } else {
          const created = await driveCreate(env, folder, file.name, file.type, bytes);
          driveFileId = created.id;
          versionNo   = 1;

          const head = await (await driveFetch(env,
            `/drive/v3/files/${driveFileId}?fields=headRevisionId`)).json();
          revisionId = head.headRevisionId;

          const r = await db.prepare(
            `INSERT INTO files (project_id, drive_file_id, file_name, mime_type, doc_type,
                                version_no, size_kb, uploaded_by)
             VALUES (?,?,?,?,?,1,?,?)
             ON CONFLICT(project_id, file_name) DO UPDATE SET
                drive_file_id = excluded.drive_file_id, is_deleted = 0,
                version_no = files.version_no + 1, updated_at = datetime('now')`
          ).bind(projectId, driveFileId, file.name, file.type, docType, sizeKb, user.name).run();

          fileId = r.meta.last_row_id ||
            (await db.prepare(`SELECT id FROM files WHERE project_id=? AND file_name=?`)
                     .bind(projectId, file.name).first()).id;
        }

        await db.prepare(
          `INSERT INTO file_revisions (file_id, version_no, drive_revision_id, size_kb, uploaded_by, change_note)
           VALUES (?,?,?,?,?,?)`
        ).bind(fileId, versionNo, revisionId, sizeKb, user.name, changeNote).run();

        return json({ file_id: fileId, version_no: versionNo, size_kb: sizeKb }, 201, cors);
      }

      // ---------------------------------------------------- 버전 이력 조회
      if ((m = path.match(/^\/api\/files\/(\d+)\/revisions$/)) && request.method === 'GET') {
        const { results } = await db.prepare(
          `SELECT version_no, drive_revision_id, size_kb, uploaded_by, change_note, created_at
             FROM file_revisions WHERE file_id = ? ORDER BY version_no DESC`
        ).bind(Number(m[1])).all();
        return json({ revisions: results }, 200, cors);
      }

      // ---------------------------------------------------- 파일 다운로드 (프록시)
      //  Drive 링크를 직접 노출하지 않습니다. 로그인한 세션만 통과.
      if ((m = path.match(/^\/api\/files\/(\d+)\/download$/)) && request.method === 'GET') {
        const f = await db.prepare(`SELECT * FROM files WHERE id = ?`).bind(Number(m[1])).first();
        if (!f) return json({ error: '없는 파일' }, 404, cors);

        const rev = url.searchParams.get('rev');   // 특정 버전 요청 시
        const drivePath = rev
          ? `/drive/v3/files/${f.drive_file_id}/revisions/${rev}?alt=media`
          : `/drive/v3/files/${f.drive_file_id}?alt=media`;

        const res = await driveFetch(env, drivePath);
        if (!res.ok) return json({ error: 'Drive 조회 실패' }, 502, cors);

        return new Response(res.body, {
          headers: {
            'Content-Type': f.mime_type || 'application/octet-stream',
            'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(f.file_name)}`,
            ...cors,
          },
        });
      }

      // ---------------------------------------------------- 파일 삭제 (소프트)
      if ((m = path.match(/^\/api\/files\/(\d+)$/)) && request.method === 'DELETE') {
        await db.prepare(`UPDATE files SET is_deleted = 1 WHERE id = ?`).bind(Number(m[1])).run();
        return json({ ok: true }, 200, cors);
      }

      return json({ error: 'Not Found' }, 404, cors);
    }
    catch (e) {
      console.error(e);
      return json({ error: e.message }, 500, cors);
    }
  },
};

// ---------------------------------------------------------------- 프로젝트 코드 채번
const ABBR = {
  'IT-Infra Project':'INFRA', 'IT-Operation':'OPS', 'IT_Security':'SEC',
  'IT-DW_Operations':'DW', 'IT RM':'RM', 'IT Core':'CORE', 'SAP-Be1':'SAP',
  'Autofocus':'AF', 'Vercel':'VRC', 'Hiparking':'HIP', 'Network':'NET',
  'PS_Script-Ops':'PSO', 'Linux_Script-Ops':'LNX', 'ADDS_IMS-DMS':'ADDS',
  'ID-PW':'IDPW', 'To-Do-List':'TODO', 'OS':'OS', 'MoM':'MOM',
  'Mail_SYSTEM':'MAIL', 'Escalation_points':'ESC', 'Service-Catalogue':'SVC',
  'DB':'DB', 'Common_sense':'CMN', 'Payment':'PAY',
};

async function nextCode(db, category) {
  const abbr = ABBR[category] || 'ETC';
  const year = todayKST().slice(0, 4);
  const prefix = `${abbr}-${year}-`;

  const row = await db.prepare(
    `SELECT code FROM projects WHERE code LIKE ? ORDER BY code DESC LIMIT 1`
  ).bind(prefix + '%').first();

  const n = row ? parseInt(row.code.slice(prefix.length), 10) + 1 : 1;
  return prefix + String(n).padStart(3, '0');
}
