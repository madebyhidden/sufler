using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace Sufler.Views;

public partial class InterviewPrep : UserControl
{
    private AppCore Core => App.Core;
    private bool _loading;

    public InterviewPrep()
    {
        InitializeComponent();
        Loaded += (_, _) => { Core.PropertyChanged += OnCore; Load(); };
        Unloaded += (_, _) => Core.PropertyChanged -= OnCore;
        IsVisibleChanged += (_, _) => { if (IsVisible) Load(); };
    }

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppCore.Interview): Load(); break;
            case nameof(AppCore.Preparing) or nameof(AppCore.LlmReady): RefreshButtons(); break;
        }
    }

    /// <summary>Поля подготовки — из открытого собеседования.</summary>
    private void Load()
    {
        var iv = Core.Interview;
        _loading = true;
        CandidateBox.Text = iv?.Candidate ?? "";
        VacancyBox.Text = iv?.Vacancy ?? "";
        ResumeBox.Text = iv?.Resume ?? "";
        NotesBox.Text = iv?.Notes ?? "";
        _loading = false;
        RefreshHints();
        RefreshButtons();
    }

    private void RefreshHints()
    {
        VacancyHint.Visibility = VacancyBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ResumeHint.Visibility = ResumeBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        NotesHint.Visibility = NotesBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshButtons()
    {
        BuildButton.IsEnabled = !Core.Preparing && Core.Interview is not null;
        BuildText.Text = Core.Interview?.Plan is null ? "Собрать карту вопросов" : "Пересобрать карту";
        VacancyPick.IsEnabled = Core.Vacancies.Count > 0;
        ResumePick.IsEnabled = Core.Resumes.Count > 0;
        DeepNote.Text = !AppCore.DeepFits ? "Карту собирает основная модель: для глубокой Gemma 26B нужна видеокарта или от 32 ГБ памяти."
            : !Core.DeepReady ? "Сейчас карту собирает основная модель. Для более глубокой подготовки скачайте Gemma 4 26B в настройках."
            : "Карту соберёт Gemma 4 26B. На это время основная модель выгружается и потом загружается снова.";
    }

    private void OnCandidate(object sender, TextChangedEventArgs e)
    {
        if (!_loading) Core.SetCandidate(CandidateBox.Text);
    }

    private void OnVacancy(object sender, TextChangedEventArgs e)
    {
        RefreshHints();
        if (!_loading) Core.EditInterview(iv => iv.Vacancy = VacancyBox.Text);
    }

    private void OnResume(object sender, TextChangedEventArgs e)
    {
        RefreshHints();
        if (!_loading) Core.EditInterview(iv => iv.Resume = ResumeBox.Text);
    }

    private void OnNotes(object sender, TextChangedEventArgs e)
    {
        RefreshHints();
        if (!_loading) Core.EditInterview(iv => iv.Notes = NotesBox.Text);
    }

    private static string? PickFile(string title)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Filter = Documents.Filter, Title = title };
        return dlg.ShowDialog() == true ? dlg.FileName : null;
    }

    private void OnVacancyFile(object sender, RoutedEventArgs e)
    {
        if (PickFile("Выберите описание вакансии") is not { } path) return;
        if (Documents.ExtractText(path)?.Trim() is { Length: > 0 } text) VacancyBox.Text = text;
        else Core.ErrorText = $"Не удалось прочитать текст из «{System.IO.Path.GetFileName(path)}».";
    }

    private void OnResumeFile(object sender, RoutedEventArgs e)
    {
        if (PickFile("Выберите резюме кандидата") is not { } path) return;
        if (Documents.ExtractText(path)?.Trim() is { Length: > 0 } text) ResumeBox.Text = text;
        else Core.ErrorText = $"Не удалось прочитать текст из «{System.IO.Path.GetFileName(path)}».";
    }

    /// <summary>Меню «Из базы»: вакансии или резюме выбранной вакансии.</summary>
    private void ShowMenu(Button owner, IEnumerable<(string Title, Action Pick)> items)
    {
        var menu = new ContextMenu { PlacementTarget = owner, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        foreach (var (title, pick) in items)
        {
            var mi = new MenuItem { Header = title };
            mi.Click += (_, _) => pick();
            menu.Items.Add(mi);
        }
        if (menu.Items.Count == 0) return;
        menu.IsOpen = true;
    }

    private void OnPickVacancy(object sender, RoutedEventArgs e) =>
        ShowMenu(VacancyPick, Core.Vacancies.Select(v => (v.Title, (Action)(() => Core.UseVacancy(v)))));

    private void OnPickResume(object sender, RoutedEventArgs e)
    {
        var vid = Core.Interview?.VacancyId;
        var list = vid is { } id ? Core.Resumes.Where(r => r.VacancyId == id).ToList() : Core.Resumes.ToList();
        if (list.Count == 0) list = Core.Resumes.ToList();
        ShowMenu(ResumePick, list.Select(r => (r.Name, (Action)(() => Core.UseResume(r)))));
    }

    private async void OnBuild(object sender, RoutedEventArgs e) => await Core.BuildPlan();
    private void OnStart(object sender, RoutedEventArgs e) => Core.ToggleRecording();
}
