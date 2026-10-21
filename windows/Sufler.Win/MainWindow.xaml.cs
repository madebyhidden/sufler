using System.ComponentModel;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Sufler.Views;

namespace Sufler;

public partial class MainWindow : Window
{
    private AppCore Core => App.Core;
    private readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private Updater.Info? _update;
    private readonly CallWatcher _calls = new();
    private bool _syncing;
    /// <summary>Список слева: встречи или собеседования — смотря какой режим включён.</summary>
    private readonly System.Windows.Data.ListCollectionView _meetings;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = Core;
        _meetings = new System.Windows.Data.ListCollectionView(Core.Meetings) { Filter = o => o is Meeting m && m.IsInterview == Core.InterviewMode };
        MeetingList.ItemsSource = _meetings;
        // Новое уточнение, а окно не на виду (компактный режим, другое приложение) — показываем уведомление
        Core.ProbeShown = p => { if (!IsActive || IsCompact) Toast.Show(this, "Дозадайте вопрос", p.Followup); };
        Core.Notify = (title, body) => Toast.Show(this, title, body);
        Core.PropertyChanged += OnCore;
        Core.OfferRecording = name => Toast.Show(this, "Похоже, начался звонок", $"{name} включил микрофон. Начать запись в Суфлёре?", "Начать запись", () => Core.AcceptCallOffer());
        _calls.MicStarted += (name, haystack) => { if (SetupPane.Visibility != Visibility.Visible) Core.MicStartedBy(name, haystack); };
        SetupPane.Finished += () => { MainPanel.Visibility = Visibility.Visible; RefreshPane(); Dispatcher.BeginInvoke(AskConsent, System.Windows.Threading.DispatcherPriority.Background); };
        StatsPane.OpenPrivacy += () => OpenSettings("privacy");
        CompactPane.Expand += () => SetCompact(false);
        // Ctrl+R — начать или остановить запись
        InputBindings.Add(new KeyBinding(new Relay(() => { if (Core.AsrReady && SetupPane.Visibility != Visibility.Visible) Core.ToggleRecording(); }), Key.R, ModifierKeys.Control));
        Loaded += async (_, _) =>
        {
            RefreshMode();
            RefreshPane();
            RefreshRecord();
            RefreshDots();
            if (SetupView.Needed)
            {
                MainPanel.Visibility = Visibility.Collapsed;
                SetupPane.Open();
                // Модели уже на месте (например, обновили приложение) — движки можно запускать сразу
                if (SetupPane.ModelsReady) _ = Core.Boot();
            }
            else _ = Core.Boot();
            _ = UpdateLoop();
            if (!TestDriver.Enabled) _ = Core.TelemetryLoop(Updater.CurrentText);
            if (!SetupView.Needed) { await Task.Delay(3000); AskConsent(); }
            if (Core.WatchCalls && !TestDriver.Enabled) _calls.Start();
            if (TestDriver.Enabled) await TestDriver.Run(this);
        };
        Closing += (_, e) =>
        {
            if (Core.IsRecording && !TestDriver.Enabled &&
                MessageBox.Show(this, "Идёт запись. Остановить её и закрыть приложение?", "Суфлёр", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
            Core.Dispose();
        };
    }

    public MeetingView Meeting => MeetingPane;
    public KnowledgeView Knowledge => KbPane;
    public SetupView Setup => SetupPane;

    private Brush Res(string key) => (Brush)FindResource(key);

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppCore.Selected) or nameof(AppCore.ShowKb): _showStats = false; RefreshPane(); break;
            case nameof(AppCore.IsRecording): RefreshRecord(); break;
            case nameof(AppCore.InterviewMode): RefreshMode(); break;
            case nameof(AppCore.AsrReady) or nameof(AppCore.AsrFailed) or nameof(AppCore.LlmReady) or nameof(AppCore.LlmFailed): RefreshDots(); break;
        }
    }

    /// <summary>Что показать справа: базу знаний, открытую встречу или приглашение начать.</summary>
    private bool _showStats;

    private void OnStats(object sender, RoutedEventArgs e)
    {
        _showStats = true;
        StatsPane.Refresh();
        RefreshPane();
    }

    public void ShowStats() => OnStats(this, new RoutedEventArgs());

    private void OnFeedback(object sender, RoutedEventArgs e) => new FeedbackWindow { Owner = this }.ShowDialog();

    /// <summary>Один раз после знакомства спрашиваем про анонимную статистику.</summary>
    private void AskConsent()
    {
        if (Core.TelemetryConsent != "unknown" || TestDriver.Enabled || SetupPane.Visibility == Visibility.Visible) return;
        new ConsentWindow { Owner = this }.ShowDialog();
    }

    private void RefreshPane()
    {
        bool stats = _showStats;
        bool kb = Core.ShowKb && !stats;
        StatsPane.Visibility = stats ? Visibility.Visible : Visibility.Collapsed;
        StatsButton.Foreground = Res(stats ? "Accent" : "Second");
        KbPane.Visibility = kb && !Core.InterviewMode ? Visibility.Visible : Visibility.Collapsed;
        LibPane.Visibility = kb && Core.InterviewMode ? Visibility.Visible : Visibility.Collapsed;
        MeetingPane.Visibility = !kb && !stats && Core.Selected is not null ? Visibility.Visible : Visibility.Collapsed;
        EmptyPane.Visibility = !kb && !stats && Core.Selected is null ? Visibility.Visible : Visibility.Collapsed;
        KbButton.Background = Res(kb ? "Accent" : "Soft");
        KbButton.Foreground = kb ? Brushes.White : Res("Ink");
        KbIcon.Foreground = kb ? Brushes.White : Res("Accent");
        _syncing = true;
        MeetingList.SelectedItem = kb ? null : Core.Selected;
        _syncing = false;
    }

    /// <summary>Режим «встречи» или «собеседования»: подписи, список слева, палитра.</summary>
    private void RefreshMode()
    {
        bool iv = Core.InterviewMode;
        Theme.Apply(iv);
        KbText.Text = iv ? "Вакансии и резюме" : "База знаний";
        KbIcon.Text = iv ? "\uE821" : "\uE8F1";
        KbCount.SetBinding(TextBlock.TextProperty, iv ? "Vacancies.Count" : "Facts.Count");
        ListTitle.Text = iv ? "СОБЕСЕДОВАНИЯ" : "ВСТРЕЧИ";
        EmptyTitle.Text = iv ? "Собеседований пока нет" : "Встреч пока нет";
        EmptyText.Text = iv ? "Добавьте вакансию и резюме — Суфлёр соберёт карту вопросов,\nподскажет уточнения по ходу разговора и оценит кандидата."
                            : "Начните запись — Суфлёр расшифрует разговор,\nпокажет последний вопрос и кому он адресован.";
        EmptyButtonText.Text = iv ? "Новое собеседование" : "Начать запись";
        _meetings.Refresh();
        RefreshRecord();
        RefreshPane();
    }

    private void RefreshRecord()
    {
        bool rec = Core.IsRecording;
        bool iv = Core.InterviewMode;
        SideRecordText.Text = rec ? "Остановить запись" : iv ? "Новое собеседование" : "Начать запись";
        SideRecordIcon.Text = rec ? "" : iv ? "\uE8FA" : "";
        SideRecord.Background = Res(rec ? "Bad" : "Accent");
    }

    private void RefreshDots()
    {
        AsrDot.Fill = Res(Core.AsrReady ? "Good" : Core.AsrFailed ? "Bad" : "Warn");
        LlmDot.Fill = Res(Core.LlmReady ? "Good" : Core.LlmFailed ? "Bad" : "Warn");
    }

    // MARK: Боковая панель

    // MARK: Компактный режим

    private Rect _normalBounds;
    private WindowState _normalState;
    private double _normalMinWidth, _normalMinHeight;
    public bool IsCompact => CompactPane.Visibility == Visibility.Visible;

    private void OnCompact(object sender, RoutedEventArgs e) => SetCompact(true);

    /// <summary>Сворачивает окно в маленькую плашку поверх всех окон и обратно.</summary>
    public void SetCompact(bool on)
    {
        if (on == IsCompact || SetupPane.Visibility == Visibility.Visible) return;
        if (on)
        {
            // В компактном окне показываем ту встречу, которая сейчас пишется
            if (Core.RecordingId != 0 && Core.Meetings.FirstOrDefault(m => m.Id == Core.RecordingId) is { } rec) Core.Select(rec);
            _normalState = WindowState;
            WindowState = WindowState.Normal;
            _normalBounds = new Rect(Left, Top, Width, Height);
            (_normalMinWidth, _normalMinHeight) = (MinWidth, MinHeight);
            MainPanel.Visibility = Visibility.Collapsed;
            CompactPane.Visibility = Visibility.Visible;
            MinWidth = 300;
            MinHeight = 220;
            Width = 400;
            Height = 380;
            var area = SystemParameters.WorkArea;
            Left = area.Right - Width - 12;
            Top = area.Top + 12;
            Topmost = true;
        }
        else
        {
            Topmost = false;
            CompactPane.Visibility = Visibility.Collapsed;
            MainPanel.Visibility = Visibility.Visible;
            (MinWidth, MinHeight) = (_normalMinWidth, _normalMinHeight);
            (Left, Top, Width, Height) = (_normalBounds.X, _normalBounds.Y, _normalBounds.Width, _normalBounds.Height);
            WindowState = _normalState;
            RefreshPane();
        }
    }

    private void OnOpenKb(object sender, RoutedEventArgs e)
    {
        if (Core.InterviewMode) Core.OpenLibrary(); else Core.ShowKb = true;
    }
    private void OnAcceptCall(object sender, RoutedEventArgs e) => Core.AcceptCallOffer();
    private void OnDismissCall(object sender, RoutedEventArgs e) => Core.CallOffer = "";

    /// <summary>Настройку «предлагать запись при звонке» включили или выключили.</summary>
    public void RefreshCallWatcher()
    {
        if (Core.WatchCalls) _calls.Start(); else { _calls.Stop(); Core.CallOffer = ""; }
    }
    /// <summary>В режиме собеседований кнопка слева заводит новое собеседование: сначала подготовка, запись — потом.</summary>
    private void OnRecord(object sender, RoutedEventArgs e)
    {
        if (Core.InterviewMode && !Core.IsRecording) Core.NewInterview();
        else Core.ToggleRecording();
    }

    private void OnMeetingPicked(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing) return;
        if (MeetingList.SelectedItem is Meeting m) Core.Select(m);
    }

    private void OnDeleteMeeting(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not Meeting m) return;
        if (m.Id == Core.RecordingId) { Core.ErrorText = "Эта встреча сейчас записывается — сначала остановите запись."; return; }
        if (MessageBox.Show(this, $"Удалить встречу «{m.Title}» вместе с расшифровкой и итогом?", "Суфлёр", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            Core.Delete(m);
    }

    private void OnSettings(object sender, RoutedEventArgs e) => OpenSettings("general");

    public async void OpenSettings(string pane)
    {
        var w = new SettingsWindow { Owner = this };
        w.ShowPane(pane);
        if (w.ShowDialog() != true) return;
        RefreshCallWatcher();
        if (_showStats) StatsPane.Refresh();
        if (w.OpenFeedback) { new FeedbackWindow { Owner = this }.ShowDialog(); return; }
        if (w.ModeChanged) { Core.ModeChanged(); RefreshMode(); }
        if (!w.EnginesChanged && !w.OpenSetup) return;
        if (Core.IsRecording) { Core.ErrorText = "Модель сменится после остановки записи и перезапуска приложения."; return; }
        // Для новой модели может понадобиться что-то докачать — тогда показываем экран моделей
        if (w.OpenSetup || SetupView.Needed)
        {
            MainPanel.Visibility = Visibility.Collapsed;
            SetupPane.Open(fromSettings: true);
        }
        else await Core.Restart();
    }

    // MARK: Обновления

    private async Task UpdateLoop()
    {
        await Task.Delay(4000);
        while (true)
        {
            if (await Updater.Check(_http) is { } info) OfferUpdate(info);
            await Task.Delay(TimeSpan.FromHours(6));
        }
    }

    public void OfferUpdate(Updater.Info info)
    {
        _update = info;
        UpdateButton.Content = $"Обновление {info.Version}";
        UpdateButton.ToolTip = info.Notes;
        UpdateButton.Visibility = Visibility.Visible;
    }

    private async void OnUpdate(object sender, RoutedEventArgs e)
    {
        if (_update is null) return;
        if (Core.IsRecording) { Core.ErrorText = "Сначала остановите запись — потом можно обновиться."; return; }
        var ask = MessageBox.Show(this, $"Доступна версия {_update.Version}.\n\n{_update.Notes}\n\nСкачается только само приложение, модели и встречи останутся на месте. Обновить и перезапустить?",
            "Суфлёр", MessageBoxButton.YesNo, MessageBoxImage.Information);
        if (ask != MessageBoxResult.Yes) return;
        UpdateButton.IsEnabled = false;
        try
        {
            await Updater.Install(_update, _http, p => Dispatcher.Invoke(() => UpdateButton.Content = $"Скачиваю… {p * 100:0}%"), () => Core.Dispose());
        }
        catch (Exception ex)
        {
            UpdateButton.IsEnabled = true;
            UpdateButton.Content = $"Обновление {_update.Version}";
            MessageBox.Show(this, "Не удалось обновить: " + ex.Message, "Суфлёр", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private sealed class Relay(Action run) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => run();
    }
}
