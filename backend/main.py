"""
FAST-NUCES Phase 1 timetable API + admin upload panel.
Python 3.10+ | FastAPI | pandas | SQLite
"""

from __future__ import annotations

import io
import re
import sqlite3
from collections import defaultdict
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

LABEL_TO_SLOT: dict[str, int] = {v: k for k, v in SLOT_TO_LABEL.items()}

DAY_ORDER: dict[str, int] = {
    "Monday": 0,
    "Tuesday": 1,
    "Wednesday": 2,
    "Thursday": 3,
    "Friday": 4,
    "Saturday": 5,
    "Sunday": 6,
}

SHEET_COURSES = "Courses"
SHEET_TIMETABLE = "Timetable Timing"
SHEET_STUDENTS = "Students"

@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(
    title="FAST-NUCES Timetable API",
    version="1.0.0",
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
    conn.execute("PRAGMA foreign_keys = ON")
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

            CREATE TABLE IF NOT EXISTS students (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                rollnumber TEXT NOT NULL,
                code TEXT NOT NULL
            );
            """
        )



def _normalize_column(name: Any) -> str:
    s = str(name).strip().lower()
    s = re.sub(r"\s+", "_", s)
    return s


def _rename_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out.columns = [_normalize_column(c) for c in out.columns]
    return out


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
        s = int(value)
        if 0 <= s <= 6:
            return s
        raise ValueError(f"slot out of range: {s}")
    text = str(value).strip()
    if text in LABEL_TO_SLOT:
        return LABEL_TO_SLOT[text]
    # tolerate minor spacing/case differences
    compact = re.sub(r"\s+", " ", text)
    for label, idx in LABEL_TO_SLOT.items():
        if compact.lower() == label.lower():
            return idx
    raise ValueError(f"unrecognized slot: {text!r}")


def _normalize_roll(value: Any) -> str:
    if pd.isna(value):
        return ""
    return str(value).strip().upper()


def _normalize_code(value: Any) -> str:
    if pd.isna(value):
        return ""
    return str(value).strip()


def _excel_data_row_number(zero_based_position: int, *, header_rows: int = 1) -> int:
    """1-based Excel row for a data row (assumes `header_rows` title rows above data)."""
    return header_rows + 1 + zero_based_position


def _raise_course_duplicate_detail(
    conflicts: dict[tuple[str, str], list[int]],
) -> None:
    locations: list[dict[str, Any]] = []
    for (code, batch) in sorted(conflicts.keys(), key=lambda t: (t[0].lower(), t[1].lower())):
        rows = sorted(set(conflicts[(code, batch)]))
        locations.append(
            {
                "sheet": SHEET_COURSES,
                "duplicate_key": {"code": code, "batch": batch},
                "excel_rows": rows,
                "hint": "PRIMARY KEY is (code, batch); remove or merge duplicate rows.",
            }
        )
    raise HTTPException(
        status_code=400,
        detail={
            "error": "Unique constraint would fail on courses (code, batch)",
            "constraint": "courses.PRIMARY_KEY (code, batch)",
            "locations": locations,
        },
    )


def _insert_courses_tracked(
    conn: sqlite3.Connection,
    course_rows: list[tuple[str, str, str, str]],
    source_excel_rows: list[int],
) -> None:
    if len(course_rows) != len(source_excel_rows):
        raise RuntimeError("course_rows and source_excel_rows length mismatch")
    sql = "INSERT INTO courses (code, batch, subject, teacher) VALUES (?, ?, ?, ?)"
    for idx, (row, excel_row) in enumerate(zip(course_rows, source_excel_rows, strict=True)):
        try:
            conn.execute(sql, row)
        except sqlite3.IntegrityError as exc:
            code, batch, subject, teacher = row
            raise HTTPException(
                status_code=400,
                detail={
                    "error": "Database constraint failed while inserting courses",
                    "constraint": str(exc),
                    "operation": "INSERT INTO courses",
                    "sheet": SHEET_COURSES,
                    "excel_row": excel_row,
                    "row_index_in_import_list": idx + 1,
                    "values": {
                        "code": code,
                        "batch": batch,
                        "subject": subject,
                        "teacher": teacher,
                    },
                    "hint": "Duplicate (code, batch), or row conflicts with an earlier insert.",
                },
            ) from exc


def _insert_timetable_tracked(
    conn: sqlite3.Connection,
    timetable_rows: list[tuple[str, str, int, str]],
    source_excel_rows: list[int],
) -> None:
    if len(timetable_rows) != len(source_excel_rows):
        raise RuntimeError("timetable_rows and source_excel_rows length mismatch")
    sql = "INSERT INTO timetable (day, location, slot, code) VALUES (?, ?, ?, ?)"
    for idx, (row, excel_row) in enumerate(zip(timetable_rows, source_excel_rows, strict=True)):
        try:
            conn.execute(sql, row)
        except sqlite3.IntegrityError as exc:
            day, location, slot, code = row
            raise HTTPException(
                status_code=400,
                detail={
                    "error": "Database constraint failed while inserting timetable",
                    "constraint": str(exc),
                    "operation": "INSERT INTO timetable",
                    "sheet": SHEET_TIMETABLE,
                    "excel_row": excel_row,
                    "row_index_in_import_list": idx + 1,
                    "values": {
                        "day": day,
                        "location": location,
                        "slot": slot,
                        "code": code,
                    },
                },
            ) from exc


def _insert_students_tracked(
    conn: sqlite3.Connection,
    student_rows: list[tuple[str, str]],
    source_excel_rows: list[int],
) -> None:
    if len(student_rows) != len(source_excel_rows):
        raise RuntimeError("student_rows and source_excel_rows length mismatch")
    sql = "INSERT INTO students (rollnumber, code) VALUES (?, ?)"
    for idx, (row, excel_row) in enumerate(zip(student_rows, source_excel_rows, strict=True)):
        try:
            conn.execute(sql, row)
        except sqlite3.IntegrityError as exc:
            roll, code = row
            raise HTTPException(
                status_code=400,
                detail={
                    "error": "Database constraint failed while inserting students",
                    "constraint": str(exc),
                    "operation": "INSERT INTO students",
                    "sheet": SHEET_STUDENTS,
                    "excel_row": excel_row,
                    "row_index_in_import_list": idx + 1,
                    "values": {"rollnumber": roll, "code": code},
                },
            ) from exc


def clear_all_tables(conn: sqlite3.Connection) -> None:
    conn.execute("DELETE FROM timetable")
    conn.execute("DELETE FROM students")
    conn.execute("DELETE FROM courses")


@app.get("/", response_class=HTMLResponse)
def admin_panel() -> str:
    return ADMIN_HTML


@app.post("/api/v1/admin/upload")
async def admin_upload(file: UploadFile = File(...)) -> JSONResponse:
    if not file.filename or not file.filename.lower().endswith((".xlsx", ".xlsm")):
        raise HTTPException(status_code=400, detail="Upload a .xlsx (or .xlsm) workbook.")

    raw = await file.read()
    try:
        workbook = pd.ExcelFile(io.BytesIO(raw))
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"Could not read Excel: {exc}") from exc

    for name in (SHEET_COURSES, SHEET_TIMETABLE, SHEET_STUDENTS):
        if name not in workbook.sheet_names:
            raise HTTPException(
                status_code=400,
                detail=f"Missing sheet {name!r}. Found: {workbook.sheet_names}",
            )

    courses = _rename_columns(pd.read_excel(workbook, sheet_name=SHEET_COURSES))
    timetable = _rename_columns(pd.read_excel(workbook, sheet_name=SHEET_TIMETABLE))
    students = _rename_columns(pd.read_excel(workbook, sheet_name=SHEET_STUDENTS))

    # Accept common header aliases
    col_map_courses = {
        "code": {"code", "course_code", "coursecode"},
        "batch": {"batch", "section"},
        "subject": {"subject", "course_title", "title"},
        "teacher": {"teacher", "instructor", "faculty"},
    }
    for target, aliases in col_map_courses.items():
        if target not in courses.columns:
            for a in aliases:
                if a in courses.columns:
                    courses = courses.rename(columns={a: target})
                    break
    _require_columns(courses, {"code", "batch", "subject", "teacher"}, "Courses sheet")

    col_map_tt = {
        "day": {"day", "weekday"},
        "location": {"location", "room", "venue"},
        "slot": {"slot", "time_slot", "timeslot", "period"},
        "code": {"code", "course_code", "coursecode"},
    }
    for target, aliases in col_map_tt.items():
        if target not in timetable.columns:
            for a in aliases:
                if a in timetable.columns:
                    timetable = timetable.rename(columns={a: target})
                    break
    _require_columns(timetable, {"day", "location", "slot", "code"}, "Timetable sheet")

    col_map_st = {
        "rollnumber": {"rollnumber", "roll_number", "roll_no", "rollno", "roll"},
        "code": {"code", "course_code", "coursecode"},
    }
    for target, aliases in col_map_st.items():
        if target not in students.columns:
            for a in aliases:
                if a in students.columns:
                    students = students.rename(columns={a: target})
                    break
    _require_columns(students, {"rollnumber", "code"}, "Students sheet")

    course_rows: list[tuple[str, str, str, str]] = []
    course_excel_rows: list[int] = []
    key_to_excel_rows: dict[tuple[str, str], list[int]] = defaultdict(list)
    for pos, (_, row) in enumerate(courses.iterrows()):
        code = _normalize_code(row["code"])
        if not code:
            continue
        batch = str(row["batch"]).strip()
        excel_row = _excel_data_row_number(pos)
        tup = (
            code,
            batch,
            str(row["subject"]).strip(),
            str(row["teacher"]).strip(),
        )
        course_rows.append(tup)
        course_excel_rows.append(excel_row)
        key_to_excel_rows[(code, batch)].append(excel_row)

    duplicate_keys = {k: v for k, v in key_to_excel_rows.items() if len(v) > 1}
    if duplicate_keys:
        _raise_course_duplicate_detail(duplicate_keys)

    timetable_rows: list[tuple[str, str, int, str]] = []
    timetable_excel_rows: list[int] = []
    for pos, (_, row) in enumerate(timetable.iterrows()):
        code = _normalize_code(row["code"])
        if not code:
            continue
        try:
            slot = _coerce_slot(row["slot"])
        except ValueError as exc:
            excel_row = _excel_data_row_number(pos)
            raise HTTPException(
                status_code=400,
                detail={
                    "error": "Invalid slot value in Timetable sheet",
                    "sheet": SHEET_TIMETABLE,
                    "excel_row": excel_row,
                    "code": code,
                    "message": str(exc),
                },
            ) from exc
        day = str(row["day"]).strip()
        location = str(row["location"]).strip()
        timetable_rows.append((day, location, slot, code))
        timetable_excel_rows.append(_excel_data_row_number(pos))

    student_rows: list[tuple[str, str]] = []
    student_excel_rows: list[int] = []
    for pos, (_, row) in enumerate(students.iterrows()):
        roll = _normalize_roll(row["rollnumber"])
        code = _normalize_code(row["code"])
        if not roll or not code:
            continue
        student_rows.append((roll, code))
        student_excel_rows.append(_excel_data_row_number(pos))

    try:
        with get_connection() as conn:
            clear_all_tables(conn)
            _insert_courses_tracked(conn, course_rows, course_excel_rows)
            _insert_timetable_tracked(conn, timetable_rows, timetable_excel_rows)
            _insert_students_tracked(conn, student_rows, student_excel_rows)
            conn.commit()
    except HTTPException:
        raise
    except sqlite3.IntegrityError as exc:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "Database constraint failed (unhandled)",
                "sqlite_message": str(exc),
                "hint": "Check course codes and keys across sheets; see server logs.",
            },
        ) from exc

    return JSONResponse(
        {
            "status": "ok",
            "inserted": {
                "courses": len(course_rows),
                "timetable": len(timetable_rows),
                "students": len(student_rows),
            },
        }
    )


@app.get("/api/v1/timetable/{rollnumber}")
def get_timetable(rollnumber: str) -> JSONResponse:
    roll = _normalize_roll(rollnumber)
    if not roll:
        raise HTTPException(status_code=400, detail="Invalid roll number.")

    query = """
        SELECT t.day AS day,
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
    """

    with get_connection() as conn:
        cur = conn.execute(query, (roll,))
        rows = cur.fetchall()

    schedule: list[dict[str, Any]] = []
    for r in rows:
        slot = int(r["slot"])
        if slot not in SLOT_TO_LABEL:
            continue
        schedule.append(
            {
                "day": r["day"],
                "location": r["location"],
                "time_slot": SLOT_TO_LABEL[slot],
                "course_code": r["course_code"],
                "subject": r["subject"],
                "teacher": r["teacher"],
                "batch": r["batch"],
            }
        )

    slot_rank = {label: slot for slot, label in SLOT_TO_LABEL.items()}

    def sort_key(item: dict[str, Any]) -> tuple[int, int]:
        day_rank = DAY_ORDER.get(str(item["day"]), 99)
        slot_idx = slot_rank.get(str(item["time_slot"]), 99)
        return day_rank, slot_idx

    schedule.sort(key=sort_key)

    payload = {"rollnumber": roll, "schedule": schedule}
    return JSONResponse(payload)


ADMIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>FAST-NUCES Timetable Admin</title>
  <style>
    :root {
      --bg: #fafafa;
      --brand: #0d47a1;
      --accent: #ffc107;
      --card: #ffffff;
      --text: #1a1a1a;
      --muted: #5f6368;
      --border: #e0e0e0;
      --radius: 14px;
      --shadow: 0 8px 30px rgba(13, 71, 161, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    header {
      background: linear-gradient(135deg, var(--brand), #1565c0);
      color: #fff;
      padding: 28px 20px 36px;
    }
    header h1 { margin: 0 0 8px; font-size: 1.6rem; letter-spacing: 0.02em; }
    header p { margin: 0; opacity: 0.92; max-width: 52rem; }
    main {
      max-width: 960px;
      margin: -24px auto 48px;
      padding: 0 18px;
      display: grid;
      gap: 18px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 22px;
      box-shadow: var(--shadow);
    }
    .card h2 {
      margin: 0 0 12px;
      font-size: 1.1rem;
      color: var(--brand);
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .badge {
      display: inline-block;
      background: var(--accent);
      color: #1a1a1a;
      font-size: 0.72rem;
      font-weight: 700;
      padding: 3px 8px;
      border-radius: 999px;
      letter-spacing: 0.04em;
    }
    label { display: block; font-weight: 600; margin: 10px 0 6px; color: var(--muted); font-size: 0.9rem; }
    input[type="file"], input[type="text"] {
      width: 100%;
      padding: 12px 12px;
      border-radius: 10px;
      border: 1px solid var(--border);
      background: #fff;
      font-size: 0.95rem;
    }
    button, .btn {
      margin-top: 14px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      padding: 12px 18px;
      border: none;
      border-radius: 10px;
      font-weight: 600;
      cursor: pointer;
      font-size: 0.95rem;
      transition: transform 0.08s ease, box-shadow 0.12s ease;
    }
    button.primary, .btn.primary {
      background: var(--brand);
      color: #fff;
      box-shadow: 0 6px 18px rgba(13, 71, 161, 0.25);
    }
    button.secondary {
      background: #fff;
      color: var(--brand);
      border: 2px solid var(--brand);
    }
    button:hover { transform: translateY(-1px); }
    button:active { transform: translateY(0); }
    pre {
      margin: 12px 0 0;
      padding: 14px;
      background: #0d1117;
      color: #e6edf3;
      border-radius: 10px;
      overflow: auto;
      max-height: 360px;
      font-size: 0.82rem;
    }
    .grid-2 {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: 14px;
    }
    .hint { font-size: 0.88rem; color: var(--muted); margin-top: 8px; }
    footer { text-align: center; color: var(--muted); font-size: 0.85rem; padding: 24px; }
    a { color: var(--brand); }
  </style>
</head>
<body>
  <header>
    <h1>FAST-NUCES Timetable Admin</h1>
    <p>Upload a workbook with sheets <strong>Courses</strong>, <strong>Timetable Timing</strong>, and <strong>Students</strong>.
    The SQLite database is replaced on each successful import.</p>
  </header>
  <main>
    <section class="card">
      <h2><span class="badge">IMPORT</span> Excel upload</h2>
      <form id="uploadForm" action="/api/v1/admin/upload" method="post" enctype="multipart/form-data">
        <label for="file">Workbook (.xlsx)</label>
        <input id="file" name="file" type="file" accept=".xlsx,.xlsm" required />
        <button class="primary" type="submit">Upload &amp; rebuild database</button>
        <p class="hint">Expected columns: Courses (code, batch, subject, teacher) · Timetable (day, location, slot, code) · Students (rollnumber, code). Slot may be 0–6 or a time range label.</p>
      </form>
      <pre id="uploadResult" hidden></pre>
    </section>

    <section class="card">
      <h2><span class="badge">TEST</span> Fetch timetable JSON</h2>
      <label for="roll">Roll number</label>
      <input id="roll" type="text" placeholder="20P-0087" autocomplete="off" />
      <button class="secondary" type="button" id="fetchBtn">GET /api/v1/timetable/{roll}</button>
      <pre id="jsonOut">// Response will appear here</pre>
    </section>

    <section class="card grid-2">
      <div>
        <h2>API</h2>
        <p class="hint" style="margin:0">OpenAPI docs: <a href="/docs" target="_blank" rel="noopener">/docs</a></p>
      </div>
      <div>
        <h2>Health</h2>
        <p class="hint" style="margin:0">Server root serves this panel. Database file: <code>timetable.db</code> next to <code>main.py</code>.</p>
      </div>
    </section>
  </main>
  <footer>FAST-NUCES Phase 1 · FastAPI + pandas + SQLite</footer>
  <script>
    const uploadForm = document.getElementById('uploadForm');
    const uploadResult = document.getElementById('uploadResult');
    uploadForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      uploadResult.hidden = true;
      const fd = new FormData(uploadForm);
      try {
        const res = await fetch('/api/v1/admin/upload', { method: 'POST', body: fd });
        const text = await res.text();
        let body;
        try { body = JSON.parse(text); } catch { body = text; }
        uploadResult.textContent = JSON.stringify(body, null, 2);
        uploadResult.hidden = false;
      } catch (err) {
        uploadResult.textContent = String(err);
        uploadResult.hidden = false;
      }
    });

    const rollInput = document.getElementById('roll');
    const jsonOut = document.getElementById('jsonOut');
    document.getElementById('fetchBtn').addEventListener('click', async () => {
      const roll = encodeURIComponent((rollInput.value || '').trim());
      if (!roll) {
        jsonOut.textContent = 'Enter a roll number.';
        return;
      }
      jsonOut.textContent = 'Loading...';
      try {
        const res = await fetch('/api/v1/timetable/' + roll);
        const data = await res.json();
        jsonOut.textContent = JSON.stringify(data, null, 2);
      } catch (err) {
        jsonOut.textContent = String(err);
      }
    });
  </script>
</body>
</html>
"""
