import SwiftUI

// MARK: Собеседование: общий экран

extension Theme {
    static func verdict(_ v: String) -> Color {
        switch v {
        case "strong": return .green
        case "ok": return .blue
        case "vague", "evasive": return .orange
        default: return .red
        }
    }

    static func kind(_ k: String) -> Color {
        switch k {
        case "must": return accent
        case "person": return .purple
        case "case": return .indigo
        default: return .pink
        }
    }

    static func fit(_ v: Int) -> Color { v >= 75 ? .green : (v >= 50 ? .orange : .red) }
}

struct InterviewEmptyState: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.text.rectangle").font(.system(size: 46, weight: .light)).foregroundStyle(Theme.accent)
            Text("Собеседований пока нет").font(.title2.weight(.semibold))
            Text("Добавьте вакансию и резюме — Суфлёр соберёт карту вопросов,\nподскажет уточнения по ходу разговора и оценит кандидата.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            PrimaryPill(title: "Новое собеседование", icon: "person.badge.plus") { app.newInterview() }.padding(.top, 4)
        }
    }
}

struct PrimaryPill: View {
    let title: String
    let icon: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).fontWeight(.semibold).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Theme.accent.opacity(enabled ? 1 : 0.45), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let e = app.errorText {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).font(.callout)
                Spacer()
                Button { app.errorText = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct InterviewView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 14) {
            Header()
            ErrorBanner()
            if app.turns.isEmpty && app.recordingID != app.selectedID {
                PrepView()
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        TranscriptCard()
                        NotesCard().frame(height: 140)
                    }
                    .frame(minWidth: 320, maxWidth: .infinity)
                    InterviewSide().frame(minWidth: 330, idealWidth: 410, maxWidth: 410)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 14)
    }
}

// MARK: Подготовка

