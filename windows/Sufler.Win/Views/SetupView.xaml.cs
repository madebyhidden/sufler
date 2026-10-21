using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NAudio.CoreAudioApi;

namespace Sufler.Views;

/// <summary>Строка проверки готовности.</summary>
public sealed class CheckRow : Observable
{
    private string _note = "";
    private Brush _dot = Brushes.Gray;
    public required string Glyph { get; init; }
    public required string Title { get; init; }
    public string Note { get => _note; set => Set(ref _note, value); }
    public Brush Dot { get => _dot; set => Set(ref _dot, value); }
}

/// <summary>Первый запуск: знакомство, загрузка моделей, проверка готовности.</summary>
public partial class SetupView : UserControl
{
    private AppCore Core => App.Core;
    private readonly ObservableCollection<ModelItem> _models = new();
    private readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private readonly CheckRow _mic = new() { Glyph = "", Title = "Микрофон" };
    private readonly CheckRow _sound = new() { Glyph = "", Title = "Звук компьютера" };
    private readonly CheckRow _speech = new() { Glyph = "", Title = "Распознавание речи" };
    private readonly CheckRow _llm = new() { Glyph = "", Title = "Языковая модель" };
    private readonly CheckRow _search = new() { Glyph = "", Title = "Поиск по базе знаний" };
    private int _step;
    private bool _downloading, _hooked;

    /// <summary>Настройка пройдена: можно показывать основное окно.</summary>
    public event Action? Finished;
    public int Step => _step;
    public bool Downloading => _downloading;

    public SetupView()
    {
        InitializeComponent();
        ModelList.ItemsSource = _models;
        CheckList.ItemsSource = new[] { _mic, _sound, _speech, _llm, _search };
    }

    public static bool Needed => !Settings.Flag("onboarded", false) || Models.Catalog().Any(m => !Models.IsReady(m));
    public bool ModelsReady => _models.Count > 0 && _models.Where(m => !m.Extra).All(Models.IsReady);

    /// <summary>Показать настройку; если знакомство уже было — сразу с моделей.</summary>
    public void Open(bool fromSettings = false)
    {
        Visibility = Visibility.Visible;
        if (!_hooked) { _hooked = true; Core.PropertyChanged += OnCore; }
        RefreshModels();
        Go(Settings.Flag("onboarded", false) || fromSettings ? 1 : 0);
    }

    private Brush Res(string key) => (Brush)FindResource(key);

