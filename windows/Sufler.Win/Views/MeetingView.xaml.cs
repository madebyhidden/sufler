using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Sufler.Views;

public partial class MeetingView : UserControl
{
    private AppCore Core => App.Core;
    private Meeting? _watched;
    private DateTime? _followPausedUntil;
    private bool _summaryDirty;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private int _ticks;

    public MeetingView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Core.PropertyChanged += OnCore;
            Core.Turns.CollectionChanged += (_, _) => RefreshHints();
            Core.Partials.CollectionChanged += (_, _) => RefreshHints();
            Watch();
            RefreshAll();
            _tick.Tick += (_, _) => OnTick();
            _tick.Start();
        };
        // Расшифровка сама едет вниз за новыми репликами — пока пользователь её не листает
        TranscriptScroll.ScrollChanged += (_, e) =>
        {
            if (e.ExtentHeightChange > 0 && _followPausedUntil is null) TranscriptScroll.ScrollToEnd();
        };
    }

    private Brush Res(string key) => (Brush)FindResource(key);

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppCore.Selected):
                Watch();
                ResumeFollow();
                RefreshAll();
                Dispatcher.BeginInvoke(() => TranscriptScroll.ScrollToEnd(), DispatcherPriority.Background);
                break;
            case nameof(AppCore.IsRecording) or nameof(AppCore.SelectedIsRecording) or nameof(AppCore.RecordingId):
                if (!Core.SelectedIsRecording) ResumeFollow();
                RefreshAll();
                break;
            case nameof(AppCore.MicMuted): RefreshMic(); break;
            case nameof(AppCore.InterviewPrep) or nameof(AppCore.Interview): RefreshMode(); break;
            case nameof(AppCore.LevelMe) or nameof(AppCore.LevelThem): RefreshLevels(); break;
            case nameof(AppCore.Summarizing) or nameof(AppCore.LlmReady) or nameof(AppCore.LlmFailed) or nameof(AppCore.Detecting) or nameof(AppCore.Answering):
                RefreshSummaryButtons();
                RefreshHints();
                break;
        }
    }

    /// <summary>Следим за открытой встречей: итог пишется по кусочку, и его надо перерисовывать.</summary>
    private void Watch()
    {
        if (_watched is not null) _watched.PropertyChanged -= OnMeeting;
        _watched = Core.Selected;
        if (_watched is not null) _watched.PropertyChanged += OnMeeting;
        _summaryDirty = true;
    }

    private void OnMeeting(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Meeting.Summary)) _summaryDirty = true;
    }

    private void OnTick()
    {
        _ticks++;
        // Кольцо-таймер на кнопке «вниз»
        if (_followPausedUntil is { } until)
        {
            double left = (until - DateTime.UtcNow).TotalSeconds / 10;
            if (left <= 0) ResumeFollow();
            else FollowRing.StrokeDashArray = new DoubleCollection { left * Math.PI * 36 / 3, 1000 };
        }
        // Итог перерисовываем не на каждый кусочек текста, а несколько раз в секунду
        if (_summaryDirty && _ticks % 2 == 0)
        {
            _summaryDirty = false;
            RenderSummary();
            RefreshSummaryButtons();
        }
        if (_ticks % 5 == 0 && Core.SelectedIsRecording && Core.Selected is { } m)
        {
            int s = Math.Max(0, (int)(DateTime.Now - m.StartedAt).TotalSeconds);
            Elapsed.Text = $"{s / 60:00}:{s % 60:00}";
        }
    }

    /// <summary>Собеседование: до начала — подготовка, потом — расшифровка и панель суфлёра для собеседований.</summary>
    private void RefreshMode()
    {
        bool iv = Core.Selected?.IsInterview == true;
        bool prep = Core.InterviewPrep;
        Prep.Visibility = prep ? Visibility.Visible : Visibility.Collapsed;
        Workspace.Visibility = prep ? Visibility.Collapsed : Visibility.Visible;
        IvSide.Visibility = iv ? Visibility.Visible : Visibility.Collapsed;
        ClassicSide.Visibility = iv ? Visibility.Collapsed : Visibility.Visible;
        NotesHint.Text = iv ? "Пишите по ходу собеседования — заметки попадут в оценку кандидата." : "Пишите по ходу встречи — заметки попадут в итог и в поиск.";
        if (!Core.IsRecording) RecordText.Text = iv ? "Начать собеседование" : "Начать запись";
    }

    private void RefreshAll()
    {
        bool rec = Core.IsRecording;
        RecordText.Text = rec ? "Остановить" : Core.Selected?.IsInterview == true ? "Начать собеседование" : "Начать запись";
        RecordIcon.Text = rec ? "" : "";
        RecordButton.Background = Res(rec ? "Bad" : "Accent");
        RefreshMic();
        RefreshLevels();
        RefreshHints();
        RefreshSummaryButtons();
        NotesHint.Visibility = string.IsNullOrEmpty(Core.Selected?.Notes) ? Visibility.Visible : Visibility.Collapsed;
        _summaryDirty = true;
        RefreshMode();
    }

    private void RefreshMic()
    {
        bool muted = Core.MicMuted;
        MicText.Text = muted ? "Включить микрофон" : "Выключить микрофон";
        MicIcon.Text = muted ? "" : "";
        MicButton.Background = Res(muted ? "Warn" : "Soft");
        MicButton.Foreground = muted ? Brushes.White : Res("Ink");
        MicButton.ToolTip = muted ? "Сейчас пишется только звук звонка" : "Писать только звук звонка, без вашего голоса";
    }

    private void RefreshLevels()
    {
        MeDot.Fill = Res(Core.LevelMe ? "Good" : "Third");
        ThemDot.Fill = Res(Core.LevelThem ? "Good" : "Third");
    }

    private void RefreshHints()
    {
        bool empty = Core.Turns.Count == 0 && Core.Partials.Count == 0;
        TranscriptHint.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        bool listening = Core.SelectedIsRecording;
        TranscriptHintText.Text = listening ? "Слушаю…" : "Здесь появится текст разговора";
        TranscriptHintIcon.Text = listening ? "" : "";
        QuestionHintText.Text = !Core.LlmReady
            ? (Core.LlmFailed ? Core.LlmStatus : "Языковая модель загружается. Вопросы начнут появляться, как только она будет готова.")
            : Core.Detecting ? "Ищу вопрос в разговоре…"
            : "Здесь появится последний вопрос из разговора: кому он адресован и краткий контекст.";
    }

    private void RefreshSummaryButtons()
    {
        var m = Core.Selected;
        bool idle = m is not null && m.Id != Core.RecordingId && !Core.Summarizing;
        bool has = m is { Summary.Length: > 0 };
        SummaryButtons.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
        RebuildButton.Visibility = Core.LlmReady && Core.Turns.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
        RebuildText.Text = has ? "Пересобрать" : "Составить итог";
        CopyButton.Visibility = WordButton.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        SummaryHint.Visibility = has || Core.Summarizing || Core.NameChecks.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Итог одним документом: заголовки полужирным, пункты с точками. Его можно выделить и скопировать целиком.</summary>
    private void RenderSummary()
    {
        var doc = new FlowDocument { PagePadding = new Thickness(0), FontFamily = (FontFamily)FindResource("TextFont"), FontSize = 14, Foreground = Res("Ink") };
        bool first = true;
        foreach (var (kind, text) in TextTools.SummaryLines(Core.Selected?.Summary ?? ""))
        {
            var p = new Paragraph { Margin = new Thickness(0, 0, 0, 5), LineHeight = 20 };
            if (kind == 'b')
            {
                p.Margin = new Thickness(14, 0, 0, 5);
                p.TextIndent = -12;
                p.Inlines.Add(new Run("•  ") { Foreground = Res("Accent") });
                Ui.AddMarked(p.Inlines, text);
            }
            else
            {
                // Строка, начинающаяся с полужирного названия раздела, отделяется от предыдущего
                if (!first && (kind == 'h' || text.StartsWith("**"))) p.Margin = new Thickness(0, 9, 0, 5);
                Ui.AddMarked(p.Inlines, text, kind == 'h');
            }
            doc.Blocks.Add(p);
            first = false;
        }
        SummaryBox.Document = doc;
        SummaryBox.Visibility = first ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: Прокрутка расшифровки

    /// <summary>Пользователь листает расшифровку во время записи: на 10 секунд перестаём тянуть её вниз.</summary>
    private void OnTranscriptWheel(object sender, MouseWheelEventArgs e)
    {
        TranscriptScroll.ScrollToVerticalOffset(TranscriptScroll.VerticalOffset - e.Delta * 0.6);
        e.Handled = true;
        if (!Core.SelectedIsRecording) return;
        _followPausedUntil = DateTime.UtcNow.AddSeconds(10);
        FollowButton.Visibility = Visibility.Visible;
    }

    private void ResumeFollow()
    {
        bool was = _followPausedUntil is not null;
        _followPausedUntil = null;
        FollowButton.Visibility = Visibility.Collapsed;
        if (was) TranscriptScroll.ScrollToEnd();
    }

    private void OnFollow(object sender, RoutedEventArgs e) => ResumeFollow();

    // MARK: Действия

    private void OnRecord(object sender, RoutedEventArgs e) => Core.ToggleRecording();
    private void OnCompact(object sender, RoutedEventArgs e) => (Window.GetWindow(this) as MainWindow)?.SetCompact(true);
    private void OnToggleMic(object sender, RoutedEventArgs e) => Core.ToggleMic();
    private void OnCloseError(object sender, RoutedEventArgs e) => Core.ErrorText = "";

    private void OnTitleDone(object sender, RoutedEventArgs e)
    {
        var t = TitleBox.Text.Trim();
        if (t.Length > 0) Core.SetTitle(t);
        else TitleBox.Text = Core.Selected?.Title ?? "";
    }

    private void OnTitleKey(object sender, KeyEventArgs e)
    {
        if (e.Key is Key.Enter or Key.Escape) { Keyboard.ClearFocus(); NotesBox.Focus(); }
    }

    private void OnNotesChanged(object sender, TextChangedEventArgs e)
    {
        NotesHint.Visibility = NotesBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        // Текст меняется и когда открывают другую встречу — сохраняем только то, что набрал человек
        if (NotesBox.IsKeyboardFocusWithin) Core.SetNotes(NotesBox.Text);
    }

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (SummaryPane is null || ChatPane is null || QuestionPane is null) return;
        QuestionPane.Visibility = TabQuestion.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        ChatPane.Visibility = TabChat.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        SummaryPane.Visibility = TabSummary.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Открыть вкладку правой панели: 0 — вопрос, 1 — чат, 2 — итог.</summary>
    public void ShowTab(int index) => (index == 1 ? TabChat : index == 2 ? TabSummary : TabQuestion).IsChecked = true;

    private async void OnSuggest(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Question q) await Core.SuggestAnswer(q);
    }

    private void OnRenameVoice(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not Turn t || t.VoiceKey == 0) return;
        var name = Ui.Prompt(Window.GetWindow(this)!, "Как зовут этого собеседника?",
            "Имя появится во всех его репликах этой встречи, и Суфлёр будет учитывать его в вопросах и итоге.", Core.VoiceName(t.VoiceKey));
        if (name is not null) Core.RenameVoice(t.VoiceKey, name);
    }

    private void OnPlayTurn(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Turn t) Core.Play(t);
    }

    private void OnPlayCheck(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is NameCheck c) Core.PlayCheck(c);
    }

    private void OnCheckFix(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is NameCheck c && c.Input.Trim().Length > 0) Core.ResolveCheck(c, c.Input);
    }

    private void OnCheckOk(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is NameCheck c) Core.ResolveCheck(c, c.Heard);
    }

    private void OnCheckKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) OnCheckFix(sender, e);
    }

    private async void OnRebuild(object sender, RoutedEventArgs e)
    {
        if (Core.Selected is { } m) await Core.Summarize(m);
    }

    private async void OnCopySummary(object sender, RoutedEventArgs e)
    {
        var text = Core.SummaryForClipboard();
        if (text.Length == 0) return;
        try { Clipboard.SetText(text); } catch { return; }
        CopyText.Text = "Скопировано";
        await Task.Delay(1800);
        CopyText.Text = "Копировать";
    }

    private void OnWord(object sender, RoutedEventArgs e)
    {
        if (Core.Selected is not { Summary.Length: > 0 } m) return;
        var safe = string.Concat(m.Title.Select(c => System.IO.Path.GetInvalidFileNameChars().Contains(c) ? ' ' : c)).Trim();
        var dlg = new Microsoft.Win32.SaveFileDialog { FileName = safe + ".docx", Filter = "Документ Word|*.docx", Title = "Куда сохранить итог встречи" };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
        try
        {
            Documents.SaveSummaryDocx(dlg.FileName, m);
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{dlg.FileName}\"");
        }
        catch (Exception ex) { Core.ErrorText = "Не удалось сохранить файл Word: " + ex.Message; }
    }
}
