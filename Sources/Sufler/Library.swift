import AppKit
import Foundation

// MARK: База собеседований: вакансии и резюме

extension AppState {
    var libVacancy: Vacancy? { vacancies.first { $0.id == libVacancyID } }
    func resumes(for vacancyID: Int64) -> [Resume] { resumes.filter { $0.vacancyID == vacancyID } }

    func openLibrary() {
        showKB = true
        if libVacancyID == nil { libVacancyID = vacancies.first?.id ?? (resumes.isEmpty ? nil : 0) }
        refreshResumeInterviews()
    }

    /// Какие собеседования проведены по каждому резюме — для ссылок в карточке кандидата.
    func refreshResumeInterviews() {
        var map: [Int64: [Int64]] = [:]
        var results: [Int64: CandidateResult] = [:]
        // Встречи идут от новых к старым: первое найденное — последнее собеседование
        for m in meetings where m.isInterview {
            guard let iv = meetingStore.interview(meetingID: m.id), let rid = iv.resumeID else { continue }
            map[rid, default: []].append(m.id)
            if results[rid] == nil || (results[rid]?.report == nil && iv.report != nil) {
                results[rid] = CandidateResult(meetingID: m.id, date: m.startedAt, report: iv.report)
            }
        }
        resumeInterviews = map
        resumeResults = results
    }

