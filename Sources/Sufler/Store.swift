import Foundation
import SQLite3

struct Meeting: Identifiable, Hashable {
    var id: Int64
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var notes: String
    var summary: String
    /// Названия, которые стоит перепроверить после встречи (JSON)
    var checks: String = ""
    /// "" — обычная встреча, "interview" — собеседование
    var kind: String = ""
    var isInterview: Bool { kind == "interview" }
}

struct Turn: Identifiable, Hashable {
    var id: Int64
    var meetingID: Int64
    var ts: Date
    var speaker: Speaker
    var text: String
    var voice: Int = 0
    /// Где эта реплика лежит в сохранённом звуке встречи, в секундах; 0–0 — звука нет
    var audioStart: Double = 0
    var audioEnd: Double = 0
}

struct Question: Identifiable, Hashable {
    var id: Int64
    var meetingID: Int64
    var ts: Date
    var question: String
    var addressee: String
    var asker: String
    var topic: String = ""
    var forMe: Bool = false
    var context: String
    var answer: String
}

struct Chunk {
    var meetingID: Int64
    var text: String
    var vector: [Float]
    var source: String = ""
}

struct Fact: Identifiable, Hashable {
    var id: Int64
    var text: String
    var previous: String
    var meetingID: Int64
    var createdAt: Date
    var updatedAt: Date
    var vector: [Float]
}

/// Вакансия в базе собеседований: под ней лежат резюме кандидатов.
struct Vacancy: Identifiable, Hashable {
    var id: Int64
    var title: String
    var text: String
    /// Акценты интервьюера для этой вакансии
    var notes: String
    var createdAt: Date
}

struct Resume: Identifiable, Hashable {
    var id: Int64
    var vacancyID: Int64
    var name: String
    var text: String
    var createdAt: Date
}

struct Doc: Identifiable, Hashable {
    var id: Int64
    var title: String
    var path: String
    var addedAt: Date
    var chars: Int
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Локальная база: встречи, реплики, вопросы и векторы для поиска. Вызывать с главного потока.
final class Store {
    private var db: OpaquePointer?

