using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Sufler.Views;

public partial class PlanView : UserControl
{
    private AppCore Core => App.Core;
    /// <summary>Что показать, когда карты ещё нет.</summary>
    public string EmptyText { get; set; } = "Карту вопросов не собирали.";

    public PlanView()
    {
        InitializeComponent();
        Loaded += (_, _) => { Core.PropertyChanged += OnCore; Render(); };
        Unloaded += (_, _) => Core.PropertyChanged -= OnCore;
    }

    private void OnCore(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppCore.Interview) or nameof(AppCore.NextPlanQuestion) or nameof(AppCore.Preparing) or nameof(AppCore.PrepNote)) Render();
    }

    private Brush Res(string key) => (Brush)FindResource(key);

    public void Render()
    {
        Body.Children.Clear();
        if (Core.Interview?.Plan is not { } plan)
        {
            var hint = new StackPanel { Margin = new Thickness(20, 60, 20, 0) };
            hint.Children.Add(new TextBlock { Style = (Style)FindResource("Icon"), Text = "", FontSize = 30, Foreground = Res("Third") });
            hint.Children.Add(new TextBlock { Style = (Style)FindResource("HintText"), Margin = new Thickness(0, 10, 0, 0), Text = Core.Preparing ? Core.PrepNote : EmptyText });
            Body.Children.Add(hint);
            return;
        }
        if (plan.Brief.Length > 0)
        {
            Body.Children.Add(Make.Caps("КАНДИДАТ"));
            Body.Children.Add(Make.Text(plan.Brief, margin: new Thickness(0, 0, 0, 12)));
        }
        if (plan.Requirements.Count > 0) Body.Children.Add(Make.List("Требования", Res("Second"), plan.Requirements));
        if (plan.Focus.Count > 0) Body.Children.Add(Make.List("Проверить особенно", Res("Warn"), plan.Focus));
        foreach (var kind in Verdicts.PlanKinds)
        {
            var qs = plan.Questions.Where(q => q.Kind == kind).ToList();
            if (qs.Count == 0) continue;
            var color = Theme.Hex(Verdicts.KindColor(kind));
            var head = new DockPanel { Margin = new Thickness(0, 8, 0, 6) };
            var count = Make.Text($"{qs.Count(q => q.Asked)} из {qs.Count}", 12, color: Res("Second"));
            DockPanel.SetDock(count, Dock.Right);
            head.Children.Add(count);
            head.Children.Add(new TextBlock { Text = Verdicts.Kind(kind).ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeights.Bold, Foreground = color });
            Body.Children.Add(head);
            foreach (var q in qs) Body.Children.Add(Row(q));
        }
        if (!plan.Deep) Body.Children.Add(Make.Text("Карту собрала основная модель.", 11.5, color: Res("Third"), margin: new Thickness(0, 6, 0, 0)));
    }

    private Border Row(PlanQuestion q)
    {
        var check = new Button { Style = (Style)FindResource("IconButton"), Content = q.CheckGlyph, FontSize = 15, VerticalAlignment = VerticalAlignment.Top,
                                 Foreground = q.Asked ? Res("Good") : Res("Second"), ToolTip = q.Asked ? "Отметить как не заданный" : "Отметить как заданный" };
        check.Click += (_, _) => Core.TogglePlanQuestion(q);
        var text = new StackPanel { Margin = new Thickness(6, 3, 0, 0) };
        text.Children.Add(Make.Selectable(q.Text, 13.5, q.Asked ? Res("Second") : Res("Ink")));
        if (q.Purpose.Length > 0) text.Children.Add(Make.Text(q.PurposeText, 12, color: Res("Second"), margin: new Thickness(0, 4, 0, 0)));
        if (q.Listen.Length > 0 && !q.Asked) text.Children.Add(Make.Text("Слушаем: " + q.Listen, 12, color: Res("Third"), margin: new Thickness(0, 3, 0, 0)));
        var row = new DockPanel();
        DockPanel.SetDock(check, Dock.Left);
        row.Children.Add(check);
        row.Children.Add(text);
        return new Border { Child = row, Background = Res("Soft"), Opacity = q.Asked ? 0.75 : 1, CornerRadius = new CornerRadius(10), Padding = new Thickness(6, 7, 10, 9), Margin = new Thickness(0, 0, 0, 6) };
    }
}
