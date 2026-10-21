import SwiftUI

// MARK: Вакансии и резюме — база режима собеседований

struct LibraryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Вакансии и резюме").font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Вакансий: \(app.vacancies.count)").chip()
                        Text("Резюме: \(app.resumes.count)").chip()
                    }
                }
                Spacer(minLength: 10)
                SoftButton(title: "Из файла", icon: "doc.badge.plus") { app.vacancyFromFile() }.fixedSize()
                PrimaryPill(title: "Новая вакансия", icon: "plus") { app.newVacancy() }.fixedSize()
            }
            ErrorBanner()
            HStack(alignment: .top, spacing: 14) {
                // Колонки сжимаются вместе с окном: с жёсткой шириной они выталкивали боковую панель и обрезались справа
                // Открыт кандидат — список вакансий сворачивается в узкую полоску, чтобы средней колонке хватало места
                if app.libResumeID != nil {
                    VacancyRail().frame(width: 52).frame(maxHeight: .infinity).card()
                } else {
                    VacancyList().frame(minWidth: 170, idealWidth: 230, maxWidth: 250).frame(maxHeight: .infinity).card()
                }
                if let v = app.libVacancy {
                    VacancyDetail(v: v).frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity).card()
                } else if app.libVacancyID == 0 {
                    UnassignedResumes().frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity).card()
                } else {
                    Hint(icon: "briefcase", text: "Добавьте вакансию — вставьте описание или загрузите файл.\nПод ней храните резюме кандидатов: собеседование по ним начинается в один клик, без загрузки с нуля.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).card()
                }
                if let r = app.resumes.first(where: { $0.id == app.libResumeID }) {
                    ResumeDetail(r: r).frame(minWidth: 280, idealWidth: 380, maxWidth: 400).frame(maxHeight: .infinity).card()
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 14)
    }
}

/// Свёрнутый список вакансий: нажатие закрывает кандидата и разворачивает список обратно.
struct VacancyRail: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { app.libResumeID = nil } } label: {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.left").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
                Image(systemName: "briefcase").foregroundStyle(.secondary)
                Text("\(app.vacancies.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Показать список вакансий")
    }
}

struct VacancyList: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(icon: "briefcase", text: "Вакансии").padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(app.vacancies) { v in
                        let rs = app.resumes(for: v.id)
                        let passed = rs.filter { app.resumeResults[$0.id] != nil }.count
                        LibRow(title: v.title, subtitle: "кандидатов: \(rs.count)" + (passed > 0 ? " · прошли: \(passed)" : ""), on: app.libVacancyID == v.id) {
                            app.libVacancyID = v.id
                            app.libResumeID = nil
                        }
                        .contextMenu { Button("Удалить вакансию и её резюме", role: .destructive) { app.deleteVacancy(v.id) } }
                    }
                    let loose = app.resumes(for: 0)
                    if !loose.isEmpty {
                        LibRow(title: "Без вакансии", subtitle: "резюме: \(loose.count)", on: app.libVacancyID == 0) { app.libVacancyID = 0; app.libResumeID = nil }
                    }
                }
                .padding(8)
            }
        }
    }
}

