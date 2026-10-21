using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Sufler.Views;

/// <summary>Уведомление «вопрос к вам»: плашка в углу экрана поверх всех окон и мигание значка на панели задач.</summary>
public static class Toast
{
    private static Window? _current;

    public static void Show(Window owner, string title, string body, string? action = null, Action? onAction = null)
    {
        try
        {
            _current?.Close();
            Brush Res(string key) => (Brush)Application.Current.Resources[key];
            var text = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
            text.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.Bold, FontSize = 13, Foreground = Res("Alert") });
            text.Children.Add(new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap, FontSize = 14, FontWeight = FontWeights.Medium, Margin = new Thickness(0, 3, 0, 0), MaxHeight = 80, TextTrimming = TextTrimming.CharacterEllipsis });
            if (action is not null)
            {
                var button = new Button { Content = action, Style = (Style)Application.Current.Resources["Pill"], FontSize = 12.5, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 9, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
                button.Click += (_, e) => { e.Handled = true; _current?.Close(); _current = null; owner.Activate(); onAction?.Invoke(); };
                text.Children.Add(button);
            }
            var row = new DockPanel();
            var icon = new TextBlock { Text = "", FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 20, Foreground = Res("Alert"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            row.Children.Add(text);
            var card = new Border
            {
                Background = Brushes.White, CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 14, 16, 14), Margin = new Thickness(14),
                BorderBrush = Res("Alert"), BorderThickness = new Thickness(1.5), Child = row,
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Direction = 270, Opacity = 0.22 },
            };
            var w = new Window
            {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true, ShowInTaskbar = false,
                ShowActivated = false, Width = 400, SizeToContent = SizeToContent.Height, Content = card,
                FontFamily = (FontFamily)Application.Current.Resources["TextFont"], Foreground = Res("Ink"),
            };
            var area = SystemParameters.WorkArea;
            w.Left = area.Right - w.Width - 6;
            w.Loaded += (_, _) => w.Top = area.Bottom - w.ActualHeight - 6;
            w.Top = area.Bottom - 140;
            w.MouseLeftButtonUp += (_, _) => { w.Close(); owner.Activate(); };
            w.Show();
            _current = w;
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(action is null ? 8 : 25) };
            timer.Tick += (_, _) => { timer.Stop(); if (ReferenceEquals(_current, w)) _current = null; w.Close(); };
            timer.Start();
            if (!owner.IsActive) Flash(owner);
        }
        catch { }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }

    [DllImport("user32.dll")]
    private static extern bool FlashWindowEx(ref FLASHWINFO info);

    private static void Flash(Window w)
    {
        var info = new FLASHWINFO { hwnd = new WindowInteropHelper(w).Handle, dwFlags = 3 | 12, uCount = 5 };
        info.cbSize = (uint)Marshal.SizeOf(info);
        FlashWindowEx(ref info);
    }
}
