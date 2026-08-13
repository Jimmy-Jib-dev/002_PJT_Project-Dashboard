-- =============================================================================
--  PJT (IT Project Management) - Cloudflare D1 스키마
-- =============================================================================
--  적용:  wrangler d1 execute pjt-db --file=./schema.sql --remote
--  로컬:  wrangler d1 execute pjt-db --file=./schema.sql --local
-- =============================================================================

PRAGMA foreign_keys = ON;

-- -----------------------------------------------------------------------------
-- 1. 프로젝트 마스터  (OneNote 페이지 1건 = 1행)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS projects (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  code            TEXT    NOT NULL UNIQUE,          -- INFRA-2026-001
  title           TEXT    NOT NULL,
  category        TEXT    NOT NULL,                 -- OneNote 섹션명
  sub_category    TEXT,
  status          TEXT    NOT NULL DEFAULT 'In-Progress',
                  -- Discussion | In-Progress | On-Hold | Completed | Dropped
  priority        TEXT    NOT NULL DEFAULT 'Medium',   -- High | Medium | Low
  owner           TEXT,
  vendor          TEXT,
  start_date      TEXT,                             -- 'YYYY-MM-DD' 로컬 조합
  target_date     TEXT,
  actual_end_date TEXT,
  progress        INTEGER NOT NULL DEFAULT 0,       -- 0~100
  budget          INTEGER,
  summary         TEXT,
  tags            TEXT,                             -- 쉼표 구분
  related_systems TEXT,
  is_archived     INTEGER NOT NULL DEFAULT 0,
  source_page_id  TEXT,                             -- OneNote 페이지 ID (재이관 중복 방지)
  created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_projects_status   ON projects(status);
CREATE INDEX IF NOT EXISTS idx_projects_category ON projects(category);
CREATE INDEX IF NOT EXISTS idx_projects_target   ON projects(target_date);
CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_srcpage
  ON projects(source_page_id) WHERE source_page_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2. 하위 작업
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tasks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  title       TEXT    NOT NULL,
  status      TEXT    NOT NULL DEFAULT 'To Do',     -- To Do | Doing | Blocked | Done
  assignee    TEXT,
  due_date    TEXT,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  note        TEXT,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_tasks_due     ON tasks(due_date) WHERE status != 'Done';

-- -----------------------------------------------------------------------------
-- 3. 진행 기록 (타임라인)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS updates (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  update_date    TEXT    NOT NULL,
  author         TEXT,
  update_type    TEXT    NOT NULL DEFAULT '일반',
                 -- 일반 | 회의록 | 의사결정 | 이슈 | 마이그레이션
  title          TEXT,
  content        TEXT,
  next_action    TEXT,
  source_page_id TEXT,
  created_at     TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_updates_project ON updates(project_id, update_date DESC);
CREATE INDEX IF NOT EXISTS idx_updates_date    ON updates(update_date DESC);

-- -----------------------------------------------------------------------------
-- 4. 파일 (실물은 Google Drive, 여기는 메타만)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS files (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  drive_file_id  TEXT    NOT NULL,                  -- Google Drive fileId
  file_name      TEXT    NOT NULL,
  mime_type      TEXT,
  doc_type       TEXT    NOT NULL DEFAULT '기타',
                 -- 제안서 | 견적서 | 계약서 | 설계서 | 보고서 | 회의자료 | 매뉴얼 | 기타
  version_no     INTEGER NOT NULL DEFAULT 1,        -- 현재 최신 버전 번호
  size_kb        INTEGER,
  uploaded_by    TEXT,
  note           TEXT,
  is_deleted     INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at     TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_files_project ON files(project_id, is_deleted);
-- 같은 프로젝트 안에서 같은 파일명은 1행만. 재업로드 = 새 리비전.
CREATE UNIQUE INDEX IF NOT EXISTS idx_files_unique ON files(project_id, file_name);

-- -----------------------------------------------------------------------------
-- 5. 파일 버전 이력  (★ 1순위 기능의 핵심 테이블)
-- -----------------------------------------------------------------------------
--  Google Drive 가 실제 바이트를 리비전으로 보관하고,
--  여기에는 "누가 언제 왜 올렸는지" 를 기록합니다. Drive 만으로는 안 남는 정보.
CREATE TABLE IF NOT EXISTS file_revisions (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  file_id           INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  version_no        INTEGER NOT NULL,
  drive_revision_id TEXT    NOT NULL,               -- Drive revisionId
  size_kb           INTEGER,
  uploaded_by       TEXT,
  change_note       TEXT,                           -- "VAT 라인 반영본" 같은 변경 사유
  created_at        TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_revisions_file ON file_revisions(file_id, version_no DESC);

-- -----------------------------------------------------------------------------
-- 6. 마스터 값
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS config (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  group_name TEXT    NOT NULL,                      -- category | status | priority | doc_type
  value      TEXT    NOT NULL,
  label      TEXT,
  color      TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  INTEGER NOT NULL DEFAULT 1
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_config_unique ON config(group_name, value);

-- -----------------------------------------------------------------------------
-- 7. 통합 검색 (FTS5)  ★ 3순위 기능
-- -----------------------------------------------------------------------------
--  trigram 토크나이저를 쓰는 이유: 기본 unicode61 은 공백 기준으로 끊어서
--  한국어 조사가 붙으면("네트워크를") 검색이 안 됩니다. trigram 은 3글자
--  단위 부분일치라 한국어에서 훨씬 잘 잡힙니다. 대신 인덱스가 좀 큽니다.
CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
  entity_type   UNINDEXED,      -- project | update | file
  entity_id     UNINDEXED,
  project_id    UNINDEXED,
  project_code  UNINDEXED,
  title,
  body,
  tokenize = 'trigram'
);

-- --- projects 동기화 트리거 -------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_projects_ai AFTER INSERT ON projects BEGIN
  INSERT INTO search_fts(entity_type, entity_id, project_id, project_code, title, body)
  VALUES ('project', NEW.id, NEW.id, NEW.code,
          NEW.title, COALESCE(NEW.summary,'') || ' ' || COALESCE(NEW.tags,'') || ' ' || COALESCE(NEW.vendor,''));
END;

CREATE TRIGGER IF NOT EXISTS trg_projects_ad AFTER DELETE ON projects BEGIN
  DELETE FROM search_fts WHERE entity_type='project' AND entity_id=OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_projects_au AFTER UPDATE ON projects BEGIN
  DELETE FROM search_fts WHERE entity_type='project' AND entity_id=OLD.id;
  INSERT INTO search_fts(entity_type, entity_id, project_id, project_code, title, body)
  VALUES ('project', NEW.id, NEW.id, NEW.code,
          NEW.title, COALESCE(NEW.summary,'') || ' ' || COALESCE(NEW.tags,'') || ' ' || COALESCE(NEW.vendor,''));
END;

-- --- updates 동기화 트리거 --------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_updates_ai AFTER INSERT ON updates BEGIN
  INSERT INTO search_fts(entity_type, entity_id, project_id, project_code, title, body)
  VALUES ('update', NEW.id, NEW.project_id,
          (SELECT code FROM projects WHERE id = NEW.project_id),
          COALESCE(NEW.title,''), COALESCE(NEW.content,''));
END;

CREATE TRIGGER IF NOT EXISTS trg_updates_ad AFTER DELETE ON updates BEGIN
  DELETE FROM search_fts WHERE entity_type='update' AND entity_id=OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_updates_au AFTER UPDATE ON updates BEGIN
  DELETE FROM search_fts WHERE entity_type='update' AND entity_id=OLD.id;
  INSERT INTO search_fts(entity_type, entity_id, project_id, project_code, title, body)
  VALUES ('update', NEW.id, NEW.project_id,
          (SELECT code FROM projects WHERE id = NEW.project_id),
          COALESCE(NEW.title,''), COALESCE(NEW.content,''));
END;

-- --- files 동기화 트리거 ----------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_files_ai AFTER INSERT ON files BEGIN
  INSERT INTO search_fts(entity_type, entity_id, project_id, project_code, title, body)
  VALUES ('file', NEW.id, NEW.project_id,
          (SELECT code FROM projects WHERE id = NEW.project_id),
          NEW.file_name, COALESCE(NEW.doc_type,'') || ' ' || COALESCE(NEW.note,''));
END;

CREATE TRIGGER IF NOT EXISTS trg_files_ad AFTER DELETE ON files BEGIN
  DELETE FROM search_fts WHERE entity_type='file' AND entity_id=OLD.id;
END;

-- -----------------------------------------------------------------------------
-- 8. 초기 마스터 데이터 (OneNote 섹션 그대로)
-- -----------------------------------------------------------------------------
INSERT OR IGNORE INTO config (group_name, value, label, color, sort_order) VALUES
  ('category','IT-Infra Project','IT-Infra Project','#2563eb', 1),
  ('category','IT-Operation','IT-Operation','#0891b2', 2),
  ('category','IT_Security','IT_Security','#dc2626', 3),
  ('category','IT-DW_Operations','IT-DW_Operations','#7c3aed', 4),
  ('category','IT RM','IT RM','#ea580c', 5),
  ('category','IT Core','IT Core','#0d9488', 6),
  ('category','SAP-Be1','SAP-Be1','#1d4ed8', 7),
  ('category','Autofocus','Autofocus','#65a30d', 8),
  ('category','Vercel','Vercel','#475569', 9),
  ('category','Hiparking','Hiparking','#c026d3',10),
  ('category','Network','Network','#0284c7',11),
  ('category','PS_Script-Ops','PS_Script-Ops','#7e22ce',12),
  ('category','Linux_Script-Ops','Linux_Script-Ops','#166534',13),
  ('category','ADDS_IMS-DMS','ADDS_IMS-DMS','#b45309',14),
  ('category','ID-PW','ID-PW','#991b1b',15),
  ('category','To-Do-List','To-Do-List','#a16207',16),
  ('category','OS','OS','#334155',17),
  ('category','MoM','MoM','#be185d',18),
  ('category','Mail_SYSTEM','Mail_SYSTEM','#0369a1',19),
  ('category','Escalation_points','Escalation_points','#b91c1c',20),
  ('category','Service-Catalogue','Service-Catalogue','#059669',21),
  ('category','DB','DB','#4338ca',22),
  ('category','Common_sense','Common_sense','#57534e',23),
  ('category','Payment','Payment','#15803d',24),
  ('category','기타','기타','#6b7280',99);

INSERT OR IGNORE INTO config (group_name, value, label, color, sort_order) VALUES
  ('status','Discussion','논의중','#fef3c7', 1),
  ('status','In-Progress','진행중','#dbeafe', 2),
  ('status','On-Hold','보류','#e5e7eb', 3),
  ('status','Completed','완료','#d1fae5', 4),
  ('status','Dropped','중단','#fee2e2', 5);

INSERT OR IGNORE INTO config (group_name, value, label, color, sort_order) VALUES
  ('priority','High','높음','#dc2626', 1),
  ('priority','Medium','보통','#f59e0b', 2),
  ('priority','Low','낮음','#10b981', 3);

INSERT OR IGNORE INTO config (group_name, value, label, sort_order) VALUES
  ('doc_type','제안서','제안서', 1),
  ('doc_type','견적서','견적서', 2),
  ('doc_type','계약서','계약서', 3),
  ('doc_type','설계서','설계서', 4),
  ('doc_type','보고서','보고서', 5),
  ('doc_type','회의자료','회의자료', 6),
  ('doc_type','매뉴얼','매뉴얼', 7),
  ('doc_type','기타','기타', 9);
