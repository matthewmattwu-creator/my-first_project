using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.IO;
using System.Text;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Shell;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Drawing100WpfPreview
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            var app = new Application();
            app.DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs e)
            {
                CrashReporter.Write("UI", e.Exception);
                MessageBox.Show(
                    "程序遇到异常，但已阻止直接闪退。\n\n" + e.Exception.Message +
                    "\n\n错误报告已保存到程序目录的 log 文件夹。",
                    "出图100% · 程序异常",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                e.Handled = true;
            };
            AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs e)
            {
                CrashReporter.Write("Fatal", e.ExceptionObject as Exception);
            };
            app.Run(new MainWindow());
        }
    }

    internal static class CrashReporter
    {
        public static void Write(string source, Exception exception)
        {
            try
            {
                string directory = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "log");
                Directory.CreateDirectory(directory);
                string path = System.IO.Path.Combine(directory, "界面异常报告.log");
                string content = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + source + "]\r\n" +
                    (exception == null ? "未知异常" : exception.ToString()) + "\r\n\r\n";
                File.AppendAllText(path, content, new UTF8Encoding(true));
            }
            catch { }
        }
    }

    internal sealed class DrawingRow
    {
        public int Index { get; set; }
        public string SourceFile { get; set; }
        public string FullSourceFile { get; set; }
        public string Frame { get; set; }
        public string No { get; set; }
        public string Name { get; set; }
        public string Type { get; set; }
        public string Scale { get; set; }
        public string Unit { get; set; }
        public string Status { get; set; }
        public string Issue { get; set; }
        public string Result { get; set; }
        public string TechnicalResult { get; set; }
        public string Tone { get; set; }
        public bool NeedsReview { get; set; }
        public string ConfirmText { get; set; }
    }

    internal sealed class FailureExplanation
    {
        public string Summary { get; private set; }
        public string Reason { get; private set; }
        public string Impact { get; private set; }
        public string Advice { get; private set; }

        public static FailureExplanation FromTechnical(string raw)
        {
            raw = raw ?? string.Empty;
            var summaries = new List<string>();
            var reasons = new List<string>();
            var advice = new List<string>();
            Action<string,string,string> add = delegate(string summary,string reason,string action) {
                summaries.Add(summary); reasons.Add(reason); advice.Add(action);
            };
            bool personnel = raw.Contains("人员姓名") || Regex.IsMatch(raw, @"N[^、，；\s]*_T\d+_H\d+");
            if (personnel) {
                bool notVisible=raw.Contains("人员姓名未写入可见属性") || raw.Contains("人员姓名未写入") || raw.Contains("人员姓名未显示");
                add(notVisible ? "人员姓名未成功显示" : "人员姓名与填写内容不一致",
                    (notVisible ? "填写的人员姓名没有全部正常显示在图签中。" : "图签上的人员姓名与填写内容没有通过一致性检查。")+"涉及岗位：" + PersonnelLabels(raw) + "。",
                    "打开输出图纸，检查这些岗位的姓名栏。有姓名栏却未正确显示，或图签没有对应栏位时，请复制诊断信息交给维护人员；也可在图纸副本中人工核对并补填。");
            }

            if (raw.Contains("缩放") && raw.Contains("不一致")) {
                bool small = IsSmallScaleDifference(raw);
                bool frame=Regex.IsMatch(raw,@"图框\s*[XY]缩放");
                bool title=Regex.IsMatch(raw,@"图签\s*[XY]缩放");
                string subject=frame&&title ? "图框、图签" : frame ? "图框" : title ? "图签" : "图框或图签";
                add(subject+(small ? "比例有细微差异" : "比例发生变化"),
                    small ? "检测到新旧图框或图签的比例存在很小差异。当前检查要求数值完全一致，因此仍被判为失败。"
                        : "新旧图框或图签的缩放比例不一致，程序没有将该文件判为通过。",
                    "对照原图与输出图，查看图框是否对齐、文字大小是否一致。即使看起来正常，也请将诊断信息交给维护人员确认；本提示不会自动放行文件。");
            }
            if (raw.Contains("字段写入结果不一致")) {
                Match m = Regex.Match(raw, @"字段写入结果不一致：([^；\r\n]*)");
                var fields = m.Success ? m.Groups[1].Value.Split('、').Where(x => !x.Trim().StartsWith("N", StringComparison.Ordinal)).Select(x => x.Trim()).Where(x => x.Length > 0).ToArray() : new string[0];
                if (fields.Length > 0 || !personnel)
                    add("图签文字未通过一致性检查", "输出图签中的" + (fields.Length > 0 ? string.Join("、", fields) : "部分文字") + "与填写内容未通过一致性检查。可能是文字不同，也可能是文字附带的格式不同。",
                        "先核对这些文字是否正确。若文字正确却仍判红，请复制诊断信息交给维护人员检查格式；若文字不正确，请核对填写内容后重新处理。");
            }
            if (raw.Contains("位置/布局") || raw.Contains("旋转(弧度)"))
                add("图框或图签的位置、方向需要检查", "新旧图框或图签的位置、所在布局或旋转方向不一致。",
                    "对照原图，检查图框与图纸内容是否对齐、文字是否转向。请保留原图，并提交诊断信息。");
            if (raw.Contains("数量不符") || raw.Contains("删除或保留数量不符"))
                add("图框、图签或签字数量不符合预期", "处理后的对象数量与计划不一致，可能存在缺少或残留的内容。",
                    "逐张检查图框、图签和签字是否齐全，复制诊断信息交给维护人员。");
            if (raw.Contains("图框/图签结构") && !raw.Contains("缩放") && !raw.Contains("位置/布局") && !raw.Contains("旋转") && !raw.Contains("数量不符"))
                add("图框或图签未通过完整性检查", "图框或图签的数量、位置或替换情况未通过检查，现有信息不足以判断具体是哪一项。",
                    "对照原图检查图框和图签是否齐全、是否对齐，并复制诊断信息交给维护人员。");
            if (raw.Contains("规划外实体"))
                add("图纸中有未计划修改的对象发生变化", "原本应保留的部分图形对象没有通过保留检查。",
                    "对照原图检查图纸内容是否缺失；将原图、输出图和诊断信息交给维护人员核对。");
            if (raw.Contains("图名或图号") && (raw.Contains("无效") || raw.Contains("为空") || raw.Contains("标点")))
                add("图名或图号不完整", "输出图名或图号为空、只有标点，或内容不可用。",
                    "填写正确的图名和图号，重新处理后再次检查。");
            if (raw.Contains("残留"))
                add("旧图签内容没有清理干净", "输出图纸仍检测到应清理的旧文字或底纸。",
                    "检查是否存在新旧图签重叠，复制诊断信息交给维护人员。");
            if (raw.Contains("CFR-E109"))
                add("无法可靠保留原文字的大小和位置", "程序没有取得可靠的原文字属性，已停止该文件的处理。",
                    "保留原图。请将原图和诊断信息交给维护人员确认图签类型，暂时人工处理这张图。");
            if (summaries.Count == 0)
                add("文件处理或检查未完成", "程序没有得到可靠的处理结果，目前不能从这条提示确定具体原因。",
                    "查看处理日志；若重新处理仍失败，请复制诊断信息交给维护人员。");
            return new FailureExplanation {
                Summary=string.Join("；",summaries.Distinct()),
                Reason=string.Join("\r\n\r\n",reasons),
                Impact="该文件尚未通过检查，暂不能作为已验收成果使用。",
                Advice=string.Join("\r\n\r\n",advice.Distinct())
            };
        }

        private static bool IsSmallScaleDifference(string raw)
        {
            var matches=Regex.Matches(raw,@"[XY]缩放\s*不一致：\s*([-+0-9.eE]+)\s*→\s*([-+0-9.eE]+)");
            if(matches.Count==0) return false;
            foreach(Match m in matches) {
                double before,after;
                if(!double.TryParse(m.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out before) ||
                   !double.TryParse(m.Groups[2].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out after) ||
                   double.IsNaN(before) || double.IsNaN(after) || double.IsInfinity(before) || double.IsInfinity(after) ||
                   Math.Abs(before)<1e-12 || Math.Abs(before-after)/Math.Abs(before)>1e-5) return false;
            }
            return true;
        }

        private static string PersonnelLabels(string raw)
        {
            var labels=new Dictionary<string,string> {
                {"设计总负责人","设计总负责人（一）"},{"执行设总","设计总负责人（二）"},{"执行设总二","设计总负责人（三）"},
                {"专业负责人","专业负责人（一）"},{"专业负责人（副）","专业负责人（二）"},{"专业负责人（副）二","专业负责人（三）"},
                {"设计","设计"},{"校对","校对"},{"审核","审核"},{"审定","审定"}
            };
            var result=new List<string>();
            foreach(Match m in Regex.Matches(raw,@"N([^、，；\s]*?)_T\d+_H\d+")) {
                string label; result.Add(labels.TryGetValue(m.Groups[1].Value,out label)?label:m.Groups[1].Value);
            }
            return result.Count>0 ? string.Join("、",result.Distinct()) : "部分人员岗位";
        }
    }

    internal sealed class MainWindow : Window
    {
        private static readonly Color Bg = C("#101418");
        private static readonly Color Side = C("#12171C");
        private static readonly Color Panel = C("#171D22");
        private static readonly Color Panel2 = C("#1B2228");
        private static readonly Color Border = C("#35404A");
        private static readonly Color Text = C("#FFFFFF");
        private static readonly Color Muted = C("#F0F3F5");
        private static readonly Color Accent = C("#8DAAC5");
        private static readonly Color Yellow = C("#F0AD42");
        private static readonly Color Red = C("#E75555");
        private readonly CadFrameReplacer.MainForm core;
        private readonly DispatcherTimer syncTimer;
        private DataGrid drawingGrid;
        private TextBlock outputPathText;
        private TextBlock inputPathText;
        private TextBlock readyTitleText;
        private TextBlock readyDetailText;
        private TextBlock totalMetricText;
        private TextBlock recognizedMetricText;
        private TextBlock reviewMetricText;
        private TextBlock failedMetricText;
        private TextBlock logText;
        private TextBlock progressPercentText;
        private ProgressBar progressBar;
        private TextBlock normalBottomText;
        private TextBlock reviewBottomText;
        private TextBlock failedBottomText;
        private readonly Dictionary<string, TextBlock> projectValueTexts =
            new Dictionary<string, TextBlock>(StringComparer.Ordinal);
        private readonly Dictionary<string, TextBlock> personnelValueTexts =
            new Dictionary<string, TextBlock>(StringComparer.Ordinal);
        private readonly Dictionary<string, TextBox> projectEditors =
            new Dictionary<string, TextBox>(StringComparer.Ordinal);
        private readonly Dictionary<string, TextBox> personnelEditors =
            new Dictionary<string, TextBox>(StringComparer.Ordinal);
        private readonly Dictionary<string, TextBlock> signaturePathTexts =
            new Dictionary<string, TextBlock>(StringComparer.Ordinal);
        private string selectedInputDirectory;
        private bool syncingUi;
        private Border selectStepCard;
        private Border scanStepCard;
        private Border processStepCard;
        private Border outputStepCard;
        private TextBlock selectedFolderText;
        private Grid pageHost;
        private UIElement batchPage;
        private readonly Dictionary<string, Border> navItems = new Dictionary<string, Border>();

        public MainWindow()
        {
            core = new CadFrameReplacer.MainForm(CadFrameReplacer.OperationMode.ReplaceFrame);
            core.ShellEnableHosting();
            core.CreateControl();
            Title = "出图100% · CAD图框图签自动处理与质量验收（v1.9.15）";
            Width = 1664;
            Height = 946;
            MinWidth = 1280;
            MinHeight = 760;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.CanResize;
            Background = Brush(C("#101418"));
            FontFamily = new FontFamily("Microsoft YaHei UI");
            Foreground = Brush(Text);
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;
            WindowChrome.SetWindowChrome(this, new WindowChrome
            {
                CaptionHeight = 28,
                ResizeBorderThickness = new Thickness(6),
                CornerRadius = new CornerRadius(10),
                GlassFrameThickness = new Thickness(0)
            });
            // A low whole-window translucency is used instead of the undocumented
            // acrylic API here. Some Windows/WPF combinations turn an acrylic
            // borderless window into a fully transparent surface. This stable
            // variant retains a subtle desktop tint on every supported machine.
            Content = BuildRoot();
            syncTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
            syncTimer.Tick += delegate { if (core.ShellBusy) SyncFromCore(); };
            syncTimer.Start();
            Closed += delegate
            {
                syncTimer.Stop();
                core.ShellShutdown();
            };
            SyncFromCore();
        }

        private UIElement BuildRoot()
        {
            var outer = new Border
            {
                Background = Brush(C("#101418")),
                BorderBrush = Brush(C("#4A5660")),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                ClipToBounds = true
            };
            var rows = new Grid { Background = Brushes.Transparent };
            rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(28) });
            rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            rows.Children.Add(BuildTitleBar());
            var body = new Grid();
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(306) });
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetRow(body, 1);
            body.Children.Add(BuildSidebar());
            pageHost = new Grid();
            batchPage = BuildContent();
            pageHost.Children.Add(batchPage);
            Grid.SetColumn(pageHost, 1);
            body.Children.Add(pageHost);
            rows.Children.Add(body);
            outer.Child = rows;
            return outer;
        }

        private UIElement BuildTitleBar()
        {
            var bar = new Grid { Background = Brush(C("#E80C1013")) };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(138) });
            bar.MouseLeftButtonDown += delegate(object sender, MouseButtonEventArgs e)
            {
                if (e.ClickCount == 2) WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
                else DragMove();
            };
            bar.Children.Add(new TextBlock
            {
                Text = "  ◆  出图100% · CAD图框图签自动处理与质量验收",
                Foreground = Brush(Muted), FontSize = 11, VerticalAlignment = VerticalAlignment.Center
            });
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            buttons.Children.Add(TitleButton("—", delegate { WindowState = WindowState.Minimized; }));
            buttons.Children.Add(TitleButton("□", delegate { WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; }));
            buttons.Children.Add(TitleButton("×", delegate { Close(); }));
            Grid.SetColumn(buttons, 1);
            bar.Children.Add(buttons);
            return bar;
        }

        private Button TitleButton(string text, Action click)
        {
            var b = new Button { Content = text, Width = 46, Height = 28, FontSize = 14, Background = Brushes.Transparent, Foreground = Brush(Text), BorderThickness = new Thickness(0) };
            WindowChrome.SetIsHitTestVisibleInChrome(b, true);
            b.Click += delegate { click(); };
            return b;
        }

        private UIElement BuildSidebar()
        {
            var side = new Grid { Background = Brush(Side) };
            side.RowDefinitions.Add(new RowDefinition { Height = new GridLength(82) });
            side.RowDefinitions.Add(new RowDefinition { Height = new GridLength(324) });
            side.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            side.RowDefinitions.Add(new RowDefinition { Height = new GridLength(98) });

            var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 14, 10, 8), HorizontalAlignment = HorizontalAlignment.Center };
            brand.Children.Add(new Border { Width = 42, Height = 42, CornerRadius = new CornerRadius(21), Background = Brush(C("#28343E")), BorderBrush = Brush(Accent), BorderThickness = new Thickness(1), Child = new TextBlock { Text = "◆", Foreground = Brush(Accent), FontSize = 22, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
            var brandText = new StackPanel { Margin = new Thickness(14, -1, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            brandText.Children.Add(T("出图100%", 24, Text, FontWeights.Bold));
            brand.Children.Add(brandText);
            side.Children.Add(brand);

            var nav = new StackPanel { Margin = new Thickness(16, 8, 16, 0) };
            nav.Children.Add(Nav("batch", "▣", "批次处理", true));
            nav.Children.Add(Nav("drawings", "▱", "图纸管理", false));
            nav.Children.Add(Nav("quality", "◆", "质量验收", false));
            nav.Children.Add(Nav("issues", "⬟", "问题清单", false));
            nav.Children.Add(Nav("history", "▤", "处理记录", false));
            nav.Children.Add(Nav("settings", "⚙", "系统设置", false));
            Grid.SetRow(nav, 1); side.Children.Add(nav);

            var logPanel = new Border
            {
                Margin = new Thickness(16, 8, 16, 8), CornerRadius = new CornerRadius(5),
                Background = Brush(C("#171D22")), BorderBrush = Brush(Border), BorderThickness = new Thickness(1)
            };
            var logRoot = new Grid();
            logRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(38) });
            logRoot.RowDefinitions.Add(new RowDefinition());
            var logHeader = new Grid { Background = Brush(C("#1B2228")), Cursor = Cursors.Hand };
            logHeader.ColumnDefinitions.Add(new ColumnDefinition());
            logHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
            var logTitle = T("处理日志（最新记录）", 12, Text, FontWeights.SemiBold); logTitle.Margin = new Thickness(12, 0, 0, 0); logTitle.VerticalAlignment = VerticalAlignment.Center; logHeader.Children.Add(logTitle);
            var logArrow = T("⌃", 14, Muted); logArrow.HorizontalAlignment = HorizontalAlignment.Center; logArrow.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(logArrow, 1); logHeader.Children.Add(logArrow);
            logRoot.Children.Add(logHeader);
            logText = new TextBlock { Text = "等待选择待处理目录。", Foreground = Brush(C("#D7DEE4")), FontSize = 11, LineHeight = 19, Margin = new Thickness(12, 8, 10, 8), TextWrapping = TextWrapping.Wrap };
            var logScroll = new ScrollViewer { Content = logText, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            Grid.SetRow(logScroll, 1); logRoot.Children.Add(logScroll);
            logHeader.MouseLeftButtonUp += delegate
            {
                bool expanded = logScroll.Visibility == Visibility.Visible;
                logScroll.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
                logArrow.Text = expanded ? "⌄" : "⌃";
            };
            logPanel.Child = logRoot; Grid.SetRow(logPanel, 2); side.Children.Add(logPanel);

            var user = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(24, 18, 12, 12) };
            user.Children.Add(new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(19), BorderBrush = Brush(Border), BorderThickness = new Thickness(1), Background = Brush(Panel2), Child = new TextBlock { Text = "●", Foreground = Brush(Muted), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
            var ut = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
            ut.Children.Add(T("系统管理员", 13, Text)); ut.Children.Add(T("admin", 11, Muted)); user.Children.Add(ut);
            Grid.SetRow(user, 3); side.Children.Add(user);
            return side;
        }

        private UIElement Nav(string key, string icon, string label, bool active)
        {
            var b = new Border { Height = 50, Margin = new Thickness(0, 2, 0, 2), CornerRadius = new CornerRadius(5), Background = active ? Brush(C("#26323D")) : Brushes.Transparent, BorderBrush = active ? Brush(C("#3E5264")) : Brushes.Transparent, BorderThickness = new Thickness(1) };
            b.Tag = active;
            var s = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
            s.Children.Add(T(icon, 18, active ? Accent : Muted));
            var labelText = T(label, 14, active ? Text : C("#C0C7CD"), active ? FontWeights.SemiBold : FontWeights.Normal); labelText.Margin = new Thickness(14, 0, 0, 0); s.Children.Add(labelText); b.Child = s;
            b.MouseEnter += delegate { b.Background = Brush(C("#2B3945")); b.BorderBrush = Brush(Accent); };
            b.MouseLeave += delegate
            {
                bool selected = b.Tag is bool && (bool)b.Tag;
                b.Background = selected ? Brush(C("#26323D")) : Brushes.Transparent;
                b.BorderBrush = selected ? Brush(C("#3E5264")) : Brushes.Transparent;
            };
            b.Cursor = Cursors.Hand;
            b.MouseLeftButtonUp += delegate { ShowPage(key); };
            navItems[key] = b;
            return b;
        }

        private UIElement BuildContent()
        {
            var content = new Grid { Margin = new Thickness(18, 14, 16, 14) };
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(106) });
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(112) });
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(326) });
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(82) });
            content.Children.Add(BuildSummary());
            var actions = BuildActions(); Grid.SetRow(actions, 1); content.Children.Add(actions);
            var table = BuildTable(); Grid.SetRow(table, 2); content.Children.Add(table);
            var info = BuildInfo(); Grid.SetRow(info, 3); content.Children.Add(info);
            var bottom = BuildBottom(); Grid.SetRow(bottom, 4); content.Children.Add(bottom);
            return content;
        }

        private void ShowPage(string key)
        {
            foreach (KeyValuePair<string, Border> item in navItems)
            {
                bool selected = item.Key == key;
                item.Value.Tag = selected;
                item.Value.Background = selected ? Brush(C("#26323D")) : Brushes.Transparent;
                item.Value.BorderBrush = selected ? Brush(C("#3E5264")) : Brushes.Transparent;
            }
            pageHost.Children.Clear();
            if (key == "batch") pageHost.Children.Add(batchPage);
            else if (key == "drawings") pageHost.Children.Add(BuildDrawingsPage());
            else if (key == "quality") pageHost.Children.Add(BuildQualityPage());
            else if (key == "issues") pageHost.Children.Add(BuildIssuesPage());
            else if (key == "history") pageHost.Children.Add(BuildHistoryPage());
            else pageHost.Children.Add(BuildSettingsPage());
        }

        private UIElement BuildPageShell(string title, string detail, UIElement content)
        {
            var root = new Grid { Margin = new Thickness(18, 18, 16, 16) };
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(78) });
            root.RowDefinitions.Add(new RowDefinition());
            var header = new StackPanel();
            header.Children.Add(T(title, 25, Text, FontWeights.Bold));
            header.Children.Add(T(detail, 12, Muted));
            root.Children.Add(header);
            Grid.SetRow(content, 1); root.Children.Add(content);
            return root;
        }

        private UIElement BuildDrawingsPage()
        {
            var rows = drawingGrid == null || drawingGrid.ItemsSource == null
                ? new List<DrawingRow>() : drawingGrid.ItemsSource.Cast<DrawingRow>().ToList();
            var list = new DataGrid { AutoGenerateColumns=false, CanUserAddRows=false, IsReadOnly=true, Background=Brush(Panel), Foreground=Brush(Text), BorderBrush=Brush(Border), RowHeight=30 };
            list.Resources[typeof(DataGridColumnHeader)] = HeaderStyle(); list.Resources[typeof(DataGridRow)] = RowStyle(); list.Resources[typeof(DataGridCell)] = CellStyle();
            list.Columns.Add(Col("源 DWG","SourceFile",230)); list.Columns.Add(Col("图号","No",150)); list.Columns.Add(Col("图名","Name",280)); list.Columns.Add(Col("图别","Type",120)); list.Columns.Add(Col("比例","Scale",100)); list.Columns.Add(Col("单位","Unit",80)); list.Columns.Add(Col("处理结果","Result",430));
            list.ItemsSource = rows;
            return BuildPageShell("图纸管理", "浏览本批次扫描到的全部图纸及图签状态。编辑请在“批次处理”页面进行。", list);
        }

        private UIElement BuildQualityPage()
        {
            var rows = drawingGrid == null || drawingGrid.ItemsSource == null ? new List<DrawingRow>() : drawingGrid.ItemsSource.Cast<DrawingRow>().ToList();
            int passed = rows.Count(r => r.Tone == "normal"); int review = rows.Count(r => r.Tone == "yellow"); int failed = rows.Count(r => r.Tone == "red");
            var card = Card(new Thickness(0), new CornerRadius(6));
            var s = new StackPanel { Margin = new Thickness(28) };
            s.Children.Add(T("当前批次质量概况", 18, Text, FontWeights.Bold));
            s.Children.Add(T("\n通过：" + passed + " 张\n待人工核对：" + review + " 张\n处理失败：" + failed + " 张\n\n最终处理后，失败成果会自动移出正式输出目录。", 14, Text));
            card.Child = s; return BuildPageShell("质量验收", "汇总逐文件扫描、替换和最终验收结果。", card);
        }

        private UIElement BuildIssuesPage()
        {
            var rows = drawingGrid == null || drawingGrid.ItemsSource == null ? new List<DrawingRow>() : drawingGrid.ItemsSource.Cast<DrawingRow>().Where(r => r.Tone != "normal").ToList();
            var root = new Grid(); root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(48) }); root.RowDefinitions.Add(new RowDefinition());
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            var exportList = OutlineButton("导出失败/待核对清单…", 190, 34); exportList.Click += delegate { ExportIssueList(false); }; buttons.Children.Add(exportList);
            var exportBug = OutlineButton("导出完整 Bug 报告…", 170, 34); exportBug.Margin = new Thickness(12,0,0,0); exportBug.Click += delegate { ExportIssueList(true); }; buttons.Children.Add(exportBug); root.Children.Add(buttons);
            var list = new DataGrid { AutoGenerateColumns=false, CanUserAddRows=false, IsReadOnly=true, Background=Brush(Panel), Foreground=Brush(Text), BorderBrush=Brush(Border), RowHeight=30 };
            list.Resources[typeof(DataGridColumnHeader)] = HeaderStyle(); list.Resources[typeof(DataGridRow)] = RowStyle(); list.Resources[typeof(DataGridCell)] = CellStyle();
            list.Columns.Add(Col("源 DWG","FullSourceFile",230)); list.Columns.Add(Col("图签","Frame",70)); list.Columns.Add(Col("图号","No",150)); list.Columns.Add(Col("图名","Name",260)); list.Columns.Add(Col("处理结果","Result",500)); list.ItemsSource = rows; Grid.SetRow(list,1); root.Children.Add(list);
            return BuildPageShell("问题清单", "集中显示待人工核对和处理失败的图纸，可导出后直接转发。", root);
        }

        private void ExportIssueList(bool includeBugDetails)
        {
            var rows = drawingGrid == null || drawingGrid.ItemsSource == null
                ? new List<DrawingRow>() : drawingGrid.ItemsSource.Cast<DrawingRow>().Where(r => r.Tone != "normal").ToList();
            using (var dialog = new System.Windows.Forms.SaveFileDialog())
            {
                dialog.Title = includeBugDetails ? "导出完整 Bug 报告" : "导出失败/待核对清单";
                dialog.Filter = "文本报告 (*.txt)|*.txt";
                dialog.FileName = (includeBugDetails ? "出图100%_Bug报告_" : "出图100%_问题清单_") + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".txt";
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                var b = new StringBuilder();
                b.AppendLine(includeBugDetails ? "出图100% 完整 Bug 报告" : "出图100% 失败/待核对清单");
                b.AppendLine("生成时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                b.AppendLine("程序版本：v1.9.15；处理核心：" + typeof(CadFrameReplacer.MainForm).Assembly.GetName().Version);
                b.AppendLine("批次文件夹名称：" + (string.IsNullOrWhiteSpace(selectedInputDirectory) ? "未选择" : System.IO.Path.GetFileName(selectedInputDirectory.TrimEnd('\\'))));
                b.AppendLine("问题总数：" + rows.Count); b.AppendLine();
                for (int i=0;i<rows.Count;i++)
                {
                    DrawingRow r=rows[i];
                    b.AppendLine((i+1)+". 源DWG："+Display(r.FullSourceFile)+"；图签："+Display(r.Frame)+"；图号："+Display(r.No)+"；图名："+Display(r.Name));
                    b.AppendLine("   处理结果："+Display(r.Result));
                    if(r.Tone=="red") {
                        var explanation=FailureExplanation.FromTechnical(r.TechnicalResult ?? r.Result);
                        b.AppendLine("   原因："+explanation.Reason);
                        b.AppendLine("   建议："+explanation.Advice);
                        if(includeBugDetails) b.AppendLine("   原始诊断："+(r.TechnicalResult ?? r.Result));
                    }
                }
                if (includeBugDetails)
                {
                    b.AppendLine(); b.AppendLine("===== 处理核心日志 ====="); b.AppendLine(core.ShellLog);
                    string crash=System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"log","界面异常报告.log");
                    if(File.Exists(crash)){b.AppendLine();b.AppendLine("===== 界面异常日志 =====");b.AppendLine(File.ReadAllText(crash,Encoding.UTF8));}
                }
                File.WriteAllText(dialog.FileName,b.ToString(),new UTF8Encoding(true));
                MessageBox.Show("报告已导出，可直接发送给问题处理人员：\n"+dialog.FileName,"导出完成",MessageBoxButton.OK,MessageBoxImage.Information);
            }
        }

        private UIElement BuildHistoryPage()
        {
            var card = Card(new Thickness(0), new CornerRadius(6));
            var g = new Grid { Margin = new Thickness(20) }; g.RowDefinitions.Add(new RowDefinition { Height=new GridLength(46) }); g.RowDefinitions.Add(new RowDefinition());
            var export = OutlineButton("导出处理记录…", 150, 34); export.HorizontalAlignment = HorizontalAlignment.Left; export.Click += delegate { ExportProcessingHistory(); }; g.Children.Add(export);
            var history = new TextBox { Text=core.ShellLog, IsReadOnly=true, AcceptsReturn=true, VerticalScrollBarVisibility=ScrollBarVisibility.Auto, Background=Brush(C("#141A1E")), Foreground=Brush(Text), BorderBrush=Brush(Border), FontFamily=new FontFamily("Consolas"), FontSize=12, Padding=new Thickness(12) }; Grid.SetRow(history,1); g.Children.Add(history); card.Child=g;
            return BuildPageShell("处理记录", "查看当前任务日志，并导出为 UTF-8 文本记录。", card);
        }

        private UIElement BuildSettingsPage()
        {
            var card=Card(new Thickness(0),new CornerRadius(6));var s=new StackPanel{Margin=new Thickness(28)};s.Children.Add(T("运行环境",18,Text,FontWeights.Bold));s.Children.Add(T("\n处理核心："+typeof(CadFrameReplacer.MainForm).Assembly.GetName().Version+"\nAutoCAD Core：由程序自动检测，也可沿用已保存配置\n输出规则：默认创建 V1.0；目录占用后继续 V2.0、V3.0……\n原始 DWG：永不覆盖",13,Text));card.Child=s;return BuildPageShell("系统设置","查看运行环境和默认处理规则。",card);
        }

        private void ExportProcessingHistory()
        {
            using (var dialog = new System.Windows.Forms.SaveFileDialog())
            {
                dialog.Title = "导出处理记录";
                dialog.Filter = "文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*";
                dialog.FileName = "出图100%_处理记录_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".txt";
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                var builder = new StringBuilder();
                builder.AppendLine("出图100% 处理记录");
                builder.AppendLine("导出时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                builder.AppendLine("待处理目录：" + Display(selectedInputDirectory));
                builder.AppendLine("输出目录：" + Display(core.ShellOutputDirectory));
                builder.AppendLine("状态：" + Display(core.ShellStatus));
                builder.AppendLine(); builder.AppendLine(core.ShellLog);
                File.WriteAllText(dialog.FileName, builder.ToString(), new UTF8Encoding(true));
                MessageBox.Show("处理记录已导出：\n" + dialog.FileName, "导出完成", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }

        private UIElement BuildSummary()
        {
            var card = Card(new Thickness(0, 0, 0, 10), new CornerRadius(6));
            var g = new Grid { Margin = new Thickness(22, 12, 18, 10) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.8, GridUnitType.Star) });
            for (int i = 0; i < 4; i++) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.72, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(128) });
            var ready = new StackPanel { Orientation = Orientation.Horizontal };
            ready.Children.Add(new Border { Width = 52, Height = 52, CornerRadius = new CornerRadius(26), BorderBrush = Brush(Accent), BorderThickness = new Thickness(2), Background = Brush(C("#1E2931")), Child = new TextBlock { Text = "✓", FontSize = 34, Foreground = Brush(Accent), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
            var rt = new StackPanel { Margin = new Thickness(18, 0, 0, 0) };
            readyTitleText = T("请选择待处理目录", 25, Text, FontWeights.Bold);
            readyDetailText = T("点击“扫描图纸”开始读取真实 DWG", 12, Muted);
            rt.Children.Add(readyTitleText); rt.Children.Add(readyDetailText); ready.Children.Add(rt); g.Children.Add(ready);
            totalMetricText = AddMetric(g, 1, "图签总数", "0", Text);
            recognizedMetricText = AddMetric(g, 2, "可处理", "0", Text);
            reviewMetricText = AddMetric(g, 3, "待人工核对", "0", Yellow);
            failedMetricText = AddMetric(g, 4, "处理失败", "0", Red);
            card.Child = g; return card;
        }

        private TextBlock AddMetric(Grid g, int column, string label, string value, Color valueColor)
        {
            var border = new Border { BorderBrush = Brush(C("#2C353D")), BorderThickness = new Thickness(1, 0, 0, 0), Margin = new Thickness(0, 10, 0, 8) };
            var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            s.Children.Add(T(label, 12, C("#C4CBD1"))); var v = T(value, 26, valueColor, FontWeights.SemiBold); v.HorizontalAlignment = HorizontalAlignment.Center; s.Children.Add(v); border.Child = s; Grid.SetColumn(border, column); g.Children.Add(border); return v;
        }

        private UIElement BuildActions()
        {
            var g = new Grid { Margin = new Thickness(0, 0, 0, 10) };
            g.RowDefinitions.Add(new RowDefinition()); g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(24) });
            for (int i = 0; i < 4; i++)
            {
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                if (i < 3) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            }
            selectStepCard = StepCard("1", "选择文件夹", "只选择待处理目录", false);
            selectStepCard.MouseLeftButtonUp += delegate { SelectInputDirectoryOnly(); };
            g.Children.Add(selectStepCard);
            scanStepCard = StepCard("2", "扫描图纸", "读取 DWG 图框与图签", false);
            scanStepCard.MouseLeftButtonUp += async delegate { await ScanSelectedDirectoryAsync(); };
            Grid.SetColumn(scanStepCard, 2); g.Children.Add(scanStepCard);
            processStepCard = StepCard("3", "开始处理", "按当前编辑值执行并验收", false);
            processStepCard.MouseLeftButtonUp += async delegate { await StartApplyAsync(); };
            Grid.SetColumn(processStepCard, 4); g.Children.Add(processStepCard);
            outputStepCard = StepCard("4", "打开输出文件夹", "默认自动创建 V1.0 文件夹", false);
            outputStepCard.MouseLeftButtonUp += delegate { if (Directory.Exists(core.ShellOutputDirectory)) core.ShellOpenOutput(); };
            Grid.SetColumn(outputStepCard, 6); g.Children.Add(outputStepCard);
            selectedFolderText = T("当前文件夹：尚未选择", 11, Text, FontWeights.SemiBold); selectedFolderText.VerticalAlignment=VerticalAlignment.Bottom; selectedFolderText.TextTrimming=TextTrimming.CharacterEllipsis; selectedFolderText.Margin=new Thickness(4,3,4,0); Grid.SetRow(selectedFolderText,1); Grid.SetColumnSpan(selectedFolderText,7); g.Children.Add(selectedFolderText);
            return g;
        }

        private Border StepCard(string number, string title, string detail, bool enabled)
        {
            var card = ActionCard(number, title, detail, false);
            card.Cursor = Cursors.Hand;
            return card;
        }

        private Border ActionCard(string icon, string title, string detail, bool active)
        {
            var b = Card(new Thickness(0), new CornerRadius(6)); b.Background = Brush(Panel); b.BorderBrush = Brush(Border);
            var s = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            var iconText = T(icon, 30, C("#8F9CA7"));
            s.Children.Add(iconText); var texts = new StackPanel { Margin = new Thickness(20, 0, 0, 0) }; texts.Children.Add(T(title, 18, Text, FontWeights.SemiBold)); texts.Children.Add(T(detail, 11, Muted)); s.Children.Add(texts); b.Child = s;
            b.MouseEnter += delegate
            {
                b.Background = Brush(C("#202B35"));
                b.BorderBrush = Brush(Accent);
                b.BorderThickness = new Thickness(1.5);
                iconText.Foreground = Brush(Accent);
            };
            b.MouseLeave += delegate
            {
                b.Background = Brush(Panel);
                b.BorderBrush = Brush(Border);
                b.BorderThickness = new Thickness(1);
                iconText.Foreground = Brush(C("#8F9CA7"));
            };
            b.MouseLeftButtonDown += delegate
            {
                b.Background = Brush(C("#18232C"));
                b.BorderBrush = Brush(C("#B7CEE2"));
            };
            b.MouseLeftButtonUp += delegate
            {
                if (b.IsMouseOver)
                {
                    b.Background = Brush(C("#202B35"));
                    b.BorderBrush = Brush(Accent);
                }
            };
            return b;
        }

        private UIElement BuildInfo()
        {
            var g = new Grid { Margin = new Thickness(0, 0, 0, 10) }; g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.82, GridUnitType.Star) }); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) }); g.ColumnDefinitions.Add(new ColumnDefinition());
            var clearInfo = OutlineButton("清空统一信息", 92, 24);
            clearInfo.ToolTip = "清空上方统一信息；逐图字段、人员姓名和签字选择保持不变";
            clearInfo.Click += delegate { ClearProjectInformation(); };
            var project = SectionCard("▦  统一信息（切换目录保留；留空保留原值）", BuildProjectInfo(), clearInfo); g.Children.Add(project);
            var clearPeople = OutlineButton("清空人员姓名", 92, 24);
            clearPeople.ToolTip = "清空所有姓名输入；逐图字段及签字 DWG 选择保持不变";
            clearPeople.Click += delegate { ClearPersonnelInformation(); };
            var people = SectionCard("▣  人员姓名（切换目录保留）", BuildPeopleInfo(), clearPeople); Grid.SetColumn(people, 2); g.Children.Add(people); return g;
        }

        private UIElement BuildProjectInfo()
        {
            var g = new Grid(); for(int i=0;i<4;i++) g.RowDefinitions.Add(new RowDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(112) }); g.ColumnDefinitions.Add(new ColumnDefinition()); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(102) }); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
            AddCell(g,0,0,"项目名称",true); AddEditorCell(g,1,0,"project"); AddCell(g,2,0,"设计项目号",true); AddEditorCell(g,3,0,"number");
            AddCell(g,0,1,"子项名称",true); AddEditorCell(g,1,1,"subitem"); AddCell(g,2,1,"图别",true); AddEditorCell(g,3,1,"type");
            AddCell(g,0,2,"建设单位",true); AddEditorCell(g,1,2,"owner"); AddCell(g,2,2,"版本号",true); AddEditorCell(g,3,2,"revision");
            AddCell(g,0,3,"比例/单位",true); AddEditorCell(g,1,3,"scale_unit"); AddCell(g,2,3,"出图日期",true); AddEditorCell(g,3,3,"date"); return g;
        }

        private UIElement BuildPeopleInfo()
        {
            // The information area is 326 px high including its 35 px title.
            // Ten 31 px personnel rows overflowed it and clipped the final
            // 审定 row.  At 28 px all ten roles remain visible without a
            // secondary scrollbar.
            var g = new Grid(); for(int i=0;i<10;i++) g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(28) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(168) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(105) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(62) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
            string[,] v={{"设计总负责人（一）","N设计总负责人_T5_H3","签字图块_设计总负责人"},{"设计总负责人（二）","N执行设总_T5_H3","签字图块_执行设总"},{"设计总负责人（三）","N执行设总二_T5_H3","签字图块_执行设总二"},{"专业负责人（一）","N专业负责人_T5_H3","签字图块_专业负责人"},{"专业负责人（二）","N专业负责人（副）_T5_H3","签字图块_专业负责人副"},{"专业负责人（三）","N专业负责人（副）二_T5_H3","签字图块_专业负责人副二"},{"设计","N设计_T5_H3","签字图块_设计"},{"校对","N校对_T5_H3","签字图块_校对"},{"审核","N审核_T5_H3","签字图块_审核"},{"审定","N审定_T5_H3","签字图块_审定"}};
            for(int r=0;r<10;r++)
            {
                AddCell(g,0,r,v[r,0],true);
                AddPersonnelEditorCell(g,1,r,v[r,1]);
                var path = T("未选择签字 DWG", 10, Text); path.TextTrimming = TextTrimming.CharacterEllipsis; path.Margin = new Thickness(8,0,4,0); signaturePathTexts[v[r,2]] = path; Grid.SetColumn(path,2);Grid.SetRow(path,r);g.Children.Add(path);
                string signatureColumn = v[r,2];
                var choose=OutlineButton("选择…",56,23); choose.Click += delegate { SelectSignatureDwg(signatureColumn); }; Grid.SetColumn(choose,3);Grid.SetRow(choose,r);g.Children.Add(choose);
                var clear=OutlineButton("清空",44,23); clear.Click += delegate { ClearSignatureDwg(signatureColumn); }; Grid.SetColumn(clear,4);Grid.SetRow(clear,r);g.Children.Add(clear);
            }
            return g;
        }

        private void SelectSignatureDwg(string signatureColumn)
        {
            using (var dialog = new System.Windows.Forms.OpenFileDialog())
            {
                dialog.Title = "选择签字 DWG";
                dialog.Filter = "AutoCAD DWG (*.dwg)|*.dwg";
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                try
                {
                    core.ShellSetSignaturePath(signatureColumn, dialog.FileName);
                    signaturePathTexts[signatureColumn].Text = System.IO.Path.GetFileName(dialog.FileName) + "（批量应用）";
                }
                catch (Exception ex) { MessageBox.Show(ex.Message, "签字 DWG 无效", MessageBoxButton.OK, MessageBoxImage.Warning); }
            }
        }

        private void ClearSignatureDwg(string signatureColumn)
        {
            core.ShellSetSignaturePath(signatureColumn, string.Empty);
            signaturePathTexts[signatureColumn].Text = "已设置为批量删除签字";
        }

        private Border AddCell(Grid g, int column, int row, string value, bool label)
        {
            var b = new Border { BorderBrush = Brush(C("#303940")), BorderThickness = new Thickness(0,0,1,1), Background = label ? Brush(C("#1B2227")) : Brushes.Transparent };
            b.Child = new TextBlock { Text=value, Foreground=Brush(label?C("#C0C7CC"):Text), FontSize=11, VerticalAlignment=VerticalAlignment.Center, Margin=new Thickness(12,0,6,0) }; Grid.SetColumn(b,column);Grid.SetRow(b,row);g.Children.Add(b);return b;
        }

        private static TextBlock CellText(Border cell) { return (TextBlock)cell.Child; }

        private void AddEditorCell(Grid g, int column, int row, string key)
        {
            var box = EditorBox();
            projectEditors[key] = box;
            box.TextChanged += delegate { if (!syncingUi) PersistProjectEditor(key, box.Text); };
            Grid.SetColumn(box, column); Grid.SetRow(box, row); g.Children.Add(box);
        }

        private void AddPersonnelEditorCell(Grid g, int column, int row, string key)
        {
            var box = EditorBox();
            personnelEditors[key] = box;
            box.TextChanged += delegate { if (!syncingUi) core.ShellSetPersonnelName(key, box.Text); };
            Grid.SetColumn(box, column); Grid.SetRow(box, row); g.Children.Add(box);
        }

        private TextBox EditorBox()
        {
            return new TextBox
            {
                Background = Brush(C("#20272D")),
                Foreground = Brush(Text),
                BorderBrush = Brush(C("#46525D")),
                BorderThickness = new Thickness(0, 0, 1, 1),
                Padding = new Thickness(10, 3, 6, 3),
                FontSize = 11,
                VerticalContentAlignment = VerticalAlignment.Center
            };
        }

        private UIElement BuildTable()
        {
            var card = SectionCard("图纸列表", null); var root = (Grid)card.Child; drawingGrid = new DataGrid { AutoGenerateColumns=false, CanUserAddRows=false, CanUserDeleteRows=false, HeadersVisibility=DataGridHeadersVisibility.Column, GridLinesVisibility=DataGridGridLinesVisibility.Horizontal, Background=Brush(C("#D8141A1E")), Foreground=Brush(Text), BorderThickness=new Thickness(0), RowHeight=27, ColumnHeaderHeight=30, FontSize=11, IsReadOnly=true, SelectionMode=DataGridSelectionMode.Single, Margin=new Thickness(0) };
            drawingGrid.Resources[typeof(DataGridColumnHeader)] = HeaderStyle(); drawingGrid.Resources[typeof(DataGridRow)] = RowStyle(); drawingGrid.Resources[typeof(DataGridCell)] = CellStyle(); drawingGrid.Columns.Add(Col("源 CAD 文件名","SourceFile",240)); drawingGrid.Columns.Add(EditCol("图号","No",135)); drawingGrid.Columns.Add(EditCol("图名","Name",220)); drawingGrid.Columns.Add(EditCol("图别","Type",100)); drawingGrid.Columns.Add(EditCol("比例","Scale",90)); drawingGrid.Columns.Add(EditCol("单位","Unit",70)); drawingGrid.Columns.Add(new DataGridTemplateColumn { Header="处理结果", Width=new DataGridLength(360), IsReadOnly=true, CellTemplate=ResultDetailsTemplate() });
            var confirm = new DataGridTemplateColumn { Header = "人工核对", Width = new DataGridLength(90), CellTemplate = ConfirmButtonTemplate() };
            drawingGrid.Columns.Add(confirm);
            drawingGrid.IsReadOnly = false;
            drawingGrid.CellEditEnding += DrawingGridCellEditEnding;
            drawingGrid.ItemsSource = new List<DrawingRow>(); Grid.SetRow(drawingGrid,1); root.Children.Add(drawingGrid); return card;
        }

        private Style HeaderStyle(){var s=new Style(typeof(DataGridColumnHeader));s.Setters.Add(new Setter(Control.BackgroundProperty,Brush(C("#E61A2126"))));s.Setters.Add(new Setter(Control.ForegroundProperty,Brush(C("#CDD4DA"))));s.Setters.Add(new Setter(Control.BorderBrushProperty,Brush(C("#303A42"))));s.Setters.Add(new Setter(Control.BorderThicknessProperty,new Thickness(0,0,1,1)));s.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(12,0,6,0)));return s;}
        private Style RowStyle(){var s=new Style(typeof(DataGridRow));s.Setters.Add(new Setter(Control.BackgroundProperty,Brush(C("#D8141A1E"))));s.Setters.Add(new Setter(Control.ForegroundProperty,Brush(Text)));s.Setters.Add(new Setter(Control.BorderBrushProperty,Brush(C("#293138"))));var yellow=new DataTrigger{Binding=new Binding("Tone"),Value="yellow"};yellow.Setters.Add(new Setter(Control.BackgroundProperty,Brush(C("#E048341B"))));yellow.Setters.Add(new Setter(Control.ForegroundProperty,Brush(C("#F2B24D"))));s.Triggers.Add(yellow);var red=new DataTrigger{Binding=new Binding("Tone"),Value="red"};red.Setters.Add(new Setter(Control.BackgroundProperty,Brush(C("#E03B2224"))));red.Setters.Add(new Setter(Control.ForegroundProperty,Brush(C("#F06A61"))));s.Triggers.Add(red);return s;}
        private DataGridTextColumn Col(string h,string path,double w){var style=CellTextStyle(); style.Setters.Add(new Setter(TextBlock.ToolTipProperty,new Binding(path))); return new DataGridTextColumn{Header=h,Binding=new Binding(path),Width=new DataGridLength(w),ElementStyle=style};}
        private DataGridTextColumn EditCol(string h,string path,double w){return new DataGridTextColumn{Header=h,Binding=new Binding(path){Mode=BindingMode.TwoWay,UpdateSourceTrigger=UpdateSourceTrigger.PropertyChanged},Width=new DataGridLength(w),ElementStyle=CellTextStyle()};}
        private Style CellTextStyle(){var s=new Style(typeof(TextBlock));s.Setters.Add(new Setter(TextBlock.VerticalAlignmentProperty,VerticalAlignment.Center));s.Setters.Add(new Setter(TextBlock.MarginProperty,new Thickness(12,0,4,0)));s.Setters.Add(new Setter(TextBlock.ForegroundProperty,Brush(Text)));return s;}
        private Style CellStyle(){var s=new Style(typeof(DataGridCell));s.Setters.Add(new Setter(Control.ForegroundProperty,Brush(Text)));s.Setters.Add(new Setter(Control.BackgroundProperty,Brushes.Transparent));s.Setters.Add(new Setter(Control.BorderBrushProperty,Brush(C("#293138"))));var selected=new Trigger{Property=DataGridCell.IsSelectedProperty,Value=true};selected.Setters.Add(new Setter(Control.BackgroundProperty,Brush(C("#35506A"))));selected.Setters.Add(new Setter(Control.ForegroundProperty,Brush(Text)));s.Triggers.Add(selected);return s;}

        private DataTemplate ConfirmButtonTemplate()
        {
            var template = new DataTemplate();
            var factory = new FrameworkElementFactory(typeof(Button));
            factory.SetBinding(ContentControl.ContentProperty, new Binding("ConfirmText"));
            factory.SetValue(Control.ForegroundProperty, Brush(Text));
            factory.SetValue(Control.BackgroundProperty, Brush(C("#2C3944")));
            factory.SetValue(Control.BorderBrushProperty, Brush(Accent));
            factory.SetValue(Control.MarginProperty, new Thickness(5, 2, 5, 2));
            factory.AddHandler(Button.ClickEvent, new RoutedEventHandler(ConfirmRowClick));
            template.VisualTree = factory;
            return template;
        }

        private DataTemplate ResultDetailsTemplate()
        {
            var template = new DataTemplate();
            var panel = new FrameworkElementFactory(typeof(DockPanel));
            var button = new FrameworkElementFactory(typeof(Button));
            button.SetValue(DockPanel.DockProperty, Dock.Right);
            button.SetValue(ContentControl.ContentProperty, "详情");
            button.SetValue(FrameworkElement.WidthProperty, 40.0);
            button.SetValue(FrameworkElement.MarginProperty, new Thickness(3,2,4,2));
            button.SetValue(Control.BackgroundProperty, Brush(C("#2C3944")));
            button.SetValue(Control.ForegroundProperty, Brush(Text));
            button.SetValue(Control.BorderBrushProperty, Brush(C("#4A5864")));
            button.SetValue(FrameworkElement.ToolTipProperty, "查看并复制完整处理结果");
            button.AddHandler(Button.ClickEvent, new RoutedEventHandler(ResultDetailsClick));
            panel.AppendChild(button);
            var text = new FrameworkElementFactory(typeof(TextBlock));
            text.SetBinding(TextBlock.TextProperty, new Binding("Result"));
            text.SetBinding(FrameworkElement.ToolTipProperty, new Binding("Result"));
            text.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
            text.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            text.SetValue(FrameworkElement.MarginProperty, new Thickness(12,0,2,0));
            text.SetValue(TextBlock.ForegroundProperty, Brush(Text));
            panel.AppendChild(text);
            template.VisualTree = panel;
            return template;
        }

        private void ResultDetailsClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            var row = button == null ? null : button.DataContext as DrawingRow;
            if (row == null) return;
            e.Handled = true;
            var dialog = CreateResultDetailsWindow(row);
            dialog.Owner = this;
            dialog.ShowDialog();
        }

        private Window CreateResultDetailsWindow(DrawingRow row)
        {
            string technical=row.TechnicalResult ?? row.Result ?? string.Empty;
            string metadata="源 DWG："+row.FullSourceFile+"\r\n图签："+row.Frame+"\r\n图号："+row.No+"\r\n图名："+row.Name;
            var explanation=FailureExplanation.FromTechnical(technical);
            string details=metadata+"\r\n\r\n"+(row.Tone=="red"
                ? "问题："+explanation.Summary+"\r\n\r\n原因：\r\n"+explanation.Reason+
                  "\r\n\r\n影响：\r\n"+explanation.Impact+"\r\n\r\n建议操作：\r\n"+explanation.Advice+
                  "\r\n\r\n查找图纸：失败成果通常在同批次的“失败文件隔离”文件夹中；若处理未完成，可能尚未生成输出文件。"+
                  "\r\n\r\n说明：同一文件中的其他图签也可能涉及这些问题。“已确认”仅表示扫描信息已确认，不代表处理失败已解决。"
                : "处理结果：\r\n"+row.Result);
            var dialog = new Window {
                Title="处理结果说明", Width=820, Height=620, MinWidth=480, MinHeight=360,
                WindowStartupLocation=WindowStartupLocation.CenterOwner,
                Background=Brush(Panel2), Foreground=Brush(Text)
            };
            var root = new Grid { Margin=new Thickness(16) };
            root.RowDefinitions.Add(new RowDefinition { Height=new GridLength(1,GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height=GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height=GridLength.Auto });
            var box = new TextBox {
                Text=details, IsReadOnly=true, TextWrapping=TextWrapping.Wrap,
                VerticalScrollBarVisibility=ScrollBarVisibility.Auto,
                Background=Brush(C("#20272D")), Foreground=Brush(Text),
                BorderBrush=Brush(C("#46525D")), Padding=new Thickness(12), FontSize=13
            };
            root.Children.Add(box);
            var diagnosticBox=new TextBox {
                Text=technical, IsReadOnly=true, TextWrapping=TextWrapping.Wrap,
                VerticalScrollBarVisibility=ScrollBarVisibility.Auto, MaxHeight=180,
                Background=Brush(C("#20272D")),Foreground=Brush(Text),Padding=new Thickness(10)
            };
            var expander=new Expander { Header="给维护人员的诊断信息（展开查看）",Content=diagnosticBox,
                IsExpanded=false,Foreground=Brush(Text),Margin=new Thickness(0,10,0,0) };
            Grid.SetRow(expander,1); root.Children.Add(expander);
            var actions = new StackPanel { Orientation=Orientation.Horizontal,
                HorizontalAlignment=HorizontalAlignment.Right, Margin=new Thickness(0,12,0,0) };
            var copy = OutlineButton("复制说明",90,30);
            copy.Margin = new Thickness(0,0,8,0);
            copy.Click += delegate {
                try { Clipboard.SetText(details); copy.Content="已复制"; }
                catch (System.Runtime.InteropServices.ExternalException) {
                    MessageBox.Show(dialog,"剪贴板暂不可用，请在内容区选择文字后按 Ctrl+C。","复制提示");
                }
            };
            var copyDiagnostic=OutlineButton("复制诊断",90,30);
            copyDiagnostic.Margin=new Thickness(0,0,8,0);
            copyDiagnostic.Click += delegate {
                try { Clipboard.SetText(details+"\r\n\r\n原始诊断：\r\n"+technical);copyDiagnostic.Content="已复制"; }
                catch(System.Runtime.InteropServices.ExternalException) { MessageBox.Show(dialog,"剪贴板暂不可用，请展开诊断信息后选择文字，按 Ctrl+C 复制。","复制提示"); }
            };
            var close = OutlineButton("关闭",70,30);
            close.IsCancel = true;
            close.Click += delegate { dialog.Close(); };
            actions.Children.Add(copy); actions.Children.Add(copyDiagnostic); actions.Children.Add(close);
            Grid.SetRow(actions,2); root.Children.Add(actions);
            dialog.Content = root;
            return dialog;
        }
        private List<DrawingRow> Rows(){return new List<DrawingRow>{R("A1-01-01","总平面图","建筑","1:500","mm","● 正常","-","normal"),R("A1-01-02","地下一层平面图","建筑","1:200","mm","● 正常","-","normal"),R("A1-01-03","地下二层平面图","建筑","1:200","mm","● 待人工核对","比例标注需核对","yellow"),R("A1-01-04","一层平面图","建筑","1:200","mm","● 正常","-","normal"),R("A1-01-05","机房层平面图","建筑","1:200","mm","● 处理失败；请手动处理","图签校验不通过（缺少审定签字）","red"),R("A1-01-06","屋顶层平面图","建筑","1:200","mm","● 待人工核对","图名与图号不一致","yellow"),R("A1-01-07","立面图 1-1～1-6","建筑","1:200","mm","● 正常","-","normal")};}
        private DrawingRow R(string a,string b,string c,string d,string e,string f,string g,string h){return new DrawingRow{No=a,Name=b,Type=c,Scale=d,Unit=e,Status=f,Issue=g,Result=g=="-"?f:f+"；"+g,Tone=h};}

        private UIElement BuildBottom()
        {
            var card = Card(new Thickness(0, 8, 0, 0), new CornerRadius(5));
            var body = new Grid { Margin = new Thickness(16, 8, 16, 8) };
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            body.ColumnDefinitions.Add(new ColumnDefinition());
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(310) });
            var title = T("处理进度", 12, Text, FontWeights.SemiBold); title.VerticalAlignment = VerticalAlignment.Center; body.Children.Add(title);
            progressBar = new ProgressBar { Minimum=0, Maximum=100, Value=0, Height=12, Foreground=Brush(C("#6F91B1")), Background=Brush(C("#263038")), BorderThickness=new Thickness(0), VerticalAlignment=VerticalAlignment.Center };
            Grid.SetColumn(progressBar,1); body.Children.Add(progressBar);
            progressPercentText=T("0%",18,Text,FontWeights.SemiBold); progressPercentText.HorizontalAlignment=HorizontalAlignment.Right; progressPercentText.VerticalAlignment=VerticalAlignment.Center; Grid.SetColumn(progressPercentText,2); body.Children.Add(progressPercentText);
            var metrics=new Grid { Margin = new Thickness(18,0,0,0) }; metrics.ColumnDefinitions.Add(new ColumnDefinition()); metrics.ColumnDefinitions.Add(new ColumnDefinition()); metrics.ColumnDefinitions.Add(new ColumnDefinition());
            normalBottomText=AddBottomMetric(metrics,0,"● 可处理","0 张",Muted); reviewBottomText=AddBottomMetric(metrics,1,"● 待核对","0 张",Yellow); failedBottomText=AddBottomMetric(metrics,2,"● 失败","0 张",Red); Grid.SetColumn(metrics,3); body.Children.Add(metrics);
            card.Child = body; return card;
        }
        private TextBlock AddBottomMetric(Grid g,int col,string label,string value,Color color){var s=new StackPanel{Margin=new Thickness(4,0,0,0),VerticalAlignment=VerticalAlignment.Center};s.Children.Add(T(label,10,color));var v=T(value,14,Text,FontWeights.SemiBold);s.Children.Add(v);Grid.SetColumn(s,col);g.Children.Add(s);return v;}

        private void SelectInputDirectoryOnly()
        {
            if (core.ShellBusy) return;
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog())
            {
                dialog.Description = "选择包含待处理 DWG 的目录";
                dialog.ShowNewFolderButton = false;
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                SetSelectedInputDirectory(dialog.SelectedPath);
            }
        }

        private void SetSelectedInputDirectory(string path)
        {
            PersistProjectEditorsToCore();
            selectedInputDirectory = path;
            if (inputPathText != null) inputPathText.Text = selectedInputDirectory;
            if (selectedFolderText != null)
            {
                string folderName = System.IO.Path.GetFileName(selectedInputDirectory.TrimEnd('\\'));
                selectedFolderText.Text = "当前文件夹：" + folderName + "    （" + selectedInputDirectory + "）";
            }
            readyTitleText.Text = "目录已选择，等待扫描";
            readyDetailText.Text = "确认目录后点击“扫描图纸”";
            UpdateStepStates(core.ShellTable == null ? 0 : core.ShellTable.Rows.Count);
        }

        private async Task ScanSelectedDirectoryAsync()
        {
            if (core.ShellBusy) return;
            if (string.IsNullOrWhiteSpace(selectedInputDirectory))
            {
                MessageBox.Show("请先点击“选择文件夹”选择待处理目录。", "尚未选择目录", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            try
            {
                IsEnabled = false;
                readyTitleText.Text = "正在扫描图纸";
                readyDetailText.Text = selectedInputDirectory;
                PersistProjectEditorsToCore();
                await core.ShellScanDirectoryAsync(selectedInputDirectory);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "扫描失败", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                IsEnabled = true;
                SyncFromCore();
            }
        }

        private async Task StartApplyAsync()
        {
            if (core.ShellBusy) return;
            if (core.ShellTable == null || core.ShellTable.Rows.Count == 0)
            {
                MessageBox.Show("请先扫描图纸。", "尚未扫描", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            try
            {
                IsEnabled = false;
                CommitWpfEditorsToCore();
                await core.ShellApplyAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "处理失败", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                IsEnabled = true;
                SyncFromCore();
            }
        }

        private void SyncFromCore()
        {
            DataTable table = core.ShellTable;
            var rows = new List<DrawingRow>();
            int review = 0;
            int failed = 0;
            int executable = 0;
            if (table != null)
            {
                string previousDrawing = null;
                for (int rowIndex = 0; rowIndex < table.Rows.Count; rowIndex++)
                {
                    DataRow row = table.Rows[rowIndex];
                    bool requiresReview = row.Field<bool?>("review_required") == true &&
                        row.Field<bool?>("review_confirmed") != true;
                    string scanStatus = Convert.ToString(row["scan_status"]);
                    bool isFailed = scanStatus.StartsWith("处理失败", StringComparison.Ordinal);
                    if (requiresReview) review++;
                    if (isFailed) failed++;
                    if (!requiresReview && !isFailed) executable++;
                    string reviewSource = table.Columns.Contains("review_source") ? Convert.ToString(row["review_source"]) : string.Empty;
                    string issue = isFailed ? "-" : requiresReview
                        ? (string.IsNullOrWhiteSpace(reviewSource) ? "图名或图号需要人工核对并确认" : reviewSource + "：请人工核对并确认")
                        : "-";
                    string fullSourceFile = Convert.ToString(row["drawing"]);
                    string displaySourceFile = string.Equals(previousDrawing, fullSourceFile, StringComparison.OrdinalIgnoreCase) ? string.Empty : fullSourceFile;
                    previousDrawing = fullSourceFile;
                    string result = issue == "-" ? scanStatus : scanStatus + "；" + issue;
                    rows.Add(new DrawingRow
                    {
                        Index = rowIndex,
                        SourceFile = displaySourceFile,
                        FullSourceFile = fullSourceFile,
                        Frame = Convert.ToString(row["sheet_sequence"]),
                        No = Convert.ToString(row["图号"]),
                        Name = Convert.ToString(row["图名"]),
                        Type = Convert.ToString(row["图别"]),
                        Scale = Convert.ToString(row["比例"]),
                        Unit = Convert.ToString(row["单位"]),
                        Status = scanStatus,
                        Issue = issue,
                        Result = isFailed ? "处理失败；"+FailureExplanation.FromTechnical(result).Summary : result,
                        TechnicalResult = result,
                        Tone = isFailed ? "red" : requiresReview ? "yellow" : "normal",
                        NeedsReview = requiresReview,
                        ConfirmText = requiresReview ? "未确认" : "已确认"
                    });
                }
            }
            drawingGrid.ItemsSource = rows;
            totalMetricText.Text = rows.Count.ToString();
            recognizedMetricText.Text = executable.ToString();
            reviewMetricText.Text = review.ToString();
            failedMetricText.Text = failed.ToString();
            normalBottomText.Text = executable + " 张";
            reviewBottomText.Text = review + " 张";
            failedBottomText.Text = failed + " 张";
            if (outputPathText != null)
                outputPathText.Text = string.IsNullOrWhiteSpace(core.ShellOutputDirectory)
                    ? "尚未选择目录" : core.ShellOutputDirectory;
            if (inputPathText != null)
                inputPathText.Text = string.IsNullOrWhiteSpace(selectedInputDirectory)
                    ? "尚未选择文件夹" : selectedInputDirectory;
            if (selectedFolderText != null)
            {
                selectedFolderText.Text = string.IsNullOrWhiteSpace(selectedInputDirectory)
                    ? "当前文件夹：尚未选择"
                    : "当前文件夹：" + System.IO.Path.GetFileName(selectedInputDirectory.TrimEnd('\\')) + "    （" + selectedInputDirectory + "）";
            }
            readyTitleText.Text = core.ShellBusy
                ? "正在执行 CAD 任务"
                : rows.Count > 0 ? "本批次准备就绪" : "请选择待处理目录";
            readyDetailText.Text = string.IsNullOrWhiteSpace(core.ShellStatus)
                ? "点击“扫描图纸”开始读取真实 DWG" : core.ShellStatus;
            progressBar.Value = Math.Max(0, Math.Min(100, core.ShellProgress));
            progressPercentText.Text = core.ShellProgress + "%";
            logText.Text = TailLines(core.ShellLog, 16);
            syncingUi = true;
            projectEditors["project"].Text = core.ShellProject;
            projectEditors["number"].Text = core.ShellProjectNumber;
            projectEditors["subitem"].Text = core.ShellSubitem;
            projectEditors["owner"].Text = core.ShellOwner;
            projectEditors["revision"].Text = core.ShellRevision;
            projectEditors["date"].Text = core.ShellDate;
            projectEditors["type"].Text = core.ShellDrawingType;
            projectEditors["scale_unit"].Text = string.IsNullOrWhiteSpace(core.ShellScale) && string.IsNullOrWhiteSpace(core.ShellUnit)
                ? string.Empty : (core.ShellScale + " / " + core.ShellUnit).Trim(' ', '/');
            foreach (string key in personnelEditors.Keys.ToList())
                personnelEditors[key].Text = core.ShellPersonnelName(key);
            foreach (string key in signaturePathTexts.Keys.ToList())
            {
                string path = core.ShellSignaturePath(key);
                signaturePathTexts[key].Text = string.IsNullOrWhiteSpace(path)
                    ? "未选择签字 DWG"
                    : System.IO.Path.GetFileName(path) + "（批量应用）";
            }
            syncingUi = false;
            UpdateStepStates(rows.Count);
        }

        private void UpdateStepStates(int rowCount)
        {
            if (selectStepCard == null) return;
            SetStepEnabled(selectStepCard, true);
            SetStepEnabled(scanStepCard, !string.IsNullOrWhiteSpace(selectedInputDirectory) && !core.ShellBusy);
            SetStepEnabled(
                processStepCard,
                rowCount > 0 &&
                core.ShellUnconfirmedReviewCount == 0 &&
                core.ShellExecutableSheetCount > 0 &&
                !core.ShellBusy);
            SetStepEnabled(outputStepCard, Directory.Exists(core.ShellOutputDirectory));
        }

        private void SetStepEnabled(Border card, bool enabled)
        {
            card.IsEnabled = enabled;
            card.Opacity = enabled ? 1.0 : 0.42;
            card.Cursor = enabled ? Cursors.Hand : Cursors.Arrow;
        }

        private void CommitWpfEditorsToCore()
        {
            drawingGrid.CommitEdit(DataGridEditingUnit.Cell, true);
            drawingGrid.CommitEdit(DataGridEditingUnit.Row, true);
            PersistProjectEditorsToCore();
            foreach (KeyValuePair<string, TextBox> item in personnelEditors)
                core.ShellSetPersonnelName(item.Key, item.Value.Text);
            // Apply batch-wide values first. Per-drawing edits below must win,
            // otherwise a uniform field would overwrite the user's final cell edit.
            core.ShellCommitEditorValues();
            foreach (DrawingRow row in drawingGrid.ItemsSource.Cast<DrawingRow>())
            {
                core.ShellSetRowValue(row.Index, "图号", row.No);
                core.ShellSetRowValue(row.Index, "图名", row.Name);
                core.ShellSetRowValue(row.Index, "图别", row.Type);
                core.ShellSetRowValue(row.Index, "比例", row.Scale);
                core.ShellSetRowValue(row.Index, "单位", row.Unit);
            }
        }

        private void DrawingGridCellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
        {
            if (syncingUi) return;
            Dispatcher.BeginInvoke(new Action(delegate
            {
                DrawingRow row = e.Row.Item as DrawingRow;
                if (row == null) return;
                core.ShellSetRowValue(row.Index, "图号", row.No);
                core.ShellSetRowValue(row.Index, "图名", row.Name);
                core.ShellSetRowValue(row.Index, "图别", row.Type);
                core.ShellSetRowValue(row.Index, "比例", row.Scale);
                core.ShellSetRowValue(row.Index, "单位", row.Unit);
            }), DispatcherPriority.Background);
        }

        private void ConfirmRowClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            DrawingRow row = button == null ? null : button.DataContext as DrawingRow;
            if (row == null || !row.NeedsReview) return;
            try
            {
                drawingGrid.CommitEdit(DataGridEditingUnit.Cell, true);
                // Confirming refreshes every visible editor from the core.
                // Persist the entire WPF form first so personnel/project values
                // typed by the user cannot be replaced by older blank values.
                CommitWpfEditorsToCore();
                core.ShellConfirmRow(row.Index);
                SyncFromCore();
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "无法确认", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private static string TailLines(string value, int count)
        {
            if (string.IsNullOrWhiteSpace(value)) return "等待任务。";
            string[] lines = value.Replace("\r", string.Empty)
                .Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            return string.Join("\n", lines.Skip(Math.Max(0, lines.Length - count)));
        }

        private static string Display(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "—" : value;
        }

        private void PersistProjectEditorsToCore()
        {
            foreach (KeyValuePair<string, TextBox> item in projectEditors)
                PersistProjectEditor(item.Key, item.Value.Text);
        }

        private void PersistProjectEditor(string key, string value)
        {
            string field;
            switch (key)
            {
                case "project": field = "设计项目名"; break;
                case "number": field = "设计项目号"; break;
                case "subitem": field = "子项名称"; break;
                case "owner": field = "建设单位"; break;
                case "revision": field = "版本号"; break;
                case "date": field = "日期"; break;
                case "type": field = "图别"; break;
                case "scale_unit":
                    int separator = value.LastIndexOf('/');
                    bool fractionOnly = System.Text.RegularExpressions.Regex.IsMatch(value,
                        @"^\s*\d+(?:\.\d+)?\s*/\s*\d+(?:\.\d+)?\s*$");
                    core.ShellSetGlobalField("比例", separator < 0 || fractionOnly
                        ? value : value.Substring(0, separator).Trim());
                    core.ShellSetGlobalField("单位", separator < 0 || fractionOnly
                        ? string.Empty : value.Substring(separator + 1).Trim());
                    return;
                default: return;
            }
            core.ShellSetGlobalField(field, value);
        }

        private void ClearProjectInformation()
        {
            if (core.ShellBusy) return;
            core.ShellClearGlobalFields();
            syncingUi = true;
            try { foreach (TextBox editor in projectEditors.Values) editor.Clear(); }
            finally { syncingUi = false; }
        }

        private void ClearPersonnelInformation()
        {
            if (core.ShellBusy) return;
            core.ShellClearPersonnelNames();
            syncingUi = true;
            try { foreach (TextBox editor in personnelEditors.Values) editor.Clear(); }
            finally { syncingUi = false; }
        }

        private Border SectionCard(string title, UIElement content, UIElement action = null)
        {
            var card=Card(new Thickness(0),new CornerRadius(6));var g=new Grid();g.RowDefinitions.Add(new RowDefinition{Height=new GridLength(35)});g.RowDefinitions.Add(new RowDefinition());var h=new Border{BorderBrush=Brush(C("#303A42")),BorderThickness=new Thickness(0,0,0,1),Background=Brush(C("#181F24"))};
            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition());
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(new TextBlock{Text=title,ToolTip=title,TextTrimming=TextTrimming.CharacterEllipsis,Foreground=Brush(Text),FontSize=12,FontWeight=FontWeights.SemiBold,Margin=new Thickness(14,0,8,0),VerticalAlignment=VerticalAlignment.Center});
            if(action!=null){var element=action as FrameworkElement;if(element!=null){element.Margin=new Thickness(0,0,8,0);element.VerticalAlignment=VerticalAlignment.Center;}Grid.SetColumn(action,1);header.Children.Add(action);}
            h.Child=header;g.Children.Add(h);if(content!=null){Grid.SetRow(content,1);g.Children.Add(content);}card.Child=g;return card;
        }
        private Border Card(Thickness margin,CornerRadius radius){return new Border{Margin=margin,CornerRadius=radius,Background=Brush(Panel),BorderBrush=Brush(Border),BorderThickness=new Thickness(1),ClipToBounds=true};}
        private Button OutlineButton(string text,double width,double height){return new Button{Content=text,Width=width,Height=height,Foreground=Brush(Text),Background=Brush(Panel2),BorderBrush=Brush(C("#4A5864")),BorderThickness=new Thickness(1),FontSize=12};}
        private TextBlock T(string text,double size,Color color,FontWeight? weight=null){return new TextBlock{Text=text,FontSize=size,Foreground=Brush(color),FontWeight=weight??FontWeights.Normal,VerticalAlignment=VerticalAlignment.Center};}
        private static SolidColorBrush Brush(Color color){var b=new SolidColorBrush(color);b.Freeze();return b;}
        private static Color C(string hex){return (Color)ColorConverter.ConvertFromString(hex);}
    }
}
