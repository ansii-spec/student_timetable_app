# FAST-NUCES Timetable — Phase 1 implementation log

## Scope

- **Backend:** FastAPI + pandas + SQLite admin upload and student timetable JSON API.
- **Frontend:** Single-file Flutter shell (`lib/main.dart`) with Google Sign-In (existing domain), three-tab bottom navigation, timetable consumption via `http`, and FAST brand colors.

## 2026-05-03 — Delivered artifacts

| Artifact | Path |
|----------|------|
| API & admin UI | `backend/main.py` |
| Python dependencies | `backend/requirements.txt` |
| Flutter entry + UI | `student_timetable_app-main/lib/main.dart` |
| Flutter deps | `student_timetable_app-main/pubspec.yaml` (`http` added) |

## Backend decisions

- **SQLite file:** `backend/timetable.db` (created beside `main.py`).
- **Upload behavior:** `POST /api/v1/admin/upload` deletes all rows in `timetable`, `students`, then `courses` (FK-safe order), then bulk-inserts from Excel.
- **Workbook sheets (exact names):** `Courses`, `Timetable Timing`, `Students`.
- **Column flexibility:** Normalized headers; common aliases accepted (e.g. `course_code` → `code`, `roll_no` → `rollnumber`). Slot accepts integers `0–6` or canonical time-range labels matching the schema mapping.
- **Timetable JSON:** Join `students` → `courses` → `timetable` on `code`; sort by weekday order then slot index. Empty `schedule` when no rows match.
- **CORS:** Permissive `allow_origins=["*"]` for local/dev Flutter clients.
- **Admin UI:** Served at `GET /` with fetch-based upload and timetable test panel (no full page reload for upload).

## Frontend decisions

- **Brand palette:** Background `#FAFAFA`, primary `#0D47A1`, accent `#FFC107` (cards/indicators).
- **Navigation:** `BottomNavigationBar` with three destinations: Home, Timetable, Exams (Miller’s Law).
- **Settings:** Gear on **Home** `AppBar` only (Fitts’s Law / discoverability).
- **Auth:** Reused hosted-domain Google Sign-In and roll-number parsing aligned with prior `login_page.dart` behavior.
- **API base URL:** `http://10.0.2.2:8000` on Android emulator, `http://localhost:8000` elsewhere (iOS simulator/desktop/web).
- **“Now” class:** Parses `time_slot` strings into minute ranges; treats current time as inside `[start, end)`.
- **Timetable tabs:** `TabController` Mon–Fri; weekend opens Monday tab; today’s tab marked with a gold dot; active session card pinned to top with gold border.
- **Free rooms:** Placeholder screen routed from Home quick-action (Phase 2 backend).
- **Exams:** Static placeholder cards for Phase 2.

## How to run

**Backend**

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Open `http://localhost:8000` for the admin panel; API docs at `/docs`.

**Flutter**

```bash
cd student_timetable_app-main
dart pub get
flutter run
```

Ensure the backend is reachable at the platform-appropriate base URL above.

## Follow-ups (not in Phase 1)

- Free-room occupancy API and map/list UI.
- Exam schedule ingestion and notifications.
- Stricter production CORS and optional auth on admin upload.