    public void RefreshModels()
    {
        _models.Clear();
        foreach (var m in Models.Catalog())
        {
            if (Models.IsReady(m)) { m.Progress = 1; m.State = "готово"; m.Ready = true; }
            _models.Add(m);
        }
        // Что лежит на диске без дела: прежняя модель после смены, недокачанные остатки
        foreach (var m in Models.Unused()) { m.Progress = 1; m.Ready = true; _models.Add(m); }
        bool light = Models.Profile == "e2b";
        ProfileNote.Text = Models.CustomChat.Length > 0 ? "Выбрана своя языковая модель: " + Models.ChatTitle
            : Machine.Discrete ? $"Найдена видеокарта {Machine.GpuName} — модели будут считаться на ней."
            : light ? "Отдельной видеокарты нет — выбрана лёгкая модель Gemma 4 E2B, она быстро работает на процессоре."
            : "Выбрана Gemma 4 E4B. Без отдельной видеокарты она работает медленно — лёгкую модель можно выбрать в настройках.";
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Models.Root)!);
            DiskNote.Text = $"Свободно на диске: {drive.AvailableFreeSpace / 1e9:0} ГБ";
        }
        catch { DiskNote.Text = ""; }
        RefreshButtons();
    }

    private void Go(int step)
    {
        _step = step;
        Step0.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        Step1.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        Step2.Visibility = step == 2 ? Visibility.Visible : Visibility.Collapsed;
        Dot0.Fill = Res(step == 0 ? "Accent" : "Third");
        Dot1.Fill = Res(step == 1 ? "Accent" : "Third");
        Dot2.Fill = Res(step == 2 ? "Accent" : "Third");
        DiskNote.Visibility = FolderButton.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        if (step == 2)
        {
            RefreshChecks();
            // Модели на месте — запускаем движки, пока человек читает
            _ = Core.Restart();
        }
        RefreshButtons();
    }

    private void RefreshButtons()
    {
        BackButton.Visibility = _step > 0 && !_downloading ? Visibility.Visible : Visibility.Collapsed;
        long need = _models.Where(m => !m.Extra && !Models.IsReady(m)).Sum(m => m.Size);
        NextButton.IsEnabled = true;
        if (_step == 0) NextButton.Content = "Дальше";
        else if (_step == 1)
        {
            NextButton.Content = _downloading ? "Скачиваю…" : need > 0 ? $"Скачать — {need / 1e9:0.0} ГБ" : "Дальше";
            NextButton.IsEnabled = !_downloading;
        }
        else
        {
            NextButton.Content = "Начать работу";
            NextButton.IsEnabled = Core.AsrReady;
        }
    }

    private void OnBack(object sender, RoutedEventArgs e) => Go(_step - 1);

    private void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        try { System.Diagnostics.Process.Start("explorer.exe", $"\"{Models.Dir}\""); } catch { }
    }

    /// <summary>Удаление модели с диска: чтобы не искать её по папкам вручную.</summary>
    private async void OnDeleteModel(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not ModelItem m || _downloading) return;
        var owner = Window.GetWindow(this)!;
        if (Core.RecordingId != 0) { MessageBox.Show(owner, "Идёт запись — сначала остановите её.", "Суфлёр", MessageBoxButton.OK, MessageBoxImage.Information); return; }
        string tail = m.Extra ? "Сейчас она не используется." : "Она нужна для работы: приложение предложит скачать её заново.";
        if (MessageBox.Show(owner, $"Удалить «{m.Title}» ({m.SizeText}) с диска?\n\n{tail}", "Суфлёр", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try
        {
            // Работающая модель держит свой файл открытым — сначала останавливаем движки
            if (!m.Extra) await Core.StopEngines();
            Models.Delete(m);
        }
        catch (Exception ex) { MessageBox.Show(owner, "Не удалось удалить: " + ex.Message, "Суфлёр", MessageBoxButton.OK, MessageBoxImage.Warning); }
        RefreshModels();
    }

    private async void OnNext(object sender, RoutedEventArgs e) => await Next();

    /// <summary>Кнопка «Дальше»: на шаге моделей сначала скачивает недостающее.</summary>
    public async Task Next()
    {
        if (_step == 0) { Go(1); return; }
        if (_step == 1)
        {
            if (_models.Any(m => !m.Extra && !Models.IsReady(m))) { await Download(); if (!ModelsReady) return; }
            Go(2);
            return;
        }
        Settings.SetFlag("onboarded", true);
        Visibility = Visibility.Collapsed;
        Finished?.Invoke();
    }

    private async Task Download()
    {
        _downloading = true;
        RefreshButtons();
        DownloadNote.Foreground = Res("Second");
        DownloadNote.Text = "Не закрывайте приложение. Если связь оборвётся — нажмите «Скачать» ещё раз, загрузка продолжится с того же места.";
        try
        {
            foreach (var m in _models.Where(m => !m.Extra && !Models.IsReady(m)).ToList())
            {
                m.State = "качаю…";
                await Models.Download(m, _http, CancellationToken.None);
                m.State = "готово";
                m.Ready = true;
            }
            DownloadNote.Text = "Все модели на месте.";
        }
        catch (Exception ex)
        {
            DownloadNote.Foreground = Res("Bad");
            DownloadNote.Text = "Не скачалось: " + ex.Message + " Нажмите «Скачать» ещё раз — загрузка продолжится.";
            foreach (var m in _models.Where(m => !m.Ready)) m.State = "";
        }
        _downloading = false;
        RefreshButtons();
    }

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        if (Visibility != Visibility.Visible || _step != 2) return;
        RefreshChecks();
        RefreshButtons();
    }

    private void RefreshChecks()
    {
        void Put(CheckRow row, bool ok, bool failed, string note)
        {
            row.Note = note;
            row.Dot = Res(ok ? "Good" : failed ? "Bad" : "Warn");
        }
        bool mic = false, sound = false;
        try
        {
            using var devices = new MMDeviceEnumerator();
            mic = devices.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Communications) || devices.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            sound = devices.HasDefaultAudioEndpoint(DataFlow.Render, Role.Console);
        }
        catch { }
        Put(_mic, mic, !mic, mic ? "Найден. Если запись не начнётся, разрешите доступ: Параметры → Конфиденциальность → Микрофон." : "Не найден. Подключите микрофон — без него будет слышно только собеседников.");
        Put(_sound, sound, !sound, sound ? "Суфлёр услышит собеседников из любого приложения для звонков." : "Устройство вывода звука не найдено.");
        Put(_speech, Core.AsrReady, Core.AsrFailed, Core.AsrReady ? Core.AsrStatus + " — готово" : Core.AsrStatus);
        Put(_llm, Core.LlmReady, Core.LlmFailed, Core.LlmReady ? Core.LlmStatus + " — готова" : Core.LlmStatus);
        Put(_search, Core.EmbedReady, Core.LlmFailed, Core.EmbedReady ? "Готов" : "Запускается вместе с языковой моделью");
    }
}
