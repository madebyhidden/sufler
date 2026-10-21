using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace Sufler.Views;

public partial class InterviewSide : UserControl
{
    private AppCore Core => App.Core;
    private InterviewData? _watched;
    private bool _liveDirty = true, _reportDirty = true;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(150) };

    public InterviewSide()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Core.PropertyChanged += OnCore;
            Core.Turns.CollectionChanged += (_, _) => _liveDirty = true;
            Watch();
            _tick.Tick += (_, _) => Flush();
            _tick.Start();
        };
    }

    private Brush Res(string key) => (Brush)FindResource(key);

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppCore.Interview): Watch(); break;
            case nameof(AppCore.Probing) or nameof(AppCore.Mastery) or nameof(AppCore.AiSuspicion) or nameof(AppCore.NextPlanQuestion) or nameof(AppCore.SelectedIsRecording) or nameof(AppCore.IsRecording):
                _liveDirty = true; break;
            case nameof(AppCore.Evaluating) or nameof(AppCore.EvalNote) or nameof(AppCore.LlmReady) or nameof(AppCore.RecordingId):
                _reportDirty = true; break;
        }
    }

    /// <summary>Следим за открытым собеседованием: разборы дописываются по кусочку.</summary>
    private void Watch()
    {
        if (_watched is not null)
        {
            _watched.PropertyChanged -= OnInterview;
            _watched.Probes.CollectionChanged -= OnProbes;
            foreach (var p in _watched.Probes) p.PropertyChanged -= OnProbe;
        }
        _watched = Core.Interview;
        if (_watched is not null)
        {
            _watched.PropertyChanged += OnInterview;
            _watched.Probes.CollectionChanged += OnProbes;
            foreach (var p in _watched.Probes) p.PropertyChanged += OnProbe;
            // Собеседование уже прошло — сразу показываем оценку
            if (_watched.Report is not null && !Core.SelectedIsRecording) TabReport.IsChecked = true;
            else if (Core.SelectedIsRecording) TabLive.IsChecked = true;
        }
        _liveDirty = _reportDirty = true;
    }

    private void OnInterview(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(InterviewData.Report)) { _reportDirty = true; TabReport.IsChecked = true; }
        else _liveDirty = true;
    }

    private void OnProbes(object? sender, NotifyCollectionChangedEventArgs e)
    {
        foreach (Probe p in e.NewItems ?? Array.Empty<Probe>()) p.PropertyChanged += OnProbe;
        _liveDirty = true;
    }

    private void OnProbe(object? sender, PropertyChangedEventArgs e) => _liveDirty = true;

    /// <summary>Перерисовываем не на каждый кусочек ответа модели, а несколько раз в секунду.</summary>
    private DateTime _lastSecond;

    private void Flush()
    {
        if (!IsVisible) return;
        // Пока идёт запись, раз в секунду обновляем секундомер паузы
        if (Core.SelectedIsRecording && (DateTime.Now - _lastSecond).TotalSeconds >= 1) { _lastSecond = DateTime.Now; _liveDirty = true; }
        if (_liveDirty) { _liveDirty = false; RenderLive(); }
        if (_reportDirty) { _reportDirty = false; RenderReport(); }
    }

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (LivePane is null || PlanPane is null || ReportPane is null || ChatPane is null) return;
        LivePane.Visibility = TabLive.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        PlanPane.Visibility = TabPlan.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        ReportPane.Visibility = TabReport.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        ChatPane.Visibility = TabChat.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        if (PlanPane.Visibility == Visibility.Visible) PlanPane.Render();
    }

    // MARK: Суфлёр

    private void RenderLive()
    {
        Live.Children.Clear();
        var probes = Core.Interview?.Probes.ToList() ?? [];
        if (Core.SelectedIsRecording && Silence() is { } pause) Live.Children.Add(pause);
        if (Core.AiSuspicion is { Score: >= 1.5 } ai) Live.Children.Add(AiCard(ai.Score, ai.Reasons));
        if (Core.Mastery is { } m) Live.Children.Add(MasteryBar(m, probes.Where(p => p.Mastery is not null).Select(p => p.Mastery!.Value).TakeLast(12).ToList()));
        if (Core.TalkShare is { } share) Live.Children.Add(TalkShare(share));
        var last = probes.LastOrDefault();
        if (last is { Active: true }) Live.Children.Add(Followup(last));
        else if (last is not null) Live.Children.Add(ProbeRow(last, true));
        if (Core.Probing) Live.Children.Add(Make.Text("Разбираю ответ…", 12, color: Res("Second"), margin: new Thickness(0, 0, 0, 10)));
        else if (probes.Count == 0 && Core.SelectedIsRecording)
            Live.Children.Add(Make.Text("Слушаю. Когда кандидат договорит, разберу ответ и, если нужно, подскажу уточнение.", 12, color: Res("Second"), margin: new Thickness(0, 0, 0, 10)));
        if (Core.NextPlanQuestion is { } q) Live.Children.Add(NextQuestion(q));
        else if (Core.Interview?.Plan is null) Live.Children.Add(Make.Text("Карта вопросов не собрана — подсказки по уточнениям всё равно будут.", 12, color: Res("Third"), margin: new Thickness(0, 0, 0, 10)));
        else Live.Children.Add(Make.Text("Все вопросы карты пройдены", 13.5, FontWeights.Medium, Res("Good"), new Thickness(0, 0, 0, 10)));
        var older = probes.Take(Math.Max(0, probes.Count - 1)).Reverse().ToList();
        if (older.Count > 0)
        {
            Live.Children.Add(Make.Caps("РАНЬШЕ", Res("Third"), 6));
            foreach (var p in older) Live.Children.Add(ProbeRow(p, false));
        }
    }

    /// <summary>Кандидат молчит после вопроса — видно сразу, без модели: сколько секунд и что можно сделать.</summary>
    private Border? Silence()
    {
        if (Core.Turns.Count == 0 || Core.Partials.Count > 0) return null;
        var last = Core.Turns[^1];
        if (AppCore.IsCandidate(last) || !(last.Text.Contains('?') || last.Text.Length > 40)) return null;
        int s = (int)(DateTime.Now - last.Ts).TotalSeconds;
        if (s < 4) return null;
        var p = new StackPanel();
        p.Children.Add(Make.Text($"Пауза {s} с — кандидат думает", 13.5, FontWeights.SemiBold, Res("Warn")));
        p.Children.Add(Make.Text(s >= 10 ? "Можно помочь наводящим: «Давайте на конкретном примере из вашего последнего проекта» — или перейти к следующему вопросу."
                                         : "Не торопите. Если затянется — предложите: «Давайте на конкретном примере».", 12, color: Res("Second"), margin: new Thickness(0, 4, 0, 0)));
        return Make.Box(p, Res("WarnSoft"), null, 12, 11);
    }

    /// <summary>«Возможно, подсматривает в ИИ»: по оценкам ответов и по поведению — и чем это проверить.</summary>
    private Border AiCard(double score, List<string> reasons)
    {
        var purple = Theme.Hex("#8E5CE6");
        var p = new StackPanel();
        p.Children.Add(Make.Text(score >= 2.3 ? "Похоже, отвечает с подсказками ИИ" : "Возможно, подсматривает в ИИ", 13.5, FontWeights.SemiBold, purple));
        foreach (var r in reasons) p.Children.Add(Make.Text("•  " + r, 12, color: Res("Second"), margin: new Thickness(0, 3, 0, 0)));
        p.Children.Add(Make.Text("Проверьте: попросите личный случай с деталями — когда, кто, что пошло не так; переспросите деталь из его же ответа; попросите рассуждать вслух.", 12, margin: new Thickness(0, 6, 0, 0)));
        return Make.Box(p, Theme.Hex("#8E5CE6", 0.08), Theme.Hex("#8E5CE6", 0.35), 12, 12);
    }

    /// <summary>Маркеры ответа по самой речи: долго думал, медленно, много «ээ», слишком гладко.</summary>
    private static WrapPanel? Markers(Probe p)
    {
        if (p.Stats is not { } st || st.Markers.Count == 0) return null;
        var w = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var (text, color) in st.Markers) { var c = Make.Chip(text, Theme.Hex(color)); c.Margin = new Thickness(0, 0, 6, 4); w.Children.Add(c); }
        return w;
    }

    /// <summary>«Плавает в теме или нет»: средняя по последним ответам и столбик на каждый ответ.</summary>
    private Border MasteryBar(double value, List<int> history)
    {
        var c = Theme.Hex(Verdicts.MasteryColor(value));
        var left = new StackPanel();
        left.Children.Add(Make.Caps("ВЛАДЕНИЕ ТЕМОЙ"));
        left.Children.Add(Make.Text(Verdicts.MasteryTitle(value), 17, FontWeights.SemiBold, c));
        left.Children.Add(Make.Text($"{value:0.0} из 5 по последним ответам", 12, color: Res("Second")));
        var bars = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Bottom, Height = 36 };
        foreach (var h in history)
            bars.Children.Add(new Border { Width = 7, Height = 6 + h * 6, CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Bottom, Background = Theme.Hex(Verdicts.MasteryColor(h)) });
        var row = new DockPanel();
        DockPanel.SetDock(bars, Dock.Right);
        row.Children.Add(bars);
        row.Children.Add(left);
        return Make.Box(row, Theme.Hex(Verdicts.MasteryColor(value), 0.09));
    }

    private StackPanel TalkShare(double share)
    {
        var p = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        var head = new DockPanel();
        if (share < 0.5)
        {
            var warn = Make.Text("дайте ему больше говорить", 12, color: Res("Warn"));
            DockPanel.SetDock(warn, Dock.Right);
            head.Children.Add(warn);
        }
        head.Children.Add(Make.Text($"Кандидат говорит {share:P0}", 12, FontWeights.Medium));
        p.Children.Add(head);
        var bar = new Grid { Height = 5, Margin = new Thickness(0, 5, 0, 0) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.02, share), GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.02, 1 - share), GridUnitType.Star) });
        var a = new Border { Background = Res("Accent"), CornerRadius = new CornerRadius(2.5), Margin = new Thickness(0, 0, 2, 0) };
        var b = new Border { Background = Res("Line"), CornerRadius = new CornerRadius(2.5) };
        Grid.SetColumn(b, 1);
        bar.Children.Add(a);
        bar.Children.Add(b);
        p.Children.Add(bar);
        return p;
    }

    private Border Followup(Probe p)
    {
        var tint = Theme.Hex(Verdicts.VerdictColor(p.Verdict));
        var s = new StackPanel();
        var head = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
        head.Children.Add(new TextBlock { Text = p.Draft ? "ПОХОЖЕ, СТОИТ УТОЧНИТЬ" : "ДОЗАДАЙТЕ", FontSize = 11.5, FontWeight = FontWeights.Bold, Foreground = tint, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        head.Children.Add(Make.Chip(p.VerdictTitle, tint));
        if (p.Mastery is { } m) head.Children.Add(Make.Chip(p.MasteryText, Theme.Hex(Verdicts.MasteryColor(m))));
        s.Children.Add(head);
        s.Children.Add(Make.Selectable(p.Followup, 18));
        if (p.Draft) s.Children.Add(Make.Text("кандидат ещё говорит — дождитесь паузы", 12, color: Res("Second"), margin: new Thickness(0, 4, 0, 0)));
        if (Markers(p) is { } mk) s.Children.Add(mk);
        if (p.Reason.Length > 0) s.Children.Add(Make.Text(p.Reason, 13, color: Res("Second"), margin: new Thickness(0, 6, 0, 0)));
        if (p.Gist.Length > 0) s.Children.Add(Make.Text("Ответ: " + p.Gist, 12, color: Res("Second"), margin: new Thickness(0, 4, 0, 0)));
        var buttons = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        buttons.Children.Add(Make.Soft("Задал", "", (_, _) => Core.MarkProbe(p, true)));
        buttons.Children.Add(Make.Soft("Не нужно", "", (_, _) => Core.MarkProbe(p, false)));
        s.Children.Add(buttons);
        // Черновик — бледнее, пока кандидат не договорил
        var box = Make.Box(s, Theme.Hex(Verdicts.VerdictColor(p.Verdict), p.Draft ? 0.05 : 0.1), p.Draft ? Theme.Hex(Verdicts.VerdictColor(p.Verdict), 0.35) : tint, 14, 14);
        return box;
    }

    private Border ProbeRow(Probe p, bool big)
    {
        var tint = Theme.Hex(Verdicts.VerdictColor(p.Verdict));
        var s = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var time = Make.Text(p.TimeText, 11, color: Res("Third"));
        DockPanel.SetDock(time, Dock.Right);
        head.Children.Add(time);
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        title.Children.Add(new System.Windows.Shapes.Ellipse { Width = 7, Height = 7, Fill = tint, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        title.Children.Add(Make.Text(p.VerdictTitle, 12, FontWeights.SemiBold, tint));
        if (p.Mastery is { } m) title.Children.Add(Make.Text(" · " + p.MasteryText, 12, color: Theme.Hex(Verdicts.MasteryColor(m))));
        head.Children.Add(title);
        s.Children.Add(head);
        s.Children.Add(Make.Text(p.Gist, big ? 13.5 : 12.5));
        if (big && Markers(p) is { } mk) s.Children.Add(mk);
        if (p.Ai is >= 2) s.Children.Add(Make.Text("похоже на зачитанное" + (p.AiWhy.Length > 0 ? ": " + p.AiWhy : ""), 11.5, color: Theme.Hex("#8E5CE6"), margin: new Thickness(0, 3, 0, 0)));
        if (!big && p.Followup.Length > 0) s.Children.Add(Make.Text((p.Used ? "✓ " : "→ ") + p.Followup, 12, color: Res("Second"), margin: new Thickness(0, 3, 0, 0)));
        return Make.Box(s, Res("Soft"), null, 11, big ? 12 : 9, 8);
    }

    private Border NextQuestion(PlanQuestion q)
    {
        var tint = Theme.Hex(Verdicts.KindColor(q.Kind));
        var s = new StackPanel();
        var head = new WrapPanel { Margin = new Thickness(0, 0, 0, 7) };
        head.Children.Add(new TextBlock { Text = "СЛЕДУЮЩИЙ ВОПРОС", FontSize = 10.5, FontWeight = FontWeights.Bold, Foreground = Res("Second"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        head.Children.Add(Make.Chip(q.KindTitle, tint));
        s.Children.Add(head);
        s.Children.Add(Make.Selectable(q.Text, 15));
        if (q.Purpose.Length > 0) s.Children.Add(Make.Text(q.PurposeText, 12, color: Res("Second"), margin: new Thickness(0, 6, 0, 0)));
        if (q.Listen.Length > 0) s.Children.Add(Make.Text("Слушаем: " + q.Listen, 12, color: Res("Third"), margin: new Thickness(0, 4, 0, 0)));
        var buttons = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        buttons.Children.Add(Make.Soft("Задан", "", (_, _) => Core.TogglePlanQuestion(q)));
        buttons.Children.Add(Make.Soft("Позже", "", (_, _) => Core.SkipPlanQuestion(q)));
        s.Children.Add(buttons);
        return Make.Box(s, Theme.Hex(Verdicts.KindColor(q.Kind), 0.07), Theme.Hex(Verdicts.KindColor(q.Kind), 0.3));
    }

    // MARK: Оценка

    private void RenderReport()
    {
        Report.Children.Clear();
        ReportButtons.Children.Clear();
        var m = Core.Selected;
        if (Core.Evaluating) Report.Children.Add(Make.Text(Core.EvalNote.Length > 0 ? Core.EvalNote : "Оцениваю кандидата…", 13.5, color: Res("Second"), margin: new Thickness(0, 0, 0, 12)));
        if (Core.Interview?.Report is { } r) RenderReportBody(r);
        else if (!Core.Evaluating)
        {
            var hint = new StackPanel { Margin = new Thickness(20, 56, 20, 0) };
            hint.Children.Add(new TextBlock { Style = (Style)FindResource("Icon"), Text = "", FontSize = 30, Foreground = Res("Third") });
            hint.Children.Add(new TextBlock
            {
                Style = (Style)FindResource("HintText"), Margin = new Thickness(0, 10, 0, 0),
                Text = Core.SelectedIsRecording ? "Оценка появится, когда вы остановите запись: матрица компетенций, бизнес-логика, соответствие вакансии и портрет кандидата." : "Оценки пока нет.",
            });
            Report.Children.Add(hint);
        }
        if (m is not null && m.Id != Core.RecordingId && !Core.Evaluating && Core.Turns.Count >= 4)
        {
            bool has = Core.Interview?.Report is not null;
            ReportButtons.Children.Add(Make.Soft(has ? "Пересобрать" : "Оценить кандидата", "", async (_, _) => await Core.EvaluateInterview(m)));
            if (has)
            {
                Button? copy = null;
                copy = Make.Soft("Копировать", "", async (_, _) =>
                {
                    try { Clipboard.SetText(Core.ReportText()); } catch { return; }
                    ((TextBlock)((StackPanel)copy!.Content).Children[1]).Text = "Скопировано";
                    await Task.Delay(1800);
                    ((TextBlock)((StackPanel)copy.Content).Children[1]).Text = "Копировать";
                });
                ReportButtons.Children.Add(copy);
                ReportButtons.Children.Add(Make.Soft("В Word", "", (_, _) => SaveWord()));
            }
        }
    }

    private void RenderReportBody(InterviewReport r)
    {
        var fit = Theme.Hex(Verdicts.FitColor(r.Fit));
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        var ring = new Grid { Width = 72, Height = 72, Margin = new Thickness(0, 0, 14, 0) };
        ring.Children.Add(new System.Windows.Shapes.Ellipse { Stroke = Res("Line"), StrokeThickness = 7 });
        // Дуга процента: штрих окружности длиной в долю соответствия
        double len = Math.PI * (72 - 7) / 7;
        ring.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Stroke = fit, StrokeThickness = 7, StrokeDashArray = new DoubleCollection { len * r.Fit / 100.0, 1000 }, StrokeDashCap = PenLineCap.Round,
            RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new RotateTransform(-90),
        });
        ring.Children.Add(new TextBlock { Text = $"{r.Fit}%", FontSize = 19, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(ring);
        var verdict = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        verdict.Children.Add(Make.Text("Соответствие вакансии", 12, color: Res("Second")));
        verdict.Children.Add(Make.Text(Verdicts.Hire(r.Verdict), 16, FontWeights.SemiBold, fit));
        if (!r.Deep) verdict.Children.Add(Make.Text("Оценила основная модель", 11, color: Res("Third")));
        head.Children.Add(verdict);
        Report.Children.Add(head);
        Report.Children.Add(Make.Selectable(r.Summary));
        Report.Children.Add(Make.Caps("МАТРИЦА КОМПЕТЕНЦИЙ", null, 14));
        foreach (var c in r.Competencies)
        {
            var color = Theme.Hex(Verdicts.ScoreColor(c.Score));
            bool low = c.Confidence == "low";
            var s = new StackPanel();
            var row = new DockPanel();
            var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
            right.Children.Add(Make.Scale(c.Score, color, low ? 0.45 : 1));
            right.Children.Add(Make.Text(c.Score.ToString(), 13.5, FontWeights.Bold, margin: new Thickness(4, 0, 0, 0)));
            DockPanel.SetDock(right, Dock.Right);
            row.Children.Add(right);
            var name = new StackPanel();
            name.Children.Add(Make.Text(c.Name, 13.5, FontWeights.SemiBold));
            if (c.Requirement.Length > 0 && c.Requirement != c.Name) name.Children.Add(Make.Text(c.Requirement, 11, color: Res("Third")));
            row.Children.Add(name);
            s.Children.Add(row);
            if (c.Evidence.Length > 0) s.Children.Add(Make.Text(c.Evidence, 12, color: Res("Second"), margin: new Thickness(0, 4, 0, 0)));
            if (low) s.Children.Add(Make.Text("мало данных — стоит проверить ещё", 11, color: Res("Warn"), margin: new Thickness(0, 3, 0, 0)));
            Report.Children.Add(Make.Box(s, Res("Soft"), null, 10, 10, 6));
        }
        if (r.Integrity is { Level: not "none" } ig)
        {
            var purple = Theme.Hex("#8E5CE6");
            var p = new StackPanel();
            p.Children.Add(Make.Caps("САМОСТОЯТЕЛЬНОСТЬ ОТВЕТОВ", purple));
            p.Children.Add(Make.Text(ig.Title, 15, FontWeights.SemiBold, ig.Level == "low" ? Res("Warn") : purple));
            foreach (var x in ig.Signs) p.Children.Add(Make.Text("•  " + x, 13.5, margin: new Thickness(0, 3, 0, 0)));
            var box = Make.Box(p, Theme.Hex("#8E5CE6", 0.07), null, 12, 12, 12);
            box.Margin = new Thickness(0, 8, 0, 4);
            Report.Children.Add(box);
        }
        if (r.Business is { } b) Report.Children.Add(Business(b));
        if (r.Portrait.Length > 0)
        {
            Report.Children.Add(Make.Caps("ПОРТРЕТ", null, 10));
            Report.Children.Add(Make.Selectable(r.Portrait));
        }
        var lists = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        if (r.Strengths.Count > 0) lists.Children.Add(Make.List("Сильные стороны", Res("Good"), r.Strengths));
        if (r.Risks.Count > 0) lists.Children.Add(Make.List("Риски", Res("Warn"), r.Risks));
        if (r.Mismatches.Count > 0) lists.Children.Add(Make.List("Расхождения", Res("Bad"), r.Mismatches));
        if (r.NextSteps.Count > 0) lists.Children.Add(Make.List("Проверить дальше", Res("Accent"), r.NextSteps));
        Report.Children.Add(lists);
    }

    /// <summary>«Бизнес-логика»: как кандидат думает внутри задачи — по кейсам и ответам «как бы вы сделали».</summary>
    private Border Business(BusinessThinking b)
    {
        var indigo = Theme.Hex("#5856D6");
        var s = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(Make.Scale(b.Score, Theme.Hex(Verdicts.ScoreColor(b.Score)), b.Confidence == "low" ? 0.45 : 1));
        right.Children.Add(Make.Text(b.Score.ToString(), 13.5, FontWeights.Bold, margin: new Thickness(4, 0, 0, 0)));
        DockPanel.SetDock(right, Dock.Right);
        head.Children.Add(right);
        head.Children.Add(new TextBlock { Text = "БИЗНЕС-ЛОГИКА", FontSize = 10.5, FontWeight = FontWeights.Bold, Foreground = indigo, VerticalAlignment = VerticalAlignment.Center });
        s.Children.Add(head);
        s.Children.Add(Make.Selectable(b.Summary));
        if (b.Approach.Count > 0)
        {
            s.Children.Add(Make.Text("Как рассуждал", 12, FontWeights.SemiBold, Res("Second"), new Thickness(0, 10, 0, 4)));
            for (int i = 0; i < b.Approach.Count; i++) s.Children.Add(Make.Text($"{i + 1}. {b.Approach[i]}", 13.5, margin: new Thickness(0, 0, 0, 3)));
        }
        if (b.Gaps.Count > 0)
        {
            s.Children.Add(Make.Text("Что упустил", 12, FontWeights.SemiBold, Res("Warn"), new Thickness(0, 8, 0, 4)));
            foreach (var g in b.Gaps) s.Children.Add(Make.Text("•  " + g, 13.5, margin: new Thickness(0, 0, 0, 3)));
        }
        if (b.Confidence == "low") s.Children.Add(Make.Text("кейсов было мало — стоит дать задачу на следующем этапе", 11, color: Res("Warn"), margin: new Thickness(0, 6, 0, 0)));
        var box = Make.Box(s, Theme.Hex("#5856D6", 0.07), null, 12, 12, 12);
        box.Margin = new Thickness(0, 8, 0, 12);
        return box;
    }

    private void SaveWord()
    {
        if (Core.ReportAsMeeting() is not { } doc) return;
        var safe = string.Concat(doc.Title.Select(c => System.IO.Path.GetInvalidFileNameChars().Contains(c) ? ' ' : c)).Trim();
        var dlg = new Microsoft.Win32.SaveFileDialog { FileName = safe + ".docx", Filter = "Документ Word|*.docx", Title = "Куда сохранить оценку кандидата" };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
        try
        {
            Documents.SaveSummaryDocx(dlg.FileName, doc);
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{dlg.FileName}\"");
        }
        catch (Exception ex) { Core.ErrorText = "Не удалось сохранить файл Word: " + ex.Message; }
    }
}