struct PrepView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Предупредите кандидата, что разговор записывается и расшифровывается. Всё остаётся на этом Mac.", systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Кандидат").font(.subheadline.weight(.semibold))
                        TextField("Имя и фамилия", text: Binding(get: { app.interview?.candidate ?? "" }, set: { app.setCandidate($0) }))
                            .textFieldStyle(.roundedBorder)
                    }
                    PrepField(title: "Вакансия", hint: "Вставьте описание вакансии или выберите её из базы: обязанности, требования, условия", height: 170,
                              text: Binding(get: { app.interview?.vacancy ?? "" }, set: { v in app.editInterview { $0.vacancy = v } }),
                              picks: app.vacancies.map { v in LibPick(id: v.id, title: v.title) { app.useVacancy(v.id) } }) { app.loadInterviewFile(resume: false) }
                    PrepField(title: "Резюме", hint: "Вставьте резюме, загрузите файл или выберите из базы. Оно не обязано совпадать с вакансией", height: 170,
                              text: Binding(get: { app.interview?.resume ?? "" }, set: { v in app.editInterview { $0.resume = v } }),
                              picks: resumePicks) { app.loadInterviewFile(resume: true) }
                    PrepField(title: "На что смотреть особенно", hint: "Необязательно: «важна самостоятельность», «проверить опыт с Kafka», «будет руководить 5 людьми»", height: 60,
                              text: Binding(get: { app.interview?.notes ?? "" }, set: { v in app.editInterview { $0.notes = v } }), onFile: nil)
                    HStack(spacing: 10) {
                        PrimaryPill(title: app.interview?.plan == nil ? "Собрать карту вопросов" : "Пересобрать карту", icon: "sparkles",
                                    enabled: !app.preparing && app.llmReady) { app.buildPlan() }
                        if app.preparing {
                            ProgressView().controlSize(.small)
                            Text(app.prepNote).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text("Вакансия и резюме сохранятся в «Вакансии и резюме», когда соберёте карту, — в следующий раз их не придётся загружать заново.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    if !app.deepFits || !app.deepModelReady {
                        Text(app.deepFits ? "Сейчас карту собирает основная модель. Для более глубокой подготовки скачайте Gemma 4 26B в настройках." : "Карту собирает основная модель: глубокой нужно от 32 ГБ памяти.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .card()

            VStack(spacing: 0) {
                HStack {
                    CardTitle(icon: "map", text: "Карта вопросов")
                    Spacer()
                    if app.interview?.plan != nil { RecordButton().controlSize(.small) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider().opacity(0.5)
                if let plan = app.interview?.plan {
                    PlanView(plan: plan)
                } else {
                    Hint(icon: app.preparing ? "ellipsis" : "map",
                         text: app.preparing ? app.prepNote : "Здесь появится карта: обязательные вопросы по требованиям, вопросы, чтобы понять человека, и вопросы с подковыркой.\n\nМожно начать и без карты — уточнения по ходу разговора всё равно будут.")
                }
            }
            .frame(minWidth: 320, idealWidth: 460, maxWidth: 460)
            .frame(maxHeight: .infinity)
            .card()
        }
    }

    /// Резюме выбранной вакансии; если вакансия не из базы — все резюме.
    private var resumePicks: [LibPick] {
        let vid = app.interview?.vacancyID
        let list = vid.map { app.resumes(for: $0) } ?? app.resumes
        return list.map { r in LibPick(id: r.id, title: r.name) { app.useResume(r.id) } }
    }
}

struct LibPick: Identifiable {
    let id: Int64
    let title: String
    let action: () -> Void
}

struct PrepField: View {
    let title: String
    let hint: String
    let height: CGFloat
    @Binding var text: String
    var picks: [LibPick] = []
    let onFile: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                if !text.isEmpty { Text("\(text.count) знаков").font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                if !picks.isEmpty {
                    Menu("Из базы") { ForEach(picks) { p in Button(p.title, action: p.action) } }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                }
                if let onFile { Button("Из файла…", action: onFile).controlSize(.small) }
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(hint).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).padding(4)
            }
            .frame(height: height)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: Карта вопросов

struct PlanView: View {
    @EnvironmentObject var app: AppState
    let plan: InterviewPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !plan.brief.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("КАНДИДАТ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(plan.brief).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !plan.requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ТРЕБОВАНИЯ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(plan.requirements, id: \.self) { r in Text("•  " + r).font(.callout) }
                    }
                }
                if !plan.focus.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ПРОВЕРИТЬ ОСОБЕННО").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        ForEach(plan.focus, id: \.self) { r in Text("•  " + r).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                ForEach(AppState.planKinds, id: \.self) { k in
                    let qs = plan.questions.filter { $0.kind == k }
                    if !qs.isEmpty {
                        HStack {
                            Text(Verdict.kind(k).uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.kind(k))
                            Spacer()
                            Text("\(qs.filter(\.asked).count) из \(qs.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        ForEach(qs) { q in PlanRow(q: q) }
                    }
                }
                if !plan.deep {
                    Text("Карту собрала основная модель.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .textSelection(.enabled)
        }
    }
}

struct PlanRow: View {
    @EnvironmentObject var app: AppState
    let q: PlanQuestion

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button { app.togglePlanQuestion(q.id) } label: {
                Image(systemName: q.asked ? "checkmark.circle.fill" : (q.skipped ? "arrow.uturn.right.circle" : "circle"))
                    .font(.system(size: 16)).foregroundStyle(q.asked ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain).help(q.asked ? "Отметить как не заданный" : "Отметить как заданный")
            VStack(alignment: .leading, spacing: 4) {
                Text(q.text).font(.callout.weight(.medium)).foregroundStyle(q.asked ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                if !q.purpose.isEmpty {
                    Label(q.purpose, systemImage: q.kind == "person" ? "eye.slash" : "scope")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !q.listen.isEmpty, !q.asked {
                    Label(q.listen, systemImage: "ear").font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft.opacity(q.asked ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Правая панель собеседования

struct InterviewSide: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IVTab(title: "Суфлёр", icon: "ear", index: 0)
                IVTab(title: "Карта", icon: "map", index: 1)
                IVTab(title: "Оценка", icon: "chart.bar.doc.horizontal", index: 2)
                IVTab(title: "Чат", icon: "sparkles", index: 3)
            }
            .padding(4)
            .background(Theme.soft, in: Capsule())
            .padding(12)
            Divider().opacity(0.5)
            switch app.interviewTab {
            case 0: LivePanel()
            case 1:
                if let plan = app.interview?.plan { PlanView(plan: plan) } else { Hint(icon: "map", text: "Карту вопросов не собирали.").frame(maxHeight: .infinity, alignment: .top) }
            case 2: ReportPanel()
            default: ChatPanel()
            }
        }
        .frame(maxHeight: .infinity)
        .card()
    }
}

struct IVTab: View {
    @EnvironmentObject var app: AppState
    let title: String
    let icon: String
    let index: Int

    var body: some View {
        let on = app.interviewTab == index
        Button { app.interviewTab = index } label: {
            Label(title, systemImage: icon)
                .labelStyle(.titleOnly)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(on ? Theme.accent : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Во время собеседования: что дозадать прямо сейчас и какой вопрос из карты следующий.
struct LivePanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let probes = app.interview?.probes ?? []
        let active = probes.last.flatMap { !$0.followup.isEmpty && !$0.used && !$0.dismissed ? $0 : nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Кандидат молчит после вопроса — видно сразу, без модели
                if app.isRecording, app.selectedID == app.recordingID { SilenceCard() }
                if let ai = app.aiSuspicion, ai.score >= 1.5 { AISuspicionCard(score: ai.score, reasons: ai.reasons) }
                if let m = app.mastery { MasteryBar(value: m, history: probes.compactMap(\.mastery)) }
                if let share = app.talkShare { TalkShareBar(share: share) }
                if let p = active {
                    FollowupCard(p: p)
                } else if let p = probes.last {
                    ProbeRow(p: p, big: true)
                }
                if app.probing {
                    HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Разбираю ответ…").font(.caption).foregroundStyle(.secondary) }
                } else if probes.isEmpty, app.isRecording {
                    Text("Слушаю. Когда кандидат договорит, разберу ответ и, если нужно, подскажу уточнение.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if let q = app.nextPlanQuestion {
                    NextQuestionCard(q: q)
                } else if app.interview?.plan == nil {
                    Text("Карта вопросов не собрана — подсказки по уточнениям всё равно будут.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Все вопросы карты пройдены", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.green)
                }

                let older = Array(probes.dropLast().reversed())
                if !older.isEmpty {
                    Text("РАНЬШЕ").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 6)
                    ForEach(older) { ProbeRow(p: $0, big: false) }
                }
            }
            .padding(14)
            .textSelection(.enabled)
        }
    }
}

/// «Плавает в теме или нет»: средняя оценка владения темой по последним ответам и столбики по каждому ответу.
struct MasteryBar: View {
    let value: Double
    let history: [Int]

    static func color(_ v: Double) -> Color { v >= 3.8 ? .green : (v >= 2.5 ? .orange : .red) }
    static func title(_ v: Double) -> String { v >= 3.8 ? "Уверенно в теме" : (v >= 2.5 ? "Местами плавает" : "Плавает в теме") }

    var body: some View {
        let c = Self.color(value)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ВЛАДЕНИЕ ТЕМОЙ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(Self.title(value)).font(.system(size: 17, weight: .semibold)).foregroundStyle(c)
                Text(String(format: "%.1f из 5 по последним ответам", value)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            // Каждый разобранный ответ — столбик: видно, тонет человек или выплывает
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(history.suffix(12).enumerated()), id: \.offset) { _, m in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.color(Double(m)))
                        .frame(width: 7, height: 6 + CGFloat(m) * 6)
                }
            }
            .frame(height: 36, alignment: .bottom)
        }
        .padding(12)
        .background(c.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TalkShareBar: View {
    let share: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Кандидат говорит \(Int(share * 100))%").font(.caption.weight(.medium))
                Spacer()
                if share < 0.5 { Text("дайте ему больше говорить").font(.caption).foregroundStyle(.orange) }
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * share))
                    Capsule().fill(Theme.line)
                }
            }
            .frame(height: 5)
        }
    }
}

struct FollowupCard: View {
    @EnvironmentObject var app: AppState
    let p: Probe

    var body: some View {
        let tint = Theme.verdict(p.verdict)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label(p.draft == true ? "ПОХОЖЕ, СТОИТ УТОЧНИТЬ" : "ДОЗАДАЙТЕ", systemImage: "arrow.turn.down.right").font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(Verdict.title(p.verdict)).chip(tint)
                if let m = p.mastery { Text("в теме \(m)/5").chip(MasteryBar.color(Double(m))) }
                Spacer(minLength: 0)
                Text(p.ts.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
            Text(p.followup).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if p.draft == true { Text("кандидат ещё говорит — дождитесь паузы").font(.caption).foregroundStyle(.secondary) }
            if let st = p.stats, !st.markers.isEmpty { Markers(stats: st) }
            if !p.reason.isEmpty { Text(p.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !p.gist.isEmpty { Text("Ответ: " + p.gist).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                SoftButton(title: "Задал", icon: "checkmark") { app.markProbe(p.id, used: true) }
                SoftButton(title: "Не нужно", icon: "xmark") { app.markProbe(p.id, used: false) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(p.draft == true ? 0.05 : 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(p.draft == true ? 0.35 : 0.7), style: StrokeStyle(lineWidth: 2, dash: p.draft == true ? [6, 4] : [])))
    }
}

/// Маркеры ответа по самой речи: долго думал, медленно, много «ээ», слишком гладко.
struct Markers: View {
    let stats: AnswerStats
    var body: some View {
        HStack(spacing: 5) {
            ForEach(stats.markers, id: \.0) { m in
                Text(m.0).chip(m.1 == "purple" ? Color.purple : Color.orange)
            }
        }
    }
}

/// Кандидат молчит после вопроса: сколько секунд и что можно сделать.
struct SilenceCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let last = app.turns.last, !AppState.isCandidate(last), app.partial.isEmpty,
               last.text.contains("?") || last.text.count > 40 {
                let s = Int(ctx.date.timeIntervalSince(last.ts))
                if s >= 4 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Пауза \(s) с — кандидат думает", systemImage: "hourglass").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        Text(s >= 10 ? "Можно помочь наводящим: «Давайте на конкретном примере из вашего последнего проекта» — или перейти к следующему вопросу."
                                     : "Не торопите. Если затянется — предложите: «Давайте на конкретном примере».")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

/// «Возможно, подсматривает в ИИ»: по оценкам ответов и по поведению — и чем это проверить.
struct AISuspicionCard: View {
    let score: Double
    let reasons: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(score >= 2.3 ? "Похоже, отвечает с подсказками ИИ" : "Возможно, подсматривает в ИИ", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.callout.weight(.semibold)).foregroundStyle(.purple)
            ForEach(reasons, id: \.self) { Text("•  " + $0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Проверьте: попросите личный случай с деталями — когда, кто, что пошло не так; переспросите деталь из его же ответа; попросите рассуждать вслух.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.purple.opacity(0.35)))
    }
}

struct ProbeRow: View {
    let p: Probe
    let big: Bool

    var body: some View {
        let tint = Theme.verdict(p.verdict)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(Verdict.title(p.verdict)).font(.caption.weight(.semibold)).foregroundStyle(tint)
                if let m = p.mastery { Text("· в теме \(m)/5").font(.caption).foregroundStyle(MasteryBar.color(Double(m))) }
                Spacer(minLength: 0)
                Text(p.ts.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(p.gist).font(big ? .callout : .caption).fixedSize(horizontal: false, vertical: true)
            if big, let st = p.stats, !st.markers.isEmpty { Markers(stats: st) }
            if let ai = p.ai, ai >= 2 { Text("похоже на зачитанное" + ((p.aiWhy ?? "").isEmpty ? "" : ": " + p.aiWhy!)).font(.caption2).foregroundStyle(.purple) }
            if !p.followup.isEmpty, !big {
                Text((p.used ? "✓ " : "→ ") + p.followup).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(big ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct NextQuestionCard: View {
    @EnvironmentObject var app: AppState
    let q: PlanQuestion

    var body: some View {
        let tint = Theme.kind(q.kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("СЛЕДУЮЩИЙ ВОПРОС").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(Verdict.kind(q.kind)).chip(tint)
                Spacer(minLength: 0)
            }
            Text(q.text).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !q.purpose.isEmpty {
                Label((q.kind == "person" ? "Скрытая цель: " : "Проверяем: ") + q.purpose, systemImage: q.kind == "person" ? "eye.slash" : "scope")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !q.listen.isEmpty {
                Label(q.listen, systemImage: "ear").font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SoftButton(title: "Задан", icon: "checkmark") { app.togglePlanQuestion(q.id) }
                SoftButton(title: "Позже", icon: "arrow.uturn.right") { app.skipPlanQuestion(q.id) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.3)))
    }
}

/// Компактное окно поверх звонка: уточнение, если есть, иначе следующий вопрос карты.
struct CompactProbe: View {
    @EnvironmentObject var app: AppState
    let iv: Interview

    var body: some View {
        if let p = iv.probes.last, !p.followup.isEmpty, !p.used, !p.dismissed {
            let tint = Theme.verdict(p.verdict)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("ДОЗАДАЙТЕ").font(.caption2.weight(.bold)).foregroundStyle(tint)
                    Spacer()
                    Button { app.markProbe(p.id, used: true) } label: { Image(systemName: "checkmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { app.markProbe(p.id, used: false) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Text(p.followup).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.7), lineWidth: 2))
        } else if let q = app.nextPlanQuestion {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("СЛЕДУЮЩИЙ: " + Verdict.kind(q.kind).uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.kind(q.kind))
                    Spacer()
                    Button { app.togglePlanQuestion(q.id) } label: { Image(systemName: "checkmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Задан")
                }
                Text(q.text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}

// MARK: Оценка и матрица компетенций

struct ReportPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if app.evaluating {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(app.evalNote).foregroundStyle(.secondary) }
                }
                if let r = app.interview?.report {
                    ReportBody(r: r)
                } else if !app.evaluating {
                    Hint(icon: "chart.bar.doc.horizontal", text: app.recordingID == app.selectedID
                         ? "Оценка появится, когда вы остановите запись: матрица компетенций, соответствие вакансии и портрет кандидата."
                         : "Оценки пока нет.")
                }
                if let m = app.selected, app.recordingID != m.id, !app.evaluating, app.llmReady, app.turns.count >= 4 {
                    HStack(spacing: 8) {
                        SoftButton(title: app.interview?.report == nil ? "Оценить кандидата" : "Пересобрать", icon: "arrow.clockwise") { Task { await app.evaluateInterview(m.id) } }
                        if app.interview?.report != nil {
                            SoftButton(title: app.copiedNote.isEmpty ? "Копировать" : app.copiedNote, icon: app.copiedNote.isEmpty ? "doc.on.doc" : "checkmark") { app.copyReport() }
                            SoftButton(title: "В Word", icon: "doc.richtext") { app.exportReportToWord() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
    }
}

struct ReportBody: View {
    let r: InterviewReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.line, lineWidth: 7)
                    Circle().trim(from: 0, to: Double(r.fit) / 100).stroke(Theme.fit(r.fit), style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(r.fit)%").font(.system(size: 19, weight: .bold))
                }
                .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Соответствие вакансии").font(.caption).foregroundStyle(.secondary)
                    Text(Verdict.hire(r.verdict)).font(.headline).foregroundStyle(Theme.fit(r.fit))
                    if !r.deep { Text("Оценила основная модель").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Text(r.summary).font(.callout).fixedSize(horizontal: false, vertical: true)

            Text("МАТРИЦА КОМПЕТЕНЦИЙ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(r.competencies) { c in CompetencyRow(c: c) }
            }

            if !r.portrait.isEmpty {
                Text("ПОРТРЕТ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(r.portrait).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let ig = r.integrity, ig.level != "none" {
                VStack(alignment: .leading, spacing: 6) {
                    Label("САМОСТОЯТЕЛЬНОСТЬ ОТВЕТОВ", systemImage: "eye.trianglebadge.exclamationmark").font(.caption2.weight(.bold)).foregroundStyle(.purple)
                    Text(ig.title).font(.headline).foregroundStyle(ig.level == "low" ? Color.orange : Color.purple)
                    ForEach(ig.signs, id: \.self) { Text("•  " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let b = r.business { BusinessBlock(b: b) }
            ReportList(title: "Сильные стороны", icon: "plus.circle.fill", color: .green, items: r.strengths)
            ReportList(title: "Риски", icon: "exclamationmark.triangle.fill", color: .orange, items: r.risks)
            ReportList(title: "Расхождения", icon: "arrow.left.arrow.right", color: .red, items: r.mismatches)
            ReportList(title: "Проверить дальше", icon: "arrow.forward.circle", color: Theme.accent, items: r.nextSteps)
        }
    }
}

struct CompetencyRow: View {
    let c: Competency

    var body: some View {
        let low = c.confidence == "low"
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.callout.weight(.semibold))
                    if !c.requirement.isEmpty, c.requirement != c.name { Text(c.requirement).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(i <= c.score ? Self.color(c.score).opacity(low ? 0.45 : 1) : Theme.line)
                            .frame(width: 16, height: 9)
                    }
                }
                Text("\(c.score)").font(.callout.weight(.bold).monospacedDigit()).frame(width: 14)
            }
            if !c.evidence.isEmpty {
                Text(c.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if low { Text("мало данных — стоит проверить ещё").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(10)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func color(_ s: Int) -> Color { s >= 4 ? .green : (s == 3 ? .blue : (s == 2 ? .orange : .red)) }
}

struct ReportList: View {
    let title: String
    let icon: String
    let color: Color
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                ForEach(items, id: \.self) { Text("•  " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

// MARK: Настройки: глубокая модель

struct DeepModelRow: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Глубокая модель для подготовки и оценки").font(.subheadline.weight(.medium)).padding(.top, 4)
            if !app.deepFits {
                Text("Gemma 4 26B требует от 32 ГБ памяти. На этом Mac карта вопросов и оценка идут на основной модели — работать будет, но проще.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if app.deepModelReady {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Gemma 4 26B готова").font(.callout)
                    if !app.deepStatus.isEmpty { Text("· " + app.deepStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            } else if app.deepDownloading {
                ProgressView(value: app.deepProgress).tint(Theme.accent)
                Text("Скачиваю: \(Int(app.deepProgress * 100))%. Если связь оборвётся — нажмите «Скачать» снова, загрузка продолжится.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let size = app.deepItems.filter { $0.state != .ready }.reduce(Int64(0)) { $0 + $1.size }
                HStack {
                    Text("Gemma 4 26B (MoE): думает глубже, а работает почти так же быстро — активна лишь часть сети.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Скачать — \(gigabytes(size))") { app.downloadDeepModel() }.disabled(app.downloading)
                }
                if app.freeDiskBytes < size + 2_000_000_000 {
                    Text("Мало места на диске: свободно \(gigabytes(app.freeDiskBytes)).").font(.caption).foregroundStyle(.red)
                }
                ForEach(app.deepItems) { m in
                    if case .failed(let e) = m.state { Text("\(m.title): \(e)").font(.caption).foregroundStyle(.red).lineLimit(2) }
                }
            }
        }
    }
}

/// «Бизнес-логика»: как кандидат думает внутри задачи — по кейсам и ответам «как бы вы сделали».
struct BusinessBlock: View {
    let b: BusinessThinking

    var body: some View {
        let c = CompetencyRow.color(b.score)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label("БИЗНЕС-ЛОГИКА", systemImage: "point.3.connected.trianglepath.dotted").font(.caption2.weight(.bold)).foregroundStyle(.indigo)
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2.5).fill(i <= b.score ? c.opacity(b.confidence == "low" ? 0.45 : 1) : Theme.line).frame(width: 16, height: 9)
                    }
                }
                Text("\(b.score)").font(.callout.weight(.bold).monospacedDigit())
            }
            Text(b.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !b.approach.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Как рассуждал").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(b.approach.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). " + step).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !b.gaps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Что упустил").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(b.gaps, id: \.self) { Text("•  " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if b.confidence == "low" { Text("кейсов было мало — стоит дать задачу на следующем этапе").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
