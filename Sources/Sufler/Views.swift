import SwiftUI

enum Theme {
    /// Режим собеседований узнаётся с одного взгляда: вместо фиолетовой — сине-зелёная «петроль» палитра
    static var interview: Bool { UserDefaults.standard.string(forKey: "appMode") == "interview" }
    static var accent: Color { interview ? Color(red: 0.0, green: 0.53, blue: 0.6) : Color(red: 0.36, green: 0.34, blue: 0.92) }
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let soft = Color.primary.opacity(0.055)
    static let line = Color.primary.opacity(0.08)
    /// Цвет карточки, когда вопрос адресован владельцу
    static let alert = Color(red: 0.96, green: 0.36, blue: 0.22)

    /// Цвет подписи для каждого голоса, чтобы собеседников было видно с одного взгляда.
    static let voices: [Color] = [.teal, .orange, .pink, .green, .purple, .brown]
    static func voice(_ n: Int) -> Color { n == 0 ? .secondary : voices[(n > 0 ? n - 1 : 1 - n) % voices.count] }
}

extension View {
    func card(_ radius: CGFloat = 18) -> some View {
        self
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.line))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    func chip(_ color: Color = .secondary) -> some View {
        self
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.showSetup { SetupView() } else if app.compact { CompactView() } else { main }
    }

    private var main: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            Group {
                if app.showStats { StatsView() } else if app.showKB { if app.interviewMode { LibraryView() } else { KnowledgeView() } } else if let m = app.selected { if m.isInterview { InterviewView() } else { MeetingView() } } else { EmptyState() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { if let name = app.callOffer { CallOfferBanner(name: name).padding(.top, 10) } }
            .background(Theme.page)
            // Содержимое поднимаем в зону заголовка окна, чтобы сверху не оставалась пустая полоса
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .navigationTitle("")
        .sheet(isPresented: $app.showSettings) { SettingsView().environmentObject(app) }
        .sheet(isPresented: $app.showUpdate) { UpdateSheet().environmentObject(app) }
        .sheet(isPresented: $app.showFeedback) { FeedbackSheet().environmentObject(app) }
        .sheet(isPresented: $app.showConsent) { ConsentSheet().environmentObject(app) }
        .sheet(isPresented: Binding(get: { app.renamingVoice != nil }, set: { if !$0 { app.renamingVoice = nil } })) {
            RenameVoiceSheet().environmentObject(app)
        }
        .tint(Theme.accent)
    }
}

