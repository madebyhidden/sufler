using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Sufler.Views;

/// <summary>Чат: по открытой встрече или по базе знаний — смотря где он стоит.</summary>
public partial class ChatPanel : UserControl
{
    public static readonly DependencyProperty HintProperty = DependencyProperty.Register(nameof(Hint), typeof(string), typeof(ChatPanel), new PropertyMetadata(""));
    public static readonly DependencyProperty PlaceholderProperty = DependencyProperty.Register(nameof(Placeholder), typeof(string), typeof(ChatPanel), new PropertyMetadata(""));
    public string Hint { get => (string)GetValue(HintProperty); set => SetValue(HintProperty, value); }
    public string Placeholder { get => (string)GetValue(PlaceholderProperty); set => SetValue(PlaceholderProperty, value); }

    private AppCore Core => App.Core;

    public ChatPanel()
    {
        InitializeComponent();
        SendButton.IsEnabled = false;
        Loaded += (_, _) => Core.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppCore.ChatBusy) or nameof(AppCore.LlmReady) or nameof(AppCore.AsrReady)) RefreshSend();
            if (e.PropertyName == nameof(AppCore.Dictating)) RefreshMic();
        };
        Scroll.ScrollChanged += (_, e) => { if (e.ExtentHeightChange > 0) Scroll.ScrollToEnd(); };
    }

    private void RefreshSend()
    {
        SendButton.IsEnabled = !Core.ChatBusy && Core.LlmReady && Input.Text.Trim().Length > 0;
        MicButton.IsEnabled = Core.Dictating || (!Core.ChatBusy && Core.LlmReady && Core.AsrReady);
    }

    private string _placeholder = "";

    /// <summary>Пока идёт диктовка, кнопка микрофона красная, а в поле — подсказка «говорите».</summary>
    private void RefreshMic()
    {
        bool on = Core.Dictating;
        MicButton.Foreground = (System.Windows.Media.Brush)FindResource(on ? "Bad" : "Second");
        MicButton.Content = on ? "\uE71A" : "\uE720";
        MicButton.ToolTip = on ? "Отменить диктовку" : "Задать вопрос голосом";
        if (on) { _placeholder = Placeholder; Placeholder = "Говорите — после паузы вопрос отправится сам…"; }
        else if (_placeholder.Length > 0) Placeholder = _placeholder;
        RefreshSend();
    }

    private void OnMic(object sender, RoutedEventArgs e) => Core.ToggleDictation();

    private void OnInput(object sender, TextChangedEventArgs e)
    {
        PlaceholderText.Visibility = Input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RefreshSend();
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Send(); e.Handled = true; }
    }

    private void OnSend(object sender, RoutedEventArgs e) => Send();

    private async void Send()
    {
        if (!SendButton.IsEnabled) return;
        var text = Input.Text;
        if (Core.Dictating) Core.CancelDictation();
        Core.ChatInput = "";
        await Core.Ask(text);
    }

    private async void OnApply(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is ChatLine line) await Core.ApplyProposal(line);
    }

    private void OnReject(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is ChatLine line) Core.RejectProposal(line);
    }
}
