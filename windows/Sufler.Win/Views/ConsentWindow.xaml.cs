using System.Windows;

namespace Sufler.Views;

/// <summary>Один раз спрашиваем, можно ли отправлять анонимную статистику. Закрыть окно крестиком — то же, что отказаться.</summary>
public partial class ConsentWindow : Window
{
    private bool _answered;

    public ConsentWindow()
    {
        InitializeComponent();
        Closed += (_, _) => { if (!_answered) App.Core.SetTelemetry(false, Updater.CurrentText); };
    }

    private void OnYes(object sender, RoutedEventArgs e) { _answered = true; App.Core.SetTelemetry(true, Updater.CurrentText); Close(); }
    private void OnNo(object sender, RoutedEventArgs e) { _answered = true; App.Core.SetTelemetry(false, Updater.CurrentText); Close(); }
}
