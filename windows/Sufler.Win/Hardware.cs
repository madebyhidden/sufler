using Microsoft.Win32;

namespace Sufler;

/// <summary>Что за компьютер: от этого зависит, какую модель брать и на чём её считать.</summary>
public static class Hardware
{
    /// <summary>Заполняет общие для ядра сведения о компьютере.</summary>
    public static void Fill()
    {
        Machine.RamGb = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1e9;
        Machine.Cpu = ReadCpu();
        (Machine.GpuName, Machine.VramGb) = ReadGpu();
        Machine.Os = Environment.OSVersion.VersionString;
    }

    private static string ReadCpu()
    {
        try { return (Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", null) as string)?.Trim() ?? "процессор неизвестен"; }
        catch { return "процессор неизвестен"; }
    }

    private static (string, double) ReadGpu()
    {
        string name = "";
        double best = -1;
        try
        {
            using var cls = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}");
            if (cls is null) return ("", 0);
            foreach (var sub in cls.GetSubKeyNames())
            {
                if (sub.Length != 4 || !sub.All(char.IsDigit)) continue;
                try
                {
                    using var k = cls.OpenSubKey(sub);
                    if (k?.GetValue("DriverDesc") is not string desc) continue;
                    double gb = Bytes(k.GetValue("HardwareInformation.qwMemorySize") ?? k.GetValue("HardwareInformation.MemorySize")) / 1e9;
                    if (gb > best) { best = gb; name = desc.Trim(); }
                }
                catch { }
            }
        }
        catch { }
        return (name, Math.Max(0, best));
    }

    private static double Bytes(object? v) => v switch
    {
        long l => l,
        int i => (uint)i,
        byte[] { Length: >= 8 } b => BitConverter.ToInt64(b, 0),
        byte[] { Length: >= 4 } b => BitConverter.ToUInt32(b, 0),
        _ => 0,
    };
}
