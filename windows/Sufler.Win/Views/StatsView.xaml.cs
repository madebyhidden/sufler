using System.Windows;
using System.Windows.Controls;

namespace Sufler.Views;

/// <summary>Личная статистика: сколько записано, расшифровано и обработано моделью на этом компьютере.</summary>
public partial class StatsView : UserControl
{
    public sealed record Tile(string Glyph, string Title, string Value, string Note);
    public sealed record Bar(double Height, string Tip);

    /// <summary>Нажали «Настройки» в карточке конфиденциальности.</summary>
    public event Action? OpenPrivacy;

    public StatsView() => InitializeComponent();

    private static string Big(long n) => n >= 1_000_000 ? $"{n / 1e6:0.0} млн" : n >= 10_000 ? $"{n / 1e3:0.0} тыс." : n.ToString();

    /// <summary>Пересчитать при каждом открытии экрана: это несколько запросов к базе.</summary>
    public void Refresh()
    {
        var u = App.Core.UsageSummary();
        Tiles.ItemsSource = new[]
        {
            new Tile("", "Встреч", u.Meetings.ToString(), $"{u.RecordedHours:0.0} ч записи"),
            new Tile("", "Слов расшифровано", Big(u.Words), "речь вас и собеседников"),
            new Tile("", "Вопросов найдено", u.Questions.ToString(), $"из них к вам: {u.QuestionsForMe}"),
            new Tile("", "Модель обработала", Big(u.LlmIn + u.LlmOut) + " ток.", $"прочла {Big(u.LlmIn)}, написала {Big(u.LlmOut)}"),
            new Tile("", "Фактов в базе", u.Facts.ToString(), $"документов: {u.Documents}"),
            new Tile("", "Фрагментов для поиска", u.Chunks.ToString(), $"база {u.DatabaseMb:0.0} МБ, звук {u.AudioMb:0} МБ"),
        };
        double top = Math.Max(1, u.Days.Max(d => d.Minutes));
        Bars.ItemsSource = u.Days.Select(d => new Bar(Math.Max(2, 146 * d.Minutes / top), $"{d.Day:d MMMM}: {d.Minutes:0} мин, {d.Words} слов")).ToList();
        FirstDay.Text = u.Days[0].Day.ToString("d MMM", Ru.Culture);
        LastDay.Text = "сегодня";
        ChartNote.Text = $"Слов за 30 дней: {Big(u.Days.Sum(d => d.Words))} · вопросов в чат: {u.ChatQuestions}";
        bool yes = App.Core.TelemetryConsent == "yes";
        PrivacyIcon.Text = yes ? "" : "";
        PrivacyIcon.Foreground = (System.Windows.Media.Brush)FindResource(yes ? "Good" : "Accent");
        PrivacyTitle.Text = yes ? "Вы помогаете улучшать Суфлёр" : "Статистика не отправляется";
        PrivacyNote.Text = yes
            ? "Раз в день уходят только счётчики: сколько минут записи, слов, вопросов. Без текстов, звука и имён."
            : "Всё остаётся на этом компьютере. Можно включить в настройках, раздел «Конфиденциальность».";
    }

    private void OnPrivacy(object sender, RoutedEventArgs e) => OpenPrivacy?.Invoke();
}
