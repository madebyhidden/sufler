using System.Net.Http;
using System.Windows;
using System.Windows.Controls;

namespace Sufler.Views;

public partial class SettingsWindow : Window
{
    private AppCore Core => App.Core;
    private readonly string _asr = Models.Asr, _profile = Models.Profile, _custom = Models.CustomChat, _mode = App.Core.AppMode;
    private string _pickedCustom = Models.CustomChat;
    private bool _loading = true;

    /// <summary>Пользователь попросил открыть экран моделей и готовности.</summary>
    public bool OpenSetup { get; private set; }
    /// <summary>Сменили модель или способ распознавания: движки надо перезапустить.</summary>
    public bool EnginesChanged => Models.Asr != _asr || Models.Profile != _profile || Models.CustomChat != _custom;
    /// <summary>Переключили режим: встречи или собеседования.</summary>
    public bool ModeChanged => Core.AppMode != _mode;

    public SettingsWindow()
    {
        InitializeComponent();
        NameBox.Text = Core.MyName;
        GlossaryBox.Text = Core.Glossary;
        MicCheck.IsChecked = Core.CaptureMic;
        SystemCheck.IsChecked = Core.CaptureSystem;
        AudioCheck.IsChecked = Core.KeepAudio;
        StopBox.SelectedIndex = Math.Max(0, Array.IndexOf(new[] { 0, 3, 5, 10, 20, 30 }, Core.AutoStopMinutes));
        CallsCheck.IsChecked = Core.WatchCalls;
        AppsBox.Text = Core.WatchApps;
        CorrectionsBox.Text = Core.CorrectionsText;
        AsrBox.SelectedIndex = Models.Asr == "whisper" ? 1 : 0;
        ModelBox.SelectedIndex = _custom.Length > 0 ? 2 : Models.Profile == "e2b" ? 1 : 0;
        VersionText.Text = "Суфлёр " + Updater.CurrentText;
        TelemetryCheck.IsChecked = Core.TelemetryConsent == "yes";
        ChannelNote.Visibility = Telemetry.Enabled ? Visibility.Collapsed : Visibility.Visible;
        PayloadBox.Text = Core.TelemetryPayload(Updater.CurrentText).ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        DataPath.Text = Models.Root;
        int pending = Core.PendingFeedback;
        PendingNote.Text = pending > 0 ? $"Ждут отправки: {pending}" : "Тексты встреч, звук и база знаний к отзыву не прикладываются.";
        RefreshModelNote();
        (Core.InterviewMode ? ModeInterview : ModeClassic).IsChecked = true;
        // Во время записи режим не меняем: запись уже идёт в своём режиме
        ModeClassic.IsEnabled = ModeInterview.IsEnabled = !Core.IsRecording;
        RefreshMode();
        Core.PropertyChanged += OnCore;
        Closed += (_, _) => Core.PropertyChanged -= OnCore;
        _loading = false;
    }

