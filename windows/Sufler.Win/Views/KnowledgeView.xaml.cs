using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Sufler.Views;

public partial class KnowledgeView : UserControl
{
    private AppCore Core => App.Core;

    public KnowledgeView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Core.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppCore.IsRecording)) RefreshRecord(); };
            RefreshRecord();
        };
    }

    private void RefreshRecord()
    {
        bool rec = Core.IsRecording;
        RecordText.Text = rec ? "Остановить" : "Начать запись";
        RecordIcon.Text = rec ? "" : "";
        RecordButton.Background = (Brush)FindResource(rec ? "Bad" : "Accent");
    }

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (FactsPane is null || DocsPane is null) return;
        FactsPane.Visibility = TabFacts.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        DocsPane.Visibility = TabDocs.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Открыть вкладку: 0 — факты, 1 — документы.</summary>
    public void ShowTab(int index) => (index == 1 ? TabDocs : TabFacts).IsChecked = true;

    private void OnRecord(object sender, RoutedEventArgs e) => Core.ToggleRecording();
    private void OnCloseError(object sender, RoutedEventArgs e) => Core.ErrorText = "";

    private async void OnAddFiles(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Filter = Documents.Filter, Title = "Файлы для базы знаний: PDF, Word, текст, Markdown" };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
        ShowTab(1);
        await Core.AddDocuments(dlg.FileNames);
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
        ShowTab(1);
        await Core.AddDocuments(files);
    }

    private void OnDeleteFact(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Fact f) Core.DeleteFact(f);
    }

    private void OnDeleteDoc(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Doc d) Core.DeleteDocument(d);
    }
}
