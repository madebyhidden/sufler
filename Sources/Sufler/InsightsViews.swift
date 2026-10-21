import Charts
import SwiftUI

// MARK: Статистика

struct StatsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        // Сводку считаем при открытии экрана: это несколько запросов к базе, не на каждый кадр
        let u = app.usageSummary()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Статистика").font(.system(size: 22, weight: .semibold))
                    Text("Всё посчитано на этом Mac. Наружу ничего не уходит, если вы не разрешили отправку анонимной статистики.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    StatTile(icon: "text.bubble", title: "Встреч", value: "\(u.meetings)", note: String(format: "%.1f ч записи", u.recordedHours))
                    StatTile(icon: "text.word.spacing", title: "Слов расшифровано", value: Self.big(u.words), note: "речь вас и собеседников")
                    StatTile(icon: "questionmark.bubble", title: "Вопросов найдено", value: "\(u.questions)", note: "из них к вам: \(u.questionsForMe)")
                    StatTile(icon: "sparkles", title: "Модель обработала", value: Self.big(u.llmIn + u.llmOut) + " ток.", note: "прочла \(Self.big(u.llmIn)), написала \(Self.big(u.llmOut))")
                    StatTile(icon: "lightbulb", title: "Фактов в базе", value: "\(u.facts)", note: "документов: \(u.documents)")
                    StatTile(icon: "square.stack.3d.up", title: "Фрагментов для поиска", value: "\(u.chunks)", note: String(format: "база %.1f МБ, звук %.0f МБ", u.databaseMB, u.audioMB))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Активность за 30 дней").font(.headline)
                    Chart(u.days, id: \.day) { d in
                        BarMark(x: .value("День", d.day, unit: .day), y: .value("Минут записи", d.minutes))
                            .foregroundStyle(Theme.accent.gradient)
                            .cornerRadius(3)
                    }
                    .chartYAxisLabel("минут записи")
                    .frame(height: 180)
                    HStack {
                        Text("Слов за 30 дней: \(Self.big(u.days.map(\.words).reduce(0, +)))")
                        Spacer()
                        Text("Вопросов в чат: \(u.chatQuestions)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .card(14)

                HStack(spacing: 12) {
                    Image(systemName: app.telemetryConsent == "yes" ? "checkmark.shield.fill" : "lock.shield.fill")
                        .font(.title2).foregroundStyle(app.telemetryConsent == "yes" ? Color.green : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.telemetryConsent == "yes" ? "Вы помогаете улучшать Суфлёр" : "Статистика не отправляется").fontWeight(.semibold)
                        Text(app.telemetryConsent == "yes"
                             ? "Раз в день уходят только счётчики: сколько минут записи, слов, вопросов. Без текстов, звука и имён."
                             : "Всё остаётся на этом Mac. Можно включить в настройках, раздел «Конфиденциальность».")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Настройки") { app.settingsPane = "privacy"; app.showSettings = true }
                }
                .padding(14)
                .card(14)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
    }

    /// 12 345 → «12,3 тыс.»
    static func big(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f млн", Double(n) / 1e6) }
        if n >= 10_000 { return String(format: "%.1f тыс.", Double(n) / 1e3) }
        return "\(n)"
    }
}

struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(14)
    }
}

// MARK: Согласие на отправку статистики

struct ConsentSheet: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Помочь сделать Суфлёр лучше?").font(.title3.weight(.semibold))
                    Text("Решать вам. Без согласия ничего не отправляется — совсем.").foregroundStyle(.secondary)
                }
            }
            ConsentList(title: "Если разрешите, раз в день уйдёт только это:", icon: "checkmark.circle.fill", color: .green, items: [
                "случайный номер установки — чтобы понимать, сколько людей пользуется;",
                "версия приложения, macOS и объём памяти;",
                "счётчики за день: минуты записи, число встреч, слов, найденных вопросов, токенов модели.",
            ])
            ConsentList(title: "Никогда не отправляется:", icon: "xmark.circle.fill", color: .red, items: [
                "звук, расшифровки, итоги, заметки, вопросы и ответы;",
                "имена, факты, документы и всё из базы знаний;",
                "что-либо, если вы нажмёте «Не отправлять».",
            ])
            Text("Решение можно поменять в любой момент: Настройки → Конфиденциальность. Там же видно, что именно уходит.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Не отправлять") { app.setTelemetry(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Разрешить анонимную статистику") { app.setTelemetry(true) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }
}

struct ConsentList: View {
    let title: String
    let icon: String
    let color: Color
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.semibold)
            ForEach(items, id: \.self) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon).foregroundStyle(color).font(.callout)
                    Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Отзыв

struct FeedbackSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Отзыв о Суфлёре").font(.title3.weight(.semibold))
            if app.feedbackSent {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                    Text("Спасибо! Отзыв сохранён.").fontWeight(.semibold)
                    Text(Telemetry.enabled ? "Он уже отправлен или уйдёт, как только появится интернет." : "Он уйдёт разработчику, как только в приложении появится канал отправки, — обновление придёт само.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Закрыть") { app.feedbackSent = false; dismiss() }.keyboardShortcut(.defaultAction).padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                Picker("", selection: app.binding(\.feedbackKind)) {
                    Text("Идея").tag("idea")
                    Text("Ошибка").tag("bug")
                    Text("Другое").tag("other")
                }
                .pickerStyle(.segmented).labelsHidden()
                ZStack(alignment: .topLeading) {
                    if app.feedbackText.isEmpty {
                        Text(app.feedbackKind == "bug" ? "Что произошло и что вы ожидали? Если можно — что делали перед этим." : "Что добавить или улучшить?")
                            .foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: app.binding(\.feedbackText)).scrollContentBackground(.hidden).padding(2)
                }
                .frame(height: 140)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
                TextField("Как с вами связаться (необязательно): Telegram, почта", text: app.binding(\.feedbackContact)).textFieldStyle(.roundedBorder)
                Toggle("Приложить версию приложения, macOS и объём памяти", isOn: app.binding(\.feedbackAttach))
                Text("Тексты встреч, звук и база знаний к отзыву не прикладываются.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Отправить") {
                        app.submitFeedback(kind: app.feedbackKind, text: app.feedbackText, contact: app.feedbackContact, attachInfo: app.feedbackAttach)
                        app.feedbackText = ""
                        app.feedbackSent = true
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

extension AppState {
    /// Привязка к полю состояния — вместо локального состояния вида, которое в этой сборке недоступно.
    func binding<T>(_ path: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: path] }, set: { self[keyPath: path] = $0 })
    }
}
