using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Sufler.Views;

public partial class LibraryView : UserControl
{
    private AppCore Core => App.Core;
    private bool _loading;
    private bool _listExpanded;

    public LibraryView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Core.PropertyChanged += OnCore;
            Core.Vacancies.CollectionChanged += (_, _) => Refresh();
            Core.Resumes.CollectionChanged += (_, _) => Refresh();
            LoadVacancy();
            LoadResume();
            Refresh();
        };
    }

    private Brush Res(string key) => (Brush)FindResource(key);

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppCore.LibVacancy) or nameof(AppCore.LibLoose): LoadVacancy(); Refresh(); break;
            case nameof(AppCore.LibResume): _listExpanded = false; LoadResume(); Refresh(); break;
            case nameof(AppCore.LibResumes) or nameof(AppCore.IsRecording): Refresh(); break;
        }
    }

    /// <summary>Раскладка колонок: открыт кандидат — список вакансий сворачивается в полоску, чтобы средней колонке хватало места.</summary>
    private void Refresh()
    {
        bool resume = Core.LibResume is not null;
        bool rail = resume && !_listExpanded;
        ListColumn.Width = new GridLength(rail ? 52 : 230);
        ListFull.Visibility = rail ? Visibility.Collapsed : Visibility.Visible;
        ListRail.Visibility = rail ? Visibility.Visible : Visibility.Collapsed;
        GapColumn.Width = new GridLength(resume ? 14 : 0);
        ResumeColumn.Width = resume ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        ResumeColumn.MinWidth = resume ? 280 : 0;
        ResumeCard.Visibility = resume ? Visibility.Visible : Visibility.Collapsed;

        bool hasVacancy = Core.LibVacancy is not null || Core.LibLoose;
        VacancyPane.Visibility = hasVacancy ? Visibility.Visible : Visibility.Collapsed;
        NoVacancy.Visibility = hasVacancy ? Visibility.Collapsed : Visibility.Visible;
        VacancyFields.Visibility = Core.LibLoose ? Visibility.Collapsed : Visibility.Visible;
        LooseTitle.Visibility = Core.LibLoose ? Visibility.Visible : Visibility.Collapsed;
        ResumeFiles.Visibility = ResumePaste.Visibility = Core.LibLoose ? Visibility.Collapsed : Visibility.Visible;
        int n = Core.LibResumes.Count;
        CandidatesTitle.Text = $"КАНДИДАТЫ · {n}";
        NoResumes.Visibility = n == 0 ? Visibility.Visible : Visibility.Collapsed;
        StartButton.IsEnabled = !Core.IsRecording;
        RenderResult();
    }

    private void LoadVacancy()
    {
        _loading = true;
        var v = Core.LibVacancy;
        VacancyTitle.Text = v?.Title ?? "";
        VacancyText.Text = v?.Text ?? "";
        VacancyNotes.Text = v?.Notes ?? "";
        _loading = false;
    }

    private void LoadResume()
    {
        _loading = true;
        var r = Core.LibResume;
        ResumeName.Text = r?.Name ?? "";
        ResumeText.Text = r?.Text ?? "";
        var items = new List<Vacancy> { new() { Id = 0, Title = "Без вакансии" } };
        items.AddRange(Core.Vacancies);
        ResumeVacancy.ItemsSource = items;
        ResumeVacancy.SelectedItem = items.FirstOrDefault(v => v.Id == (r?.VacancyId ?? 0));
        _loading = false;
    }

    /// <summary>Итог последнего собеседования в карточке кандидата.</summary>
    private void RenderResult()
    {
        ResultBox.Children.Clear();
        if (Core.LibResume?.Result is not { } res) { StartText.Text = "Начать собеседование"; return; }
        StartText.Text = "Ещё одно собеседование";
        var tint = Theme.Hex(Core.LibResume.ResultColor);
        var s = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var date = Make.Text(res.Date.ToString("d MMM", Ru.Culture), 12, color: Res("Second"));
        DockPanel.SetDock(date, Dock.Right);
        head.Children.Add(date);
        head.Children.Add(new TextBlock { Text = "СОБЕСЕДОВАНИЕ ПРОЙДЕНО", FontSize = 11, FontWeight = FontWeights.Bold, Foreground = tint });
        s.Children.Add(head);
        if (res.Report is { } r)
        {
            s.Children.Add(Make.Text($"{r.Fit}% · {Verdicts.Hire(r.Verdict)}", 16, FontWeights.SemiBold, tint));
            s.Children.Add(Make.Text(r.Summary, 12.5, color: Res("Second"), margin: new Thickness(0, 4, 0, 8)));
            // Самые сильные и самые слабые места — с одного взгляда
            var sorted = r.Competencies.OrderByDescending(c => c.Score).ToList();
            var shown = sorted.Take(2).Concat(sorted.TakeLast(2).Where(c => !sorted.Take(2).Contains(c))).ToList();
            if (r.Business is { } b) shown.Add(new Competency { Name = "Бизнес-логика", Score = b.Score });
            foreach (var c in shown)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
                var scale = Make.Scale(c.Score, Theme.Hex(Verdicts.ScoreColor(c.Score)), 1, 10, 6);
                DockPanel.SetDock(scale, Dock.Right);
                row.Children.Add(scale);
                row.Children.Add(new TextBlock { Text = c.Name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
                s.Children.Add(row);
            }
        }
        else s.Children.Add(Make.Text("Оценку ещё не составили — откройте собеседование и нажмите «Оценить кандидата».", 12, color: Res("Second")));
        var open = Make.Soft("Открыть собеседование", "", (_, _) => { if (Core.Meetings.FirstOrDefault(m => m.Id == res.MeetingId) is { } m) Core.Select(m); });
        s.Children.Add(open);
        ResultBox.Children.Add(Make.Box(s, Theme.Hex(Core.LibResume.ResultColor, 0.09), Theme.Hex(Core.LibResume.ResultColor, 0.35), 12, 12, 0));
    }

    // MARK: Вакансии

    private void OnNewVacancy(object sender, RoutedEventArgs e)
    {
        Core.NewVacancy();
        VacancyTitle.Focus();
        VacancyTitle.SelectAll();
    }

    private void OnVacancyFile(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Filter = Documents.Filter, Title = "Выберите описание вакансии" };
        if (dlg.ShowDialog() != true) return;
        if (Documents.ExtractText(dlg.FileName)?.Trim() is { Length: > 0 } text) Core.NewVacancy(text, System.IO.Path.GetFileNameWithoutExtension(dlg.FileName));
        else Core.ErrorText = $"Не удалось прочитать текст из «{System.IO.Path.GetFileName(dlg.FileName)}».";
    }

    private void OnVacancyEdited(object sender, TextChangedEventArgs e)
    {
        if (_loading || Core.LibVacancy is not { } v) return;
        v.Title = VacancyTitle.Text;
        v.Text = VacancyText.Text;
        v.Notes = VacancyNotes.Text;
        Core.SaveVacancy(v);
    }

    private void OnDeleteVacancy(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not Vacancy v) return;
        if (MessageBox.Show(Window.GetWindow(this)!, $"Удалить вакансию «{v.Title}» вместе с резюме кандидатов? Проведённые собеседования останутся.", "Суфлёр", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            Core.DeleteVacancy(v);
    }

    private void OnLoose(object sender, RoutedEventArgs e)
    {
        Core.LibVacancy = null;
        Core.LibLoose = true;
        Core.LibResume = null;
    }

    private void OnExpandList(object sender, RoutedEventArgs e) { _listExpanded = true; Refresh(); }

    // MARK: Кандидаты

    private void OnResumeFiles(object sender, RoutedEventArgs e)
    {
        if (Core.LibVacancy is not { } v) return;
        var dlg = new Microsoft.Win32.OpenFileDialog { Filter = Documents.Filter, Title = "Выберите резюме кандидатов", Multiselect = true };
        if (dlg.ShowDialog() != true) return;
        foreach (var path in dlg.FileNames)
        {
            if (Documents.ExtractText(path)?.Trim() is { Length: > 0 } text) Core.NewResume(v.Id, System.IO.Path.GetFileNameWithoutExtension(path), text);
            else Core.ErrorText = $"Не удалось прочитать текст из «{System.IO.Path.GetFileName(path)}».";
        }
    }

    private void OnNewResume(object sender, RoutedEventArgs e)
    {
        if (Core.LibVacancy is not { } v) return;
        Core.NewResume(v.Id);
        ResumeText.Focus();
    }

    private void OnPickResume(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Resume r) Core.LibResume = r;
    }

    private void OnStartInterview(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Resume r) Core.StartInterview(r);
    }

    private void OnStartSelected(object sender, RoutedEventArgs e)
    {
        if (Core.LibResume is { } r) Core.StartInterview(r);
    }

    private void OnResumeEdited(object sender, TextChangedEventArgs e)
    {
        if (_loading || Core.LibResume is not { } r) return;
        r.Name = ResumeName.Text;
        r.Text = ResumeText.Text;
        Core.SaveResume(r);
    }

    private void OnResumeMoved(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || Core.LibResume is not { } r || ResumeVacancy.SelectedItem is not Vacancy v || v.Id == r.VacancyId) return;
        Core.MoveResume(r, v.Id);
        if (v.Id == 0) { Core.LibVacancy = null; Core.LibLoose = true; }
        else Core.LibVacancy = Core.Vacancies.FirstOrDefault(x => x.Id == v.Id);
        Core.LibResume = r;
    }

    private void OnDeleteResume(object sender, RoutedEventArgs e)
    {
        if (Core.LibResume is not { } r) return;
        if (MessageBox.Show(Window.GetWindow(this)!, $"Удалить резюме «{r.Name}»? Проведённые собеседования останутся.", "Суфлёр", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            Core.DeleteResume(r);
    }

    private void OnCloseResume(object sender, RoutedEventArgs e) => Core.LibResume = null;
    private void OnCloseError(object sender, RoutedEventArgs e) => Core.ErrorText = "";
}
