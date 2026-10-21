using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;

namespace Sufler;

/// <summary>Значки из системного шрифта Windows (Segoe Fluent Icons / Segoe MDL2 Assets).</summary>
public static class Glyph
{
    public const string Mic = "", MicOff = "", Stop = "", Library = "", Settings = "", Delete = "",
        Add = "", Send = "", Down = "", Bulb = "", Page = "", Copy = "", Refresh = "",
        Lock = "", Chat = "", Question = "", Person = "", Bell = "", Check = "", Download = "",
        Warning = "", Close = "", People = "", Record = "", List = "", Message = "", Edit = "",
        Sound = "", Search = "", Shield = "", Word = "", Remove = "", Swap = "", Ear = "";
}

/// <summary>Показать элемент, если значение «не пустое»: true, непустая строка, число не ноль, объект. Параметр «!» — наоборот.</summary>
public sealed class VisConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        bool on = value switch
        {
            bool b => b,
            string s => s.Length > 0,
            int i => i != 0,
            long l => l != 0,
            null => false,
            _ => true,
        };
        if (parameter as string == "!") on = !on;
        return on ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>Цвет подписи для каждого голоса, чтобы собеседников было видно с одного взгляда.</summary>
public sealed class VoiceBrushConverter : IValueConverter
{
    private static readonly Brush[] Palette = new[] { "#1FA39B", "#F0932B", "#E0569B", "#2EAD5B", "#8E5CE6", "#A0714B" }
        .Select(c => { var b = (Brush)new BrushConverter().ConvertFromString(c)!; b.Freeze(); return b; }).ToArray();
    private static readonly Brush Gray = Frozen("#6B6F7B");

    private static Brush Frozen(string c) { var b = (Brush)new BrushConverter().ConvertFromString(c)!; b.Freeze(); return b; }

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        int n = value is int i ? i : 0;
        return n == 0 ? Gray : Palette[(n > 0 ? n - 1 : 1 - n) % Palette.Length];
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>Конец длинного текста: в компактном окне важнее последние слова реплики.</summary>
public sealed class TailConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is string { Length: > 190 } s ? "…" + s[^190..] : value ?? "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class OpGlyphConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        (value as string) switch { "delete" => Glyph.Remove, "add" => Glyph.Add, _ => Glyph.Refresh };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class OpBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Application.Current.Resources[(value as string) switch { "delete" => "Bad", "add" => "Good", _ => "Warn" }];
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

public static class Ui
{
    /// <summary>
    /// Колесо мыши над вложенными текстами: выделяемый текст внутри списка перехватывает прокрутку,
    /// и список перестаёт листаться. С этим свойством область прокрутки листает себя сама.
    /// </summary>
    public static readonly DependencyProperty WheelProperty =
        DependencyProperty.RegisterAttached("Wheel", typeof(bool), typeof(Ui), new PropertyMetadata(false, (d, e) =>
        {
            if (d is not ScrollViewer sv || e.NewValue is not true) return;
            sv.PreviewMouseWheel += (_, a) =>
            {
                sv.ScrollToVerticalOffset(sv.VerticalOffset - a.Delta * 0.6);
                a.Handled = true;
            };
        }));

    public static void SetWheel(DependencyObject d, bool v) => d.SetValue(WheelProperty, v);
    public static bool GetWheel(DependencyObject d) => (bool)d.GetValue(WheelProperty);

    /// <summary>Строка итога с пометками «**полужирный**» — в кусочки текста.</summary>
    public static void AddMarked(System.Windows.Documents.InlineCollection into, string text, bool bold = false)
    {
        var parts = text.Split("**");
        for (int i = 0; i < parts.Length; i++)
        {
            if (parts[i].Length == 0) continue;
            var run = new System.Windows.Documents.Run(parts[i]);
            if (bold || i % 2 == 1) run.FontWeight = FontWeights.SemiBold;
            into.Add(run);
        }
    }

    /// <summary>Простой вопрос с полем ввода: возвращает текст или null, если отменили.</summary>
    public static string? Prompt(Window owner, string title, string note, string value)
    {
        var box = new TextBox { Text = value, Style = (Style)Application.Current.Resources["Field"], Margin = new Thickness(0, 12, 0, 16) };
        var ok = new Button { Content = "Сохранить", Style = (Style)Application.Current.Resources["Pill"], IsDefault = true };
        var cancel = new Button { Content = "Отмена", Style = (Style)Application.Current.Resources["PillGray"], IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 16, FontWeight = FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = note, Foreground = (Brush)Application.Current.Resources["Second"], TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), FontSize = 12.5 });
        panel.Children.Add(box);
        panel.Children.Add(buttons);
        var w = new Window { Owner = owner, Title = "Суфлёр", Width = 400, Content = panel, Style = (Style)Application.Current.Resources["Dialog"], WindowStartupLocation = WindowStartupLocation.CenterOwner };
        ok.Click += (_, _) => w.DialogResult = true;
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return w.ShowDialog() == true ? box.Text : null;
    }
}

