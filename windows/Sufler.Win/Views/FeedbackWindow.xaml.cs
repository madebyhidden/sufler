using System.Windows;

namespace Sufler.Views;

/// <summary>Отзыв или сообщение об ошибке: уходит разработчику, тексты встреч к нему не прикладываются.</summary>
public partial class FeedbackWindow : Window
{
    public FeedbackWindow() => InitializeComponent();

    private string Kind => KindBug.IsChecked == true ? "bug" : KindOther.IsChecked == true ? "other" : "idea";

    private void OnKind(object sender, RoutedEventArgs e)
    {
        if (Placeholder is null) return;
        Placeholder.Text = Kind == "bug" ? "Что произошло и что вы ожидали? Если можно — что делали перед этим." : "Что добавить или улучшить?";
    }

    private void OnText(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        Placeholder.Visibility = TextBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        SendButton.IsEnabled = TextBox.Text.Trim().Length >= 3;
    }

    private void OnSend(object sender, RoutedEventArgs e)
    {
        App.Core.SubmitFeedback(Kind, TextBox.Text.Trim(), ContactBox.Text.Trim(), AttachCheck.IsChecked == true, Updater.CurrentText);
        DoneNote.Text = Telemetry.Enabled
            ? "Он уже отправлен или уйдёт, как только появится интернет."
            : "Он уйдёт разработчику, как только в приложении появится канал отправки, — обновление придёт само.";
        Form.Visibility = Visibility.Collapsed;
        Done.Visibility = Visibility.Visible;
    }
}
