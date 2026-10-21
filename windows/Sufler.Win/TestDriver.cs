using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Sufler.Views;

namespace Sufler;

/// <summary>
/// Автоматическая проверка приложения: проходит первый запуск, записывает встречу из звуковых файлов,
/// открывает все экраны и сохраняет их снимки. Включается переменной окружения SUFLER_TEST=папка для снимков;
/// звук берётся из папки SUFLER_TEST_WAVS (файлы 16 кГц моно, имя с «me» — как будто из микрофона).
/// </summary>
public static class TestDriver
{
    private static readonly string? Dir = Environment.GetEnvironmentVariable("SUFLER_TEST") is { Length: > 0 } d ? d : null;
    public static bool Enabled => Dir is not null;

    private static void Note(string text)
    {
        try { File.AppendAllText(Path.Combine(Dir!, "log.txt"), $"[{DateTime.Now:HH:mm:ss}] {text}\n"); } catch { }
    }

    private static void Shot(Window w, string name)
    {
        try
        {
            // Снимаем корень окна, а не его содержимое: у содержимого бывают поля, и снимок съезжает
            if ((VisualTreeHelper.GetChildrenCount(w) > 0 ? VisualTreeHelper.GetChild(w, 0) : w.Content) is not FrameworkElement el || el.ActualWidth < 1) return;
            const double scale = 1.5;
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                var rect = new Rect(0, 0, el.ActualWidth, el.ActualHeight);
                dc.DrawRectangle(w.Background ?? Brushes.White, null, rect);
                // Снимаем ровно область окна: без этого кисть берёт всё содержимое вместе с тем, что прокручено
                // или выходит за край, и снимок оказывается сдвинутым
                dc.DrawRectangle(new VisualBrush(el) { Stretch = Stretch.None, ViewboxUnits = BrushMappingMode.Absolute, Viewbox = rect, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top }, null, rect);
            }
            var bmp = new RenderTargetBitmap((int)(el.ActualWidth * scale), (int)(el.ActualHeight * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            bmp.Render(visual);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(bmp));
            using var f = File.Create(Path.Combine(Dir!, name + ".png"));
            enc.Save(f);
            Note("снимок " + name);
        }
        catch (Exception ex) { Note($"снимок {name} не получился: {ex.Message}"); }
    }

    private static async Task<bool> Until(Func<bool> done, int seconds)
    {
        for (int i = 0; i < seconds * 5; i++)
        {
            if (done()) return true;
            await Task.Delay(200);
        }
        return done();
    }

    private static float[] Wav(string path)
    {
        var b = File.ReadAllBytes(path);
        int o = 12;
        while (!(b[o] == 'd' && b[o + 1] == 'a' && b[o + 2] == 't' && b[o + 3] == 'a')) o += 8 + BitConverter.ToInt32(b, o + 4);
        int n = BitConverter.ToInt32(b, o + 4) / 2;
        var x = new float[n];
        for (int i = 0; i < n; i++) x[i] = BitConverter.ToInt16(b, o + 8 + i * 2) / 32768f;
        return x;
    }