    private void OnCore(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppCore.DeepProgress) or nameof(AppCore.DeepDownloading) or nameof(AppCore.DeepReady)) RefreshDeep();
    }

    private void OnMode(object sender, RoutedEventArgs e)
    {
        if (ModeNote is null) return;
        RefreshMode();
    }

    private void RefreshMode()
    {
        bool iv = ModeInterview.IsChecked == true;
        ModeNote.Text = iv
            ? "Подготовка по вакансии и резюме, карта вопросов, уточнения по ходу разговора и оценка кандидата с матрицей компетенций и бизнес-логикой."
            : "Расшифровка встреч, последний вопрос, подсказки, итоги и база знаний.";
        DeepPanel.Visibility = iv ? Visibility.Visible : Visibility.Collapsed;
        RefreshDeep();
    }

    /// <summary>Gemma 4 26B: скачать, качается, готова или не влезает на этот компьютер.</summary>
    private void RefreshDeep()
    {
        DeepBar.Visibility = Core.DeepDownloading ? Visibility.Visible : Visibility.Collapsed;
        DeepBar.Value = Core.DeepProgress;
        if (!AppCore.DeepFits)
        {
            DeepNote.Text = "Gemma 4 26B нужна видеокарта или от 32 ГБ памяти. На этом компьютере карта вопросов и оценка идут на основной модели — работать будет, но проще.";
            DeepButton.Visibility = Visibility.Collapsed;
        }
        else if (Core.DeepReady)
        {
            DeepNote.Text = "Gemma 4 26B готова. Загружается только для карты вопросов и итоговой оценки, на это время основная модель выгружается; во время собеседования её в памяти нет.";
            DeepButton.Visibility = Visibility.Collapsed;
        }
        else if (Core.DeepDownloading)
        {
            DeepNote.Text = $"Скачиваю Gemma 4 26B: {Core.DeepProgress * 100:0}%. Можно закрыть настройки — загрузка продолжится.";
            DeepButton.Visibility = Visibility.Collapsed;
        }
        else
        {
            long size = AppCore.DeepItems().Where(m => !Models.IsReady(m)).Sum(m => m.Size);
            DeepNote.Text = "Gemma 4 26B (MoE): думает глубже, а работает почти так же быстро — активна лишь часть сети. Если связь оборвётся, загрузка продолжится с того же места.";
            DeepButton.Content = $"Скачать — {size / 1e9:0.0} ГБ";
            DeepButton.Visibility = Visibility.Visible;
        }
    }

    private async void OnDeepDownload(object sender, RoutedEventArgs e) => await Core.DownloadDeep();

    private void RefreshModelNote()
    {
        ModelNote.Text = ModelBox.SelectedIndex == 2 && _pickedCustom.Length > 0
            ? "Своя модель: " + System.IO.Path.GetFileName(_pickedCustom) + ". Суфлёр настроен и проверен на Gemma 4."
            : Machine.Discrete ? $"На этом компьютере есть видеокарта {Machine.GpuName} — подойдёт E4B."
            : $"На этом компьютере нет отдельной видеокарты (память {Machine.RamGb:0} ГБ) — рекомендуем лёгкую E2B.";
    }

    private void OnModelPicked(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (ModelBox.SelectedIndex == 2)
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "Модель GGUF|*.gguf", Title = "Выберите языковую модель в формате GGUF" };
            if (dlg.ShowDialog(this) == true) _pickedCustom = dlg.FileName;
            else if (_pickedCustom.Length == 0) { _loading = true; ModelBox.SelectedIndex = Models.Profile == "e2b" ? 1 : 0; _loading = false; }
        }
        RefreshModelNote();
    }

    /// <summary>Открыть раздел: general, recording, speech, models, privacy, about.</summary>
    public void ShowPane(string pane) => (pane switch
    {
        "recording" => NavRecording, "speech" => NavSpeech, "models" => NavModels, "privacy" => NavPrivacy, "about" => NavAbout, _ => NavGeneral,
    }).IsChecked = true;

    private void OnNav(object sender, RoutedEventArgs e)
    {
        if (PageAbout is null) return;
        var pairs = new (RadioButton Nav, FrameworkElement Page)[]
        {
            (NavGeneral, PageGeneral), (NavRecording, PageRecording), (NavSpeech, PageSpeech), (NavModels, PageModels), (NavPrivacy, PagePrivacy), (NavAbout, PageAbout),
        };
        foreach (var (nav, page) in pairs) page.Visibility = nav.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnDataFolder(object sender, RoutedEventArgs e)
    {
        try { System.Diagnostics.Process.Start("explorer.exe", $"\"{Models.Root}\""); } catch { }
    }

    /// <summary>Пользователь хочет написать отзыв: окно настроек закрывается, отзыв открывает главное окно.</summary>
    public bool OpenFeedback { get; private set; }

    private void OnFeedback(object sender, RoutedEventArgs e)
    {
        Save();
        OpenFeedback = true;
        DialogResult = true;
    }

    private void Save()
    {
        bool telemetry = TelemetryCheck.IsChecked == true;
        if (telemetry != (Core.TelemetryConsent == "yes")) Core.SetTelemetry(telemetry, Updater.CurrentText);
        Core.MyName = NameBox.Text.Trim();
        Core.Glossary = GlossaryBox.Text.Trim();
        Core.CaptureMic = MicCheck.IsChecked == true;
        Core.CaptureSystem = SystemCheck.IsChecked == true;
        Core.KeepAudio = AudioCheck.IsChecked == true;
        Core.AutoStopMinutes = int.Parse((string)((ComboBoxItem)StopBox.SelectedItem).Tag);
        Core.WatchCalls = CallsCheck.IsChecked == true;
        Core.WatchApps = AppsBox.Text.Trim().Length > 0 ? AppsBox.Text.Trim() : AppCore.DefaultWatchApps;
        Core.CorrectionsText = CorrectionsBox.Text.Trim();
        if (!Core.IsRecording) Core.AppMode = ModeInterview.IsChecked == true ? "interview" : "classic";
        Models.Asr = (string)((ComboBoxItem)AsrBox.SelectedItem).Tag;
        if (ModelBox.SelectedIndex == 2 && _pickedCustom.Length > 0) Models.CustomChat = _pickedCustom;
        else
        {
            Models.CustomChat = "";
            Models.Profile = ModelBox.SelectedIndex == 1 ? "e2b" : "e4b";
        }
    }

    private void OnDone(object sender, RoutedEventArgs e)
    {
        Save();
        DialogResult = true;
    }

    private void OnSetup(object sender, RoutedEventArgs e)
    {
        Save();
        OpenSetup = true;
        DialogResult = true;
    }

    private async void OnDiag(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText(Core.Diagnostics(Updater.CurrentText)); } catch { return; }
        DiagButton.Content = "Скопировано";
        await Task.Delay(1800);
        DiagButton.Content = "Скопировать замеры";
    }

    private async void OnCheckUpdate(object sender, RoutedEventArgs e)
    {
        UpdateNote.Text = "Проверяю…";
        using var http = new HttpClient();
        var info = await Updater.Check(http);
        UpdateNote.Text = info is null ? "У вас последняя версия." : $"Есть версия {info.Version} — кнопка обновления слева внизу окна.";
        if (info is not null && Owner is MainWindow w) w.OfferUpdate(info);
    }
}