struct LibRow: View {
    let title: String
    let subtitle: String
    let on: Bool
    /// Цвет итога собеседования: полоска слева и подпись — видно, с кем уже поговорили и чем кончилось
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let tint { RoundedRectangle(cornerRadius: 2).fill(on ? Color.white : tint).frame(width: 4) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
                    Text(subtitle).font(.caption.weight(tint == nil ? .regular : .semibold))
                        .foregroundStyle(on ? Color.white.opacity(0.85) : (tint ?? Color.secondary))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(on ? Theme.accent : (tint.map { $0.opacity(0.1) } ?? Theme.soft), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct VacancyDetail: View {
    @EnvironmentObject var app: AppState
    let v: Vacancy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Длинное название переносится, а не растягивает колонку шире карточки
                TextField("Название вакансии", text: Binding(get: { v.title }, set: { t in app.editVacancy(v.id) { $0.title = t } }), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                PrepField(title: "Описание", hint: "Обязанности, требования, условия", height: 200,
                          text: Binding(get: { v.text }, set: { t in app.editVacancy(v.id) { $0.text = t } }), onFile: nil)
                PrepField(title: "На что смотреть особенно", hint: "Подставится в каждое собеседование по этой вакансии", height: 60,
                          text: Binding(get: { v.notes }, set: { t in app.editVacancy(v.id) { $0.notes = t } }), onFile: nil)
                ResumeSection(vacancyID: v.id)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UnassignedResumes: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Резюме без вакансии").font(.system(size: 18, weight: .semibold))
                Text("Сохранены с собеседований, где вакансию не указывали. Их можно перенести к вакансии в карточке кандидата.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ResumeSection(vacancyID: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ResumeSection: View {
    @EnvironmentObject var app: AppState
    let vacancyID: Int64

    var body: some View {
        let list = app.resumes(for: vacancyID)
        return VStack(alignment: .leading, spacing: 8) {
            // В узкой колонке кнопки уходят под заголовок, а не выталкивают его за край
            ViewThatFits(in: .horizontal) {
                HStack {
                    header(list.count)
                    Spacer(minLength: 6)
                    buttons
                }
                VStack(alignment: .leading, spacing: 6) {
                    header(list.count)
                    HStack { buttons }
                }
            }
            if list.isEmpty {
                Text("Резюме пока нет. Можно выбрать сразу несколько файлов — каждый станет кандидатом.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { r in
                let done = app.resumeInterviews[r.id]?.count ?? 0
                HStack(spacing: 8) {
                    let res = app.resumeResults[r.id]
                    LibRow(title: r.name, subtitle: res?.label ?? (done > 0 ? "собеседований: \(done)" : "ещё не собеседовали"), on: app.libResumeID == r.id,
                           tint: res.map { $0.report.map { Theme.fit($0.fit) } ?? Color.blue }) { app.libResumeID = r.id }
                    Button { app.startInterview(resumeID: r.id) } label: {
                        Image(systemName: "person.badge.plus").foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Theme.accent.opacity(0.12), in: Circle()).contentShape(Circle())
                    }
                    .buttonStyle(.plain).disabled(app.isRecording).help("Новое собеседование с этим кандидатом")
                }
            }
        }
    }
}

extension ResumeSection {
    private func header(_ n: Int) -> some View {
        Text("КАНДИДАТЫ · \(n)").font(.caption2.weight(.bold)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    @ViewBuilder private var buttons: some View {
        if vacancyID != 0 {
            SoftButton(title: "Из файлов", icon: "doc.badge.plus") { app.resumesFromFiles(in: vacancyID) }.fixedSize()
                .help("Можно выбрать сразу несколько резюме")
            SoftButton(title: "Вставить", icon: "plus") { app.newResume(in: vacancyID) }.fixedSize()
        }
    }
}

struct ResumeDetail: View {
    @EnvironmentObject var app: AppState
    let r: Resume

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Имя кандидата", text: Binding(get: { r.name }, set: { t in app.editResume(r.id) { $0.name = t } }))
                        .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                    Button { app.libResumeID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Picker("Вакансия", selection: Binding(get: { r.vacancyID }, set: { id in app.editResume(r.id) { $0.vacancyID = id }; app.libVacancyID = id })) {
                    Text("Без вакансии").tag(Int64(0))
                    ForEach(app.vacancies) { v in Text(v.title).tag(v.id) }
                }
                .lineLimit(1).truncationMode(.middle)
                if let res = app.resumeResults[r.id] { CandidateResultCard(res: res) }
                PrimaryPill(title: app.resumeResults[r.id] == nil ? "Начать собеседование" : "Ещё одно собеседование", icon: "person.badge.plus", enabled: !app.isRecording) { app.startInterview(resumeID: r.id) }.fixedSize()
                if let ids = app.resumeInterviews[r.id], !ids.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("СОБЕСЕДОВАНИЯ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(ids, id: \.self) { id in
                            if let m = app.meetings.first(where: { $0.id == id }) {
                                Button { app.select(id) } label: {
                                    Label(m.title + " · " + m.startedAt.formatted(.dateTime.day().month()), systemImage: "person.text.rectangle").font(.callout)
                                }
                                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                PrepField(title: "Резюме", hint: "Текст резюме", height: 380,
                          text: Binding(get: { r.text }, set: { t in app.editResume(r.id) { $0.text = t } }), onFile: nil)
                Button("Удалить резюме", role: .destructive) { app.deleteResume(r.id) }.controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Итог последнего собеседования в карточке кандидата.
struct CandidateResultCard: View {
    @EnvironmentObject var app: AppState
    let res: CandidateResult

    var body: some View {
        let tint = res.report.map { Theme.fit($0.fit) } ?? Color.blue
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("СОБЕСЕДОВАНИЕ ПРОЙДЕНО", systemImage: "checkmark.seal.fill").font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(res.date.formatted(.dateTime.day().month())).font(.caption).foregroundStyle(.secondary)
            }
            if let r = res.report {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Theme.line, lineWidth: 5)
                        Circle().trim(from: 0, to: Double(r.fit) / 100).stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(r.fit)%").font(.system(size: 13, weight: .bold))
                    }
                    .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Verdict.hire(r.verdict)).font(.headline).foregroundStyle(tint)
                        Text(r.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Самые сильные и самые слабые места — с одного взгляда
                let sorted = r.competencies.sorted { $0.score > $1.score }
                let shown = (sorted.prefix(2) + sorted.suffix(2).filter { c in !sorted.prefix(2).contains(c) })
                VStack(spacing: 4) {
                    ForEach(Array(shown), id: \.name) { c in
                        HStack(spacing: 6) {
                            Text(c.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 1.5).fill(i <= c.score ? CompetencyRow.color(c.score) : Theme.line).frame(width: 10, height: 6)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Оценку ещё не составили — откройте собеседование и нажмите «Оценить кандидата».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { app.select(res.meetingID) } label: {
                Label("Открыть собеседование", systemImage: "arrow.right.circle").font(.callout.weight(.medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.35)))
    }
}
