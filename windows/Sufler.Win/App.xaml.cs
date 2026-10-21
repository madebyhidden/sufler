using System.IO;
using System.Threading;
using System.Windows;

namespace Sufler;

public partial class App : Application
{
    private static AppCore? _core;
    /// <summary>Вся логика приложения; окна только показывают её состояние.</summary>
    public static AppCore Core => _core ??= Create();

    private static AppCore Create()
    {
        Hardware.Fill();
        var core = new AppCore
        {
            AudioFactory = loopback => new AudioSource(loopback),
            WhisperFactory = () => new WhisperEngine(Models.PathOf(Models.Whisper), "ru", Machine.Discrete),
            PlayAudio = Player.Play,
        };
        return core;
    }

    private static Mutex? _single;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Вторая копия приложения мешала бы первой: общая база, общие модели, занятые файлы при обновлении
        _single = new Mutex(true, "Sufler.SingleInstance", out bool first);
        if (!first)
        {
            MessageBox.Show("Суфлёр уже запущен — посмотрите на панели задач.", "Суфлёр", MessageBoxButton.OK, MessageBoxImage.Information);
            Environment.Exit(0);
        }
        KillOrphans();
        // Палитра режима: в собеседованиях — своя, чтобы режим было видно с одного взгляда
        Theme.Apply(Settings.Get("appMode", "classic") == "interview");
        // Любую необработанную ошибку пишем в файл и показываем — чтобы её можно было прислать разработчику
        DispatcherUnhandledException += (_, a) => { Report(a.Exception); a.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, a) => Report(a.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, a) => { Log(a.Exception); a.SetObserved(); };
        base.OnStartup(e);
    }

    /// <summary>Языковые модели, оставшиеся от прошлого запуска (например, после сбоя), занимают память — закрываем их.</summary>
    private static void KillOrphans()
    {
        foreach (var p in System.Diagnostics.Process.GetProcessesByName("llama-server"))
        {
            try { if (string.Equals(p.MainModule?.FileName, Models.LlamaExe, StringComparison.OrdinalIgnoreCase)) p.Kill(); } catch { }
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        base.OnExit(e);
        // Выходим сразу и наверняка: обычное завершение может зависнуть на фоновых потоках моделей,
        // и невидимая копия приложения осталась бы в памяти
        try { _core?.Dispose(); } catch { }
        System.Diagnostics.Process.GetCurrentProcess().Kill();
    }

    private static string LogPath => Path.Combine(Models.Root, "error.log");

    private static void Log(Exception? ex)
    {
        if (ex is null) return;
        try { File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {ex}\n\n"); } catch { }
    }

    private static void Report(Exception? ex)
    {
        if (ex is null) return;
        Log(ex);
        // При автоматической проверке окно с ошибкой некому закрыть
        if (TestDriver.Enabled) return;
        try { MessageBox.Show($"Ошибка: {ex.Message}\n\nПодробности записаны в файл:\n{LogPath}", "Суфлёр", MessageBoxButton.OK, MessageBoxImage.Warning); } catch { }
    }
}