/// «Похоже, начался звонок»: предложение начать запись.
struct CallOfferBanner: View {
    @EnvironmentObject var app: AppState
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.arrow.down.left.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Похоже, начался звонок").fontWeight(.semibold)
                Text("\(name) включил микрофон").font(.caption).foregroundStyle(.secondary)
            }
            Button { app.callOffer = nil; if !app.isRecording { app.toggleRecording() } } label: {
                Text("Начать запись").fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7).background(Theme.accent, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { app.callOffer = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

// MARK: Компактный режим

/// Маленькое окно поверх всех: две последние реплики и последний вопрос — чтобы держать рядом со звонком.
struct CompactView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if app.isRecording, let m = app.meetings.first(where: { $0.id == app.recordingID }) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(m.startedAt)))
                        Label(String(format: "%02d:%02d", s / 60, s % 60), systemImage: "record.circle.fill").chip(.red)
                    }
                } else {
                    Text("Суфлёр").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if app.isRecording {
                    Button { app.toggleMic() } label: {
                        Image(systemName: app.micMuted ? "mic.slash.fill" : "mic.fill").foregroundStyle(app.micMuted ? Color.orange : Color.secondary)
                            .frame(width: 28, height: 28).background(Theme.soft, in: Circle()).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(app.micMuted ? "Включить микрофон" : "Выключить микрофон")
                }
                Button { app.toggleRecording() } label: {
                    Image(systemName: app.isRecording ? "stop.fill" : "mic.fill").foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(app.isRecording ? Color.red : Theme.accent, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(!app.asrReady).help(app.isRecording ? "Остановить запись" : "Начать запись")
                Button { app.toggleCompact() } label: {
                    Image(systemName: "pip.exit").foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).background(Theme.soft, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Вернуть обычное окно")
            }

            // Две последние реплики; у длинной показываем конец — там самое свежее
            let last = Array(app.turns.suffix(2))
            if last.isEmpty && app.partial.isEmpty {
                Text(app.isRecording ? "Слушаю…" : "Начните запись — здесь появятся последние реплики и вопрос.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(last) { t in CompactLine(name: app.label(t), text: t.text, color: Theme.voice(AppState.voiceKey(t)), live: false) }
            if app.selectedID == app.recordingID {
                ForEach([Speaker.them, .me], id: \.self) { sp in
                    if let p = app.partial[sp] { CompactLine(name: sp.rawValue, text: p, color: .secondary, live: true) }
                }
            }

            if let iv = app.interview, iv.meetingID == app.selectedID {
                CompactProbe(iv: iv)
            } else if !app.pendingQuestion.isEmpty {
                Text(app.pendingQuestion + " ▍").font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else if let q = app.lastQuestion {
                let tint = q.forMe ? Theme.alert : Theme.accent
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if q.forMe { Label("К ВАМ", systemImage: "bell.fill").font(.caption2.weight(.bold)).foregroundStyle(Theme.alert) }
                        if !q.addressee.isEmpty { Text("Кому: " + q.addressee).chip(tint) }
                        if !q.asker.isEmpty { Text(q.asker == Speaker.me.rawValue ? "спросил я" : q.asker).chip() }
                        Spacer(minLength: 0)
                        Text(q.ts.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(q.question).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !q.topic.isEmpty { Text("Тема: " + q.topic).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(q.forMe ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(q.forMe ? 0.8 : 0.3), lineWidth: q.forMe ? 2 : 1))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 30).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.page)
    }
}

struct CompactLine: View {
    let name: String
    let text: String
    let color: Color
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(color)
            Text(text.count > 190 ? "…" + text.suffix(190) : text).font(.callout).foregroundStyle(live ? .secondary : .primary)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct EmptyState: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if app.interviewMode { InterviewEmptyState() } else { classic }
    }

    private var classic: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 46, weight: .light)).foregroundStyle(Theme.accent)
            Text("Встреч пока нет").font(.title2.weight(.semibold))
            Text("Начните запись — Суфлёр расшифрует разговор,\nпокажет последний вопрос и кому он адресован.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            RecordButton().padding(.top, 4)
        }
    }
}

// MARK: Боковая панель

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // В режиме собеседований вместо базы знаний — вакансии и резюме кандидатов
            Button { app.showStats = false; if app.interviewMode { app.openLibrary() } else { app.showKB = true } } label: {
                HStack(spacing: 9) {
                    Image(systemName: app.interviewMode ? "briefcase.fill" : "books.vertical.fill").foregroundStyle(app.showKB ? Color.white : Theme.accent).frame(width: 18)
                    Text(app.interviewMode ? "Вакансии и резюме" : "База знаний").fontWeight(.medium)
                    Spacer()
                    let n = app.interviewMode ? app.vacancies.count : app.documents.count
                    if n > 0 { Text("\(n)").font(.caption).opacity(0.7) }
                }
                .foregroundStyle(app.showKB && !app.showStats ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(app.showKB && !app.showStats ? Theme.accent : Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)

            // Запись можно начать из любого места, не выбирая встречу. Собеседование сначала готовят
            Button { if app.interviewMode && !app.isRecording { app.newInterview() } else { app.toggleRecording() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: app.isRecording ? "stop.fill" : (app.interviewMode ? "person.badge.plus" : "mic.fill")).frame(width: 18)
                    Text(app.isRecording ? "Остановить запись" : (app.interviewMode ? "Новое собеседование" : "Начать запись")).fontWeight(.medium)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background((app.isRecording ? Color.red : Theme.accent).opacity(app.asrReady ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).disabled(!app.asrReady)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)

            List(selection: Binding(get: { app.showKB ? nil : app.selectedID }, set: { app.select($0) })) {
                Section(app.interviewMode ? "Собеседования" : "Встречи") {
                    ForEach(app.modeMeetings) { m in
                        HStack(spacing: 9) {
                            Image(systemName: app.recordingID == m.id ? "record.circle.fill" : (m.isInterview ? "person.text.rectangle" : "text.bubble"))
                                .foregroundStyle(app.recordingID == m.id ? Color.red : Color.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).lineLimit(1)
                                Text(m.startedAt.formatted(.dateTime.day().month().hour().minute()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(m.id)
                        .contextMenu {
                            Button(m.isInterview ? "Удалить собеседование" : "Удалить встречу", role: .destructive) { app.delete(m.id) }
                                .disabled(app.recordingID == m.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 7) {
                StatusRow(ok: app.asrReady, failed: app.asrFailed, text: app.asrStatus)
                StatusRow(ok: app.llmReady, failed: app.llmFailed, text: app.llmStatus)
                if app.interviewMode, !app.deepStatus.isEmpty {
                    StatusRow(ok: app.deepClient != nil, failed: app.deepStatus.contains("не "), text: app.deepStatus)
                }
                if let u = app.updateInfo {
                    Button { app.updatePhase = .idle; app.showUpdate = true } label: {
                        Label("Обновление \(u.version)", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Theme.accent, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).padding(.top, 2)
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Label("Всё локально", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { app.showStats = true } label: { Image(systemName: "chart.bar.xaxis").font(.body) }
                        .buttonStyle(.plain).foregroundStyle(app.showStats ? Theme.accent : Color.secondary).help("Статистика")
                    Button { app.showFeedback = true } label: { Image(systemName: "bubble.left.and.exclamationmark.bubble.right").font(.body) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Отзыв или сообщение об ошибке")
                    Button { app.toggleCompact() } label: { Image(systemName: "pip.enter").font(.body) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Компактный режим: маленькое окно поверх всех")
                    Button { app.showSettings = true } label: { Image(systemName: "gearshape").font(.body) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Настройки")
                }
            }
            .padding(12)
        }
    }
}

struct StatusRow: View {
    let ok: Bool
    let failed: Bool
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if ok {
                    Circle().fill(.green).frame(width: 8, height: 8)
                } else if failed {
                    Circle().fill(.red).frame(width: 8, height: 8)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 14)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Встреча

struct RecordButton: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Button { app.toggleRecording() } label: {
            HStack(spacing: 8) {
                Image(systemName: app.isRecording ? "stop.fill" : "mic.fill")
                Text(app.isRecording ? "Остановить" : (app.selected?.isInterview == true ? "Начать собеседование" : "Начать запись")).fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(app.isRecording ? Color.red : Theme.accent, in: Capsule())
            .opacity(app.asrReady ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!app.asrReady)
        .keyboardShortcut("r", modifiers: .command)
        .help("⌘R")
    }
}

struct MeetingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 14) {
            Header()
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
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    TranscriptCard()
                    NotesCard().frame(height: 170)
                }
                .frame(minWidth: 380, maxWidth: .infinity)
                SideCard().frame(width: 390)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 14)
    }
}

struct Header: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Название встречи", text: Binding(get: { app.selected?.title ?? "" }, set: { app.setTitle($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    if let m = app.selected {
                        Text(m.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month())).chip()
                        if app.recordingID == m.id, app.isRecording {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Label(elapsed(from: m.startedAt, to: ctx.date), systemImage: "record.circle.fill").chip(.red)
                            }
                        } else if let end = m.endedAt {
                            Text(m.startedAt.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)).chip()
                        }
                    }
                }
            }
            Spacer(minLength: 10)
            if app.isRecording, app.selectedID == app.recordingID {
                Button { app.toggleMic() } label: {
                    Label(app.micMuted ? "Включить микрофон" : "Выключить микрофон", systemImage: app.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(app.micMuted ? Color.white : Color.primary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(app.micMuted ? Color.orange : Theme.soft, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(app.micMuted ? "Сейчас пишется только звук звонка" : "Писать только звук звонка, без вашего голоса")
            }
            Button { app.toggleCompact() } label: {
                Image(systemName: "pip.enter").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36).background(Theme.soft, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).help("Компактный режим: маленькое окно поверх всех")
            RecordButton()
        }
    }

    private func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct CardTitle: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct TranscriptCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CardTitle(icon: "text.quote", text: "Расшифровка")
                Spacer()
                if app.isRecording, app.selectedID == app.recordingID {
                    LevelDot(label: "Я", level: app.levels[.me] ?? 0)
                    LevelDot(label: "Звонок", level: app.levels[.them] ?? 0)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    // Обычный VStack: ленивый при автопрокрутке к концу временами оставлял панель пустой
                    VStack(spacing: 8) {
                        if app.turns.isEmpty && app.partial.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: app.isRecording ? "ear" : "text.bubble").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                                Text(app.isRecording ? "Слушаю…" : "Здесь появится текст разговора").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        // На экране держим только последние реплики: вся долгая встреча разом тормозит прокрутку
                        let hidden = max(0, app.turns.count - app.shownTurns)
                        if hidden > 0 {
                            Button { app.shownTurns += 200 } label: {
                                Text("Показать более ранние реплики (\(hidden))").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.accent.opacity(0.12), in: Capsule()).contentShape(Capsule())
                            }
                            .buttonStyle(.plain).padding(.bottom, 4)
                        }
                        let audio = app.selectedHasAudio
                        ForEach(app.turns.suffix(app.shownTurns)) { t in
                            let key = AppState.voiceKey(t)
                            Bubble(speaker: t.speaker, text: t.text, time: t.ts, live: false, voice: key, name: app.label(t),
                                   canPlay: audio && t.audioEnd > t.audioStart, playing: app.playingTurnID == t.id,
                                   onPlay: { app.play(t) },
                                   onRename: { app.renameText = app.voiceNames[key] ?? ""; app.renamingVoice = key })
                                .equatable()
                        }
                        if app.selectedID == app.recordingID {
                            ForEach([Speaker.them, .me], id: \.self) { sp in
                                if let p = app.partial[sp] { Bubble(speaker: sp, text: p, time: nil, live: true, voice: 0, name: sp.rawValue).equatable() }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: app.turns.count) { _, _ in if app.followPausedUntil == nil { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end") } } }
                .onChange(of: app.turns.last?.text) { _, _ in if app.followPausedUntil == nil { proxy.scrollTo("end") } }
                .onChange(of: app.partial) { _, _ in if app.followPausedUntil == nil { proxy.scrollTo("end") } }
                .onChange(of: app.selectedID) { _, _ in proxy.scrollTo("end") }
                .onChange(of: app.scrollTick) { _, _ in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end") } }
                .background(ScrollWatcher { app.userScrolled() })
                .overlay(alignment: .bottomTrailing) {
                    if let until = app.followPausedUntil { FollowButton(until: until).padding(14) }
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

/// Ловит прокрутку колесом или трекпадом над расшифровкой.
struct ScrollWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? WatcherView)?.onScroll = onScroll }

    final class WatcherView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, event.scrollingDeltaY != 0,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onScroll?()
                }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Кнопка «вниз» с кольцом-таймером: показывает, через сколько расшифровка сама вернётся к последней реплике.
struct FollowButton: View {
    @EnvironmentObject var app: AppState
    let until: Date

    var body: some View {
        Button { app.resumeFollow() } label: {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let left = max(0, min(1, until.timeIntervalSince(ctx.date) / 10))
                ZStack {
                    Circle().fill(Theme.card)
                    Circle().stroke(Theme.line, lineWidth: 3)
                    Circle().trim(from: 0, to: left).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("К последней реплике")
    }
}

struct LevelDot: View {
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(level > 0.02 ? Color.green : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
    }
}

/// Реплика в расшифровке. Вид нарочно не подписан на общее состояние приложения и сравнивается по значениям:
/// иначе при каждом изменении (черновик фразы, индикатор звука, очередной кусочек ответа модели) SwiftUI
/// заново пересчитывал бы все реплики встречи, и на долгой встрече интерфейс начинал тормозить.
struct Bubble: View, Equatable {
    let speaker: Speaker
    let text: String
    let time: Date?
    let live: Bool
    let voice: Int
    let name: String
    var canPlay = false
    var playing = false
    var onPlay: () -> Void = {}
    var onRename: () -> Void = {}

    static func == (a: Bubble, b: Bubble) -> Bool {
        a.text == b.text && a.name == b.name && a.voice == b.voice && a.speaker == b.speaker && a.live == b.live
            && a.time == b.time && a.canPlay == b.canPlay && a.playing == b.playing
    }

    var body: some View {
        let me = speaker == .me && voice == 0
        HStack(spacing: 0) {
            if me { Spacer(minLength: 50) }
            VStack(alignment: me ? .trailing : .leading, spacing: 3) {
                if !me {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.voice(voice)).frame(width: 7, height: 7)
                        Text(name).font(.caption.weight(.semibold)).foregroundStyle(Theme.voice(voice))
                    }
                    .padding(.horizontal, 4)
                }
                Text(text)
                    .foregroundStyle(live ? .secondary : .primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(me ? Theme.accent.opacity(0.13) : Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 4) {
                    if me { Text(name).fontWeight(.medium) }
                    if let time { Text(time.formatted(date: .omitted, time: .shortened)) }
                    if live { Text("…") }
                    if canPlay {
                        Button(action: onPlay) {
                            Image(systemName: playing ? "stop.circle.fill" : "play.circle").font(.system(size: 13))
                                .foregroundStyle(playing ? Theme.accent : Color.secondary)
                        }
                        .buttonStyle(.plain).help(playing ? "Остановить" : "Переслушать эту реплику")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
            .contextMenu {
                if canPlay { Button(playing ? "Остановить" : "Переслушать", action: onPlay) }
                if !me, voice != 0 { Button("Назвать «\(name)» по имени…", action: onRename) }
            }
            if !me { Spacer(minLength: 50) }
        }
    }
}

struct RenameVoiceSheet: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Как зовут этого собеседника?").font(.headline)
            Text("Имя появится во всех его репликах этой встречи, и Суфлёр будет учитывать его в вопросах и итоге.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Имя", text: $app.renameText).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Отмена") { app.renamingVoice = nil }.keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        if let v = app.renamingVoice { app.renameVoice(v, to: app.renameText) }
        app.renamingVoice = nil
    }
}

struct NotesCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(icon: "pencil.line", text: "Заметки").padding(.horizontal, 16).padding(.top, 12)
            ZStack(alignment: .topLeading) {
                if (app.selected?.notes ?? "").isEmpty {
                    Text("Пишите по ходу встречи — заметки попадут в итог и в поиск.")
                        .foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { app.selected?.notes ?? "" }, set: { app.setNotes($0) }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

// MARK: Правая панель

struct SideCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TabPill(title: "Вопрос", icon: "questionmark.bubble", index: 0)
                TabPill(title: "Чат", icon: "sparkles", index: 1)
                TabPill(title: "Итог", icon: "list.bullet.rectangle", index: 2)
            }
            .padding(4)
            .background(Theme.soft, in: Capsule())
            .padding(12)
            Divider().opacity(0.5)
            switch app.tab {
            case 0: QuestionPanel()
            case 1: ChatPanel()
            default: SummaryPanel()
            }
        }
        .frame(maxHeight: .infinity)
        .card()
    }
}

struct TabPill: View {
    @EnvironmentObject var app: AppState
    let title: String
    let icon: String
    let index: Int

    var body: some View {
        let on = app.tab == index
        Button { app.tab = index } label: {
            Label(title, systemImage: icon)
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

struct Hint: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 70)
    }
}

struct QuestionPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !app.pendingQuestion.isEmpty {
                    Text("НОВЫЙ ВОПРОС").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                    Text(app.pendingQuestion + " ▍")
                        .font(.system(size: 18, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let q = app.lastQuestion {
                    HStack {
                        Text("ПОСЛЕДНИЙ ВОПРОС").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                        Spacer()
                        if app.detecting { ProgressView().controlSize(.mini) }
                    }
                    QuestionCard(q: q, big: true)
                    let older = Array(app.questions.dropLast().reversed())
                    if !older.isEmpty {
                        Text("РАНЬШЕ").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 8)
                        ForEach(older) { QuestionCard(q: $0, big: false) }
                    }
                } else if !app.llmReady {
                    Hint(icon: "hourglass", text: app.llmFailed ? app.llmStatus : "Языковая модель загружается. Вопросы начнут появляться, как только она будет готова.")
                } else if !app.pendingQuestion.isEmpty {
                    EmptyView()
                } else if app.detecting {
                    Hint(icon: "ellipsis.bubble", text: "Ищу вопрос в разговоре…")
                } else {
                    Hint(icon: "questionmark.bubble", text: "Здесь появится последний вопрос из разговора: кому он адресован и краткий контекст.")
                }
            }
            .padding(14)
        }
    }
}

struct QuestionCard: View {
    @EnvironmentObject var app: AppState
    let q: Question
    let big: Bool

    var body: some View {
        let tint = q.forMe ? Theme.alert : Theme.accent
        VStack(alignment: .leading, spacing: 10) {
            if q.forMe {
                Label("ВОПРОС К ВАМ", systemImage: "bell.fill").font(.caption.weight(.bold)).foregroundStyle(Theme.alert)
            }
            HStack(spacing: 6) {
                if !q.addressee.isEmpty {
                    Label("Кому: " + q.addressee, systemImage: "person.fill").chip(tint)
                }
                if !q.asker.isEmpty { Text(q.asker == Speaker.me.rawValue ? "спросил я" : "спросил: " + q.asker).chip() }
                Spacer(minLength: 0)
                Text(q.ts.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
            Text(q.question)
                .font(big ? .system(size: 18, weight: .semibold) : .callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !q.topic.isEmpty || !q.context.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.5)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 5) {
                        if !q.topic.isEmpty {
                            (Text("Тема: ").foregroundStyle(.secondary) + Text(q.topic).fontWeight(.semibold))
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if !q.context.isEmpty, big {
                            Text(q.context).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !q.answer.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Подсказка", systemImage: "lightbulb.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(.init(q.answer)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if big, app.llmReady {
                Button { app.suggestAnswer(for: q.id) } label: {
                    Label(app.answering ? "Думаю…" : (q.answer.isEmpty ? "Подсказать ответ" : "Обновить подсказку"), systemImage: "lightbulb")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(app.answering)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(q.forMe ? Theme.alert.opacity(big ? 0.13 : 0.08) : (big ? Theme.accent.opacity(0.07) : Theme.soft), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(q.forMe ? Theme.alert.opacity(big ? 0.8 : 0.4) : (big ? Theme.accent.opacity(0.35) : Color.clear), lineWidth: q.forMe && big ? 2 : 1))
        .textSelection(.enabled)
    }
}

struct ChatPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if app.chat.isEmpty {
                            Hint(icon: "sparkles", text: app.showKB ? "Спросите что-нибудь по фактам, документам и встречам.\nИли попросите: «запомни, что…», «исправь…», «удали факт про…», «проведи аудит фактов»." : "Спросите что-нибудь по этой встрече — отвечу по всей её расшифровке, итогу и заметкам.")
                        }
                        ForEach(app.chat) { line in
                            let user = line.role == "user"
                            HStack(spacing: 0) {
                                if user { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(.init(line.text.isEmpty ? "…" : Self.tidy(line.text)))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(user ? Theme.accent.opacity(0.13) : Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    if !line.ops.isEmpty { FactOpsView(line: line) }
                                    if !line.sources.isEmpty {
                                        VStack(alignment: .leading, spacing: 3) {
                                            ForEach(line.sources.prefix(4), id: \.self) { src in
                                                Label(src, systemImage: "doc.text").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        .padding(.horizontal, 6)
                                    }
                                }
                                if !user { Spacer(minLength: 40) }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: app.chat.last?.text) { _, _ in proxy.scrollTo("end") }
            }
            HStack(spacing: 8) {
                TextField(app.dictating ? "Говорите — после паузы вопрос отправится сам…" : (app.showKB ? "Вопрос по базе знаний…" : "Вопрос по этой встрече…"), text: $app.chatInput)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                Button { app.toggleDictation() } label: {
                    Image(systemName: app.dictating ? "mic.circle.fill" : "mic").font(.system(size: app.dictating ? 22 : 15))
                        .foregroundStyle(app.dictating ? Color.red : Color.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!app.asrReady || !app.llmReady || app.chatBusy)
                .help(app.dictating ? "Отменить диктовку" : "Задать вопрос голосом")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
            .background(Theme.soft, in: Capsule())
            .padding(12)
        }
    }

    /// Модель любит списки со звёздочками — показываем их аккуратными пунктами.
    static func tidy(_ text: String) -> String {
        text.components(separatedBy: "\n").map { raw -> String in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("* ") || t.hasPrefix("- ") { return "•  " + t.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            return raw
        }.joined(separator: "\n")
    }

    private var canSend: Bool {
        !app.chatBusy && app.llmReady && !app.chatInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        guard canSend else { return }
        app.ask(app.chatInput)
        app.chatInput = ""
    }
}

struct SummaryPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if app.summarizing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Составляю итог…").foregroundStyle(.secondary) }
                }
                if app.checkingNames {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Проверяю названия…").foregroundStyle(.secondary) }
                }
                if !app.nameChecks.isEmpty, app.recordingID != app.selectedID { NameChecksCard() }
                if let s = app.selected?.summary, !s.isEmpty {
                    // Одним текстом: так его можно выделить и скопировать целиком, а не по строчке
                    Text(Self.styled(s)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                } else if !app.summarizing {
                    Hint(icon: "list.bullet.rectangle", text: "Итог составляется автоматически после остановки записи: коротко, решения, задачи, открытые вопросы.")
                }
                if let m = app.selected, app.recordingID != m.id, !app.summarizing {
                    HStack(spacing: 8) {
                        if app.llmReady, app.turns.count >= 2 {
                            SoftButton(title: m.summary.isEmpty ? "Составить итог" : "Пересобрать", icon: "arrow.clockwise") { Task { await app.summarize(m.id) } }
                        }
                        if !m.summary.isEmpty {
                            SoftButton(title: app.copiedNote.isEmpty ? "Копировать" : app.copiedNote, icon: app.copiedNote.isEmpty ? "doc.on.doc" : "checkmark") { app.copySummary() }
                            SoftButton(title: "В Word", icon: "doc.richtext") { app.exportSummaryToWord() }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
    }
}

extension SummaryPanel {
    /// Итог в виде одного размеченного текста: заголовки полужирным, пункты с точками.
    static func styled(_ summary: String) -> AttributedString {
        var lines: [String] = []
        for raw in summary.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append("  •  " + line.dropFirst(2).trimmingCharacters(in: .whitespaces))
            } else {
                let heading = line.hasPrefix("#") || line.hasPrefix("**")
                while line.hasPrefix("#") { line.removeFirst() }
                line = line.trimmingCharacters(in: .whitespaces)
                if heading, !lines.isEmpty { lines.append("") }
                lines.append(line)
            }
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// «Проверьте названия»: слова, которые распознавание могло исковеркать. Ответы уходят в словарь.
struct NameChecksCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Проверьте названия", systemImage: "character.cursor.ibeam").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text("Эти слова могли распознаться неверно. Впишите, как правильно, — исправлю во встрече и запомню на будущее.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(app.nameChecks) { c in NameCheckRow(check: c) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct NameCheckRow: View {
    @EnvironmentObject var app: AppState
    let check: NameCheck

    var body: some View {
        // Поле ввода хранит своё значение в общем состоянии: локальное состояние вида в этой сборке недоступно
        let text = Binding(get: { app.checkInputs[check.id] ?? check.guess }, set: { app.checkInputs[check.id] = $0 })
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("«\(check.heard)»").fontWeight(.semibold)
                if let t = app.turns.first(where: { $0.id == check.turnID }), app.hasAudio(t) {
                    Button { app.playCheck(check) } label: {
                        Image(systemName: app.playingTurnID == check.turnID ? "stop.circle.fill" : "play.circle").foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain).help("Послушать, как это прозвучало")
                }
                Spacer(minLength: 0)
            }
            Text(check.quote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Как правильно", text: text).textFieldStyle(.roundedBorder)
                    .onSubmit { app.resolveCheck(check, right: text.wrappedValue) }
                Button("Исправить") { app.resolveCheck(check, right: text.wrappedValue) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Верно") { app.resolveCheck(check, right: check.heard) }.help("Слово записано правильно — больше не спрашивать")
            }
            .controlSize(.small)
        }
        .padding(9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct SoftButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.accent.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: База знаний

struct KnowledgeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("База знаний").font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 6) {
                        Text("Фактов: \(app.facts.count)").chip()
                        Text("Документов: \(app.documents.count)").chip()
                        Text("Встреч: \(app.meetings.count)").chip()
                        if !app.kbStatus.isEmpty {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(app.kbStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
                Spacer(minLength: 10)
                Button { app.pickDocuments() } label: {
                    Label("Добавить файлы", systemImage: "plus").fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Theme.accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
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
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        KBTab(title: "Факты", icon: "lightbulb", count: app.facts.count, index: 0)
                        KBTab(title: "Документы", icon: "doc.on.doc", count: app.documents.count, index: 1)
                    }
                    .padding(4)
                    .background(Theme.soft, in: Capsule())
                    .padding(12)
                    Divider().opacity(0.5)
                    if app.kbTab == 0 {
                        if app.facts.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "lightbulb").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                                Text("Факты собираются сами после каждой встречи: цифры, решения, сроки, кто за что отвечает.\nИх можно добавлять и править через чат справа: «запомни, что…».")
                                    .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(app.facts) { f in FactRow(fact: f) }
                                }
                                .padding(12)
                            }
                        }
                    } else if app.documents.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                            Text("Перетащите сюда файлы или нажмите «Добавить файлы».\nPDF, Word, текст, Markdown — всё остаётся на этом Mac.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(app.documents) { d in DocRow(doc: d) }
                            }
                            .padding(12)
                        }
                    }
                }
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                .card()
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in app.addDocuments([url]) } }
                        }
                    }
                    return true
                }

                VStack(spacing: 0) {
                    HStack { CardTitle(icon: "sparkles", text: "Чат по базе"); Spacer() }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().opacity(0.5)
                    ChatPanel()
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .card()
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 14)
    }
}

struct KBTab: View {
    @EnvironmentObject var app: AppState
    let title: String
    let icon: String
    let count: Int
    let index: Int

    var body: some View {
        let on = app.kbTab == index
        Button { app.kbTab = index } label: {
            Label("\(title) · \(count)", systemImage: icon)
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

struct FactRow: View {
    @EnvironmentObject var app: AppState
    let fact: Fact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").font(.callout).foregroundStyle(Theme.accent).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.text).fixedSize(horizontal: false, vertical: true)
                if !fact.previous.isEmpty {
                    Text("Было: " + fact.previous).font(.caption).foregroundStyle(.secondary).strikethrough().fixedSize(horizontal: false, vertical: true)
                }
                Text(meta).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { app.deleteFact(fact.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Удалить факт")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textSelection(.enabled)
    }

    private var meta: String {
        var s = (fact.previous.isEmpty ? "добавлен " : "обновлён ") + fact.updatedAt.formatted(.dateTime.day().month())
        if let m = app.meetings.first(where: { $0.id == fact.meetingID }) { s += " · " + m.title } else if fact.meetingID == 0 { s += " · вручную" }
        return s
    }
}

struct FactOpsView: View {
    @EnvironmentObject var app: AppState
    let line: ChatLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(line.ops) { op in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: op.op == "delete" ? "minus.circle.fill" : (op.op == "add" ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill"))
                        .foregroundStyle(op.op == "delete" ? Color.red : (op.op == "add" ? Color.green : Color.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        if op.op == "delete" {
                            Text(op.old).strikethrough().fixedSize(horizontal: false, vertical: true)
                        } else {
                            if !op.old.isEmpty { Text(op.old).strikethrough().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            Text(op.text).fixedSize(horizontal: false, vertical: true)
                        }
                        if !op.reason.isEmpty { Text(op.reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .font(.caption)
            }
            if line.opsPending {
                HStack(spacing: 8) {
                    Button { app.applyProposal(line.id) } label: {
                        Text("Применить").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.accent, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { app.rejectProposal(line.id) } label: {
                        Text("Отклонить").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.soft, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct DocRow: View {
    @EnvironmentObject var app: AppState
    let doc: Doc

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: doc.title.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                .font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).lineLimit(1).truncationMode(.middle)
                Text("\(doc.addedAt.formatted(.dateTime.day().month())) · \(doc.chars / 1000 + 1) тыс. знаков").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { app.deleteDocument(doc.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Убрать из базы (сам файл не удаляется)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Настройки

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Разделы настроек — как в Системных настройках macOS: значок в цветном квадрате и название
    static let panes: [(id: String, title: String, icon: String, color: Color)] = [
        ("general", "Основное", "gearshape.fill", .gray),
        ("recording", "Запись", "record.circle.fill", .red),
        ("speech", "Распознавание", "waveform", .orange),
        ("models", "Модели", "cpu.fill", .blue),
        ("privacy", "Конфиденциальность", "hand.raised.fill", .indigo),
        ("about", "Обновления и отзыв", "arrow.down.circle.fill", .green),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.panes, id: \.id) { p in
                    let on = app.settingsPane == p.id
                    Button { app.settingsPane = p.id } label: {
                        HStack(spacing: 9) {
                            Image(systemName: p.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(p.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(p.title).foregroundStyle(on ? Color.white : Color.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(on ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Готово") { app.nameChanged(); dismiss() }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
            }
            .padding(10)
            .frame(width: 210)
            .background(Color.primary.opacity(0.04))

            Form { pane }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
    }

    @ViewBuilder private var pane: some View {
        switch app.settingsPane {
        case "recording": recording
        case "speech": speech
        case "models": models
        case "privacy": privacy
        case "about": about
        default: general
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
        Section {
            Picker("Режим", selection: Binding(get: { app.appMode }, set: { app.appMode = $0; app.modeChanged() })) {
                Text("Суфлёр встреч").tag("classic")
                Text("Суфлёр собеседований").tag("interview")
            }
            .disabled(app.isRecording)
            note(app.interviewMode
                 ? "Подготовка по вакансии и резюме, карта вопросов, уточнения по ходу разговора и оценка кандидата с матрицей компетенций."
                 : "Расшифровка встреч, последний вопрос, подсказки, итоги и база знаний.")
            if app.interviewMode { DeepModelRow() }
        }
        Section("О вас") {
            TextField("Моё имя", text: app.$myName, prompt: Text("Денис, Денис Иванов, Ден"))
            note("Имя, фамилия и то, как вас называют, — через запятую. Когда вопрос обращён к вам, карточка выделяется цветом и приходит уведомление.")
        }
        Section("Имена и термины") {
            TextEditor(text: app.$glossary).frame(height: 70).font(.body)
            note("Имена коллег, названия проектов — через запятую. Помогает правильно распознавать их и понимать, к кому обращён вопрос.")
        }
    }

    @ViewBuilder private var recording: some View {
        Section("Что записывать") {
            Toggle("Микрофон", isOn: app.$captureMic)
            Toggle("Звук звонка (системный звук)", isOn: app.$captureSystem)
            Picker("Останавливать запись после тишины", selection: app.$autoStopMinutes) {
                Text("Никогда").tag(0)
                Text("3 минуты").tag(3)
                Text("5 минут").tag(5)
                Text("10 минут").tag(10)
                Text("20 минут").tag(20)
                Text("30 минут").tag(30)
            }
        }
        Section("Звук встреч") {
            Toggle("Сохранять звук, чтобы переслушивать реплики", isOn: app.$keepAudio)
            note("Хранится только на этом Mac, около 15 МБ на час речи; записи старше 30 дней удаляются сами.")
        }
        Section("Начало звонка") {
            Toggle("Предлагать запись, когда начинается звонок", isOn: Binding(get: { app.watchCalls }, set: { app.watchCalls = $0; app.watchCallsChanged() }))
            TextField("Приложения", text: app.$watchApps, prompt: Text("Zoom, Telegram, Chrome…")).disabled(!app.watchCalls)
            note("Когда одно из этих приложений включает микрофон, Суфлёр покажет уведомление. Для звонков в браузере достаточно названия браузера.")
        }
    }

    @ViewBuilder private var speech: some View {
        Section("Распознавание речи") {
            Picker("Язык речи", selection: app.$language) {
                Text("Русский").tag("ru")
                Text("Английский").tag("en")
                Text("Определять автоматически").tag("auto")
            }
            LabeledContent("Модель", value: app.asrStatus)
        }
        Section("Словарь исправлений") {
            TextEditor(text: app.$corrections).frame(height: 110).font(.body)
            note("Строки вида «как услышано = как правильно». Пополняется сам, когда вы исправляете названия после встречи, и применяется сразу при распознавании.")
        }
    }

    @ViewBuilder private var models: some View {
        Section("Языковая модель") {
            LabeledContent("Сейчас", value: app.chatModelPath.isEmpty ? "Gemma 4 E4B (по умолчанию)" : URL(fileURLWithPath: app.chatModelPath).deletingPathExtension().lastPathComponent)
            HStack {
                Button("Выбрать свою модель GGUF…") { app.chooseChatModel() }
                if !app.chatModelPath.isEmpty { Button("Вернуть Gemma") { app.resetChatModel() } }
            }
            note("Суфлёр настроен и проверен на Gemma 4 E4B; своя модель может хуже находить вопросы.")
        }
        Section("Модели и разрешения") {
            LabeledContent("Распознавание", value: app.asrStatus)
            LabeledContent("Вопросы и итоги", value: app.llmStatus)
            LabeledContent("Поиск по базе", value: app.embedReady ? "Готов" : "Не запущен")
            Button("Открыть экран моделей и разрешений…") { app.reopenSetup() }
        }
    }

    @ViewBuilder private var privacy: some View {
        Section {
            Label("Звук, расшифровки, итоги, база знаний и модели — только на этом Mac. Распознавание и ответы работают без интернета.", systemImage: "lock.fill")
                .fixedSize(horizontal: false, vertical: true)
        }
        Section("Анонимная статистика") {
            Toggle("Отправлять анонимную статистику", isOn: Binding(get: { app.telemetryConsent == "yes" }, set: { app.setTelemetry($0) }))
            note("Раз в день — только счётчики: минуты записи, число встреч, слов, вопросов, токенов модели; версия приложения и macOS; случайный номер установки. Никогда — тексты, звук, имена и база знаний.")
            DisclosureGroup("Что именно отправится") {
                let json = (try? JSONSerialization.data(withJSONObject: app.telemetryPayload(), options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Text(json).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !Telemetry.enabled { note("Сейчас в этой версии канал отправки ещё не подключён — даже с согласием ничего не уходит.") }
        }
        Section("Данные") {
            Button("Показать папку с данными в Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.supportDir]) }
        }
    }

    @ViewBuilder private var about: some View {
        Section("Версия") {
            LabeledContent("Суфлёр", value: app.currentVersion)
            HStack {
                Button("Проверить обновления") { Task { await app.checkForUpdate(manual: true) } }
                Text(app.updateCheckNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Обратная связь") {
            Button("Написать отзыв или сообщить об ошибке…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showFeedback = true } }
            if app.pendingFeedback > 0 { note("Ждут отправки: \(app.pendingFeedback)") }
        }
    }
}
