using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace Sufler.Views;

/// <summary>Компактный режим: две последние реплики и последний вопрос в маленьком окне поверх всех.</summary>
public partial class CompactView : UserControl
{
    private AppCore Core => App.Core;
    private readonly ObservableCollection<Turn> _lines = new();
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private Question? _watched;

    /// <summary>Нажали «вернуть обычное окно».</summary>
    public event Action? Expand;

    public CompactView()
    {
        InitializeComponent();
        Lines.ItemsSource = _lines;
        Loaded += (_, _) =>
        {
            Core.Turns.CollectionChanged += (_, _) => RefreshLines();
            Core.Partials.CollectionChanged += (_, _) => RefreshLines();
            Core.Questions.CollectionChanged += (_, _) => RefreshQuestion();
            Core.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName is nameof(AppCore.IsRecording) or nameof(AppCore.MicMuted)) RefreshButtons();
                if (e.PropertyName is nameof(AppCore.PendingQuestion)) RefreshQuestion();
                if (e.PropertyName is nameof(AppCore.Interview) or nameof(AppCore.NextPlanQuestion) or nameof(AppCore.Probing) or nameof(AppCore.Mastery)) RefreshInterview();
            };
            _tick.Tick += (_, _) =>
            {
                if (IsVisible && Core.Interview is not null) RefreshInterview();
                if (!Core.IsRecording || Core.Meetings.FirstOrDefault(m => m.Id == Core.RecordingId) is not { } m) return;
                int s = Math.Max(0, (int)(DateTime.Now - m.StartedAt).TotalSeconds);
                Elapsed.Text = $"{s / 60:00}:{s % 60:00}";
            };
            _tick.Start();
            RefreshLines();
            RefreshQuestion();
            RefreshButtons();
        };
    }

    private Brush Res(string key) => (Brush)FindResource(key);

    private void RefreshLines()
    {
        _lines.Clear();
        foreach (var t in Core.Turns.Skip(Math.Max(0, Core.Turns.Count - 2))) _lines.Add(t);
        foreach (var p in Core.Partials) _lines.Add(p);
        Hint.Visibility = _lines.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Hint.Text = Core.IsRecording ? "Слушаю…" : "Начните запись — здесь появятся последние реплики и вопрос.";
    }

    private void RefreshQuestion()
    {
        var q = Core.Questions.FirstOrDefault();
        if (!ReferenceEquals(q, _watched))
        {
            if (_watched is not null) _watched.PropertyChanged -= OnQuestion;
            _watched = q;
            if (q is not null) q.PropertyChanged += OnQuestion;
        }
        QuestionCard.DataContext = q;
        // Пока модель дописывает новый вопрос, показываем его, а не предыдущий. В собеседовании вместо вопроса — уточнения
        QuestionCard.Visibility = q is null || Core.PendingQuestion.Length > 0 || Core.Selected?.IsInterview == true ? Visibility.Collapsed : Visibility.Visible;
        PaintQuestion();
    }

    private void OnQuestion(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Question.ForMe)) PaintQuestion();
    }

    private void PaintQuestion()
    {
        bool me = _watched?.ForMe == true;
        ForMe.Visibility = me ? Visibility.Visible : Visibility.Collapsed;
        QuestionCard.Background = Res(me ? "AlertSoft" : "AccentFaint");
        QuestionCard.BorderBrush = Res(me ? "Alert" : "AccentLine");
        QuestionCard.BorderThickness = new Thickness(me ? 2 : 1);
    }

    private void RefreshButtons()
    {
        bool rec = Core.IsRecording;
        RecordButton.Content = rec ? "\uE71A" : "\uE720";
        RecordButton.Background = Res(rec ? "Bad" : "Accent");
        RecordButton.ToolTip = rec ? "Остановить запись" : "Начать запись";
        MicButton.Content = Core.MicMuted ? "\uEC54" : "\uE720";
        MicButton.Foreground = Res(Core.MicMuted ? "Warn" : "Second");
        MicButton.ToolTip = Core.MicMuted ? "Включить микрофон" : "Выключить микрофон";
        RefreshLines();
    }

    /// <summary>В собеседовании вместо последнего вопроса — что дозадать прямо сейчас, иначе следующий вопрос карты.</summary>
    private void RefreshInterview()
    {
        Interview.Children.Clear();
        bool iv = Core.Interview is not null && Core.Selected?.IsInterview == true;
        if (iv) QuestionCard.Visibility = Visibility.Collapsed;
        if (!iv) return;
        if (Core.Interview!.Probes.LastOrDefault() is { Active: true } p)
        {
            var tint = Theme.Hex(Verdicts.VerdictColor(p.Verdict));
            var s = new StackPanel();
            var head = new DockPanel { Margin = new Thickness(0, 0, 0, 5) };
            var close = new Button { Style = (Style)FindResource("IconButton"), Content = "\uE711", FontSize = 10, Width = 22, Height = 22, ToolTip = "Не нужно" };
            close.Click += (_, _) => { Core.MarkProbe(p, false); RefreshInterview(); };
            var done = new Button { Style = (Style)FindResource("IconButton"), Content = "\uE73E", FontSize = 11, Width = 22, Height = 22, ToolTip = "Задал" };
            done.Click += (_, _) => { Core.MarkProbe(p, true); RefreshInterview(); };
            DockPanel.SetDock(close, Dock.Right);
            DockPanel.SetDock(done, Dock.Right);
            head.Children.Add(close);
            head.Children.Add(done);
            head.Children.Add(new TextBlock { Text = p.Draft ? "ПОХОЖЕ, СТОИТ УТОЧНИТЬ" : "ДОЗАДАЙТЕ", FontSize = 11, FontWeight = FontWeights.Bold, Foreground = tint, VerticalAlignment = VerticalAlignment.Center });
            s.Children.Add(head);
            s.Children.Add(Make.Text(p.Followup, 15, FontWeights.SemiBold));
            Interview.Children.Add(Make.Box(s, Theme.Hex(Verdicts.VerdictColor(p.Verdict), 0.12), tint, 11, 10, 7));
        }
        else if (Core.NextPlanQuestion is { } q)
        {
            var s = new StackPanel();
            s.Children.Add(new TextBlock { Text = "СЛЕДУЮЩИЙ: " + q.KindTitle.ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeights.Bold, Foreground = Theme.Hex(Verdicts.KindColor(q.Kind)), Margin = new Thickness(0, 0, 0, 4) });
            s.Children.Add(Make.Text(q.Text, 13.5, FontWeights.SemiBold));
            Interview.Children.Add(Make.Box(s, Res("Soft"), null, 11, 10, 7));
        }
        if (Core.Mastery is { } m)
            Interview.Children.Add(Make.Text($"{Verdicts.MasteryTitle(m)} · {m:0.0} из 5", 12, FontWeights.SemiBold, Theme.Hex(Verdicts.MasteryColor(m)), new Thickness(2, 0, 0, 6)));
    }

    private void OnMic(object sender, RoutedEventArgs e) => Core.ToggleMic();
    private void OnRecord(object sender, RoutedEventArgs e) => Core.ToggleRecording();
    private void OnExpand(object sender, RoutedEventArgs e) => Expand?.Invoke();
}
