using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Sufler;

/// <summary>
/// Обновления «по воздуху»: приложение читает маленький файл с номером последней версии,
/// скачивает архив самого приложения (модели не трогаются), проверяет подпись и заменяет себя.
/// </summary>
public static class Updater
{
    public const string ManifestUrl = "https://github.com/madebyhidden/sufler/releases/download/win-channel/update-win.json";
    /// <summary>Открытый ключ Ed25519 — тот же, что у версии для Mac. Архив без подписи парным ключом не установится.</summary>
    public const string PublicKey = "YP++IUeTcwDBDq0FFK4qvrcuun/13KLkg/xOxSJ/CtE=";

    public sealed record Info(string Version, string Notes, string Url, string Signature, long Size);

    public static Version Current => Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0);
    public static string CurrentText => $"{Current.Major}.{Current.Minor}.{Current.Build}";

    public static async Task<Info?> Check(HttpClient http)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var json = await http.GetStringAsync(ManifestUrl + "?t=" + DateTimeOffset.UtcNow.ToUnixTimeSeconds(), cts.Token);
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            var info = new Info(r.GetProperty("version").GetString()!, r.TryGetProperty("notes", out var n) ? n.GetString() ?? "" : "",
                r.GetProperty("url").GetString()!, r.GetProperty("signature").GetString()!, r.TryGetProperty("size", out var s) ? s.GetInt64() : 0);
            return Version.TryParse(info.Version, out var v) && v > new Version(Current.Major, Current.Minor, Math.Max(0, Current.Build)) ? info : null;
        }
        catch { return null; }
    }

    public static async Task Install(Info info, HttpClient http, Action<double> progress, Action beforeExit)
    {
        var app = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        // Проверяем, что в свою папку можно писать (например, приложение не запущено прямо из архива)
        try { File.WriteAllText(Path.Combine(app, ".write-test"), ""); File.Delete(Path.Combine(app, ".write-test")); }
        catch { throw new Exception("Нет прав на запись в папку приложения. Распакуйте его в обычную папку и запустите оттуда."); }

        var dir = Path.Combine(Path.GetTempPath(), "sufler-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var zip = Path.Combine(dir, "update.zip");
        using (var resp = await http.GetAsync(info.Url, HttpCompletionOption.ResponseHeadersRead))
        {
            resp.EnsureSuccessStatusCode();
            long total = resp.Content.Headers.ContentLength ?? info.Size;
            await using var src = await resp.Content.ReadAsStreamAsync();
            await using var dst = File.Create(zip);
            var buf = new byte[1 << 20];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n));
                done += n;
                if (total > 0) progress((double)done / total);
            }
        }

        // Подпись: архив должен быть выпущен владельцем ключа
        var data = await File.ReadAllBytesAsync(zip);
        var verifier = new Ed25519Signer();
        verifier.Init(false, new Ed25519PublicKeyParameters(Convert.FromBase64String(PublicKey), 0));
        verifier.BlockUpdate(data, 0, data.Length);
        if (!verifier.VerifySignature(Convert.FromBase64String(info.Signature)))
            throw new Exception("Подпись обновления не сошлась — установка отменена.");

        var fresh = Path.Combine(dir, "new");
        ZipFile.ExtractToDirectory(zip, fresh, true);
        if (!File.Exists(Path.Combine(fresh, "Sufler.exe"))) throw new Exception("Архив обновления повреждён.");

        // Заменить себя на ходу нельзя: это делает маленький сценарий после нашего выхода.
        // Пути передаём через переменные окружения — так им не страшны русские буквы и пробелы.
        // Ждём не по списку процессов (он на части систем отвечает не так, как ожидается), а по самому файлу:
        // пока приложение живо, его библиотека занята и на запись не открывается.
        var script = Path.Combine(dir, "install.cmd");
        var sb = new StringBuilder();
        sb.AppendLine("@echo off");
        sb.AppendLine("set /a n=0");
        sb.AppendLine(":wait");
        sb.AppendLine("2>nul (>>\"%SUF_APP%\\Sufler.dll\" (call )) && goto copy");
        sb.AppendLine("set /a n+=1");
        sb.AppendLine("if %n% GEQ 8 taskkill /IM Sufler.exe /F >nul 2>&1");
        sb.AppendLine("if %n% GEQ 60 goto copy");
        sb.AppendLine("ping -n 2 127.0.0.1 >nul");
        sb.AppendLine("goto wait");
        sb.AppendLine(":copy");
        // Зависшая или вторая копия приложения держит файлы занятыми, и они не заменяются — закрываем все копии
        sb.AppendLine("taskkill /IM Sufler.exe /F >nul 2>&1");
        sb.AppendLine("ping -n 2 127.0.0.1 >nul");
        sb.AppendLine("robocopy \"%SUF_NEW%\" \"%SUF_APP%\" /E /IS /IT /R:30 /W:1 /NP > \"%SUF_LOG%\" 2>&1");
        sb.AppendLine("start \"\" \"%SUF_APP%\\Sufler.exe\"");
        await File.WriteAllTextAsync(script, sb.ToString(), Encoding.ASCII);
        var psi = new ProcessStartInfo("cmd.exe", $"/c \"{script}\"") { CreateNoWindow = true, UseShellExecute = false, WorkingDirectory = dir };
        psi.Environment["SUF_APP"] = app;
        psi.Environment["SUF_NEW"] = fresh;
        psi.Environment["SUF_PID"] = Environment.ProcessId.ToString();
        psi.Environment["SUF_LOG"] = Path.Combine(Models.Root, "update.log");
        Process.Start(psi);
        try { beforeExit(); } catch { }
        // Выходим сразу и наверняка: обычное завершение может ждать фоновые потоки моделей
        Process.GetCurrentProcess().Kill();
        Environment.Exit(0);
    }
}