    private static func pickFiles(_ message: String, many: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = many
        panel.canChooseDirectories = false
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Название по первой содержательной строке текста.
    private static func title(from text: String, fallback: String) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count >= 3 } ?? ""
        let t = line.count > 70 ? String(line.prefix(70)) + "…" : line
        return t.isEmpty ? fallback : t
    }

    // MARK: Вакансии

    func newVacancy(text: String = "", title: String = "") {
        let v = meetingStore.addVacancy(title: title.isEmpty ? Self.title(from: text, fallback: "Новая вакансия") : title, text: text)
        vacancies.insert(v, at: 0)
        libVacancyID = v.id
        libResumeID = nil
    }

    func vacancyFromFile() {
        guard let url = Self.pickFiles("Выберите описание вакансии: PDF, Word, текст", many: false).first else { return }
        guard let text = Self.extractText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            errorText = "Не удалось прочитать текст из «\(url.lastPathComponent)»."
            return
        }
        newVacancy(text: text, title: url.deletingPathExtension().lastPathComponent)
    }

    func editVacancy(_ id: Int64, _ change: (inout Vacancy) -> Void) {
        guard let i = vacancies.firstIndex(where: { $0.id == id }) else { return }
        change(&vacancies[i])
        let v = vacancies[i]
        librarySaveTask?.cancel()
        librarySaveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self.meetingStore.update(v) }
        }
    }

    func deleteVacancy(_ id: Int64) {
        meetingStore.deleteVacancy(id)
        vacancies.removeAll { $0.id == id }
        resumes.removeAll { $0.vacancyID == id }
        if libVacancyID == id { libVacancyID = vacancies.first?.id; libResumeID = nil }
    }

    // MARK: Резюме

    func newResume(in vacancyID: Int64, name: String = "", text: String = "") {
        let r = meetingStore.addResume(vacancyID: vacancyID, name: name.isEmpty ? Self.title(from: text, fallback: "Новый кандидат") : name, text: text)
        resumes.insert(r, at: 0)
        libResumeID = r.id
    }

    /// Можно выбрать сразу несколько резюме — каждое станет кандидатом этой вакансии.
    func resumesFromFiles(in vacancyID: Int64) {
        for url in Self.pickFiles("Выберите резюме кандидатов: PDF, Word, текст", many: true) {
            guard let text = Self.extractText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                errorText = "Не удалось прочитать текст из «\(url.lastPathComponent)»."
                continue
            }
            newResume(in: vacancyID, name: url.deletingPathExtension().lastPathComponent, text: text)
        }
    }

    func editResume(_ id: Int64, _ change: (inout Resume) -> Void) {
        guard let i = resumes.firstIndex(where: { $0.id == id }) else { return }
        change(&resumes[i])
        let r = resumes[i]
        librarySaveTask?.cancel()
        librarySaveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self.meetingStore.update(r) }
        }
    }

    func deleteResume(_ id: Int64) {
        meetingStore.deleteResume(id)
        resumes.removeAll { $0.id == id }
        if libResumeID == id { libResumeID = nil }
    }

    // MARK: Связь с собеседованием

    /// Собеседование по резюме из базы: вакансия, резюме и акценты уже на месте — остаётся собрать карту.
    func startInterview(resumeID: Int64) {
        guard let r = resumes.first(where: { $0.id == resumeID }) else { return }
        newInterview()
        let v = vacancies.first { $0.id == r.vacancyID }
        editInterview { iv in
            iv.resumeID = r.id
            iv.resume = r.text
            iv.vacancyID = v?.id
            iv.vacancy = v?.text ?? ""
            iv.notes = v?.notes ?? ""
        }
        setCandidate(r.name)
        refreshResumeInterviews()
    }

    /// На экране подготовки: подставить вакансию из базы.
    func useVacancy(_ id: Int64) {
        guard let v = vacancies.first(where: { $0.id == id }) else { return }
        editInterview { iv in
            iv.vacancyID = v.id
            iv.vacancy = v.text
            if iv.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { iv.notes = v.notes }
        }
    }

    func useResume(_ id: Int64) {
        guard let r = resumes.first(where: { $0.id == id }) else { return }
        editInterview { iv in
            iv.resumeID = r.id
            iv.resume = r.text
            if iv.vacancyID == nil, let v = vacancies.first(where: { $0.id == r.vacancyID }) { iv.vacancyID = v.id; iv.vacancy = v.text }
        }
        setCandidate(r.name)
    }

    /// Вставленное вручную сохраняем в базу, чтобы в следующий раз не грузить заново.
    func saveInterviewToLibrary() {
        guard let iv = interview else { return }
        let vText = iv.vacancy.trimmingCharacters(in: .whitespacesAndNewlines)
        let rText = iv.resume.trimmingCharacters(in: .whitespacesAndNewlines)
        var vid = iv.vacancyID.flatMap { id in vacancies.contains { $0.id == id } ? id : nil }
        if vid == nil, !vText.isEmpty {
            let v = meetingStore.addVacancy(title: Self.title(from: vText, fallback: "Вакансия"), text: vText, notes: iv.notes)
            vacancies.insert(v, at: 0)
            vid = v.id
        } else if let id = vid, let i = vacancies.firstIndex(where: { $0.id == id }), vacancies[i].text != vText, !vText.isEmpty {
            // Поправили текст вакансии прямо на подготовке — обновляем и в базе
            vacancies[i].text = vText
            meetingStore.update(vacancies[i])
        }
        var rid = iv.resumeID.flatMap { id in resumes.contains { $0.id == id } ? id : nil }
        if rid == nil, !rText.isEmpty {
            let name = iv.candidate.trimmingCharacters(in: .whitespaces)
            let r = meetingStore.addResume(vacancyID: vid ?? 0, name: name.isEmpty ? Self.title(from: rText, fallback: "Кандидат") : name, text: rText)
            resumes.insert(r, at: 0)
            rid = r.id
        } else if let id = rid, let i = resumes.firstIndex(where: { $0.id == id }), resumes[i].text != rText, !rText.isEmpty {
            resumes[i].text = rText
            meetingStore.update(resumes[i])
        }
        if vid != iv.vacancyID || rid != iv.resumeID {
            editInterview { $0.vacancyID = vid; $0.resumeID = rid }
            if let i = interview { meetingStore.saveInterview(i) }
            refreshResumeInterviews()
        }
    }
}

/// Чем закончилось последнее собеседование с кандидатом.
struct CandidateResult: Hashable {
    var meetingID: Int64
    var date: Date
    var report: InterviewReport?

    var label: String {
        let d = date.formatted(.dateTime.day().month())
        guard let r = report else { return "собеседование \(d), без оценки" }
        return "\(r.fit)% · \(Verdict.hire(r.verdict)) · \(d)"
    }
}