    init() {
        let path = Paths.supportDir.appendingPathComponent("sufler.sqlite").path
        sqlite3_open(path, &db)
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS meetings(id INTEGER PRIMARY KEY, title TEXT, started_at REAL, ended_at REAL, notes TEXT DEFAULT '', summary TEXT DEFAULT '');
        CREATE TABLE IF NOT EXISTS turns(id INTEGER PRIMARY KEY, meeting_id INTEGER, ts REAL, speaker TEXT, text TEXT);
        CREATE TABLE IF NOT EXISTS questions(id INTEGER PRIMARY KEY, meeting_id INTEGER, ts REAL, question TEXT, addressee TEXT, asker TEXT, context TEXT, answer TEXT DEFAULT '');
        CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, meeting_id INTEGER, text TEXT, vector BLOB);
        CREATE INDEX IF NOT EXISTS turns_m ON turns(meeting_id);
        CREATE INDEX IF NOT EXISTS chunks_m ON chunks(meeting_id);
        CREATE TABLE IF NOT EXISTS voices(meeting_id INTEGER, voice INTEGER, name TEXT, PRIMARY KEY(meeting_id, voice));
        """)
        // Колонки, добавленные позже: на существующей базе ALTER просто вернёт ошибку «уже есть»
        sqlite3_exec(db, "ALTER TABLE turns ADD COLUMN voice INTEGER DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE questions ADD COLUMN topic TEXT DEFAULT ''", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE chunks ADD COLUMN doc_id INTEGER DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE questions ADD COLUMN for_me INTEGER DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE turns ADD COLUMN audio_start REAL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE turns ADD COLUMN audio_end REAL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN checks TEXT DEFAULT ''", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN kind TEXT DEFAULT ''", nil, nil, nil)
        exec("CREATE TABLE IF NOT EXISTS interviews(meeting_id INTEGER PRIMARY KEY, data TEXT);")
        exec("CREATE TABLE IF NOT EXISTS vacancies(id INTEGER PRIMARY KEY, title TEXT, text TEXT, notes TEXT DEFAULT '', created_at REAL);")
        exec("CREATE TABLE IF NOT EXISTS resumes(id INTEGER PRIMARY KEY, vacancy_id INTEGER, name TEXT, text TEXT, created_at REAL);")
        exec("CREATE TABLE IF NOT EXISTS documents(id INTEGER PRIMARY KEY, title TEXT, path TEXT, added_at REAL, chars INTEGER);")
        exec("CREATE TABLE IF NOT EXISTS facts(id INTEGER PRIMARY KEY, text TEXT, previous TEXT DEFAULT '', meeting_id INTEGER DEFAULT 0, created_at REAL, updated_at REAL, vector BLOB);")
    }

    func exec(_ sql: String) {
        var e: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &e) != SQLITE_OK, let e { log("sqlite: " + String(cString: e)) }
    }

    /// Запрос для расширений базы (статистика и т. п.)
    func rawRun(_ sql: String, _ args: [Any?], row: ((OpaquePointer) -> Void)? = nil) { run(sql, args, row: row) }

    private func run(_ sql: String, _ args: [Any?], row: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            log("sqlite prepare: " + String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(st, n, v, -1, SQLITE_TRANSIENT)
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(st, n)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row?(st) }
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    // MARK: Встречи

    func createMeeting(title: String, kind: String = "") -> Meeting {
        let now = Date()
        run("INSERT INTO meetings(title, started_at, kind) VALUES(?,?,?)", [title, now.timeIntervalSince1970, kind])
        return Meeting(id: sqlite3_last_insert_rowid(db), title: title, startedAt: now, endedAt: nil, notes: "", summary: "", kind: kind)
    }

    /// Начало встречи переносим на момент, когда запись реально началась (собеседование готовят заранее).
    func setStarted(_ id: Int64, _ date: Date) {
        run("UPDATE meetings SET started_at=? WHERE id=?", [date.timeIntervalSince1970, id])
    }

    // MARK: Вакансии и резюме

    func vacancies() -> [Vacancy] {
        var out: [Vacancy] = []
        run("SELECT id,title,text,notes,created_at FROM vacancies ORDER BY created_at DESC", []) { st in
            out.append(Vacancy(id: sqlite3_column_int64(st, 0), title: self.text(st, 1), text: self.text(st, 2), notes: self.text(st, 3), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4))))
        }
        return out
    }

    func addVacancy(title: String, text: String, notes: String = "") -> Vacancy {
        let now = Date()
        run("INSERT INTO vacancies(title, text, notes, created_at) VALUES(?,?,?,?)", [title, text, notes, now.timeIntervalSince1970])
        return Vacancy(id: sqlite3_last_insert_rowid(db), title: title, text: text, notes: notes, createdAt: now)
    }

    func update(_ v: Vacancy) { run("UPDATE vacancies SET title=?, text=?, notes=? WHERE id=?", [v.title, v.text, v.notes, v.id]) }

    func deleteVacancy(_ id: Int64) {
        run("DELETE FROM resumes WHERE vacancy_id=?", [id])
        run("DELETE FROM vacancies WHERE id=?", [id])
    }

    func resumes() -> [Resume] {
        var out: [Resume] = []
        run("SELECT id,vacancy_id,name,text,created_at FROM resumes ORDER BY created_at DESC", []) { st in
            out.append(Resume(id: sqlite3_column_int64(st, 0), vacancyID: sqlite3_column_int64(st, 1), name: self.text(st, 2), text: self.text(st, 3), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4))))
        }
        return out
    }

    func addResume(vacancyID: Int64, name: String, text: String) -> Resume {
        let now = Date()
        run("INSERT INTO resumes(vacancy_id, name, text, created_at) VALUES(?,?,?,?)", [vacancyID, name, text, now.timeIntervalSince1970])
        return Resume(id: sqlite3_last_insert_rowid(db), vacancyID: vacancyID, name: name, text: text, createdAt: now)
    }

    func update(_ r: Resume) { run("UPDATE resumes SET vacancy_id=?, name=?, text=? WHERE id=?", [r.vacancyID, r.name, r.text, r.id]) }

    func deleteResume(_ id: Int64) { run("DELETE FROM resumes WHERE id=?", [id]) }

    // MARK: Собеседования

    func interview(meetingID: Int64) -> Interview? {
        var out: Interview?
        run("SELECT data FROM interviews WHERE meeting_id=?", [meetingID]) { st in
            out = (self.text(st, 0).data(using: .utf8)).flatMap { try? JSONDecoder().decode(Interview.self, from: $0) }
        }
        return out
    }

    func saveInterview(_ iv: Interview) {
        guard let d = try? JSONEncoder().encode(iv), let s = String(data: d, encoding: .utf8) else { return }
        run("INSERT OR REPLACE INTO interviews(meeting_id, data) VALUES(?,?)", [iv.meetingID, s])
    }

    func meetings() -> [Meeting] {
        var out: [Meeting] = []
        run("SELECT id,title,started_at,ended_at,notes,summary,checks,kind FROM meetings ORDER BY started_at DESC", []) { st in
            let ended = sqlite3_column_type(st, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 3))
            out.append(Meeting(id: sqlite3_column_int64(st, 0), title: self.text(st, 1), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)), endedAt: ended, notes: self.text(st, 4), summary: self.text(st, 5), checks: self.text(st, 6), kind: self.text(st, 7)))
        }
        return out
    }

    func update(_ m: Meeting) {
        run("UPDATE meetings SET title=?, ended_at=?, notes=?, summary=?, checks=? WHERE id=?", [m.title, m.endedAt?.timeIntervalSince1970, m.notes, m.summary, m.checks, m.id])
    }

    func deleteMeeting(_ id: Int64) {
        for t in ["turns", "questions", "chunks", "voices", "interviews"] { run("DELETE FROM \(t) WHERE meeting_id=?", [id]) }
        run("DELETE FROM meetings WHERE id=?", [id])
    }

    // MARK: Реплики и вопросы

    func addTurn(meetingID: Int64, speaker: Speaker, text: String, voice: Int, audio: (Double, Double) = (0, 0)) -> Turn {
        let now = Date()
        run("INSERT INTO turns(meeting_id, ts, speaker, text, voice, audio_start, audio_end) VALUES(?,?,?,?,?,?,?)", [meetingID, now.timeIntervalSince1970, speaker.rawValue, text, Int64(voice), audio.0, audio.1])
        return Turn(id: sqlite3_last_insert_rowid(db), meetingID: meetingID, ts: now, speaker: speaker, text: text, voice: voice, audioStart: audio.0, audioEnd: audio.1)
    }

    func voiceNames(meetingID: Int64) -> [Int: String] {
        var out: [Int: String] = [:]
        run("SELECT voice, name FROM voices WHERE meeting_id=?", [meetingID]) { st in out[Int(sqlite3_column_int64(st, 0))] = self.text(st, 1) }
        return out
    }

    func setVoiceName(meetingID: Int64, voice: Int, name: String) {
        run("INSERT OR REPLACE INTO voices(meeting_id, voice, name) VALUES(?,?,?)", [meetingID, Int64(voice), name])
    }

    func deleteTurn(_ id: Int64) { run("DELETE FROM turns WHERE id=?", [id]) }

    func updateTurn(_ t: Turn) {
        run("UPDATE turns SET text=?, ts=?, audio_start=?, audio_end=? WHERE id=?", [t.text, t.ts.timeIntervalSince1970, t.audioStart, t.audioEnd, t.id])
    }

    func turns(meetingID: Int64) -> [Turn] {
        var out: [Turn] = []
        run("SELECT id,ts,speaker,text,voice,audio_start,audio_end FROM turns WHERE meeting_id=? ORDER BY id", [meetingID]) { st in
            out.append(Turn(id: sqlite3_column_int64(st, 0), meetingID: meetingID, ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), speaker: Speaker(rawValue: self.text(st, 2)) ?? .them, text: self.text(st, 3), voice: Int(sqlite3_column_int64(st, 4)),
                            audioStart: sqlite3_column_double(st, 5), audioEnd: sqlite3_column_double(st, 6)))
        }
        return out
    }

    func addQuestion(_ q: Question) -> Question {
        run("INSERT INTO questions(meeting_id, ts, question, addressee, asker, context) VALUES(?,?,?,?,?,?)", [q.meetingID, q.ts.timeIntervalSince1970, q.question, q.addressee, q.asker, q.context])
        var r = q
        r.id = sqlite3_last_insert_rowid(db)
        return r
    }

    func update(_ q: Question) {
        run("UPDATE questions SET question=?, addressee=?, asker=?, topic=?, context=?, answer=?, for_me=? WHERE id=?", [q.question, q.addressee, q.asker, q.topic, q.context, q.answer, Int64(q.forMe ? 1 : 0), q.id])
    }

    func questions(meetingID: Int64) -> [Question] {
        var out: [Question] = []
        run("SELECT id,ts,question,addressee,asker,context,answer,topic,for_me FROM questions WHERE meeting_id=? ORDER BY id", [meetingID]) { st in
            out.append(Question(id: sqlite3_column_int64(st, 0), meetingID: meetingID, ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), question: self.text(st, 2), addressee: self.text(st, 3), asker: self.text(st, 4), topic: self.text(st, 7), forMe: sqlite3_column_int64(st, 8) != 0, context: self.text(st, 5), answer: self.text(st, 6)))
        }
        return out
    }

    // MARK: Векторы

    func replaceChunks(meetingID: Int64, chunks: [(String, [Float])]) {
        run("DELETE FROM chunks WHERE meeting_id=?", [meetingID])
        for (t, v) in chunks {
            let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
            run("INSERT INTO chunks(meeting_id, text, vector) VALUES(?,?,?)", [meetingID, t, data])
        }
    }

    // MARK: Факты

    private func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    func facts() -> [Fact] {
        var out: [Fact] = []
        run("SELECT id,text,previous,meeting_id,created_at,updated_at,vector FROM facts ORDER BY updated_at DESC", []) { st in
            let n = Int(sqlite3_column_bytes(st, 6))
            var v = [Float](repeating: 0, count: n / MemoryLayout<Float>.size)
            if n > 0, let p = sqlite3_column_blob(st, 6) { _ = v.withUnsafeMutableBytes { memcpy($0.baseAddress, p, n) } }
            out.append(Fact(id: sqlite3_column_int64(st, 0), text: self.text(st, 1), previous: self.text(st, 2), meetingID: sqlite3_column_int64(st, 3),
                            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)), vector: v))
        }
        return out
    }

    func addFact(text: String, meetingID: Int64, vector: [Float]) -> Fact {
        let now = Date()
        run("INSERT INTO facts(text, meeting_id, created_at, updated_at, vector) VALUES(?,?,?,?,?)", [text, meetingID, now.timeIntervalSince1970, now.timeIntervalSince1970, blob(vector)])
        return Fact(id: sqlite3_last_insert_rowid(db), text: text, previous: "", meetingID: meetingID, createdAt: now, updatedAt: now, vector: vector)
    }

    /// Новая формулировка заменяет старую; старую храним, чтобы было видно, что изменилось.
    func updateFact(_ f: Fact) {
        run("UPDATE facts SET text=?, previous=?, meeting_id=?, updated_at=?, vector=? WHERE id=?", [f.text, f.previous, f.meetingID, f.updatedAt.timeIntervalSince1970, blob(f.vector), f.id])
    }

    func deleteFact(_ id: Int64) { run("DELETE FROM facts WHERE id=?", [id]) }

    // MARK: База знаний

    func addDocument(title: String, path: String, chars: Int) -> Doc {
        let now = Date()
        run("INSERT INTO documents(title, path, added_at, chars) VALUES(?,?,?,?)", [title, path, now.timeIntervalSince1970, Int64(chars)])
        return Doc(id: sqlite3_last_insert_rowid(db), title: title, path: path, addedAt: now, chars: chars)
    }

    func documents() -> [Doc] {
        var out: [Doc] = []
        run("SELECT id,title,path,added_at,chars FROM documents ORDER BY added_at DESC", []) { st in
            out.append(Doc(id: sqlite3_column_int64(st, 0), title: self.text(st, 1), path: self.text(st, 2), addedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)), chars: Int(sqlite3_column_int64(st, 4))))
        }
        return out
    }

    func deleteDocument(_ id: Int64) {
        run("DELETE FROM chunks WHERE doc_id=?", [id])
        run("DELETE FROM documents WHERE id=?", [id])
    }

    func addDocChunks(docID: Int64, chunks: [(String, [Float])]) {
        exec("BEGIN")
        for (t, v) in chunks {
            let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
            run("INSERT INTO chunks(meeting_id, doc_id, text, vector) VALUES(0,?,?,?)", [docID, t, data])
        }
        exec("COMMIT")
    }

    func allChunks() -> [Chunk] {
        var out: [Chunk] = []
        run("SELECT c.meeting_id, c.text, c.vector, COALESCE(d.title, m.title, '') FROM chunks c LEFT JOIN documents d ON d.id=c.doc_id LEFT JOIN meetings m ON m.id=c.meeting_id", []) { st in
            let n = Int(sqlite3_column_bytes(st, 2))
            var v = [Float](repeating: 0, count: n / MemoryLayout<Float>.size)
            if n > 0, let p = sqlite3_column_blob(st, 2) { _ = v.withUnsafeMutableBytes { memcpy($0.baseAddress, p, n) } }
            out.append(Chunk(meetingID: sqlite3_column_int64(st, 0), text: self.text(st, 1), vector: v, source: self.text(st, 3)))
        }
        return out
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return dot / ((na * nb).squareRoot() + 1e-9)
}