    public static async Task Run(MainWindow w)
    {
        var core = App.Core;
        try
        {
            Directory.CreateDirectory(Dir!);
            Note("старт: " + Machine.Summary);
            // Проверка обновления «по воздуху»: старая сборка должна заменить себя новой и запуститься заново
            if (Environment.GetEnvironmentVariable("SUFLER_TEST_UPDATE") is { Length: > 0 })
            {
                using var http = new System.Net.Http.HttpClient { Timeout = Timeout.InfiniteTimeSpan };
                var info = await Updater.Check(http);
                Note($"версия {Updater.CurrentText}, в канале: {info?.Version ?? "новее нет"}");
                if (info is null) { File.WriteAllText(Path.Combine(Dir!, "updated.txt"), Updater.CurrentText); return; }
                await Updater.Install(info, http, _ => { }, () => core.Dispose());
                return;
            }
            await Task.Delay(1500);

            if (w.Setup.Visibility == Visibility.Visible)
            {
                if (w.Setup.Step == 0) { Shot(w, "01-welcome"); await w.Setup.Next(); }
                await Task.Delay(400);
                Shot(w, "02-models");
                var download = w.Setup.Next();
                await Task.Delay(5000);
                if (w.Setup.Downloading) Shot(w, "03-downloading");
                await download;
                Note($"модели: {(w.Setup.ModelsReady ? "скачаны" : "НЕ скачаны")}");
                if (!w.Setup.ModelsReady) { Shot(w, "03-download-failed"); return; }
            }
            bool up = await Until(() => core.AsrReady && (core.LlmReady || core.LlmFailed), 900);
            await Until(() => core.EmbedReady || core.LlmFailed, 120);
            Note($"движки: речь={core.AsrReady} «{core.AsrStatus}», модель={core.LlmReady} «{core.LlmStatus}», поиск={core.EmbedReady}");
            if (w.Setup.Visibility == Visibility.Visible)
            {
                await Task.Delay(500);
                Shot(w, "04-ready");
                await w.Setup.Next();
            }
            await Task.Delay(600);
            Shot(w, "05-main");
            if (!up || !core.AsrReady) return;

            // Запись встречи из файлов: устройств звука на проверочной машине нет
            core.MyName = "Денис, Денис Иванов";
            core.AudioFactory = null;
            core.ToggleRecording();
            await Task.Delay(500);
            Shot(w, "06-listening");
            var wavs = Environment.GetEnvironmentVariable("SUFLER_TEST_WAVS");
            int k = 0;
            foreach (var f in wavs is null ? new List<string>() : Directory.GetFiles(wavs, "*.wav").OrderBy(x => x).ToList())
            {
                string who = Path.GetFileName(f).Contains("me") ? Speaker.Me : Speaker.Them;
                var x = Wav(f).Concat(new float[16000 * 2]).ToArray();
                for (int i = 0; i < x.Length; i += 1600) { core.FeedAudio(who, x[i..Math.Min(x.Length, i + 1600)]); await Task.Delay(100); }
                if (++k == 3) { await Until(() => core.Questions.Count > 0 && !core.Detecting, 120); Shot(w, "07-question-for-me"); }
            }
            await Task.Delay(2000);
            await Until(() => !core.Detecting, 180);
            await Task.Delay(500);
            Shot(w, "08-recording");
            Note($"реплик {core.Turns.Count}, вопросов {core.Questions.Count}");
            foreach (var t in core.Turns) Note($"  [{t.Label}] {t.Text}");
            foreach (var q in core.Questions) Note($"  вопрос{(q.ForMe ? " К ВАМ" : "")}: {q.Text} | {q.AddresseeText} | {q.AskerText} | {q.Topic}");

            w.SetCompact(true);
            await Task.Delay(800);
            Shot(w, "08b-compact");
            w.SetCompact(false);
            await Task.Delay(500);
            if (core.Questions.Count > 0 && core.LlmReady) { await core.SuggestAnswer(core.Questions[0]); await Task.Delay(300); Shot(w, "09-hint"); }

            core.ToggleRecording();
            w.Meeting.ShowTab(2);
            await Task.Delay(3000);
            if (core.Summarizing) Shot(w, "10-summary-writing");
            await Until(() => core.RecordingId == 0 && !core.Summarizing && core.KbStatus.Length == 0, 900);
            await Task.Delay(2500);
            await Until(() => core.KbStatus.Length == 0, 600);
            await Task.Delay(800);
            await Until(() => !core.CheckingNames, 300);
            // Для снимка: слово на проверку есть всегда, даже если модель ничего подозрительного не нашла
            if (core.NameChecks.Count == 0 && core.Turns.Count > 0) core.NameChecks.Add(new NameCheck { Heard = "Марина", Guess = "", Input = "", Quote = "…Отвечает за него Марина", TurnId = core.Turns[0].Id });
            await Task.Delay(400);
            Shot(w, "11-summary");
            Note("итог: " + core.Selected?.Summary);
            foreach (var c in core.NameChecks) Note($"  проверить: «{c.Heard}» → «{c.Guess}»");
            if (core.Selected is { } rec && core.Turns.Count > 0)
            {
                var t0 = core.Turns[0];
                Note($"звук встречи: файл {(MeetingAudio.Exists(rec.Id) ? new FileInfo(MeetingAudio.PathOf(rec.Id)).Length : 0)} байт; первая реплика {t0.AudioStart:0.0}–{t0.AudioEnd:0.0} с, можно играть: {t0.CanPlay}, прочитано отсчётов: {MeetingAudio.Read(rec.Id, t0.AudioStart, t0.AudioEnd).Length}");
            }
            if (core.NameChecks.Count > 0) { core.ResolveCheck(core.NameChecks[0], core.NameChecks[0].Heard); Note("словарь имён: " + core.Glossary); }
            core.MicStartedBy("Zoom Meetings", "Zoom Zoom Meetings");
            await Task.Delay(700);
            Shot(w, "11b-call-offer");
            core.CallOffer = "";

            if (core.LlmReady)
            {
                w.Meeting.ShowTab(1);
                await core.Ask("Когда релиз на всех?");
                await core.Ask("А кто отвечает за бюджет?");
                await Task.Delay(500);
                Shot(w, "12-chat");

                core.ShowKb = true;
                await Task.Delay(500);
                await core.Ask("Запомни, что офис переезжает на Ленинский проспект в марте");
                await core.Ask("Запомни, что сегодня хорошая погода");
                await core.Ask("Проведи аудит фактов");
                await Task.Delay(500);
                Shot(w, "13-knowledge");
                foreach (var fct in core.Facts) Note("  факт: " + fct.Text);

                var doc = Path.Combine(Dir!, "Регламент отпусков.txt");
                File.WriteAllText(doc, "Регламент отпусков.\nЗаявление на отпуск подаётся за 14 дней через портал.\nОтпуск согласует руководитель отдела, затем отдел кадров.");
                if (core.Selected is { Summary.Length: > 0 } m) Documents.SaveSummaryDocx(Path.Combine(Dir!, "Итог встречи.docx"), m);
                await core.AddDocuments(Directory.GetFiles(Dir!).Where(x => x.EndsWith(".txt") && !x.EndsWith("log.txt") || x.EndsWith(".docx")));
                w.Knowledge.ShowTab(1);
                await core.Ask("За сколько дней подавать заявление на отпуск?");
                await Task.Delay(500);
                Shot(w, "14-documents");
            }

            var settings = new SettingsWindow { Owner = w };
            settings.Show();
            await Task.Delay(800);
            Shot(settings, "15-settings");
            foreach (var pane in new[] { "recording", "speech", "models", "privacy", "about" })
            {
                settings.ShowPane(pane);
                await Task.Delay(400);
                Shot(settings, "15-settings-" + pane);
            }
            settings.Close();
            w.ShowStats();
            await Task.Delay(800);
            Shot(w, "16-stats");
            var consent = new ConsentWindow { Owner = w };
            consent.Show();
            await Task.Delay(600);
            Shot(consent, "17-consent");
            consent.Close();
            var feedback = new FeedbackWindow { Owner = w };
            feedback.Show();
            await Task.Delay(600);
            Shot(feedback, "18-feedback");
            feedback.Close();
            File.WriteAllText(Path.Combine(Dir!, "diag.txt"), core.Diagnostics(Updater.CurrentText));
            Note("готово");
        }
        catch (Exception ex) { Note("ОШИБКА: " + ex); }
        finally
        {
            try { File.WriteAllText(Path.Combine(Dir!, "done.txt"), "done"); } catch { }
            Application.Current.Shutdown();
        }
    }
}