/// <summary>Цвет из строки «#RRGGBB» — им ядро помечает итоги и вердикты. Параметр — прозрачность фона, например «0.1».</summary>
public sealed class HexBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not string { Length: 7 } hex) return Brushes.Transparent;
        var c = (Color)ColorConverter.ConvertFromString(hex);
        if (parameter is string p && double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out double a)) c.A = (byte)(a * 255);
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>Палитра режима: в собеседованиях — сине-зелёная, чтобы режим было видно с одного взгляда.</summary>
public static class Theme
{
    public static void Apply(bool interview)
    {
        var c = interview ? Color.FromRgb(0x00, 0x87, 0x99) : Color.FromRgb(0x5C, 0x57, 0xEB);
        Set("Accent", c, 0xFF);
        Set("AccentSoft", c, 0x1F);
        Set("AccentFaint", c, 0x12);
        Set("AccentLine", c, 0x59);
    }

    private static void Set(string key, Color c, byte alpha)
    {
        var res = Application.Current.Resources;
        var color = Color.FromArgb(alpha, c.R, c.G, c.B);
        // Кисти из ресурсов не заморожены — меняем цвет на месте, и он обновляется во всех окнах сразу
        if (res[key] is SolidColorBrush b && !b.IsFrozen) b.Color = color;
        else res[key] = new SolidColorBrush(color);
    }

    public static Brush Hex(string hex, double alpha = 1)
    {
        var c = (Color)ColorConverter.ConvertFromString(hex);
        c.A = (byte)(alpha * 255);
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}

/// <summary>Сборка мелких элементов из кода: карточки разбора и оценки состоят из списков разной длины.</summary>
public static class Make
{
    private static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    public static TextBlock Text(string text, double size = 13.5, FontWeight? weight = null, Brush? color = null, Thickness? margin = null)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = color ?? Res("Ink"), Margin = margin ?? new Thickness(0) };
        if (weight is { } w) t.FontWeight = w;
        return t;
    }

    public static TextBlock Caps(string text, Brush? color = null, double top = 0) =>
        new() { Text = text, FontSize = 10.5, FontWeight = FontWeights.Bold, Foreground = color ?? Res("Second"), Margin = new Thickness(0, top, 0, 6) };

    public static TextBox Selectable(string text, double size = 13.5, Brush? color = null) =>
        new() { Text = text, Style = (Style)Application.Current.Resources["Selectable"], FontSize = size, Foreground = color ?? Res("Ink") };

    public static Border Box(UIElement child, Brush back, Brush? line = null, double radius = 12, double pad = 12, double bottom = 10) =>
        new() { Child = child, Background = back, BorderBrush = line ?? Brushes.Transparent, BorderThickness = new Thickness(line is null ? 0 : 1.5), CornerRadius = new CornerRadius(radius), Padding = new Thickness(pad), Margin = new Thickness(0, 0, 0, bottom) };

    public static Border Chip(string text, Brush color) =>
        new()
        {
            Background = color is SolidColorBrush s ? Theme.Hex($"#{s.Color.R:X2}{s.Color.G:X2}{s.Color.B:X2}", 0.14) : Res("Soft"),
            CornerRadius = new CornerRadius(11), Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = color },
        };

    /// <summary>Шкала из пяти делений: оценка 0–5.</summary>
    public static StackPanel Scale(int score, Brush color, double opacity = 1, double w = 16, double h = 9)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        for (int i = 1; i <= 5; i++)
            p.Children.Add(new Border { Width = w, Height = h, CornerRadius = new CornerRadius(2.5), Margin = new Thickness(0, 0, 3, 0), Background = i <= score ? color : Res("Line"), Opacity = i <= score ? opacity : 1 });
        return p;
    }

    public static Button Soft(string text, string glyph, RoutedEventHandler click)
    {
        var b = new Button { Style = (Style)Application.Current.Resources["PillSoft"], Margin = new Thickness(0, 6, 8, 0) };
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(new TextBlock { Style = (Style)Application.Current.Resources["Icon"], Text = glyph, FontSize = 12, Margin = new Thickness(0, 0, 6, 0) });
        sp.Children.Add(new TextBlock { Text = text });
        b.Content = sp;
        b.Click += click;
        return b;
    }

    public static StackPanel List(string title, Brush color, IEnumerable<string> items)
    {
        var p = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        p.Children.Add(Text(title, 13, FontWeights.SemiBold, color, new Thickness(0, 0, 0, 4)));
        foreach (var x in items) p.Children.Add(Text("•  " + x, 13.5, margin: new Thickness(0, 0, 0, 3)));
        return p;
    }
}
