# Theory Exams Update Log

Date: 2026-05-03  
Scope: Theory-exam-specific backend and Flutter updates (lab logic left unchanged)

## 1) Backend (`backend/main.py`)

### A. Database schema migration for `theory_exams`
- Updated `theory_exams` structure to:
  - `id` (PK, autoincrement)
  - `course_code` (TEXT NOT NULL)
  - `course_name` (TEXT NOT NULL)
  - `exam_date` (TEXT NOT NULL)
  - `start_time` (TEXT NOT NULL)
  - `end_time` (TEXT NOT NULL)
- Added index:
  - `idx_theory_exams_code` on `course_code`
- Added unique index:
  - `uq_theory_exams_row` on `(course_code, course_name, exam_date, start_time, end_time)`

### B. Safe schema alignment
- Added `_ensure_theory_schema(conn)`:
  - Checks current table columns using `PRAGMA table_info(theory_exams)`
  - Rebuilds `theory_exams` only if old/incompatible schema is detected
  - Prevents repeated destructive behavior on every startup

### C. Theory ingestion endpoint
- Endpoint: `POST /api/v1/admin/upload/theory-exams`
- Behavior:
  - Accepts uploaded Excel workbook
  - Reads/normalizes columns:
    - `course_code`, `course_name`, `exam_date`, `start_time`, `end_time`
    - with alias fallback support
  - Clears existing `theory_exams`
  - Inserts using `INSERT OR REPLACE`

### D. Theory student filtering endpoint
- Endpoint: `GET /api/v1/student/theory-exams/{rollnumber}`
- Matching rule:
  - `students.code` == `theory_exams.course_code`
- Returns:
  - `course_code`, `course_name`, `exam_date`, `start_time`, `end_time`
  - wrapped as `{"rollnumber": "...", "theory_exams": [...] }`

### E. Admin dashboard rendering (server HTML)
- Updated theory-test rendering to show theory fields:
  - `course_code`, `course_name`, `exam_date`, `start_time`, `end_time`

## 2) Flutter (`student_timetable_app-main/lib/main.dart`)

### A. Theory model update
- Added `TheoryExamEntry` with fields:
  - `courseCode`, `courseName`, `examDate`, `startTime`, `endTime`
- `ExamsPayload.theoryExams` now uses `List<TheoryExamEntry>`

### B. Theory local cache support
- Added cache key:
  - `cached_theory_exams_${rollNumber}`
- On Exams load:
  - Reads cached theory exams first (offline support)
  - Fetches network theory exams
  - Writes latest result back to SharedPreferences cache

### C. Theory UI section update
- Theory cards now display:
  - course name
  - exam date
  - start/end time
  - course code

## 3) Explicitly not changed
- Weekly timetable logic/routes/layout untouched
- Working lab mapping/filtering/display logic untouched

## 4) Validation done
- `python3 -m py_compile backend/main.py` passed
- `theory_exams` columns verified via backend venv:
  - `id, course_code, course_name, exam_date, start_time, end_time`

## 5) Current git working state (at log generation time)
- Modified:
  - `backend/main.py`
  - `backend/timetable.db`
  - `student_timetable_app-main/lib/main.dart`
- Untracked:
  - `backend/.~lock.lab_exams.xlsx#`
  - `backend/final_exam_datesheet_NOD.xlsx`
  - `backend/lab_exams.xlsx`
