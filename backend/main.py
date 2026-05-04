"""
FAST-NUCES timetable backend with isolated routine/lab/theory tables.
Python 3.10+ | FastAPI | pandas | SQLite
"""

from __future__ import annotations

import io
import re
import sqlite3
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import pandas as pd
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "timetable.db"

SLOT_TO_LABEL: dict[int, str] = {
    0: "08:00 AM - 09:30 AM",
    1: "09:30 AM - 11:00 AM",
    2: "11:00 AM - 12:30 PM",
    3: "12:30 PM - 02:00 PM",
    4: "02:00 PM - 03:30 PM",
    5: "03:30 PM - 05:00 PM",
    6: "05:00 PM - 06:30 PM",
}
LABEL_TO_SLOT: dict[str, int] = {label: slot for slot, label in SLOT_TO_LABEL.items()}

DAY_ORDER: dict[str, int] = {
    "Monday": 0,
    "Tuesday": 1,
    "Wednesday": 2,
    "Thursday": 3,
    "Friday": 4,
    "Saturday": 5,
    "Sunday": 6,
}
# REMOVED

SHEET_TIMETABLE = "Timetable Timing"
SHEET_STUDENTS = "Students"
SHEET_LAB_EXAMS = "Lab Exams"
SHEET_THEORY_EXAMS = "Theory Exams"


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(
    title="FAST-NUCES Timetable API",
    version="2.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with get_connection() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS courses (
                code TEXT NOT NULL,
                batch TEXT NOT NULL,
                subject TEXT NOT NULL,
                teacher TEXT NOT NULL,
                PRIMARY KEY (code, batch)
            );

            CREATE TABLE IF NOT EXISTS timetable (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                day TEXT NOT NULL,
                location TEXT NOT NULL,
                slot INTEGER NOT NULL,
                code TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS lab_exams (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL,
                venue TEXT NOT NULL,
                time TEXT NOT NULL,
                code TEXT NOT NULL,
                batch TEXT NOT NULL,
                subject TEXT NOT NULL,
                teacher TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS theory_exams (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                course_code TEXT NOT NULL,
                course_name TEXT NOT NULL,
                exam_date TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS students (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                rollnumber TEXT NOT NULL,
                code TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_students_roll ON students(rollnumber);
            CREATE INDEX IF NOT EXISTS idx_students_code ON students(code);
            CREATE INDEX IF NOT EXISTS idx_timetable_code ON timetable(code);
            CREATE INDEX IF NOT EXISTS idx_lab_exams_code ON lab_exams(code);
            CREATE INDEX IF NOT EXISTS idx_theory_exams_code ON theory_exams(course_code);

            CREATE UNIQUE INDEX IF NOT EXISTS uq_timetable_row
            ON timetable(day, location, slot, code);
            CREATE UNIQUE INDEX IF NOT EXISTS uq_students_row
            ON students(rollnumber, code);
            CREATE UNIQUE INDEX IF NOT EXISTS uq_lab_exams_row
            ON lab_exams(date, venue, time, code, batch, subject, teacher);
            CREATE UNIQUE INDEX IF NOT EXISTS uq_theory_exams_row
            ON theory_exams(course_code, course_name, exam_date, start_time, end_time);
            """
        )
        _ensure_theory_schema(conn)


def _ensure_theory_schema(conn: sqlite3.Connection) -> None:
    rows = conn.execute("PRAGMA table_info(theory_exams)").fetchall()
    existing_cols = [row[1] for row in rows]
    expected_cols = [
        "id",
        "course_code",
        "course_name",
        "exam_date",
        "start_time",
        "end_time",
    ]
    if existing_cols == expected_cols:
        return
    conn.execute("DROP TABLE IF EXISTS theory_exams")
    conn.executescript(
        """
        CREATE TABLE theory_exams (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            course_code TEXT NOT NULL,
            course_name TEXT NOT NULL,
            exam_date TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_theory_exams_code ON theory_exams(course_code);
        CREATE UNIQUE INDEX IF NOT EXISTS uq_theory_exams_row
        ON theory_exams(course_code, course_name, exam_date, start_time, end_time);
        """
    )


def _normalize_column(name: Any) -> str:
    normalized = str(name).strip().lower()
    return re.sub(r"\s+", "_", normalized)


def _rename_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out.columns = [_normalize_column(col) for col in out.columns]
    return out


def _normalize_code(value: Any) -> str:
    if pd.isna(value):
        return ""
    return str(value).strip()


def _normalize_roll(value: Any) -> str:
    if pd.isna(value):
        return ""
    return str(value).strip().upper()


def _as_clean_text(value: Any) -> str:
    if pd.isna(value):
        return ""
    return str(value).strip()


def _require_columns(df: pd.DataFrame, required: set[str], context: str) -> None:
    missing = required - set(df.columns)
    if missing:
        raise HTTPException(
            status_code=400,
            detail=f"{context}: missing columns {sorted(missing)}. Found: {list(df.columns)}",
        )


def _coerce_slot(value: Any) -> int:
    if pd.isna(value):
        raise ValueError("empty slot")
    if isinstance(value, (int, float)) and float(value).is_integer():
        slot = int(value)
        if 0 <= slot <= 6:
            return slot
        raise ValueError(f"slot out of range: {slot}")
    text = str(value).strip()
    if text in LABEL_TO_SLOT:
        return LABEL_TO_SLOT[text]
    compact = re.sub(r"\s+", " ", text)
    for label, slot in LABEL_TO_SLOT.items():
        if compact.lower() == label.lower():
            return slot
    raise ValueError(f"unrecognized slot: {text!r}")


def _apply_aliases(df: pd.DataFrame, aliases: dict[str, set[str]]) -> pd.DataFrame:
    out = df.copy()
    for target, candidates in aliases.items():
        if target in out.columns:
            continue
        for name in candidates:
            if name in out.columns:
                out = out.rename(columns={name: target})
                break
    return out


def _split_code_section(raw_code: str) -> tuple[str, str]:
    parts = [part.strip() for part in raw_code.split(",")]
    base = parts[0].upper() if parts else ""
    section = parts[1].upper() if len(parts) > 1 else ""
    return base, section


def _is_lab_code(code: str) -> bool:
    # Lab if second character in the base course code is 'L' (e.g., AL2002).
    return len(code) >= 2 and code[1].upper() == "L"

# REMOVED

async def _read_workbook(file: UploadFile) -> pd.ExcelFile:
    if not file.filename or not file.filename.lower().endswith((".xlsx", ".xlsm")):
        raise HTTPException(status_code=400, detail="Upload a .xlsx (or .xlsm) workbook.")
    raw = await file.read()
    try:
        return pd.ExcelFile(io.BytesIO(raw))
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"Could not read Excel: {exc}") from exc


def _extract_timetable_and_students(
    workbook: pd.ExcelFile,
) -> tuple[list[tuple[str, str, str, str]], list[tuple[str, str, int, str]], list[tuple[str, str]]]:
    for name in ("Courses", SHEET_TIMETABLE, SHEET_STUDENTS):
        if name not in workbook.sheet_names:
            raise HTTPException(
                status_code=400,
                detail=f"Missing sheet {name!r}. Found: {workbook.sheet_names}",
            )

    courses_df = _rename_columns(pd.read_excel(workbook, sheet_name="Courses"))
    timetable_df = _rename_columns(pd.read_excel(workbook, sheet_name=SHEET_TIMETABLE))
    students_df = _rename_columns(pd.read_excel(workbook, sheet_name=SHEET_STUDENTS))

    col_map_courses = {
        "code": {"code", "course_code", "coursecode"},
        "batch": {"batch", "section"},
        "subject": {"subject", "course_title", "title"},
        "teacher": {"teacher", "instructor", "faculty"},
    }
    for target, aliases in col_map_courses.items():
        if target not in courses_df.columns:
            for a in aliases:
                if a in courses_df.columns:
                    courses_df = courses_df.rename(columns={a: target})
                    break

    timetable_df = _apply_aliases(
        timetable_df,
        {
            "day": {"weekday"},
            "location": {"room", "venue"},
            "slot": {"time_slot", "timeslot", "period"},
            "code": {"course_code", "coursecode"},
        },
    )
    students_df = _apply_aliases(
        students_df,
        {
            "rollnumber": {"roll_number", "roll_no", "rollno", "roll"},
            "code": {"course_code", "coursecode"},
        },
    )

    _require_columns(courses_df, {"code", "batch", "subject", "teacher"}, "Courses sheet")
    _require_columns(timetable_df, {"day", "location", "slot", "code"}, "Timetable sheet")
    _require_columns(students_df, {"rollnumber", "code"}, "Students sheet")

    course_rows: list[tuple[str, str, str, str]] = []
    for _, row in courses_df.iterrows():
        code = _normalize_code(row["code"])
        if not code:
            continue
        batch = str(row["batch"]).strip()
        course_rows.append((
            code,
            batch,
            str(row["subject"]).strip(),
            str(row["teacher"]).strip(),
        ))

    timetable_rows: list[tuple[str, str, int, str]] = []
    for _, row in timetable_df.iterrows():
        code = _normalize_code(row["code"])
        if not code:
            continue
        try:
            slot = _coerce_slot(row["slot"])
        except ValueError as exc:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid timetable slot {row['slot']!r}: {exc}",
            ) from exc
        timetable_rows.append(
            (_as_clean_text(row["day"]), _as_clean_text(row["location"]), slot, code)
        )

    student_rows: list[tuple[str, str]] = []
    for _, row in students_df.iterrows():
        roll = _normalize_roll(row["rollnumber"])
        code = _normalize_code(row["code"])
        if roll and code:
            student_rows.append((roll, code))

    return course_rows, timetable_rows, student_rows


def _extract_exam_rows(
    workbook: pd.ExcelFile,
    preferred_sheet_name: str,
) -> list[tuple[str, str, str, str, str, str, str]]:
    if preferred_sheet_name in workbook.sheet_names:
        df = _rename_columns(pd.read_excel(workbook, sheet_name=preferred_sheet_name))
    else:
        # Processed files may use one custom sheet name; fallback to first.
        if not workbook.sheet_names:
            raise HTTPException(status_code=400, detail="Workbook has no sheets.")
        df = _rename_columns(pd.read_excel(workbook, sheet_name=workbook.sheet_names[0]))

    df = _apply_aliases(
        df,
        {
            "date": {"exam_date", "day"},
            "venue": {"location", "room"},
            "time": {"exam_time", "time_slot", "slot"},
            "code": {"course_code", "coursecode"},
            "batch": {"section"},
            "subject": {"title", "course_title"},
            "teacher": {"instructor", "faculty"},
        },
    )
    _require_columns(
        df,
        {"date", "venue", "time", "code", "batch", "subject", "teacher"},
        "Exam sheet",
    )

    rows: list[tuple[str, str, str, str, str, str, str]] = []
    for _, row in df.iterrows():
        code = _normalize_code(row["code"])
        if not code:
            continue
        rows.append(
            (
                _as_clean_text(row["date"]),
                _as_clean_text(row["venue"]),
                _as_clean_text(row["time"]),
                code,
                _as_clean_text(row["batch"]),
                _as_clean_text(row["subject"]),
                _as_clean_text(row["teacher"]),
            )
        )
    return rows


def _extract_theory_exam_rows(
    workbook: pd.ExcelFile,
    preferred_sheet_name: str,
) -> list[tuple[str, str, str, str, str]]:
    if preferred_sheet_name in workbook.sheet_names:
        df = _rename_columns(pd.read_excel(workbook, sheet_name=preferred_sheet_name))
    else:
        if not workbook.sheet_names:
            raise HTTPException(status_code=400, detail="Workbook has no sheets.")
        df = _rename_columns(pd.read_excel(workbook, sheet_name=workbook.sheet_names[0]))

    df = _apply_aliases(
        df,
        {
            "course_code": {"code", "coursecode"},
            "course_name": {"course_title", "subject", "title"},
            "exam_date": {"date", "day"},
            "start_time": {"time", "start", "from_time"},
            "end_time": {"end", "to_time", "finish_time"},
        },
    )
    _require_columns(
        df,
        {"course_code", "course_name", "exam_date", "start_time", "end_time"},
        "Theory Exams sheet",
    )

    rows: list[tuple[str, str, str, str, str]] = []
    for _, row in df.iterrows():
        course_code = _normalize_code(row["course_code"])
        if not course_code:
            continue
        rows.append(
            (
                course_code,
                _as_clean_text(row["course_name"]),
                _as_clean_text(row["exam_date"]),
                _as_clean_text(row["start_time"]),
                _as_clean_text(row["end_time"]),
            )
        )
    return rows


def _validate_roll(rollnumber: str) -> str:
    roll = _normalize_roll(rollnumber)
    if not roll:
        raise HTTPException(status_code=400, detail="Invalid roll number.")
    return roll


@app.get("/", response_class=HTMLResponse)
def admin_panel() -> str:
    return ADMIN_HTML


@app.post("/api/v1/admin/upload/timetable")
async def upload_timetable(file: UploadFile = File(...)) -> JSONResponse:
    workbook = await _read_workbook(file)
    course_rows, timetable_rows, student_rows = _extract_timetable_and_students(workbook)

    with get_connection() as conn:
        conn.execute("DELETE FROM courses")
        conn.execute("DELETE FROM timetable")
        conn.execute("DELETE FROM students")
        conn.executemany(
            """
            INSERT OR REPLACE INTO courses (code, batch, subject, teacher)
            VALUES (?, ?, ?, ?)
            """,
            course_rows,
        )
        conn.executemany(
            """
            INSERT OR REPLACE INTO timetable (day, location, slot, code)
            VALUES (?, ?, ?, ?)
            """,
            timetable_rows,
        )
        conn.executemany(
            """
            INSERT OR REPLACE INTO students (rollnumber, code)
            VALUES (?, ?)
            """,
            student_rows,
        )
        conn.commit()

    return JSONResponse(
        {
            "status": "ok",
            "message": "Timetable and students uploaded successfully.",
            "inserted": {"courses": len(course_rows), "timetable": len(timetable_rows), "students": len(student_rows)},
        }
    )


@app.post("/api/v1/admin/upload/lab-exams")
async def upload_lab_exams(file: UploadFile = File(...)) -> JSONResponse:
    workbook = await _read_workbook(file)
    rows = _extract_exam_rows(workbook, SHEET_LAB_EXAMS)

    with get_connection() as conn:
        conn.execute("DELETE FROM lab_exams")
        conn.executemany(
            """
            INSERT OR REPLACE INTO lab_exams (date, venue, time, code, batch, subject, teacher)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        conn.commit()

    return JSONResponse(
        {
            "status": "ok",
            "message": "Lab exams uploaded successfully.",
            "inserted": {"lab_exams": len(rows)},
        }
    )


@app.post("/api/v1/admin/upload/theory-exams")
async def upload_theory_exams(file: UploadFile = File(...)) -> JSONResponse:
    workbook = await _read_workbook(file)
    rows = _extract_theory_exam_rows(workbook, SHEET_THEORY_EXAMS)

    with get_connection() as conn:
        conn.execute("DELETE FROM theory_exams")
        conn.executemany(
            """
            INSERT OR REPLACE INTO theory_exams (
                course_code,
                course_name,
                exam_date,
                start_time,
                end_time
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            rows,
        )
        conn.commit()

    return JSONResponse(
        {
            "status": "ok",
            "message": "Theory exams uploaded successfully.",
            "inserted": {"theory_exams": len(rows)},
        }
    )


@app.post("/api/v1/admin/upload")
async def legacy_upload(file: UploadFile = File(...)) -> JSONResponse:
    """Backward-compatible alias for old one-click upload."""
    return await upload_timetable(file)


@app.get("/api/v1/student/timetable/{rollnumber}")
def get_student_timetable(rollnumber: str) -> JSONResponse:
    roll = _validate_roll(rollnumber)
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT DISTINCT
                t.day AS day,
                t.location AS location,
                t.slot AS slot,
                c.code AS course_code,
                c.subject AS subject,
                c.teacher AS teacher,
                c.batch AS batch
            FROM students s
            INNER JOIN courses c ON s.code = c.code
            INNER JOIN timetable t ON t.code = c.code
            WHERE s.rollnumber = ?
            """,
            (roll,),
        ).fetchall()

    schedule: list[dict[str, Any]] = []
    for row in rows:
        slot = int(row["slot"])
        if slot not in SLOT_TO_LABEL:
            continue
        schedule.append(
            {
                "day": row["day"],
                "location": row["location"],
                "time_slot": SLOT_TO_LABEL[slot],
                "course_code": row["course_code"],
                "subject": row["subject"],
                "teacher": row["teacher"],
                "batch": row["batch"],
            }
        )
    schedule.sort(
        key=lambda item: (
            DAY_ORDER.get(str(item["day"]), 99),
            LABEL_TO_SLOT.get(str(item["time_slot"]), 99),
        )
    )
    return JSONResponse({"rollnumber": roll, "schedule": schedule})


@app.get("/api/v1/student/lab-exams/{rollnumber}")
def get_student_lab_exams(rollnumber: str) -> JSONResponse:
    roll = _validate_roll(rollnumber)
    with get_connection() as conn:
        student_codes = conn.execute(
            """
            SELECT DISTINCT s.code AS student_code
            FROM students s
            WHERE s.rollnumber = ?
            """,
            (roll,),
        ).fetchall()

        rows = conn.execute(
            """
            SELECT
                e.date AS date,
                e.venue AS venue,
                e.time AS time,
                e.code AS course_code,
                e.batch AS batch,
                e.subject AS subject,
                e.teacher AS teacher
            FROM lab_exams e
            ORDER BY e.date, e.time, e.code, e.batch
            """,
        ).fetchall()

    enrolled_lab_pairs: set[tuple[str, str]] = set()
    for row in student_codes:
        raw = _normalize_code(row["student_code"])
        base_code, section = _split_code_section(raw)
        if _is_lab_code(base_code) and section:
            enrolled_lab_pairs.add((base_code, section))

    payload: list[dict[str, str | bool]] = []
    seen: set[tuple[str, str, str, str]] = set()
    for row in rows:
        exam_code = _normalize_code(row["course_code"]).upper()
        exam_batch = _as_clean_text(row["batch"]).upper()
        if (exam_code, exam_batch) not in enrolled_lab_pairs:
            continue
        dedup_key = (
            _as_clean_text(row["date"]),
            _as_clean_text(row["time"]),
            exam_code,
            exam_batch,
        )
        if dedup_key in seen:
            continue
        seen.add(dedup_key)
        payload.append(
            {
                "date": row["date"],
                "venue": row["venue"],
                "time": row["time"],
                "extended_time": "", # CLEANED
                "course_code": row["course_code"],
                "batch": row["batch"],
                "subject": row["subject"],
                "teacher": row["teacher"],
                "is_lab": True,
                "code_with_section": f"{row['course_code']},{row['batch']}",
            }
        )
    return JSONResponse({"rollnumber": roll, "lab_exams": payload})


@app.get("/api/v1/student/theory-exams/{rollnumber}")
def get_student_theory_exams(rollnumber: str) -> JSONResponse:
    roll = _validate_roll(rollnumber)
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT DISTINCT
                th.course_code AS course_code,
                th.course_name AS course_name,
                th.exam_date AS exam_date,
                th.start_time AS start_time,
                th.end_time AS end_time
            FROM students s
            INNER JOIN theory_exams th ON th.course_code = (
                CASE
                    WHEN INSTR(s.code, ',') > 0
                    THEN SUBSTR(s.code, 1, INSTR(s.code, ',') - 1)
                    ELSE s.code
                END
            )
            WHERE s.rollnumber = ?
            ORDER BY th.exam_date, th.start_time, th.course_code
            """,
            (roll,),
        ).fetchall()

    payload = [
        {
            "course_code": row["course_code"],
            "course_name": row["course_name"],
            "exam_date": row["exam_date"],
            "start_time": row["start_time"],
            "end_time": row["end_time"],
        }
        for row in rows
    ]
    return JSONResponse({"rollnumber": roll, "theory_exams": payload})


@app.get("/api/v1/timetable/{rollnumber}")
def legacy_timetable_route(rollnumber: str) -> JSONResponse:
    """Backward-compatible alias for older clients."""
    return get_student_timetable(rollnumber)


ADMIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>FAST-NUCES Timetable Admin</title>
  <style>
    :root {
      --bg: #f7f8fb;
      --card: #ffffff;
      --brand: #0d47a1;
      --text: #101828;
      --muted: #667085;
      --border: #e4e7ec;
      --ok-bg: #ecfdf3;
      --ok-bd: #abefc6;
      --ok-fg: #067647;
      --err-bg: #fef3f2;
      --err-bd: #fecdca;
      --err-fg: #b42318;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; background: var(--bg); color: var(--text); }
    header { background: var(--brand); color: white; padding: 20px; }
    header h1 { margin: 0; font-size: 1.35rem; }
    header p { margin: 8px 0 0; opacity: 0.95; }
    main { max-width: 1100px; margin: 20px auto; padding: 0 16px; display: grid; gap: 16px; }
    .cards-3 { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
    h2 { margin: 0 0 8px; font-size: 1.05rem; color: var(--brand); }
    p.hint { margin: 0 0 12px; color: var(--muted); font-size: 0.92rem; }
    label { display: block; margin: 8px 0 6px; font-weight: 600; font-size: 0.92rem; }
    input[type=file], input[type=text] {
      width: 100%;
      padding: 10px;
      border-radius: 10px;
      border: 1px solid #d0d5dd;
      background: #fff;
      font-size: 0.95rem;
    }
    button {
      margin-top: 10px;
      border: none;
      border-radius: 10px;
      padding: 10px 14px;
      cursor: pointer;
      font-weight: 600;
    }
    .btn-primary { background: var(--brand); color: #fff; }
    .btn-outline { background: #fff; border: 1px solid var(--brand); color: var(--brand); margin-right: 8px; }
    .status {
      margin-top: 10px;
      border-radius: 10px;
      padding: 10px 12px;
      border: 1px solid transparent;
      font-size: 0.92rem;
      white-space: pre-wrap;
    }
    .status.ok { background: var(--ok-bg); border-color: var(--ok-bd); color: var(--ok-fg); }
    .status.err { background: var(--err-bg); border-color: var(--err-bd); color: var(--err-fg); }
    .status.neutral { background: #f8f9fc; border-color: var(--border); color: #475467; }
    .table-wrap { overflow-x: auto; margin-top: 10px; }
    table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
    th, td { border: 1px solid var(--border); padding: 8px 10px; text-align: left; vertical-align: top; }
    th { background: #f9fafb; }
    ul.readable { margin: 10px 0 0 18px; padding: 0; }
    ul.readable li { margin: 6px 0; }
  </style>
</head>
<body>
  <header>
    <h1>FAST-NUCES Admin Dashboard</h1>
    <p>Separate ingestion for routine timetable, lab exams, and theory exams.</p>
  </header>

  <main>
    <section class="cards-3">
      <article class="card">
        <h2>Upload Timetable & Students</h2>
        <p class="hint">Expected sheets: <b>Timetable Timing</b> and <b>Students</b>.</p>
        <form id="uploadTimetableForm">
          <label for="timetableFile">Workbook (.xlsx/.xlsm)</label>
          <input id="timetableFile" name="file" type="file" accept=".xlsx,.xlsm" required />
          <button class="btn-primary" type="submit">Upload Timetable Data</button>
        </form>
        <div id="timetableUploadStatus" class="status neutral">No upload yet.</div>
      </article>

      <article class="card">
        <h2>Upload Lab Exams</h2>
        <p class="hint">Upload processed lab datesheet Excel file.</p>
        <form id="uploadLabForm">
          <label for="labFile">Workbook (.xlsx/.xlsm)</label>
          <input id="labFile" name="file" type="file" accept=".xlsx,.xlsm" required />
          <button class="btn-primary" type="submit">Upload Lab Exams</button>
        </form>
        <div id="labUploadStatus" class="status neutral">No upload yet.</div>
      </article>

      <article class="card">
        <h2>Upload Theory Exams</h2>
        <p class="hint">Upload parsed theory datesheet Excel file.</p>
        <form id="uploadTheoryForm">
          <label for="theoryFile">Workbook (.xlsx/.xlsm)</label>
          <input id="theoryFile" name="file" type="file" accept=".xlsx,.xlsm" required />
          <button class="btn-primary" type="submit">Upload Theory Exams</button>
        </form>
        <div id="theoryUploadStatus" class="status neutral">No upload yet.</div>
      </article>
    </section>

    <section class="card">
      <h2>Test Student APIs</h2>
      <p class="hint">Human-readable output for timetable/lab/theory data by roll number.</p>
      <label for="roll">Roll number</label>
      <input id="roll" type="text" placeholder="20P-0087" />
      <div style="margin-top: 10px;">
        <button id="btnTimetable" class="btn-outline" type="button">Show Timetable</button>
        <button id="btnLab" class="btn-outline" type="button">Show Lab Exams</button>
        <button id="btnTheory" class="btn-outline" type="button">Show Theory Exams</button>
      </div>
      <div id="readableOut" class="status neutral">Run a test query to view formatted results.</div>
    </section>
  </main>

  <script>
    function esc(v) {
      return String(v ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function setStatus(el, kind, text) {
      el.className = "status " + kind;
      el.textContent = text;
    }

    async function uploadForm(formId, endpoint, statusId) {
      const form = document.getElementById(formId);
      const status = document.getElementById(statusId);
      form.addEventListener("submit", async (e) => {
        e.preventDefault();
        setStatus(status, "neutral", "Uploading...");
        try {
          const fd = new FormData(form);
          const res = await fetch(endpoint, { method: "POST", body: fd });
          const data = await res.json();
          if (!res.ok) {
            throw new Error(data.detail ? JSON.stringify(data.detail) : JSON.stringify(data));
          }
          const inserted = data.inserted ? Object.entries(data.inserted).map(([k, v]) => `${k}: ${v}`).join(", ") : "";
          setStatus(status, "ok", `${data.message || "Upload completed."}${inserted ? "\\n" + inserted : ""}`);
        } catch (err) {
          setStatus(status, "err", String(err));
        }
      });
    }

    function renderTimetable(data) {
      const rows = data.schedule || [];
      if (!rows.length) {
        return `<strong>Roll ${esc(data.rollnumber)}</strong><br>No timetable entries found.`;
      }
      const sentenceList = rows
        .map((r) => `<li>${esc(r.day)} - ${esc(r.time_slot)}: <b>${esc(r.course_code)}</b> (${esc(r.subject)}) by ${esc(r.teacher)} in ${esc(r.location)}</li>`)
        .join("");
      const tableRows = rows
        .map(
          (r) => `<tr>
            <td>${esc(r.day)}</td>
            <td>${esc(r.time_slot)}</td>
            <td>${esc(r.course_code)}</td>
            <td>${esc(r.subject)}</td>
            <td>${esc(r.teacher)}</td>
            <td>${esc(r.location)}</td>
          </tr>`
        )
        .join("");
      return `
        <strong>Roll ${esc(data.rollnumber)} — Weekly Timetable</strong>
        <ul class="readable">${sentenceList}</ul>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Day</th><th>Time</th><th>Course Code</th><th>Subject</th><th>Teacher</th><th>Location</th></tr></thead>
            <tbody>${tableRows}</tbody>
          </table>
        </div>
      `;
    }

    function renderExamSet(data, key, title) {
      const rows = data[key] || [];
      if (!rows.length) {
        return `<strong>Roll ${esc(data.rollnumber)}</strong><br>No ${esc(title)} records found.`;
      }
      const tableRows = rows
        .map(
          (r) => `<tr>
            <td>${esc(r.date)}</td>
            <td>${esc(r.time)}</td>
            <td>${esc(r.course_code)}</td>
            <td>${esc(r.subject)}</td>
            <td>${esc(r.teacher)}</td>
            <td>${esc(r.batch)}</td>
            <td>${esc(r.venue)}</td>
          </tr>`
        )
        .join("");
      return `
        <strong>Roll ${esc(data.rollnumber)} — ${esc(title)}</strong>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Date</th><th>Time</th><th>Code</th><th>Subject</th><th>Teacher</th><th>Batch</th><th>Venue</th></tr>
            </thead>
            <tbody>${tableRows}</tbody>
          </table>
        </div>
      `;
    }

    function renderTheorySet(data) {
      const rows = data.theory_exams || [];
      if (!rows.length) {
        return `<strong>Roll ${esc(data.rollnumber)}</strong><br>No Theory Exams records found.`;
      }
      const tableRows = rows
        .map(
          (r) => `<tr>
            <td>${esc(r.course_code)}</td>
            <td>${esc(r.course_name)}</td>
            <td>${esc(r.exam_date)}</td>
            <td>${esc(r.start_time)}</td>
            <td>${esc(r.end_time)}</td>
          </tr>`
        )
        .join("");
      return `
        <strong>Roll ${esc(data.rollnumber)} — Theory Exams</strong>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Course Code</th><th>Course Name</th><th>Exam Date</th><th>Start Time</th><th>End Time</th></tr>
            </thead>
            <tbody>${tableRows}</tbody>
          </table>
        </div>
      `;
    }

    async function hit(endpoint, mode) {
      const out = document.getElementById("readableOut");
      const rollInput = document.getElementById("roll");
      const roll = encodeURIComponent((rollInput.value || "").trim());
      if (!roll) {
        setStatus(out, "err", "Enter a roll number first.");
        return;
      }
      setStatus(out, "neutral", "Loading...");
      try {
        const res = await fetch(endpoint + roll);
        const data = await res.json();
        if (!res.ok) {
          throw new Error(data.detail ? JSON.stringify(data.detail) : JSON.stringify(data));
        }
        out.className = "status neutral";
        if (mode === "timetable") {
          out.innerHTML = renderTimetable(data);
        } else if (mode === "lab") {
          out.innerHTML = renderExamSet(data, "lab_exams", "Lab Exams");
        } else {
          out.innerHTML = renderTheorySet(data);
        }
      } catch (err) {
        setStatus(out, "err", String(err));
      }
    }

    uploadForm("uploadTimetableForm", "/api/v1/admin/upload/timetable", "timetableUploadStatus");
    uploadForm("uploadLabForm", "/api/v1/admin/upload/lab-exams", "labUploadStatus");
    uploadForm("uploadTheoryForm", "/api/v1/admin/upload/theory-exams", "theoryUploadStatus");

    document.getElementById("btnTimetable").addEventListener("click", () => hit("/api/v1/student/timetable/", "timetable"));
    document.getElementById("btnLab").addEventListener("click", () => hit("/api/v1/student/lab-exams/", "lab"));
    document.getElementById("btnTheory").addEventListener("click", () => hit("/api/v1/student/theory-exams/", "theory"));
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
