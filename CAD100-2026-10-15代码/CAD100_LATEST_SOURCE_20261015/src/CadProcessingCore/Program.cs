using System;
using System.Collections.Generic;
using System.Data;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("出图100%")]
[assembly: AssemblyProduct("出图100%")]
[assembly: AssemblyDescription("本地便携式 CAD 图框替换与图签更新工具，支持 AutoCAD 2020 及以上版本")]
[assembly: AssemblyVersion("1.9.15.0")]
[assembly: AssemblyFileVersion("1.9.15.0")]

namespace CadFrameReplacer
{
    public enum OperationMode
    {
        ReplaceFrame,
        UpdateTitle
    }

    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += delegate(object sender, System.Threading.ThreadExceptionEventArgs e)
            {
                MessageBox.Show(e.Exception.ToString(), "程序错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            };
            // The public workflow is deliberately unified.  ReplaceFrame is
            // now an automatic strategy: matched frames are replaced, while
            // an unpaired local editable title is updated in place.
            Application.Run(new MainForm(OperationMode.ReplaceFrame));
        }
    }

    internal sealed class ModeSelectionForm : Form
    {
        public OperationMode SelectedMode { get; private set; }

        public ModeSelectionForm()
        {
            Text = "CAD图框图签助手";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ClientSize = new Size(640, 300);
            Font = new Font("Microsoft YaHei UI", 10F);
            Icon = SystemIcons.Application;

            var title = new Label
            {
                Text = "请选择本次工作模式",
                Font = new Font("Microsoft YaHei UI", 19F, FontStyle.Bold),
                ForeColor = Color.FromArgb(27, 67, 105),
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleCenter,
                Bounds = new Rectangle(20, 18, 600, 48)
            };
            Controls.Add(title);

            var replace = CreateModeButton(
                "替换图框",
                "识别旧图框尺寸，换成内置的同规格新图框，并更新图签。",
                35
            );
            replace.Click += delegate
            {
                SelectedMode = OperationMode.ReplaceFrame;
                DialogResult = DialogResult.OK;
                Close();
            };
            Controls.Add(replace);

            var update = CreateModeButton(
                "仅更新图签",
                "修改本地可编辑图签。\r\nXREF 格式容易失败，可以使用换图框助手解决。",
                335
            );
            update.Click += delegate
            {
                SelectedMode = OperationMode.UpdateTitle;
                DialogResult = DialogResult.OK;
                Close();
            };
            Controls.Add(update);

            var note = new Label
            {
                Text = "两种模式都不会覆盖原 DWG，成果写入新的输出目录。",
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleCenter,
                ForeColor = Color.FromArgb(90, 90, 90),
                Bounds = new Rectangle(20, 258, 600, 28)
            };
            Controls.Add(note);
        }

        private static Button CreateModeButton(string title, string detail, int left)
        {
            var button = new Button
            {
                Bounds = new Rectangle(left, 88, 270, 150),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.White,
                ForeColor = Color.FromArgb(35, 65, 90),
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Microsoft YaHei UI", 12F, FontStyle.Bold),
                Text = title + "\r\n\r\n" + detail
            };
            button.FlatAppearance.BorderColor = Color.FromArgb(120, 155, 185);
            button.FlatAppearance.BorderSize = 2;
            return button;
        }
    }

    public sealed class MainForm : Form
    {
        private enum AccentState
        {
            Disabled = 0,
            EnableBlurBehind = 3,
            EnableAcrylicBlurBehind = 4
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct AccentPolicy
        {
            public AccentState AccentState;
            public int AccentFlags;
            public int GradientColor;
            public int AnimationId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WindowCompositionAttributeData
        {
            public int Attribute;
            public IntPtr Data;
            public int SizeOfData;
        }

        [DllImport("user32.dll")]
        private static extern int SetWindowCompositionAttribute(
            IntPtr hwnd,
            ref WindowCompositionAttributeData data);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(
            IntPtr hwnd,
            int attribute,
            ref int value,
            int valueSize);

        private static readonly Color ThemeWindow = Color.FromArgb(25, 27, 30);
        private static readonly Color ThemePanel = Color.FromArgb(34, 37, 41);
        private static readonly Color ThemePanelAlt = Color.FromArgb(42, 45, 50);
        private static readonly Color ThemeInput = Color.FromArgb(28, 30, 34);
        private static readonly Color ThemeBorder = Color.FromArgb(78, 83, 90);
        private static readonly Color ThemeText = Color.FromArgb(226, 229, 233);
        private static readonly Color ThemeMuted = Color.FromArgb(162, 168, 176);
        private static readonly Color ThemeAccent = Color.FromArgb(105, 128, 153);
        private const string ClearSignatureSentinel = "__CFR_CLEAR_SIGNATURE__";

        private sealed class VerificationSummary
        {
            public int PassedMainFiles { get; set; }
            public int FailedMainFiles { get; set; }
            public List<string> FailedFiles { get; private set; }
            public HashSet<string> FailedMainFileNames { get; private set; }
            public HashSet<string> PassedMainFileNames { get; private set; }
            public HashSet<string> DependencyFileNames { get; private set; }
            public Dictionary<string, string> FailureReasons { get; private set; }

            public VerificationSummary()
            {
                FailedFiles = new List<string>();
                FailedMainFileNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                PassedMainFileNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                DependencyFileNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                FailureReasons = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            }
        }

        private sealed class SignatureFieldDefinition
        {
            public string DisplayName { get; private set; }
            public string TextField { get; private set; }
            public string AnchorField { get; private set; }
            public string SignatureColumn { get; private set; }

            public SignatureFieldDefinition(
                string displayName,
                string textField,
                string anchorField,
                string signatureColumn)
            {
                DisplayName = displayName;
                TextField = textField;
                AnchorField = anchorField;
                SignatureColumn = signatureColumn;
            }

            public override string ToString()
            {
                return DisplayName;
            }
        }

        private static readonly string[] EditableTags = new[]
        {
            "图号", "版本号", "图别", "设计项目号",
            "N审定_T5_H3", "N审核_T5_H3", "N校对_T5_H3", "N设计_T5_H3",
            "N专业负责人（副）_T5_H3", "N专业负责人_T5_H3",
            "N执行设总_T5_H3", "N设计总负责人_T5_H3",
            "比例", "单位", "图名", "建设单位", "设计项目名", "子项名称",
            "N执行设总二_T5_H3",
            "N设计总负责人_T6_H6", "N执行设总_T6_H6",
            "N执行设总二_T6_H6", "N专业负责人_T6_H6",
            "N专业负责人（副）_T6_H8", "N设计_T6_H6",
            "N校对_T6_H6", "N审核_T6_H6", "N审定_T6_H6",
            "N专业负责人（副）二_T5_H3", "N专业负责人（副）二_T6_H8",
            "日期", "是否会签", "图纸类别"
        };
        private static readonly string[] ProxyTitleHandleColumns = new[]
        {
            "__proxy_drawing_name_handle",
            "__proxy_drawing_number_handle"
        };
        private static readonly SignatureFieldDefinition[] SignatureFields = new[]
        {
            new SignatureFieldDefinition(
                "设计总负责人（一）",
                "N设计总负责人_T5_H3",
                "N设计总负责人_T6_H6",
                "签字图块_设计总负责人"),
            new SignatureFieldDefinition(
                "设计总负责人（二）",
                "N执行设总_T5_H3",
                "N执行设总_T6_H6",
                "签字图块_执行设总"),
            new SignatureFieldDefinition(
                "设计总负责人（三）",
                "N执行设总二_T5_H3",
                "N执行设总二_T6_H6",
                "签字图块_执行设总二"),
            new SignatureFieldDefinition(
                "专业负责人（一）",
                "N专业负责人_T5_H3",
                "N专业负责人_T6_H6",
                "签字图块_专业负责人"),
            new SignatureFieldDefinition(
                "专业负责人（二）",
                "N专业负责人（副）_T5_H3",
                "N专业负责人（副）_T6_H8",
                "签字图块_专业负责人副"),
            new SignatureFieldDefinition(
                "专业负责人（三）",
                "N专业负责人（副）二_T5_H3",
                "N专业负责人（副）二_T6_H8",
                "签字图块_专业负责人副二"),
            new SignatureFieldDefinition("设计", "N设计_T5_H3", "N设计_T6_H6", "签字图块_设计"),
            new SignatureFieldDefinition("校对", "N校对_T5_H3", "N校对_T6_H6", "签字图块_校对"),
            new SignatureFieldDefinition("审核", "N审核_T5_H3", "N审核_T6_H6", "签字图块_审核"),
            new SignatureFieldDefinition("审定", "N审定_T5_H3", "N审定_T6_H6", "签字图块_审定")
        };
        private static readonly string[] UiFieldOrder = new[]
        {
            "图号", "版本号", "图别", "设计项目号",
            "N审定_T5_H3", "N审核_T5_H3", "N校对_T5_H3", "N设计_T5_H3",
            "N专业负责人（副）二_T5_H3", "N专业负责人（副）_T5_H3",
            "N专业负责人_T5_H3", "N执行设总二_T5_H3",
            "N执行设总_T5_H3", "N设计总负责人_T5_H3",
            "比例", "单位", "图名", "建设单位", "设计项目名", "子项名称",
            "日期"
        };
        private static readonly Dictionary<string, string> FriendlyFieldNames =
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                { "图号", "图号（DWG NO.）" },
                { "图名", "图名（DWG NAME）" },
                { "N审定_T5_H3", "审定姓名" },
                { "N审核_T5_H3", "审核姓名" },
                { "N校对_T5_H3", "校对姓名" },
                { "N设计_T5_H3", "设计姓名" },
                { "N专业负责人_T5_H3", "专业负责人（一）姓名" },
                { "N专业负责人（副）_T5_H3", "专业负责人（二）姓名" },
                { "N专业负责人（副）二_T5_H3", "专业负责人（三）姓名" },
                { "N设计总负责人_T5_H3", "设计总负责人（一）姓名" },
                { "N执行设总_T5_H3", "设计总负责人（二）姓名" },
                { "N执行设总二_T5_H3", "设计总负责人（三）姓名" }
            };
        private static readonly Regex ProcessProgressPattern =
            new Regex(@"^\[(\d+)/(\d+)\]", RegexOptions.Compiled);

        private sealed class BatchFieldChoice
        {
            public string DisplayName { get; private set; }
            public string Field { get; private set; }

            public BatchFieldChoice(string displayName, string field)
            {
                DisplayName = displayName;
                Field = field;
            }

            public override string ToString()
            {
                return DisplayName;
            }
        }

        private readonly string appRoot;
        private readonly string scriptsRoot;
        private string sessionRoot;
        private OperationMode operationMode;
        private bool shellHosted;
        private readonly TextBox inputBox = new TextBox();
        private readonly TextBox outputBox = new TextBox();
        private readonly TextBox coreBox = new TextBox();
        private readonly TextBox ownerBox = new TextBox();
        private readonly TextBox projectBox = new TextBox();
        private readonly TextBox dateBox = new TextBox();
        private readonly TextBox numberBox = new TextBox();
        private readonly TextBox subitemBox = new TextBox();
        private readonly TextBox drawingTypeBox = new TextBox();
        private readonly TextBox scaleBox = new TextBox();
        private readonly TextBox unitBox = new TextBox();
        private readonly TextBox revisionBox = new TextBox();
        private readonly DataGridView grid = new DataGridView();
        private readonly ComboBox batchFieldBox = new ComboBox();
        private readonly TextBox batchValueBox = new TextBox();
        private readonly Dictionary<string, TextBox> personnelNameBoxes =
            new Dictionary<string, TextBox>(StringComparer.Ordinal);
        private readonly Dictionary<string, TextBox> personnelSignatureBoxes =
            new Dictionary<string, TextBox>(StringComparer.Ordinal);
        private readonly HashSet<string> explicitlyClearedSignatures =
            new HashSet<string>(StringComparer.Ordinal);
        private readonly TextBox logBox = new TextBox();
        private readonly Label statusLabel = new Label();
        private readonly ProgressBar progressBar = new ProgressBar();
        private readonly Label progressLabel = new Label();
        private readonly Label titleLabel = new Label();
        private readonly Button scanButton = new Button();
        private readonly Button applyButton = new Button();
        private readonly Button openButton = new Button();
        private readonly Button nextBatchButton = new Button();
        private readonly Button reviewNextButton = new Button();
        private readonly Button confirmReviewButton = new Button();
        private DataTable sheetTable;
        private bool busy;
        private bool batchCompleted;

        public MainForm(OperationMode mode)
        {
            operationMode = mode;
            appRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            scriptsRoot = Path.Combine(appRoot, "engine", "scripts");
            sessionRoot = CreateSessionRoot();

            Text = "出图100% · CAD图框图签自动处理与质量验收（v1.6.1）";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(1280, 760);
            Size = new Size(1664, 946);
            Font = new Font("Microsoft YaHei UI", 9F);
            Icon = SystemIcons.Application;

            BuildInterface();
            InitializeTable();
            ApplyDarkTheme();
            coreBox.Text = DetectCoreConsole();
            dateBox.Text = string.Empty;
            FormClosing += OnFormClosing;
            Shown += delegate { EnableDesktopAcrylic(); };
        }

        private void BuildInterface()
        {
            var shell = new TableLayoutPanel();
            shell.Dock = DockStyle.Fill;
            shell.Padding = new Padding(0);
            shell.ColumnCount = 2;
            shell.RowCount = 1;
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 18.5F));
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 81.5F));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            Controls.Add(shell);

            shell.Controls.Add(BuildSidebar(), 0, 0);

            var root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.Padding = new Padding(18, 12, 18, 14);
            root.ColumnCount = 1;
            root.RowCount = 8;
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 104));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 222));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 142));
            shell.Controls.Add(root, 1, 0);

            titleLabel.Dock = DockStyle.Fill;
            titleLabel.Text = operationMode == OperationMode.ReplaceFrame
                ? "出图100% · 图框图签自动处理"
                : "出图100% · 更新图签";
            titleLabel.Font = new Font("Microsoft YaHei UI", 19F, FontStyle.Bold);
            titleLabel.ForeColor = ThemeText;
            titleLabel.TextAlign = ContentAlignment.MiddleLeft;
            root.Controls.Add(titleLabel, 0, 0);

            var pathPanel = new TableLayoutPanel();
            pathPanel.Dock = DockStyle.Fill;
            pathPanel.ColumnCount = 3;
            pathPanel.RowCount = 3;
            pathPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
            pathPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            pathPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
            AddPathRow(pathPanel, 0, "待处理目录", inputBox, "浏览…", BrowseInput);
            AddPathRow(pathPanel, 1, "输出目录", outputBox, "浏览…", BrowseOutput);
            AddPathRow(pathPanel, 2, "AutoCAD Core", coreBox, "选择…", BrowseCore);
            root.Controls.Add(pathPanel, 0, 1);

            var fields = new TableLayoutPanel();
            fields.Dock = DockStyle.Fill;
            fields.ColumnCount = 10;
            fields.RowCount = 3;
            for (int i = 0; i < 5; i++)
            {
                fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, i == 0 ? 84 : 72));
                fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20));
            }
            AddField(fields, 0, 0, "建设单位", ownerBox);
            AddField(fields, 2, 0, "设计项目名", projectBox);
            AddField(fields, 4, 0, "子项名称", subitemBox);
            AddField(fields, 6, 0, "项目号", numberBox);
            AddField(fields, 8, 0, "日期", dateBox);
            AddField(fields, 0, 1, "图别", drawingTypeBox);
            AddField(fields, 2, 1, "比例", scaleBox);
            AddField(fields, 4, 1, "单位", unitBox);
            AddField(fields, 6, 1, "版本号", revisionBox);
            var hint = new Label();
            hint.Text = "本批次统一信息：留空＝保留原值；填写＝应用到全部。黄色＝待人工核对；红色＝处理失败，请手动处理。";
            hint.ForeColor = operationMode == OperationMode.UpdateTitle
                ? Color.FromArgb(236, 159, 150)
                : ThemeMuted;
            hint.Font = operationMode == OperationMode.UpdateTitle
                ? new Font("Microsoft YaHei UI", 10F, FontStyle.Bold)
                : Font;
            hint.Dock = DockStyle.Fill;
            hint.TextAlign = ContentAlignment.MiddleLeft;
            fields.Controls.Add(hint, 0, 2);
            fields.SetColumnSpan(hint, 10);
            root.Controls.Add(fields, 0, 2);

            var personnelGroup = BuildPersonnelPanel();
            root.Controls.Add(personnelGroup, 0, 3);

            var actions = new FlowLayoutPanel();
            actions.Dock = DockStyle.Fill;
            actions.FlowDirection = FlowDirection.LeftToRight;
            actions.WrapContents = false;
            scanButton.Text = "① 扫描图纸";
            applyButton.Text = "② 开始处理";
            openButton.Text = "打开输出目录";
            nextBatchButton.Text = "开始下一批…";
            reviewNextButton.Text = "跳到待核对";
            confirmReviewButton.Text = "确认当前项";
            foreach (var button in new[] { scanButton, applyButton, reviewNextButton,
                confirmReviewButton, openButton, nextBatchButton })
            {
                button.AutoSize = true;
                button.Height = 34;
                button.Margin = new Padding(0, 5, 10, 5);
                actions.Controls.Add(button);
            }
            foreach (var primaryButton in new[] { scanButton, applyButton })
            {
                primaryButton.AutoSize = false;
                primaryButton.Size = new Size(178, 46);
                primaryButton.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
                primaryButton.ForeColor = Color.White;
                primaryButton.BackColor = primaryButton == scanButton
                    ? Color.FromArgb(76, 84, 94)
                    : ThemeAccent;
                primaryButton.FlatStyle = FlatStyle.Flat;
                primaryButton.FlatAppearance.BorderSize = 0;
                primaryButton.Margin = new Padding(0, 4, 12, 4);
            }
            scanButton.Click += async delegate { await ScanAsync(); };
            applyButton.Click += async delegate { await ApplyAsync(); };
            openButton.Click += delegate { OpenOutput(); };
            nextBatchButton.Click += delegate { StartNextBatch(); };
            reviewNextButton.Click += delegate { JumpToNextReviewRow(); };
            confirmReviewButton.Click += delegate { ConfirmCurrentReviewRow(); };
            actions.Controls.Add(new Label
            {
                Text = "进度",
                AutoSize = true,
                TextAlign = ContentAlignment.MiddleLeft,
                Margin = new Padding(8, 13, 5, 0)
            });
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.Value = 0;
            progressBar.Style = ProgressBarStyle.Continuous;
            progressBar.Width = 245;
            progressBar.Height = 22;
            progressBar.Margin = new Padding(0, 10, 8, 0);
            actions.Controls.Add(progressBar);
            progressLabel.Text = "0%  等待任务";
            progressLabel.AutoSize = false;
            progressLabel.Width = 265;
            progressLabel.Height = 30;
            progressLabel.TextAlign = ContentAlignment.MiddleLeft;
            progressLabel.ForeColor = ThemeMuted;
            progressLabel.Margin = new Padding(0, 7, 0, 0);
            actions.Controls.Add(progressLabel);
            root.Controls.Add(actions, 0, 4);

            var batch = new FlowLayoutPanel();
            batch.Dock = DockStyle.Fill;
            batch.WrapContents = false;
            batch.Controls.Add(new Label
            {
                Text = "批量文字：",
                AutoSize = true,
                TextAlign = ContentAlignment.MiddleLeft,
                Margin = new Padding(0, 12, 4, 0)
            });
            batchFieldBox.DropDownStyle = ComboBoxStyle.DropDownList;
            batchFieldBox.Width = 260;
            batchFieldBox.Margin = new Padding(0, 7, 8, 0);
            batchFieldBox.Items.AddRange(BuildBatchFieldChoices().Cast<object>().ToArray());
            if (batchFieldBox.Items.Count > 0) batchFieldBox.SelectedIndex = 0;
            batch.Controls.Add(batchFieldBox);
            batchValueBox.Width = 360;
            batchValueBox.Margin = new Padding(0, 7, 8, 0);
            batch.Controls.Add(batchValueBox);
            var applyAll = new Button { Text = "应用到全部图签", AutoSize = true, Height = 30, Margin = new Padding(0, 5, 8, 0) };
            applyAll.Click += delegate { ApplyBatchValue(); };
            batch.Controls.Add(applyAll);
            var syncGlobals = new Button { Text = "应用顶部统一信息", AutoSize = true, Height = 30, Margin = new Padding(0, 5, 8, 0) };
            syncGlobals.Click += delegate { SyncTopFieldsToAll(true); };
            batch.Controls.Add(syncGlobals);
            statusLabel.AutoSize = true;
            statusLabel.ForeColor = Color.FromArgb(170, 203, 188);
            statusLabel.Margin = new Padding(18, 12, 0, 0);
            batch.Controls.Add(statusLabel);
            root.Controls.Add(batch, 0, 5);

            grid.Dock = DockStyle.Fill;
            grid.AllowUserToAddRows = false;
            grid.AllowUserToDeleteRows = false;
            grid.AutoGenerateColumns = true;
            grid.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None;
            grid.RowHeadersVisible = false;
            grid.SelectionMode = DataGridViewSelectionMode.CellSelect;
            grid.MultiSelect = true;
            grid.ClipboardCopyMode = DataGridViewClipboardCopyMode.EnableWithoutHeaderText;
            grid.BackgroundColor = ThemePanel;
            grid.BorderStyle = BorderStyle.None;
            root.Controls.Add(grid, 0, 6);

            logBox.Dock = DockStyle.Fill;
            logBox.Multiline = true;
            logBox.ReadOnly = true;
            logBox.ScrollBars = ScrollBars.Both;
            logBox.WordWrap = false;
            logBox.Font = new Font("Consolas", 9F);
            logBox.BackColor = ThemeInput;
            root.Controls.Add(logBox, 0, 7);
        }

        private Control BuildSidebar()
        {
            var sidebar = new TableLayoutPanel();
            sidebar.Dock = DockStyle.Fill;
            sidebar.Padding = new Padding(20, 24, 16, 20);
            sidebar.ColumnCount = 1;
            sidebar.RowCount = 9;
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 70));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 96));
            // WinForms child controls do not support arbitrary alpha values.
            // Desktop translucency is provided by the top-level acrylic window;
            // the sidebar stays opaque to preserve text contrast.
            sidebar.BackColor = Color.FromArgb(31, 34, 38);

            var brand = new Label
            {
                Text = "出图100%\r\nCAD图框图签自动处理",
                Dock = DockStyle.Fill,
                Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold),
                ForeColor = ThemeText,
                TextAlign = ContentAlignment.TopLeft
            };
            sidebar.Controls.Add(brand, 0, 0);

            sidebar.Controls.Add(new Label
            {
                Text = "图框图签批次处理",
                Dock = DockStyle.Fill,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold),
                ForeColor = ThemeMuted,
                TextAlign = ContentAlignment.MiddleLeft
            }, 0, 1);

            string[] steps =
            {
                "01  选择图纸目录",
                "02  扫描并人工核对",
                "03  开始批量处理",
                "04  逐文件质量验收"
            };
            for (int index = 0; index < steps.Length; index++)
            {
                sidebar.Controls.Add(new Label
                {
                    Text = steps[index],
                    Dock = DockStyle.Fill,
                    Padding = new Padding(12, 0, 0, 0),
                    BackColor = index == 0 ? Color.FromArgb(72, 77, 84) : Color.Transparent,
                    ForeColor = index == 0 ? Color.White : ThemeText,
                    Font = new Font("Microsoft YaHei UI", 9.5F,
                        index == 0 ? FontStyle.Bold : FontStyle.Regular),
                    TextAlign = ContentAlignment.MiddleLeft,
                    Margin = new Padding(0, 3, 0, 3)
                }, 0, index + 2);
            }

            var divider = new Label
            {
                Dock = DockStyle.Top,
                Height = 1,
                BackColor = ThemeBorder,
                Margin = new Padding(0, 12, 0, 0)
            };
            sidebar.Controls.Add(divider, 0, 6);

            sidebar.Controls.Add(new Label
            {
                Text = "黄色  待人工核对\r\n红色  处理失败，需手动处理\r\n成果永不覆盖原始 DWG",
                Dock = DockStyle.Fill,
                ForeColor = ThemeMuted,
                Font = new Font("Microsoft YaHei UI", 8.5F),
                TextAlign = ContentAlignment.BottomLeft
            }, 0, 8);
            return sidebar;
        }

        private void ApplyDarkTheme()
        {
            BackColor = ThemeWindow;
            ForeColor = ThemeText;
            ApplyDarkThemeToChildren(this);

            titleLabel.ForeColor = ThemeText;
            logBox.BackColor = ThemeInput;
            logBox.ForeColor = Color.FromArgb(190, 204, 216);

            grid.EnableHeadersVisualStyles = false;
            grid.BackgroundColor = ThemePanel;
            grid.GridColor = ThemeBorder;
            grid.BorderStyle = BorderStyle.None;
            grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single;
            grid.ColumnHeadersDefaultCellStyle.BackColor = ThemePanelAlt;
            grid.ColumnHeadersDefaultCellStyle.ForeColor = ThemeText;
            grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = ThemePanelAlt;
            grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = ThemeText;
            grid.DefaultCellStyle.BackColor = ThemeInput;
            grid.DefaultCellStyle.ForeColor = ThemeText;
            grid.DefaultCellStyle.SelectionBackColor = ThemeAccent;
            grid.DefaultCellStyle.SelectionForeColor = Color.White;
            grid.AlternatingRowsDefaultCellStyle.BackColor = Color.FromArgb(32, 35, 39);

            StylePrimaryButton(scanButton, Color.FromArgb(76, 84, 94));
            StylePrimaryButton(applyButton, ThemeAccent);
            ApplyReviewRowStyles();
        }

        private static void ApplyDarkThemeToChildren(Control parent)
        {
            foreach (Control control in parent.Controls)
            {
                if (control is TextBox)
                {
                    control.BackColor = ThemeInput;
                    control.ForeColor = ThemeText;
                    ((TextBox)control).BorderStyle = BorderStyle.FixedSingle;
                }
                else if (control is ComboBox)
                {
                    control.BackColor = ThemeInput;
                    control.ForeColor = ThemeText;
                    ((ComboBox)control).FlatStyle = FlatStyle.Flat;
                }
                else if (control is Button)
                {
                    var button = (Button)control;
                    button.BackColor = ThemePanelAlt;
                    button.ForeColor = ThemeText;
                    button.FlatStyle = FlatStyle.Flat;
                    button.FlatAppearance.BorderColor = ThemeBorder;
                    button.FlatAppearance.BorderSize = 1;
                }
                else if (control is Label)
                {
                    if (control.ForeColor == SystemColors.ControlText || control.ForeColor == Color.Black)
                        control.ForeColor = ThemeText;
                }
                else if (control is GroupBox)
                {
                    control.ForeColor = ThemeText;
                    control.BackColor = Color.Transparent;
                }
                else if (control is TableLayoutPanel || control is FlowLayoutPanel || control is Panel)
                {
                    if (control.BackColor == SystemColors.Control)
                        control.BackColor = Color.Transparent;
                }
                ApplyDarkThemeToChildren(control);
            }
        }

        private static void StylePrimaryButton(Button button, Color color)
        {
            button.BackColor = color;
            button.ForeColor = Color.White;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = ControlPaint.Light(color, 0.08F);
            button.FlatAppearance.MouseDownBackColor = ControlPaint.Dark(color, 0.08F);
        }

        private void EnableDesktopAcrylic()
        {
            EnableDarkTitleBar();
            bool enabled = TrySetWindowAccent(AccentState.EnableAcrylicBlurBehind, 236);
            if (!enabled)
                enabled = TrySetWindowAccent(AccentState.EnableBlurBehind, 240);
            // SetWindowCompositionAttribute alone only blurs the top-level
            // backdrop. WinForms child controls remain opaque. A restrained
            // whole-window opacity is therefore required for desktop colour
            // to remain visibly present through the complete interface.
            Opacity = 0.97D;
        }

        private void EnableDarkTitleBar()
        {
            try
            {
                int enabled = 1;
                int result = DwmSetWindowAttribute(Handle, 20, ref enabled, sizeof(int));
                if (result != 0)
                    DwmSetWindowAttribute(Handle, 19, ref enabled, sizeof(int));
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            catch (ExternalException) { }
        }

        private bool TrySetWindowAccent(AccentState state, byte alpha)
        {
            IntPtr policyPointer = IntPtr.Zero;
            try
            {
                var policy = new AccentPolicy
                {
                    AccentState = state,
                    AccentFlags = 2,
                    GradientColor = (alpha << 24) | (30 << 16) | (28 << 8) | 26,
                    AnimationId = 0
                };
                int policySize = Marshal.SizeOf(policy);
                policyPointer = Marshal.AllocHGlobal(policySize);
                Marshal.StructureToPtr(policy, policyPointer, false);
                var data = new WindowCompositionAttributeData
                {
                    Attribute = 19,
                    Data = policyPointer,
                    SizeOfData = policySize
                };
                return SetWindowCompositionAttribute(Handle, ref data) != 0;
            }
            catch (DllNotFoundException) { return false; }
            catch (EntryPointNotFoundException) { return false; }
            catch (ExternalException) { return false; }
            finally
            {
                if (policyPointer != IntPtr.Zero) Marshal.FreeHGlobal(policyPointer);
            }
        }

        private Control BuildPersonnelPanel()
        {
            var group = new GroupBox();
            group.Dock = DockStyle.Fill;
            group.Text = "人员姓名与签字 DWG（留空=保留原值；姓名填[清空]=删除姓名；签字点“清空”=删除签字；选择DWG=替换）";
            group.Padding = new Padding(8, 20, 8, 7);

            var halves = new TableLayoutPanel();
            halves.Dock = DockStyle.Fill;
            halves.ColumnCount = 2;
            halves.RowCount = 1;
            halves.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            halves.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            group.Controls.Add(halves);

            for (int halfIndex = 0; halfIndex < 2; halfIndex++)
            {
                var panel = new TableLayoutPanel();
                panel.Dock = DockStyle.Fill;
                panel.ColumnCount = 5;
                panel.RowCount = 6;
                panel.Margin = halfIndex == 0
                    ? new Padding(0, 0, 8, 0)
                    : new Padding(8, 0, 0, 0);
                panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 155));
                panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
                panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 76));
                panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 52));
                panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
                for (int rowIndex = 1; rowIndex < 6; rowIndex++)
                {
                    panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
                }

                AddPersonnelHeader(panel);
                for (int rowIndex = 0; rowIndex < 5; rowIndex++)
                {
                    int signatureIndex = halfIndex * 5 + rowIndex;
                    AddPersonnelRow(panel, rowIndex + 1, SignatureFields[signatureIndex]);
                }
                halves.Controls.Add(panel, halfIndex, 0);
            }
            return group;
        }

        private static void AddPersonnelHeader(TableLayoutPanel panel)
        {
            string[] labels = { "岗位", "姓名", "签字 DWG", "", "" };
            for (int i = 0; i < labels.Length; i++)
            {
                panel.Controls.Add(
                    new Label
                    {
                        Text = labels[i],
                        Dock = DockStyle.Fill,
                        TextAlign = ContentAlignment.MiddleLeft,
                        ForeColor = Color.FromArgb(90, 90, 90)
                    },
                    i,
                    0
                );
            }
        }

        private void AddPersonnelRow(
            TableLayoutPanel panel,
            int rowIndex,
            SignatureFieldDefinition signature)
        {
            var roleLabel = new Label
            {
                Text = signature.DisplayName,
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleRight,
                Padding = new Padding(0, 0, 6, 0)
            };
            var nameBox = new TextBox
            {
                Dock = DockStyle.Fill,
                Margin = new Padding(0, 2, 6, 2)
            };
            var signatureBox = new TextBox
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                Margin = new Padding(0, 2, 6, 2)
            };
            var browseButton = new Button
            {
                Text = "选择…",
                Dock = DockStyle.Fill,
                Margin = new Padding(0, 1, 5, 1)
            };
            var clearButton = new Button
            {
                Text = "清空",
                Dock = DockStyle.Fill,
                Margin = new Padding(0, 1, 0, 1)
            };
            browseButton.Click += delegate { BrowseSignatureForRole(signature); };
            clearButton.Click += delegate { ClearPersonnelSignature(signature); };

            personnelNameBoxes[signature.TextField] = nameBox;
            personnelSignatureBoxes[signature.SignatureColumn] = signatureBox;
            panel.Controls.Add(roleLabel, 0, rowIndex);
            panel.Controls.Add(nameBox, 1, rowIndex);
            panel.Controls.Add(signatureBox, 2, rowIndex);
            panel.Controls.Add(browseButton, 3, rowIndex);
            panel.Controls.Add(clearButton, 4, rowIndex);
        }

        private void AddPathRow(TableLayoutPanel panel, int row, string labelText, TextBox box, string buttonText, EventHandler handler)
        {
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            var label = new Label { Text = labelText, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight };
            box.Dock = DockStyle.Fill;
            box.Margin = new Padding(4, 5, 8, 3);
            var button = new Button { Text = buttonText, Dock = DockStyle.Fill, Margin = new Padding(0, 3, 0, 3) };
            button.Click += handler;
            panel.Controls.Add(label, 0, row);
            panel.Controls.Add(box, 1, row);
            panel.Controls.Add(button, 2, row);
        }

        private void AddField(TableLayoutPanel panel, int column, int row, string labelText, TextBox box)
        {
            var label = new Label { Text = labelText, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight };
            box.Dock = DockStyle.Fill;
            box.Margin = new Padding(3, 5, 12, 4);
            panel.Controls.Add(label, column, row);
            panel.Controls.Add(box, column + 1, row);
        }

        private void InitializeTable()
        {
            sheetTable = new DataTable("图签字段");
            sheetTable.Columns.Add("drawing", typeof(string));
            sheetTable.Columns.Add("source_display", typeof(string));
            sheetTable.Columns.Add("sheet_sequence", typeof(string));
            sheetTable.Columns.Add("layout", typeof(string));
            sheetTable.Columns.Add("scan_status", typeof(string));
            sheetTable.Columns.Add("review_required", typeof(bool));
            sheetTable.Columns.Add("review_confirmed", typeof(bool));
            sheetTable.Columns.Add("review_source", typeof(string));
            sheetTable.Columns.Add("title_only", typeof(bool));
            sheetTable.Columns.Add("old_frame_handle", typeof(string));
            foreach (string column in ProxyTitleHandleColumns)
                sheetTable.Columns.Add(column, typeof(string));
            foreach (string tag in EditableTags) sheetTable.Columns.Add(tag, typeof(string));
            foreach (SignatureFieldDefinition signature in SignatureFields)
            {
                sheetTable.Columns.Add(signature.SignatureColumn, typeof(string));
            }
            grid.DataSource = sheetTable;
            ConfigureGridColumns();
        }

        private void ConfigureGridColumns()
        {
            if (grid.Columns.Count == 0) return;
            grid.Columns["drawing"].HeaderText = "源 DWG（内部）";
            grid.Columns["drawing"].ReadOnly = true;
            grid.Columns["drawing"].Visible = false;
            grid.Columns["source_display"].HeaderText = "源 DWG 文件名";
            grid.Columns["source_display"].ReadOnly = true;
            grid.Columns["source_display"].Frozen = true;
            grid.Columns["source_display"].Width = 260;
            grid.Columns["source_display"].DisplayIndex = 0;
            grid.Columns["source_display"].SortMode = DataGridViewColumnSortMode.NotSortable;
            grid.Columns["sheet_sequence"].HeaderText = "图签";
            grid.Columns["sheet_sequence"].ReadOnly = true;
            grid.Columns["sheet_sequence"].Frozen = true;
            grid.Columns["sheet_sequence"].Width = 66;
            grid.Columns["sheet_sequence"].DisplayIndex = 1;
            grid.Columns["sheet_sequence"].SortMode = DataGridViewColumnSortMode.NotSortable;
            grid.Columns["layout"].HeaderText = "空间/布局";
            grid.Columns["layout"].ReadOnly = true;
            grid.Columns["layout"].Visible = false;
            grid.Columns["scan_status"].HeaderText = "当前模式处理状态";
            grid.Columns["scan_status"].ReadOnly = true;
            grid.Columns["scan_status"].Frozen = true;
            grid.Columns["scan_status"].Width = 142;
            grid.Columns["scan_status"].DisplayIndex = 2;
            grid.Columns["scan_status"].SortMode = DataGridViewColumnSortMode.NotSortable;
            foreach (string reviewColumn in new[] {
                "review_required", "review_confirmed", "review_source", "title_only" })
            {
                grid.Columns[reviewColumn].ReadOnly = true;
                grid.Columns[reviewColumn].Visible = false;
            }
            grid.Columns["old_frame_handle"].HeaderText = "原图框句柄";
            grid.Columns["old_frame_handle"].ReadOnly = true;
            grid.Columns["old_frame_handle"].Frozen = false;
            grid.Columns["old_frame_handle"].Visible = false;
            foreach (string columnName in ProxyTitleHandleColumns)
            {
                grid.Columns[columnName].ReadOnly = true;
                grid.Columns[columnName].Visible = false;
            }
            foreach (string tag in EditableTags)
            {
                var column = grid.Columns[tag];
                if (column == null) continue;
                column.Visible = false;
                column.HeaderText = GetFriendlyFieldName(tag);
                column.ToolTipText = "新图签属性标签：" + tag;
                column.Width = GetColumnWidth(tag);
                column.SortMode = DataGridViewColumnSortMode.NotSortable;
            }
            foreach (SignatureFieldDefinition signature in SignatureFields)
            {
                var signatureColumn = grid.Columns[signature.SignatureColumn];
                if (signatureColumn != null) signatureColumn.Visible = false;
            }
            int displayIndex = 3;
            foreach (string field in BuildGridFieldOrder())
            {
                var column = grid.Columns[field];
                if (column == null) continue;
                column.Visible = true;
                column.DisplayIndex = displayIndex++;
                column.HeaderText = GetFriendlyFieldName(field);
                column.ToolTipText = field.StartsWith("签字图块_", StringComparison.Ordinal)
                    ? "右侧签字格使用的外部 DWG 图块路径"
                    : "新图签字段：" + field;
                column.Width = field.StartsWith("签字图块_", StringComparison.Ordinal)
                    ? 260
                    : GetColumnWidth(field);
                column.SortMode = DataGridViewColumnSortMode.NotSortable;
            }
        }

        private static string[] BuildGridFieldOrder()
        {
            return new[]
            {
                "图号", "版本号", "图别", "设计项目号",
                "比例", "单位", "图名", "建设单位", "设计项目名", "子项名称",
                "日期"
            };
        }

        private static BatchFieldChoice[] BuildBatchFieldChoices()
        {
            var choices = new List<BatchFieldChoice>();
            var personnelFields = new HashSet<string>(
                SignatureFields.Select(signature => signature.TextField),
                StringComparer.Ordinal);
            foreach (string tag in UiFieldOrder)
            {
                if (personnelFields.Contains(tag)) continue;
                choices.Add(new BatchFieldChoice(GetFriendlyFieldName(tag), tag));
            }
            return choices.ToArray();
        }

        private static string GetFriendlyFieldName(string tag)
        {
            if (tag.StartsWith("签字图块_", StringComparison.Ordinal))
            {
                return tag.Substring("签字图块_".Length) + "签字图块";
            }
            string friendly;
            return FriendlyFieldNames.TryGetValue(tag, out friendly) ? friendly : tag;
        }

        private static int GetColumnWidth(string tag)
        {
            if (tag == "建设单位" || tag == "设计项目名" || tag == "图名" || tag == "子项名称") return 230;
            if (tag.StartsWith("N", StringComparison.Ordinal)) return 160;
            return 110;
        }

        private void BrowseInput(object sender, EventArgs e)
        {
            SelectInputDirectory(false);
        }

        private void StartNextBatch()
        {
            SelectInputDirectory(true);
        }

        private void SelectInputDirectory(bool explicitlyStartingNextBatch)
        {
            using (var dialog = new FolderBrowserDialog())
            {
                dialog.Description = explicitlyStartingNextBatch
                    ? "选择下一批待处理 DWG 所在目录"
                    : (operationMode == OperationMode.ReplaceFrame
                        ? "选择存放待处理 DWG 的目录"
                        : "选择存放待更新图签 DWG 的目录");
                if (Directory.Exists(inputBox.Text)) dialog.SelectedPath = inputBox.Text;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                string selectedPath = Path.GetFullPath(dialog.SelectedPath);
                bool inputChanged = !PathsEqual(inputBox.Text, selectedPath);
                bool resetBatch = explicitlyStartingNextBatch || inputChanged || sheetTable.Rows.Count > 0;
                if (resetBatch && sheetTable.Rows.Count > 0 && !batchCompleted)
                {
                    DialogResult answer = MessageBox.Show(
                        "当前扫描表尚未完成交付。切换目录会清空当前扫描表和运行日志；上方全局信息、人员姓名及签字 DWG 会保留。\r\n\r\n是否继续？",
                        "确认切换处理目录",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Warning,
                        MessageBoxDefaultButton.Button2
                    );
                    if (answer != DialogResult.Yes) return;
                }
                LoadBatchDirectory(selectedPath, resetBatch);
            }
        }

        private void LoadBatchDirectory(string selectedPath, bool resetBatch)
        {
            if (resetBatch)
            {
                sheetTable.Rows.Clear();
                grid.ClearSelection();
                batchValueBox.Clear();
                logBox.Clear();
                sessionRoot = CreateSessionRoot();
                batchCompleted = false;
                SetProgress(0, "等待扫描");
            }
            inputBox.Text = selectedPath;
            outputBox.Text = BuildDefaultOutputDirectory(selectedPath);
            statusLabel.Text = resetBatch
                ? "已选择新批次，请扫描"
                : "已选择待处理目录，请扫描";
            AppendLog("输入目录：" + selectedPath);
            AppendLog("自动输出目录：" + outputBox.Text);
            scanButton.Focus();
        }

        private string BuildDefaultOutputDirectory(string inputDirectory)
        {
            string normalized = Path.GetFullPath(inputDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var directory = new DirectoryInfo(normalized);
            string folderName = string.IsNullOrWhiteSpace(directory.Name)
                ? "DWG"
                : directory.Name;
            string suffix = operationMode == OperationMode.ReplaceFrame
                ? "图框图签处理输出"
                : "图签更新输出";
            string outputName = string.Format(
                "{0}_{1}_{2}",
                folderName,
                suffix,
                DateTime.Now.ToString("yyyyMMdd")
            );
            string baseOutput = directory.Parent == null
                ? Path.Combine(normalized, outputName)
                : Path.Combine(directory.Parent.FullName, outputName);
            return FindAvailableOutputDirectory(baseOutput);
        }

        private static string FindAvailableOutputDirectory(string requestedPath)
        {
            string normalized = Path.GetFullPath(requestedPath)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (!Directory.Exists(normalized) && !File.Exists(normalized)) return normalized;

            string parent = Path.GetDirectoryName(normalized);
            string name = Path.GetFileName(normalized);
            Match versionMatch = Regex.Match(
                name,
                @"^(?<base>.+)_V(?<version>\d+)\.0$",
                RegexOptions.IgnoreCase);
            string baseName = versionMatch.Success
                ? versionMatch.Groups["base"].Value
                : name;
            int firstVersion = 1;
            if (versionMatch.Success)
            {
                int currentVersion;
                if (int.TryParse(versionMatch.Groups["version"].Value, out currentVersion))
                    firstVersion = currentVersion + 1;
            }
            for (int version = firstVersion; version <= 9999; version++)
            {
                string candidate = Path.Combine(
                    parent,
                    string.Format("{0}_V{1}.0", baseName, version));
                if (!Directory.Exists(candidate) && !File.Exists(candidate)) return candidate;
            }
            throw new IOException("无法生成新的输出目录版本号，请清理同名历史输出目录后重试。");
        }

        private static bool PathsEqual(string left, string right)
        {
            if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
            try
            {
                string normalizedLeft = Path.GetFullPath(left)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string normalizedRight = Path.GetFullPath(right)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return string.Equals(
                    normalizedLeft,
                    normalizedRight,
                    StringComparison.OrdinalIgnoreCase
                );
            }
            catch
            {
                return false;
            }
        }

        private static string CreateSessionRoot()
        {
            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CADFrameReplacer",
                "sessions",
                DateTime.Now.ToString("yyyyMMdd_HHmmss_fff") + "_" +
                Guid.NewGuid().ToString("N").Substring(0, 8)
            );
            Directory.CreateDirectory(root);
            return root;
        }

        private void BrowseOutput(object sender, EventArgs e)
        {
            using (var dialog = new FolderBrowserDialog())
            {
                dialog.Description = "选择或创建成果输出目录";
                if (Directory.Exists(outputBox.Text)) dialog.SelectedPath = outputBox.Text;
                if (dialog.ShowDialog(this) == DialogResult.OK) outputBox.Text = dialog.SelectedPath;
            }
        }

        private void BrowseCore(object sender, EventArgs e)
        {
            using (var dialog = new OpenFileDialog())
            {
                dialog.Filter = "AutoCAD Core Console|accoreconsole.exe";
                dialog.FileName = "accoreconsole.exe";
                if (dialog.ShowDialog(this) == DialogResult.OK) coreBox.Text = dialog.FileName;
            }
        }

        private void BrowseSignatureForRole(SignatureFieldDefinition signature)
        {
            using (var dialog = new OpenFileDialog())
            {
                dialog.Title = "选择“" + signature.DisplayName + "”签字 DWG 图块";
                dialog.Filter = "AutoCAD 图形 (*.dwg)|*.dwg";
                dialog.CheckFileExists = true;
                TextBox box;
                if (personnelSignatureBoxes.TryGetValue(signature.SignatureColumn, out box) &&
                    File.Exists(box.Text))
                {
                    dialog.FileName = box.Text;
                }
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    explicitlyClearedSignatures.Remove(signature.SignatureColumn);
                    personnelSignatureBoxes[signature.SignatureColumn].Text = dialog.FileName;
                    if (sheetTable.Rows.Count > 0)
                    {
                        SyncPersonnelFieldsToAll(false);
                        statusLabel.Text = "已选择并同步：" + signature.DisplayName + "签字图块";
                    }
                }
            }
        }

        private void ClearPersonnelSignature(SignatureFieldDefinition signature)
        {
            TextBox box;
            if (personnelSignatureBoxes.TryGetValue(signature.SignatureColumn, out box))
            {
                box.Clear();
            }
            explicitlyClearedSignatures.Add(signature.SignatureColumn);
            if (sheetTable.Rows.Count > 0)
            {
                foreach (DataRow row in sheetTable.Rows)
                {
                    row[signature.AnchorField] = string.Empty;
                    row[signature.SignatureColumn] = ClearSignatureSentinel;
                }
                statusLabel.Text = "已明确删除并同步：" + signature.DisplayName + "签字图块";
            }
        }

        private string DetectCoreConsole()
        {
            var candidates = new List<Tuple<int, string>>();
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            for (int version = 2027; version >= 2020; version--)
            {
                string path = Path.Combine(
                    programFiles,
                    "Autodesk",
                    "AutoCAD " + version,
                    "accoreconsole.exe"
                );
                AddCoreCandidate(candidates, version, path);
            }

            foreach (RegistryHive hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
            {
                foreach (RegistryView view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
                {
                    try
                    {
                        using (RegistryKey baseKey = RegistryKey.OpenBaseKey(hive, view))
                        using (RegistryKey acadKey = baseKey.OpenSubKey(@"SOFTWARE\Autodesk\AutoCAD"))
                        {
                            if (acadKey == null) continue;
                            foreach (string releaseName in acadKey.GetSubKeyNames())
                            {
                                using (RegistryKey releaseKey = acadKey.OpenSubKey(releaseName))
                                {
                                    if (releaseKey == null) continue;
                                    foreach (string productName in releaseKey.GetSubKeyNames())
                                    {
                                        using (RegistryKey productKey = releaseKey.OpenSubKey(productName))
                                        {
                                            if (productKey == null) continue;
                                            int year;
                                            if (!int.TryParse(Convert.ToString(productKey.GetValue("UPIRELEASE")), out year)) continue;
                                            string install = Convert.ToString(productKey.GetValue("GlobUPILocation"));
                                            if (string.IsNullOrWhiteSpace(install))
                                            {
                                                install = Convert.ToString(productKey.GetValue("InstallLocation"));
                                            }
                                            if (string.IsNullOrWhiteSpace(install))
                                            {
                                                install = Convert.ToString(productKey.GetValue("UPIInstallLocation"));
                                            }
                                            if (!string.IsNullOrWhiteSpace(install))
                                            {
                                                AddCoreCandidate(candidates, year, Path.Combine(install, "accoreconsole.exe"));
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    catch
                    {
                        // Registry discovery is best-effort. The user can always browse to the executable.
                    }
                }
            }

            var supported = candidates
                .Where(item => item.Item1 >= 2020 && File.Exists(item.Item2))
                .ToList();
            // 2021+ writes the UTF-8 scan inventory required for reliable
            // Tianzheng/proxy title recovery. Prefer the newest installed Core;
            // retain 2020 only as a compatibility fallback.
            Tuple<int, string> best = supported
                .OrderByDescending(item => item.Item1)
                .FirstOrDefault();
            return best == null ? string.Empty : best.Item2;
        }

        private static void AddCoreCandidate(List<Tuple<int, string>> candidates, int year, string path)
        {
            if (year < 2020 || string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
            if (candidates.Any(item => string.Equals(item.Item2, path, StringComparison.OrdinalIgnoreCase))) return;
            candidates.Add(Tuple.Create(year, path));
        }

        private string GetOperationModeArgument()
        {
            return operationMode == OperationMode.ReplaceFrame
                ? "Replace"
                : "UpdateTitle";
        }

        private static string GetOptionalFieldArgument(string value)
        {
            return string.IsNullOrWhiteSpace(value)
                ? "__CFR_PRESERVE__"
                : value;
        }

        private bool ValidateInputs(bool requireOutput)
        {
            if (!Directory.Exists(inputBox.Text))
            {
                MessageBox.Show("请选择有效的旧图框目录。", "缺少输入", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (Directory.GetFiles(inputBox.Text, "*.dwg", SearchOption.TopDirectoryOnly).Length == 0)
            {
                MessageBox.Show("输入目录中没有 DWG 文件。", "没有图纸", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (!File.Exists(coreBox.Text))
            {
                MessageBox.Show("找不到 AutoCAD Core Console，请选择 AutoCAD 2020 或更高版本的 accoreconsole.exe。", "缺少 AutoCAD", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            try
            {
                FileVersionInfo info = FileVersionInfo.GetVersionInfo(coreBox.Text);
                if (info.FileMajorPart < 23 || (info.FileMajorPart == 23 && info.FileMinorPart < 1))
                {
                    MessageBox.Show("当前选择的 AutoCAD 低于 2020。本版本仅支持 AutoCAD 2020 或更高版本。", "AutoCAD 版本不支持", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }
            }
            catch
            {
                MessageBox.Show("无法识别所选 Core Console 的版本，请重新选择 AutoCAD 2020 或更高版本。", "AutoCAD 版本无法识别", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (requireOutput && string.IsNullOrWhiteSpace(outputBox.Text))
            {
                MessageBox.Show("请选择成果输出目录。", "缺少输出", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            return true;
        }

        private async Task ScanAsync()
        {
            if (busy || !ValidateInputs(false)) return;
            batchCompleted = false;
            SetBusy(true, "正在扫描和生成字段表…");
            SetProgress(0, "准备扫描");
            try
            {
                string dryRun = Path.Combine(sessionRoot, "dry_run");
                string sourceInventory = Path.Combine(sessionRoot, "source_inventory");
                Directory.CreateDirectory(dryRun);
                Directory.CreateDirectory(sourceInventory);
                logBox.Clear();
                SetProgress(3, "准备扫描目录");
                AppendLog("开始合并扫描：一次打开 DWG，同时识别边框尺寸、读取图签字段并生成验收清单；最多并行处理 2 个 DWG。");

                SetProgress(5, "识别图框并建立验收清单");
                int exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "run_frame_replacement.ps1"),
                    new[]
                    {
                        "-InputDirectory", inputBox.Text,
                        "-建设单位", GetOptionalFieldArgument(ownerBox.Text),
                        "-设计项目名", GetOptionalFieldArgument(projectBox.Text),
                        "-出图日期", GetOptionalFieldArgument(dateBox.Text),
                        "-设计项目号", GetOptionalFieldArgument(numberBox.Text),
                        "-CoreConsolePath", coreBox.Text,
                        "-OperationMode", GetOperationModeArgument(),
                        "-DryRunLogDirectory", dryRun,
                        "-CombinedInventoryDirectory", sourceInventory,
                        "-MaxWorkers", "2"
                    },
                    5,
                    85,
                    "扫描原图"
                );
                if (exit != 0) throw new InvalidOperationException("dry-run 失败，退出码：" + exit);
                SetProgress(87, "载入图签字段");
                LoadDryRunRows(dryRun);
                string dependencyReport = Path.Combine(dryRun, "dependency_skips.csv");
                int skippedDependencyCount = File.Exists(dependencyReport)
                    ? Math.Max(0, File.ReadAllLines(dependencyReport, Encoding.UTF8)
                        .Count(line => !string.IsNullOrWhiteSpace(line)) - 1)
                    : 0;
                if (skippedDependencyCount > 0)
                {
                    AppendLog(string.Format(
                        "已跳过 {0} 个图框/底图外参依赖 DWG（例如 A0、A1、A2、Baseplan、底图）；只把引用它们的宿主图列入字段表。",
                        skippedDependencyCount
                    ));
                }
                int xrefRequiresReplaceCount = CountDryRunRowsByStatus(
                    dryRun,
                    "REQUIRES_REPLACE"
                );
                if (operationMode == OperationMode.UpdateTitle &&
                    xrefRequiresReplaceCount > 0)
                {
                    AppendLog(string.Format(
                        "识别到 {0} 个 XREF 图框；已保留在字段表并标记为“需切换换图框”，其旧图签位于外参内部，不能在“仅更新图签”模式安全原位写入。",
                        xrefRequiresReplaceCount
                    ));
                    DialogResult switchAnswer = MessageBox.Show(
                        string.Format(
                            "识别到 {0} 个 XREF 图框，它们已显示在字段表中。\r\n\r\n" +
                            "这些右侧旧图签属于 A0/A1/A2 等外参内部，不是宿主 DWG 中可直接修改的属性块。强行更新可能误改详图标题，或者修改被多张图共享的外参源文件。\r\n\r\n" +
                            "是否立即切换到“替换图框”模式并自动重新扫描？",
                            xrefRequiresReplaceCount
                        ),
                        "XREF 图签需要替换图框模式",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Information,
                        MessageBoxDefaultButton.Button1
                    );
                    if (switchAnswer == DialogResult.Yes)
                    {
                        SwitchToReplaceMode();
                        BeginInvoke((Action)(async () => await ScanAsync()));
                        return;
                    }
                    AppendLog(
                        GetExecutableSheetCount() == 0
                            ? "用户保留“仅更新图签”模式；本批图签全部需要换图框，字段表仅供核对，执行前会再次提示切换模式。"
                            : "用户保留“仅更新图签”模式；XREF 图框仍显示在字段表并标记状态，执行时只处理本地可编辑图签。"
                    );
                }
                if (sheetTable.Rows.Count == 0) throw new InvalidOperationException("没有识别到可处理的本地可编辑图签。");
                SyncTopFieldsToAll(false);
                AppendLog("已将上方全局字段、人员姓名和签字 DWG 同步到全部图签。");

                SetProgress(90, "分析原图清单");
                exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "analyze_inventory.ps1"),
                    new[]
                    {
                        "-InventoryDirectory", sourceInventory,
                        "-OutputCsv", Path.Combine(sourceInventory, "frame_inventory.csv")
                    },
                    90,
                    98,
                    "分析原图清单"
                );
                if (exit != 0) throw new InvalidOperationException("原图清单分析失败，退出码：" + exit);

                string sourceInventoryCsv = Path.Combine(
                    sourceInventory,
                    "frame_inventory.csv"
                );
                string coverageReport = Path.Combine(
                    sourceInventory,
                    "规划句柄覆盖检查.csv"
                );
                SetProgress(96, "核对模型空间与布局清单");
                exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "validate_inventory_coverage.ps1"),
                    new[]
                    {
                        "-PlanDirectory", dryRun,
                        "-InventoryCsv", sourceInventoryCsv,
                        "-ReportCsv", coverageReport
                    },
                    96,
                    98,
                    "核对源清单"
                );
                if (exit != 0)
                {
                    AppendLog(
                        "首次源清单不完整（AutoCAD 2020 可能尚未加载全部模型/布局对象），正在独立复扫一次。"
                    );
                    string retryInventory = Path.Combine(
                        sessionRoot,
                        "source_inventory_retry"
                    );
                    Directory.CreateDirectory(retryInventory);
                    exit = await RunPowerShellAsync(
                        Path.Combine(scriptsRoot, "scan_all_frames.ps1"),
                        new[]
                        {
                            "-InputDirectory", inputBox.Text,
                            "-OutputDirectory", retryInventory,
                            "-CoreConsolePath", coreBox.Text,
                            "-MaxWorkers", "2"
                        },
                        96,
                        97,
                        "复扫原图"
                    );
                    if (exit != 0)
                    {
                        throw new InvalidOperationException(
                            "原图完整性复扫失败，退出码：" + exit
                        );
                    }
                    string retryCsv = Path.Combine(
                        retryInventory,
                        "frame_inventory.csv"
                    );
                    exit = await RunPowerShellAsync(
                        Path.Combine(scriptsRoot, "analyze_inventory.ps1"),
                        new[]
                        {
                            "-InventoryDirectory", retryInventory,
                            "-OutputCsv", retryCsv
                        },
                        97,
                        98,
                        "分析复扫清单"
                    );
                    if (exit != 0)
                    {
                        throw new InvalidOperationException(
                            "原图复扫清单分析失败，退出码：" + exit
                        );
                    }
                    exit = await RunPowerShellAsync(
                        Path.Combine(scriptsRoot, "validate_inventory_coverage.ps1"),
                        new[]
                        {
                            "-PlanDirectory", dryRun,
                            "-InventoryCsv", retryCsv,
                            "-ReportCsv", Path.Combine(
                                retryInventory,
                                "规划句柄覆盖检查.csv"
                            )
                        },
                        98,
                        99,
                        "复核源清单"
                    );
                    if (exit != 0)
                    {
                        throw new InvalidOperationException(
                            "源清单连续两次未覆盖全部已规划图框。为避免误写，已停止执行。"
                        );
                    }
                    File.Copy(retryCsv, sourceInventoryCsv, true);
                    AppendLog("独立复扫已补齐全部规划图框和图签句柄。执行前验收基线已更新。");
                }

                SetProgress(100, "扫描完成");
                int modelSheetCount;
                int layoutSheetCount;
                GetSheetSpaceCounts(out modelSheetCount, out layoutSheetCount);
                statusLabel.Text = string.Format(
                    "已读取 {0} 个源 DWG、{1} 张图签（模型 {2} / 布局 {3}），上方信息已同步",
                    GetSourceDrawingCount(),
                    sheetTable.Rows.Count,
                    modelSheetCount,
                    layoutSheetCount
                );
                AppendLog(
                    string.Format(
                        "扫描完成：{0} 个源 DWG、{1} 张图签，其中模型空间 {2} 张、布局空间 {3} 张。源文件名每个文件只显示一次；图签仍逐张编辑。",
                        GetSourceDrawingCount(),
                        sheetTable.Rows.Count,
                        modelSheetCount,
                        layoutSheetCount
                    )
                );
                int recognitionIssueCount = WriteRecognitionIssueReport();
                if (recognitionIssueCount > 0)
                {
                    statusLabel.Text += string.Format(
                        "；{0} 张需人工核对",
                        recognitionIssueCount
                    );
                    AppendLog(string.Format(
                        "识别问题报告已生成：{0}（{1} 张需人工核对；未确认时对应 DWG 将整份跳过，其他文件继续处理。）",
                        GetRecognitionIssueReportPath(),
                        recognitionIssueCount
                    ));
                    if (!shellHosted)
                    {
                        DialogResult reviewStart = MessageBox.Show(
                            string.Format(
                                "扫描完成：共识别 {0} 张图签，其中 {1} 张需要人工核对。\r\n\r\n是否现在跳到第一张待核对项？",
                                sheetTable.Rows.Count,
                                recognitionIssueCount),
                            "扫描完成",
                            MessageBoxButtons.YesNo,
                            MessageBoxIcon.Information,
                            MessageBoxDefaultButton.Button1);
                        if (reviewStart == DialogResult.Yes) JumpToNextReviewRow();
                    }
                }
            }
            catch (Exception ex)
            {
                statusLabel.Text = "扫描失败，请查看日志";
                SetProgressFailed("扫描未完成");
                AppendLog("错误：" + ex.Message);
                MessageBox.Show(ex.Message, "扫描失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                SetBusy(false, statusLabel.Text);
            }
        }

        private void LoadDryRunRows(string dryRunDirectory)
        {
            sheetTable.Rows.Clear();
            foreach (string file in Directory.GetFiles(dryRunDirectory, "*.tsv").OrderBy(p => p, StringComparer.CurrentCulture))
            {
                string[] lines = File.ReadAllLines(file, Encoding.UTF8);
                if (lines.Length < 2) continue;
                string[] headers = lines[0].Split('\t');
                var indexes = new Dictionary<string, int>(StringComparer.Ordinal);
                for (int i = 0; i < headers.Length; i++) indexes[headers[i]] = i;
                int plannedSuggestionIndex = 0;
                for (int lineIndex = 1; lineIndex < lines.Length; lineIndex++)
                {
                    string[] values = lines[lineIndex].Split('\t');
                    string dryStatus = GetValue(values, indexes, "status");
                    if (dryStatus != "PLANNED" &&
                        dryStatus != "REQUIRES_REPLACE") continue;
                    plannedSuggestionIndex++;
                    DataRow row = sheetTable.NewRow();
                    row["drawing"] = GetValue(values, indexes, "drawing");
                    row["layout"] = GetValue(values, indexes, "layout");
                    bool virtualTitle = GetValue(
                        values,
                        indexes,
                        "virtual_title"
                    ) == "1";
                    bool titleOnly = string.Equals(
                        GetValue(values, indexes, "frame_spec"),
                        "TITLE_ONLY",
                        StringComparison.OrdinalIgnoreCase
                    );
                    row["title_only"] = titleOnly;
                    string scannedDrawingName = NormalizeRecoveredDrawingName(
                        GetValue(values, indexes, "图名"));
                    bool drawingNameMissing = string.IsNullOrWhiteSpace(scannedDrawingName) ||
                        IsSuspiciousRecoveredDrawingName(scannedDrawingName);
                    string scannedDrawingNumber = GetValue(values, indexes, "图号");
                    bool drawingNumberMissing = string.IsNullOrWhiteSpace(scannedDrawingNumber) ||
                        IsSuspiciousRecoveredDrawingNumber(scannedDrawingNumber);
                    string suggestedNumber = string.Empty;
                    string suggestedName = string.Empty;
                    bool suggestionAvailable = false;
                    if (drawingNameMissing || drawingNumberMissing)
                    {
                        suggestionAvailable = TryBuildFilenameSuggestion(
                            GetValue(values, indexes, "drawing"),
                            plannedSuggestionIndex,
                            out suggestedNumber,
                            out suggestedName
                        );
                    }
                    string scanStatus = dryStatus == "REQUIRES_REPLACE"
                        ? "已识别；需切换换图框"
                        : (titleOnly
                            ? (operationMode == OperationMode.ReplaceFrame
                                ? "待人工核对；仅能更新图签文字，无法自动换图框"
                                : "已识别；仅更新本地图签")
                            : operationMode == OperationMode.ReplaceFrame
                            ? "已识别；可替换"
                            : (virtualTitle
                                ? "已识别；可覆盖图名/图号"
                                : "已识别；可仅更新"));
                    if (titleOnly && operationMode == OperationMode.ReplaceFrame)
                    {
                        row["review_required"] = true;
                        row["review_confirmed"] = false;
                        row["review_source"] = "仅识别到本地图签，未识别到可安全替换的图框";
                    }
                    else if (drawingNameMissing || drawingNumberMissing)
                    {
                        scanStatus += suggestionAvailable
                            ? "；建议值需人工核对"
                            : "；缺失值需人工补填";
                        row["review_required"] = true;
                        row["review_confirmed"] = false;
                        row["review_source"] = suggestionAvailable
                            ? "文件名建议"
                            : "识别缺失";
                    }
                    else
                    {
                        row["review_required"] = false;
                        row["review_confirmed"] = true;
                        row["review_source"] = string.Empty;
                    }
                    if (drawingNameMissing && !suggestionAvailable)
                    {
                        scanStatus += "；图名待填";
                    }
                    if (drawingNumberMissing && !suggestionAvailable)
                    {
                        scanStatus += "；图号待填";
                    }
                    row["scan_status"] = scanStatus;
                    row["old_frame_handle"] = GetValue(values, indexes, "old_frame_handle");
                    foreach (string column in ProxyTitleHandleColumns)
                        row[column] = GetValue(values, indexes, column);
                    foreach (string tag in EditableTags) row[tag] = GetValue(values, indexes, tag);
                    if (!drawingNameMissing) row["图名"] = scannedDrawingName;
                    if (suggestionAvailable)
                    {
                        if (drawingNumberMissing) row["图号"] = suggestedNumber;
                        if (drawingNameMissing) row["图名"] = suggestedName;
                    }
                    else if (IsSuspiciousRecoveredDrawingNumber(scannedDrawingNumber))
                    {
                        // Do not expose or later write a nearby section/detail marker as
                        // a sheet number. Its paired name is equally untrusted.
                        row["图号"] = string.Empty;
                        row["图名"] = string.Empty;
                    }
                    else if (IsSuspiciousRecoveredDrawingName(scannedDrawingName))
                    {
                        row["图名"] = string.Empty;
                    }
                    sheetTable.Rows.Add(row);
                }
            }
            RefreshSourceDisplayColumns();
            ConfigureGridColumns();
            ApplyReviewRowStyles();
        }

        private static bool TryBuildFilenameSuggestion(
            string drawing,
            int sheetIndex,
            out string drawingNumber,
            out string drawingName)
        {
            drawingNumber = string.Empty;
            drawingName = string.Empty;
            string stem = Path.GetFileNameWithoutExtension(drawing);
            if (string.IsNullOrWhiteSpace(stem)) return false;
            stem = Regex.Replace(stem, @"[（(]修改[）)]\s*$", "");
            stem = Regex.Replace(stem, @"(?:[_ ]+t\d+)+.*$", "", RegexOptions.IgnoreCase);
            stem = Regex.Replace(stem, @"\s*A[012](?:\+(?:0\.)?\d+)?\s*$", "", RegexOptions.IgnoreCase);
            Match match = Regex.Match(
                stem,
                @"^(?<prefix>[A-Za-z]+(?:-[A-Za-z0-9]+)+-)(?<start>\d{3})(?:~(?<end>\d{3}))?\s*(?<name>.*)$"
            );
            if (!match.Success) return false;
            int startNumber;
            int endNumber;
            if (!int.TryParse(match.Groups["start"].Value, out startNumber)) return false;
            bool hasEnd = int.TryParse(match.Groups["end"].Value, out endNumber);
            int suggestedNumber = startNumber + Math.Max(0, sheetIndex - 1);
            if (hasEnd && suggestedNumber > endNumber) suggestedNumber = endNumber;
            drawingNumber = match.Groups["prefix"].Value + suggestedNumber.ToString("D3");
            drawingName = match.Groups["name"].Value.Trim();
            if (Regex.IsMatch(drawingName, @"^[.~～_-]")) return false;
            return !string.IsNullOrWhiteSpace(drawingNumber) &&
                !string.IsNullOrWhiteSpace(drawingName);
        }

        private static bool IsSuspiciousRecoveredDrawingNumber(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return true;
            string text = value.Trim();
            if (!Regex.IsMatch(text, @"[\p{L}\p{N}\u4e00-\u9fff]")) return true;
            return Regex.IsMatch(text, @"^[A-Za-z0-9]{1,2}$");
        }

        private static string NormalizeRecoveredDrawingName(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return string.Empty;
            string normalized = value.Trim();
            // Remove common MTEXT group/font wrappers while retaining the
            // visible Chinese drawing name.
            normalized = Regex.Replace(normalized, @"^\{\\[^;{}]+;", string.Empty);
            normalized = normalized.Trim('{', '}');
            normalized = normalized.Replace("\\P", " ").Replace("\\~", " ");
            return normalized.Trim();
        }

        private static bool IsSuspiciousRecoveredDrawingName(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return true;
            string text = value.Trim();
            // A visible title made only of punctuation (for example ".") is
            // not a valid drawing name.  Treat it as missing so the file is
            // sent to manual review instead of silently producing a bad DWG.
            if (!Regex.IsMatch(text, @"[\p{L}\p{N}\u4e00-\u9fff]")) return true;
            return Regex.IsMatch(text, @"(?i)PANTONE|对应色号|材料颜色|COLOR\s*(NO|CODE)");
        }

        private void ApplyReviewRowStyles()
        {
            foreach (DataGridViewRow gridRow in grid.Rows)
            {
                DataRowView view = gridRow.DataBoundItem as DataRowView;
                if (view == null) continue;
                bool required = view.Row.Field<bool?>("review_required") == true;
                bool confirmed = view.Row.Field<bool?>("review_confirmed") == true;
                bool failed = Convert.ToString(view.Row["scan_status"])
                    .StartsWith("处理失败", StringComparison.Ordinal);
                gridRow.DefaultCellStyle.BackColor = failed
                    ? Color.FromArgb(79, 39, 43)
                    : required && !confirmed
                        ? Color.FromArgb(78, 62, 33)
                        : ThemeInput;
                gridRow.DefaultCellStyle.ForeColor = failed
                    ? Color.FromArgb(255, 178, 178)
                    : required && !confirmed
                        ? Color.FromArgb(246, 211, 139)
                        : ThemeText;
                gridRow.DefaultCellStyle.SelectionBackColor = failed
                    ? Color.FromArgb(137, 58, 64)
                    : required && !confirmed
                        ? Color.FromArgb(123, 96, 46)
                        : ThemeAccent;
                gridRow.DefaultCellStyle.SelectionForeColor = Color.White;
            }
        }

        private void MarkFailedDrawings(VerificationSummary verification)
        {
            if (verification == null || verification.FailedMainFileNames.Count == 0) return;
            int firstFailedRow = -1;
            for (int index = 0; index < sheetTable.Rows.Count; index++)
            {
                DataRow row = sheetTable.Rows[index];
                string fileName = Path.GetFileName(Convert.ToString(row["drawing"]));
                if (!verification.FailedMainFileNames.Contains(fileName)) continue;
                string reason;
                row["scan_status"] = "处理失败；" +
                    (verification.FailureReasons.TryGetValue(fileName, out reason)
                        ? reason : "执行或成果复扫失败，详见处理日志");
                if (firstFailedRow < 0) firstFailedRow = index;
            }
            ApplyReviewRowStyles();
            if (firstFailedRow >= 0 && firstFailedRow < grid.Rows.Count)
            {
                grid.CurrentCell = grid.Rows[firstFailedRow].Cells["scan_status"];
                grid.FirstDisplayedScrollingRowIndex = firstFailedRow;
            }
        }

        private void JumpToNextReviewRow()
        {
            if (grid.Rows.Count == 0) return;
            int start = grid.CurrentCell == null ? -1 : grid.CurrentCell.RowIndex;
            for (int offset = 1; offset <= grid.Rows.Count; offset++)
            {
                int index = (start + offset) % grid.Rows.Count;
                DataRowView view = grid.Rows[index].DataBoundItem as DataRowView;
                if (view == null ||
                    view.Row.Field<bool?>("review_required") != true ||
                    view.Row.Field<bool?>("review_confirmed") == true) continue;
                grid.CurrentCell = grid.Rows[index].Cells["图号"];
                grid.FirstDisplayedScrollingRowIndex = index;
                return;
            }
            MessageBox.Show("没有尚未确认的建议项。", "人工核对", MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }

        private void ConfirmCurrentReviewRow()
        {
            if (grid.CurrentCell == null) return;
            grid.EndEdit();
            DataRowView view = grid.Rows[grid.CurrentCell.RowIndex].DataBoundItem as DataRowView;
            if (view == null || view.Row.Field<bool?>("review_required") != true) return;
            if (string.IsNullOrWhiteSpace(Convert.ToString(view.Row["图名"])) ||
                string.IsNullOrWhiteSpace(Convert.ToString(view.Row["图号"])))
            {
                MessageBox.Show("图名和图号不能为空。请修改后再确认。", "无法确认",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            view.Row["review_confirmed"] = true;
            view.Row["scan_status"] = view.Row.Field<bool?>("title_only") == true
                ? "人工已确认；可更新图签文字"
                : "人工已确认；可替换";
            ApplyReviewRowStyles();
            JumpToNextReviewRow();
        }

        private static int CountDryRunRowsByStatus(
            string dryRunDirectory,
            string expectedStatus)
        {
            int count = 0;
            foreach (string file in Directory.GetFiles(
                dryRunDirectory,
                "*.tsv").OrderBy(p => p, StringComparer.CurrentCulture))
            {
                string[] lines = File.ReadAllLines(file, Encoding.UTF8);
                if (lines.Length < 2) continue;
                string[] headers = lines[0].Split('\t');
                int statusIndex = Array.IndexOf(headers, "status");
                if (statusIndex < 0) continue;
                for (int i = 1; i < lines.Length; i++)
                {
                    if (string.IsNullOrWhiteSpace(lines[i])) continue;
                    string[] cells = lines[i].Split('\t');
                    if (statusIndex < cells.Length &&
                        string.Equals(
                            cells[statusIndex],
                            expectedStatus,
                            StringComparison.OrdinalIgnoreCase))
                    {
                        count++;
                    }
                }
            }
            return count;
        }

        private void SwitchToReplaceMode()
        {
            operationMode = OperationMode.ReplaceFrame;
            Text = "出图100% · CAD图框图签自动处理与质量验收（v1.6.1）";
            titleLabel.Text =
                "出图100% · 图框图签自动处理";
            applyButton.Text = "② 开始处理";
            sheetTable.Rows.Clear();
            grid.ClearSelection();
            batchValueBox.Clear();
            sessionRoot = CreateSessionRoot();
            batchCompleted = false;
            if (Directory.Exists(inputBox.Text))
            {
                outputBox.Text = BuildDefaultOutputDirectory(inputBox.Text);
            }
            statusLabel.Text = "已切换到替换图框模式，准备自动重扫";
            SetProgress(0, "切换模式");
        }

        private int GetSourceDrawingCount()
        {
            var drawings = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (DataRow row in sheetTable.Rows)
            {
                string drawing = Convert.ToString(row["drawing"]).Trim();
                if (!string.IsNullOrWhiteSpace(drawing)) drawings.Add(drawing);
            }
            return drawings.Count;
        }

        private bool IsExecutableRow(DataRow row)
        {
            string scanStatus = Convert.ToString(row["scan_status"]);
            bool scanSucceeded = !scanStatus.StartsWith(
                "处理失败",
                StringComparison.Ordinal
            );
            bool modeAllowed = operationMode != OperationMode.UpdateTitle ||
                !scanStatus.StartsWith(
                    "已识别；需切换换图框",
                    StringComparison.Ordinal
                );
            string drawing = Convert.ToString(row["drawing"]);
            bool reviewAllowed = !sheetTable.Rows.Cast<DataRow>().Any(item =>
                string.Equals(
                    Convert.ToString(item["drawing"]), drawing,
                    StringComparison.OrdinalIgnoreCase) &&
                item.Field<bool?>("review_required") == true &&
                item.Field<bool?>("review_confirmed") != true);
            return scanSucceeded && modeAllowed && reviewAllowed;
        }

        private int GetUnconfirmedReviewCount()
        {
            return sheetTable.Rows.Cast<DataRow>().Count(row =>
                row.Field<bool?>("review_required") == true &&
                row.Field<bool?>("review_confirmed") != true);
        }

        private int GetExecutableSheetCount()
        {
            return sheetTable.Rows.Cast<DataRow>().Count(IsExecutableRow);
        }

        private int GetRequiresReplaceSheetCount()
        {
            return sheetTable.Rows.Cast<DataRow>().Count(row =>
                Convert.ToString(row["scan_status"]).StartsWith(
                    "已识别；需切换换图框",
                    StringComparison.Ordinal
                )
            );
        }

        private int GetExecutableSourceDrawingCount()
        {
            var drawings = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (DataRow row in sheetTable.Rows)
            {
                if (!IsExecutableRow(row)) continue;
                string drawing = Convert.ToString(row["drawing"]).Trim();
                if (!string.IsNullOrWhiteSpace(drawing)) drawings.Add(drawing);
            }
            return drawings.Count;
        }

        private void GetSheetSpaceCounts(
            out int modelSheetCount,
            out int layoutSheetCount,
            bool executableOnly = false)
        {
            modelSheetCount = 0;
            layoutSheetCount = 0;
            foreach (DataRow row in sheetTable.Rows)
            {
                if (executableOnly && !IsExecutableRow(row)) continue;
                string layout = Convert.ToString(row["layout"]).Trim();
                if (string.Equals(
                    layout,
                    "Model",
                    StringComparison.OrdinalIgnoreCase))
                {
                    modelSheetCount++;
                }
                else
                {
                    layoutSheetCount++;
                }
            }
        }

        private void RefreshSourceDisplayColumns()
        {
            var totals = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            var indexes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (DataRow row in sheetTable.Rows)
            {
                string drawing = Convert.ToString(row["drawing"]).Trim();
                int total;
                totals.TryGetValue(drawing, out total);
                totals[drawing] = total + 1;
            }
            foreach (DataRow row in sheetTable.Rows)
            {
                string drawing = Convert.ToString(row["drawing"]).Trim();
                int index;
                indexes.TryGetValue(drawing, out index);
                index++;
                indexes[drawing] = index;
                row["source_display"] = index == 1
                    ? Path.GetFileName(drawing)
                    : string.Empty;
                row["sheet_sequence"] = string.Format("{0}/{1}", index, totals[drawing]);
            }
        }

        private static string GetValue(string[] values, Dictionary<string, int> indexes, string name)
        {
            int index;
            if (!indexes.TryGetValue(name, out index) || index < 0 || index >= values.Length) return string.Empty;
            return values[index];
        }

        private async Task ApplyAsync()
        {
            if (busy || !ValidateInputs(true)) return;
            if (sheetTable.Rows.Count == 0)
            {
                MessageBox.Show("请先执行“① 扫描图纸”。", "尚未扫描", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            int requiresReplaceSheetCount = GetRequiresReplaceSheetCount();
            if (operationMode == OperationMode.UpdateTitle &&
                requiresReplaceSheetCount > 0)
            {
                int executableSheetCount = GetExecutableSheetCount();
                if (executableSheetCount == 0)
                {
                    DialogResult switchAnswer = MessageBox.Show(
                        string.Format(
                            "已识别 {0} 张图签，但它们全部位于 XREF 内，不能仅更新图签。\r\n\r\n是否切换到“替换图框”模式并重新扫描？",
                            requiresReplaceSheetCount
                        ),
                        "当前批次需要替换图框",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Information,
                        MessageBoxDefaultButton.Button1
                    );
                    if (switchAnswer == DialogResult.Yes)
                    {
                        SwitchToReplaceMode();
                        BeginInvoke((Action)(async () => await ScanAsync()));
                    }
                    return;
                }
                DialogResult continueAnswer = MessageBox.Show(
                    string.Format(
                        "字段表共识别 {0} 张图签，其中 {1} 张位于 XREF 内并已标记为“需切换换图框”。\r\n\r\n继续后仅更新其余 {2} 张本地可编辑图签；标记项不会生成成果文件。是否继续？",
                        sheetTable.Rows.Count,
                        requiresReplaceSheetCount,
                        executableSheetCount
                    ),
                    "部分图签当前模式不可写",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2
                );
                if (continueAnswer != DialogResult.Yes) return;
            }
            grid.EndEdit();
            int unconfirmedReviewCount = GetUnconfirmedReviewCount();
            if (unconfirmedReviewCount > 0)
            {
                if (shellHosted)
                {
                    statusLabel.Text = string.Format(
                        "还有 {0} 张待核对图签未确认，暂不允许开始处理",
                        unconfirmedReviewCount);
                    return;
                }
                DialogResult reviewAnswer = MessageBox.Show(
                    string.Format(
                                "还有 {0} 张待核对图签尚未人工确认。\r\n\r\n继续后，这些项目对应的文件将跳过并写入失败报告；其他已确认文件照常处理。是否继续？",
                        unconfirmedReviewCount),
                    "存在未确认项目",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2
                );
                if (reviewAnswer != DialogResult.Yes)
                {
                    JumpToNextReviewRow();
                    return;
                }
            }
            // 顶部统一信息在执行前必须自动写入逐张字段表，
            // 否则扫描表中的空白单元格会覆盖当前界面上的项目名和项目号。
            SyncGlobalFields();
            // 人员区是全局输入。即使用户在扫描后修改姓名但忘记点“同步”，
            // 执行前也必须以界面上当前显示的姓名和签字为准。
            SyncPersonnelFieldsToAll(false);
            WriteRecognitionIssueReport();

            string signatureError;
            if (!ValidateSignatureFiles(out signatureError))
            {
                MessageBox.Show(
                    signatureError,
                    "签字图块无效",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning
                );
                return;
            }

            if (Directory.Exists(outputBox.Text) &&
                Directory.EnumerateFileSystemEntries(outputBox.Text).Any())
            {
                string occupiedOutput = outputBox.Text;
                outputBox.Text = FindAvailableOutputDirectory(occupiedOutput);
                AppendLog("原输出目录已占用，自动改用新版本目录：" + outputBox.Text);
                statusLabel.Text = "已自动创建新版本输出目录";
            }

            bool allowPlaceholder = Regex.IsMatch(numberBox.Text, "X{3,}", RegexOptions.IgnoreCase);
            if (allowPlaceholder)
            {
                DialogResult answer = MessageBox.Show(
                    "项目号看起来仍是占位值：“" + numberBox.Text + "”。\r\n\r\n确定要按这个项目号处理全部图纸吗？",
                    "确认占位项目号",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2
                );
                if (answer != DialogResult.Yes) return;
            }

            int modelSheetCount;
            int layoutSheetCount;
            GetSheetSpaceCounts(
                out modelSheetCount,
                out layoutSheetCount,
                true
            );
            string operationExplanation = operationMode == OperationMode.ReplaceFrame
                ? "本次为【自动处理】模式：可靠匹配的图框按同一精确规格整框替换；只有本地可编辑图签而无法确认边框时，仅更新图签。"
                : "本次为【仅更新图签】模式：只更新原图签字段，不会更换任何边框。";
            if (!shellHosted)
            {
                DialogResult confirm = MessageBox.Show(
                    string.Format(
                        "{0}\r\n\r\n将处理 {1} 个源 DWG 中的 {2} 张图签（模型空间 {3} 张、布局空间 {4} 张），并插入 {5} 个签字图块。\r\n原 DWG 不会被覆盖，成果写入：\r\n{6}\r\n\r\n是否继续？",
                        operationExplanation,
                        GetExecutableSourceDrawingCount(),
                        GetExecutableSheetCount(),
                        modelSheetCount,
                        layoutSheetCount,
                        CountConfiguredSignatures(),
                        outputBox.Text
                    ),
                    "确认执行",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question,
                    MessageBoxDefaultButton.Button2
                );
                if (confirm != DialogResult.Yes) return;
            }

            SetBusy(
                true,
                    operationMode == OperationMode.ReplaceFrame
                    ? "正在自动处理图框图签…"
                    : "正在更新图签…"
            );
            SetProgress(
                0,
                    operationMode == OperationMode.ReplaceFrame
                    ? "准备自动处理"
                    : "准备更新图签"
            );
            try
            {
                string valuesPath = Path.Combine(sessionRoot, "sheet_values.tsv");
                SetProgress(3, "整理字段与签字图块");
                Dictionary<string, string> stagedSignatures = PrepareSignatureAssets();
                WriteFieldTable(valuesPath, stagedSignatures);
                SetProgress(
                    8,
                    operationMode == OperationMode.ReplaceFrame
                        ? "批量处理图框图签"
                        : "批量更新图签"
                );
                AppendLog(
                    operationMode == OperationMode.ReplaceFrame
                        ? "字段表已锁定，开始逐文件自动处理。"
                        : "字段表已锁定，开始批量更新图签。"
                );
                var args = new List<string>
                {
                    "-InputDirectory", inputBox.Text,
                    "-OutputDirectory", outputBox.Text,
                    "-建设单位", GetOptionalFieldArgument(ownerBox.Text),
                    "-设计项目名", GetOptionalFieldArgument(projectBox.Text),
                    "-出图日期", GetOptionalFieldArgument(dateBox.Text),
                    "-设计项目号", GetOptionalFieldArgument(numberBox.Text),
                    "-CoreConsolePath", coreBox.Text,
                    "-OperationMode", GetOperationModeArgument(),
                    "-SheetValuesPath", valuesPath,
                    "-MaxWorkers", "2",
                    "-Apply"
                };
                if (allowPlaceholder) args.Add("-AllowPlaceholderProjectNumber");
                int exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "run_frame_replacement.ps1"),
                    args.ToArray(),
                    8,
                    55,
                    operationMode == OperationMode.ReplaceFrame
                        ? "处理图框图签"
                        : "更新图签"
                );
                if (exit != 0)
                {
                    string batchSummary = Path.Combine(
                        outputBox.Text,
                        "logs",
                        "batch_summary.csv"
                    );
                    if (!File.Exists(batchSummary))
                    {
                        throw new InvalidOperationException(
                            (operationMode == OperationMode.ReplaceFrame
                                ? "批量处理失败，退出码："
                                : "批量更新失败，退出码：") + exit
                        );
                    }
                    AppendLog(
                        "部分图纸执行失败；继续复扫输出并逐张验收。执行报告：" +
                        batchSummary
                    );
                }

                string outputInventory = Path.Combine(sessionRoot, "output_inventory");
                Directory.CreateDirectory(outputInventory);
                SetProgress(58, "重新打开并扫描成果");
                AppendLog(
                    (operationMode == OperationMode.ReplaceFrame
                        ? "处理完成"
                        : "更新完成") +
                    "，开始独立扫描成果。"
                );
                exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "scan_all_frames.ps1"),
                    new[]
                    {
                        "-InputDirectory", outputBox.Text,
                        "-OutputDirectory", outputInventory,
                        "-CoreConsolePath", coreBox.Text,
                        "-MaxWorkers", "2"
                    },
                    58,
                    78,
                    "复扫成果"
                );
                if (exit != 0)
                {
                    string scanSummary = Path.Combine(
                        outputInventory,
                        "scan_summary.csv"
                    );
                    if (!File.Exists(scanSummary))
                    {
                        throw new InvalidOperationException(
                            "成果扫描失败且未生成逐张报告，退出码：" + exit
                        );
                    }
                    AppendLog(
                        "部分成果复扫失败；继续分析已扫描文件并由最终验收列出失败项。扫描报告：" +
                        scanSummary
                    );
                }
                SetProgress(80, "分析成果清单");
                exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "analyze_inventory.ps1"),
                    new[]
                    {
                        "-InventoryDirectory", outputInventory,
                        "-OutputCsv", Path.Combine(outputInventory, "frame_inventory.csv")
                    },
                    80,
                    86,
                    "分析成果清单"
                );
                if (exit != 0) throw new InvalidOperationException("成果清单分析失败，退出码：" + exit);

                string logsDirectory = Path.Combine(outputBox.Text, "logs");
                Directory.CreateDirectory(logsDirectory);
                string dependencyReport = Path.Combine(
                    sessionRoot,
                    "dry_run",
                    "dependency_skips.csv"
                );
                if (File.Exists(dependencyReport))
                {
                    File.Copy(
                        dependencyReport,
                        Path.Combine(logsDirectory, "dependency_skips.csv"),
                        true
                    );
                }
                string report = Path.Combine(logsDirectory, "最终验收报告.csv");
                SetProgress(88, "执行最终验收");
                exit = await RunPowerShellAsync(
                    Path.Combine(scriptsRoot, "verify_replacement.ps1"),
                    new[]
                    {
                        "-SourceInventoryCsv", Path.Combine(sessionRoot, "source_inventory", "frame_inventory.csv"),
                        "-OutputInventoryCsv", Path.Combine(outputInventory, "frame_inventory.csv"),
                        "-ReportCsv", report,
                        "-建设单位", GetOptionalFieldArgument(ownerBox.Text),
                        "-设计项目名", GetOptionalFieldArgument(projectBox.Text),
                        "-出图日期", GetOptionalFieldArgument(dateBox.Text),
                        "-设计项目号", GetOptionalFieldArgument(numberBox.Text),
                        "-SheetValuesPath", valuesPath,
                        "-PlanDirectory", Path.Combine(sessionRoot, "dry_run"),
                        "-OperationMode", GetOperationModeArgument()
                    },
                    88,
                    96,
                    "最终验收"
                );
                VerificationSummary verification = File.Exists(report)
                    ? ReadVerificationSummary(report)
                    : null;
                if (verification != null)
                {
                    MergeProcessFailures(
                        verification,
                        Path.Combine(outputBox.Text, "logs", "batch_summary.csv"),
                        "执行"
                    );
                    MergeProcessFailures(
                        verification,
                        Path.Combine(outputInventory, "scan_summary.csv"),
                        "成果复扫"
                    );
                }
                if (exit != 0)
                {
                    if (verification == null || verification.FailedFiles.Count == 0)
                    {
                        throw new InvalidOperationException(
                            "最终验收程序异常，无法生成可靠的逐张结果。请勿使用当前输出目录。"
                        );
                    }
                }

                SetProgress(98, "归档签字与验收配置");
                Dictionary<string, string> archivedSignatures =
                    ArchiveSignatureAssets(logsDirectory, stagedSignatures);
                WriteFieldTable(
                    Path.Combine(logsDirectory, "图签字段配置.tsv"),
                    archivedSignatures
                );
                if (verification != null && verification.FailedFiles.Count > 0)
                {
                    MarkFailedDrawings(verification);
                    string quarantineDirectory = QuarantineFailedOutputDrawings(
                        outputBox.Text,
                        logsDirectory,
                        verification
                    );
                    string failureList = Path.Combine(logsDirectory, "验收失败文件.txt");
                    WriteFailureList(failureList, verification, report, quarantineDirectory);
                    SetProgress(
                        100,
                        string.Format(
                            "完成：成功 {0} 个文件，失败 {1} 个文件",
                            verification.PassedMainFiles,
                            verification.FailedFiles.Count
                        )
                    );
                    statusLabel.Text = string.Format(
                        "部分完成：{0} 个文件通过；{1} 个失败成果已移出正式输出目录",
                        verification.PassedMainFiles,
                        verification.FailedFiles.Count
                    );
                    AppendLog(
                        statusLabel.Text + "。失败清单：" + failureList
                    );
                    batchCompleted = true;
                    if (!shellHosted)
                    {
                        MessageBox.Show(
                            statusLabel.Text +
                            "\r\n\r\n失败文件：\r\n" +
                            BuildFailureDisplay(verification.FailedFiles) +
                            "\r\n\r\n通过验收的文件可以继续使用；失败 DWG 已移到：" +
                            quarantineDirectory +
                            "\r\n失败项目已在表格中标红，请只对以上文件手动处理。" +
                            "\r\n完整清单：" + failureList,
                            "部分完成：请处理失败文件",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Warning
                        );
                    }
                    return;
                }
                SetProgress(
                    100,
                    (operationMode == OperationMode.ReplaceFrame
                        ? "处理完成"
                        : "图签更新完成") +
                    "，验收 0 失败"
                );
                statusLabel.Text = string.Format(
                    "完成：{0} 个源 DWG、{1} 张图签，验收 0 失败",
                    GetSourceDrawingCount(),
                    sheetTable.Rows.Count
                );
                AppendLog("全部完成，最终验收 0 失败。报告：" + report);
                batchCompleted = true;
                if (!shellHosted)
                {
                    MessageBox.Show(
                        (operationMode == OperationMode.ReplaceFrame
                            ? "图框图签处理"
                            : "图签更新") +
                        "和独立验收均已完成。\r\n\r\n" + statusLabel.Text,
                        "处理成功",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information
                    );
                }
            }
            catch (Exception ex)
            {
                statusLabel.Text = "处理失败，当前输出不得交付";
                SetProgressFailed("处理未完成");
                AppendLog("错误：" + ex.Message);
                MessageBox.Show(
                    ex.Message + "\r\n\r\n如输出目录中已有文件，请将该目录标记为“_勿用”。",
                    "处理失败",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
            finally
            {
                SetBusy(false, statusLabel.Text);
            }
        }

        private string GetRecognitionIssueReportPath()
        {
            string output = outputBox.Text.TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar
            );
            return output + "_扫描识别问题报告.txt";
        }

        private int WriteRecognitionIssueReport()
        {
            var issues = sheetTable.Rows.Cast<DataRow>()
                .Where(row =>
                    (row.Field<bool?>("review_required") == true &&
                     row.Field<bool?>("review_confirmed") != true) ||
                    string.IsNullOrWhiteSpace(Convert.ToString(row["图名"])) ||
                     string.IsNullOrWhiteSpace(Convert.ToString(row["图号"])))
                .ToList();
            string path = GetRecognitionIssueReportPath();
            if (issues.Count == 0)
            {
                if (File.Exists(path)) File.Delete(path);
                return 0;
            }
            var lines = new List<string>
            {
                "CAD图框图签助手——扫描识别问题报告",
                "错误代码：CFR-E106",
                "生成时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
                "",
                "以下图签缺少真实可读的图名或图号、正在使用文件名建议值，或只识别到可编辑图签但无法安全识别旧图框。请在字段表中修改并逐项确认；未确认项目对应的文件会跳过并记录失败，不影响其他文件。",
                "",
                "文件\t布局\t问题\t当前图号\t当前图名"
            };
            foreach (DataRow row in issues)
            {
                var missing = new List<string>();
                if (string.IsNullOrWhiteSpace(Convert.ToString(row["图名"])))
                    missing.Add("图名");
                if (string.IsNullOrWhiteSpace(Convert.ToString(row["图号"])))
                    missing.Add("图号");
                if (row.Field<bool?>("review_required") == true &&
                    row.Field<bool?>("review_confirmed") != true)
                    missing.Add(Convert.ToString(row["review_source"]));
                lines.Add(string.Format(
                    "{0}\t{1}\t{2}\t{3}\t{4}",
                    Convert.ToString(row["drawing"]),
                    Convert.ToString(row["layout"]),
                    string.Join("、", missing),
                    Convert.ToString(row["图号"]),
                    Convert.ToString(row["图名"])
                ));
            }
            lines.Add("");
            lines.Add("处理建议：点击“跳到待核对”，逐项修改并确认；无法确认的文件让程序跳过，后续人工处理。 ");
            File.WriteAllLines(path, lines, new UTF8Encoding(true));
            return issues.Count;
        }

        private static VerificationSummary ReadVerificationSummary(string reportPath)
        {
            string[] lines = File.ReadAllLines(reportPath, Encoding.UTF8);
            var summary = new VerificationSummary();
            if (lines.Length == 0) return summary;

            List<string> headers = ParseCsvLine(lines[0]);
            int fileIndex = headers.IndexOf("file");
            int modeIndex = headers.IndexOf("mode");
            int resultIndex = headers.IndexOf("result");
            int reasonIndex = headers.IndexOf("failure_reason");
            if (fileIndex < 0 || resultIndex < 0)
            {
                throw new InvalidDataException("最终验收报告缺少 file 或 result 列。");
            }

            for (int i = 1; i < lines.Length; i++)
            {
                if (string.IsNullOrWhiteSpace(lines[i])) continue;
                List<string> values = ParseCsvLine(lines[i]);
                if (fileIndex >= values.Count || resultIndex >= values.Count) continue;
                string file = values[fileIndex].Trim();
                string result = values[resultIndex].Trim();
                string mode = modeIndex >= 0 && modeIndex < values.Count
                    ? values[modeIndex].Trim()
                    : string.Empty;
                bool dependency = string.Equals(
                    mode,
                    "XrefDependencyCopy",
                    StringComparison.OrdinalIgnoreCase
                );
                if (dependency && !string.IsNullOrWhiteSpace(file))
                    summary.DependencyFileNames.Add(Path.GetFileName(file));
                if (string.Equals(result, "PASS", StringComparison.OrdinalIgnoreCase))
                {
                    if (!dependency)
                    {
                        summary.PassedMainFiles++;
                        if (!string.IsNullOrWhiteSpace(file))
                            summary.PassedMainFileNames.Add(Path.GetFileName(file));
                    }
                    continue;
                }

                if (!dependency)
                {
                    summary.FailedMainFiles++;
                    if (!string.IsNullOrWhiteSpace(file))
                    {
                        summary.FailedMainFileNames.Add(Path.GetFileName(file));
                        string reason = reasonIndex >= 0 && reasonIndex < values.Count
                            ? values[reasonIndex].Trim() : string.Empty;
                        if (string.IsNullOrWhiteSpace(reason))
                        {
                            var failures = new List<string>();
                            var checks = new[] {
                                new[] { "structure_ok", "图框/图签结构不符" },
                                new[] { "editable_fields_match", "字段写入结果不一致" },
                                new[] { "visible_personnel_ok", "人员姓名未写入可见属性" },
                                new[] { "unchanged_entities_ok", "规划外实体句柄清单变化" },
                                new[] { "signature_blocks_ok", "新签字块数量不符" },
                                new[] { "preserved_signature_blocks_ok", "保留签字块数量不符" },
                                new[] { "required_fields_ok", "图名或图号无效" },
                                new[] { "old_title_text_removed_ok", "旧图签文字或底纸残留" }
                            };
                            foreach (string[] check in checks)
                            {
                                int column = headers.IndexOf(check[0]);
                                if (column >= 0 && column < values.Count &&
                                    string.Equals(values[column], "False", StringComparison.OrdinalIgnoreCase))
                                    failures.Add(check[1]);
                            }
                            reason = failures.Count > 0 ? string.Join("；", failures)
                                : "验收未通过，报告未提供具体原因";
                        }
                        summary.FailureReasons[Path.GetFileName(file)] = reason;
                    }
                }
                summary.FailedFiles.Add(
                    dependency ? file + "（XREF 依赖）" : file
                );
            }
            return summary;
        }

        private static List<string> ParseCsvLine(string line)
        {
            var values = new List<string>();
            var value = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < line.Length; i++)
            {
                char current = line[i];
                if (current == '"')
                {
                    if (quoted && i + 1 < line.Length && line[i + 1] == '"')
                    {
                        value.Append('"');
                        i++;
                    }
                    else
                    {
                        quoted = !quoted;
                    }
                }
                else if (current == ',' && !quoted)
                {
                    values.Add(value.ToString());
                    value.Clear();
                }
                else
                {
                    value.Append(current);
                }
            }
            values.Add(value.ToString());
            return values;
        }

        private static void MergeProcessFailures(
            VerificationSummary summary,
            string csvPath,
            string stage)
        {
            if (!File.Exists(csvPath)) return;
            string[] lines = File.ReadAllLines(csvPath, Encoding.UTF8);
            if (lines.Length < 2) return;
            List<string> headers = ParseCsvLine(lines[0]);
            int fileIndex = headers.IndexOf("file");
            int statusIndex = headers.IndexOf("status");
            if (fileIndex < 0 || statusIndex < 0) return;
            for (int i = 1; i < lines.Length; i++)
            {
                if (string.IsNullOrWhiteSpace(lines[i])) continue;
                List<string> values = ParseCsvLine(lines[i]);
                if (fileIndex >= values.Count || statusIndex >= values.Count) continue;
                string file = values[fileIndex].Trim();
                string status = values[statusIndex].Trim();
                if (summary.DependencyFileNames.Contains(Path.GetFileName(file)))
                    continue;
                bool failed = stage == "执行"
                    ? string.Equals(status, "failed", StringComparison.OrdinalIgnoreCase) ||
                      string.Equals(status, "attention", StringComparison.OrdinalIgnoreCase)
                    : !string.Equals(status, "scanned", StringComparison.OrdinalIgnoreCase);
                if (!failed || string.IsNullOrWhiteSpace(file)) continue;
                if (summary.FailedFiles.Any(item =>
                    item.StartsWith(file, StringComparison.OrdinalIgnoreCase))) continue;
                string mainFileName = Path.GetFileName(file);
                if (summary.PassedMainFileNames.Remove(mainFileName) &&
                    summary.PassedMainFiles > 0)
                    summary.PassedMainFiles--;
                summary.FailedMainFiles++;
                summary.FailedMainFileNames.Add(mainFileName);
                summary.FailedFiles.Add(string.Format(
                    "{0}（{1}失败：{2}）", file, stage, status));
            }
        }

        private static string QuarantineFailedOutputDrawings(
            string outputDirectory,
            string logsDirectory,
            VerificationSummary summary)
        {
            string fullOutput = Path.GetFullPath(outputDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string parent = Path.GetDirectoryName(fullOutput);
            string outputName = Path.GetFileName(fullOutput);
            string quarantine = Path.Combine(parent, outputName + "_失败文件隔离");
            Directory.CreateDirectory(quarantine);

            var records = new List<string>
            {
                "CAD图框图签助手——失败成果隔离记录",
                "",
                "正式输出目录：" + fullOutput,
                "隔离目录：" + quarantine,
                ""
            };
            foreach (string rawName in summary.FailedMainFileNames)
            {
                string fileName = Path.GetFileName(rawName);
                if (string.IsNullOrWhiteSpace(fileName)) continue;
                string source = Path.GetFullPath(Path.Combine(fullOutput, fileName));
                if (!string.Equals(
                    Path.GetDirectoryName(source),
                    fullOutput,
                    StringComparison.OrdinalIgnoreCase))
                    continue;
                if (!File.Exists(source))
                {
                    records.Add(fileName + "：正式输出目录中不存在，无需隔离");
                    continue;
                }
                string destination = Path.Combine(quarantine, fileName);
                if (File.Exists(destination))
                {
                    string stem = Path.GetFileNameWithoutExtension(fileName);
                    string extension = Path.GetExtension(fileName);
                    destination = Path.Combine(
                        quarantine,
                        string.Format("{0}_{1:yyyyMMdd_HHmmssfff}{2}",
                            stem, DateTime.Now, extension));
                }
                File.Move(source, destination);
                records.Add(fileName + " -> " + destination);
            }
            string recordPath = Path.Combine(logsDirectory, "失败成果隔离记录.txt");
            File.WriteAllLines(recordPath, records, new UTF8Encoding(true));
            return quarantine;
        }

        private static string BuildFailureDisplay(IList<string> failedFiles)
        {
            const int displayLimit = 20;
            IEnumerable<string> visible = failedFiles
                .Take(displayLimit)
                .Select((file, index) => string.Format("{0}. {1}", index + 1, file));
            string text = string.Join("\r\n", visible);
            if (failedFiles.Count > displayLimit)
            {
                text += string.Format(
                    "\r\n……另有 {0} 张，请查看完整清单。",
                    failedFiles.Count - displayLimit
                );
            }
            return text;
        }

        private static void WriteFailureList(
            string path,
            VerificationSummary summary,
            string reportPath,
            string quarantineDirectory)
        {
            var lines = new List<string>
            {
                "CAD图框图签助手——验收失败文件",
                "",
                string.Format("通过验收：{0} 个文件", summary.PassedMainFiles),
                string.Format("需要手动处理：{0} 个文件", summary.FailedFiles.Count),
                "",
                "以下文件没有通过自动验收，请手动替换或检查；其他通过验收的文件可以继续使用："
            };
            lines.AddRange(summary.FailedFiles.Select(
                (file, index) => string.Format("{0}. {1}", index + 1, file)
            ));
            lines.Add("");
            lines.Add("失败 DWG 隔离目录：" + quarantineDirectory);
            lines.Add("详细报告：" + reportPath);
            string diagnosticPath = Path.Combine(
                Path.GetDirectoryName(path),
                "失败文件代码文档.txt"
            );
            lines.Add("可转发诊断文档：" + diagnosticPath);
            File.WriteAllLines(path, lines, new UTF8Encoding(true));
            WriteFailureDiagnostic(diagnosticPath, summary, reportPath);
        }

        private static void WriteFailureDiagnostic(
            string path,
            VerificationSummary summary,
            string reportPath)
        {
            var lines = new List<string>
            {
                "CAD图框图签助手——失败文件代码文档",
                "版本：1.5.7.0",
                "生成时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
                "",
                "把本文件连同整个 logs 文件夹发给维护人员即可，不必先发送原 DWG。",
                "",
                "错误代码说明：",
                "CFR-E001  执行或成果复扫失败，未形成可验收成果",
                "CFR-E101  图框/图签数量、句柄或位置结构不符合规划",
                "CFR-E102  规划外实体发生变化",
                "CFR-E103  新签字图块数量不符",
                "CFR-E104  XREF 中应保留的签字图块数量不符",
                "CFR-E105  图签字段与扫描表不一致",
                "CFR-E106  成果图名或图号为空、仅含标点或不可用，源图应保留并转人工处理",
                "CFR-E107  已识别的旧图名/图号文字仍残留在成果中",
                "CFR-E108  人员姓名未写入可见属性",
                "CFR-E199  验收失败，但报告未给出更具体的布尔项",
                "",
                "失败文件："
            };

            var reported = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(reportPath))
            {
                string[] reportLines = File.ReadAllLines(reportPath, Encoding.UTF8);
                if (reportLines.Length > 0)
                {
                    List<string> headers = ParseCsvLine(reportLines[0]);
                    int fileIndex = headers.IndexOf("file");
                    int resultIndex = headers.IndexOf("result");
                    var checks = new[]
                    {
                        new[] { "structure_ok", "CFR-E101" },
                        new[] { "unchanged_entities_ok", "CFR-E102" },
                        new[] { "signature_blocks_ok", "CFR-E103" },
                        new[] { "preserved_signature_blocks_ok", "CFR-E104" },
                        new[] { "editable_fields_match", "CFR-E105" },
                        new[] { "required_fields_ok", "CFR-E106" },
                        new[] { "old_title_text_removed_ok", "CFR-E107" },
                        new[] { "visible_personnel_ok", "CFR-E108" }
                    };
                    for (int i = 1; i < reportLines.Length; i++)
                    {
                        if (string.IsNullOrWhiteSpace(reportLines[i])) continue;
                        List<string> values = ParseCsvLine(reportLines[i]);
                        if (fileIndex < 0 || resultIndex < 0 ||
                            fileIndex >= values.Count || resultIndex >= values.Count ||
                            string.Equals(values[resultIndex], "PASS", StringComparison.OrdinalIgnoreCase))
                            continue;
                        string file = values[fileIndex].Trim();
                        var codes = new List<string>();
                        foreach (string[] check in checks)
                        {
                            int index = headers.IndexOf(check[0]);
                            if (index >= 0 && index < values.Count &&
                                string.Equals(values[index], "False", StringComparison.OrdinalIgnoreCase))
                                codes.Add(check[1]);
                        }
                        if (codes.Count == 0) codes.Add("CFR-E199");
                        lines.Add(string.Format("- {0} | {1}", file, string.Join(",", codes)));
                        string reason;
                        if (summary.FailureReasons.TryGetValue(Path.GetFileName(file), out reason))
                            lines.Add("  原因：" + reason);
                        reported.Add(file);
                    }
                }
            }
            foreach (string failedFile in summary.FailedFiles)
            {
                if (reported.Any(file =>
                    failedFile.StartsWith(file, StringComparison.OrdinalIgnoreCase))) continue;
                lines.Add("- " + failedFile + " | CFR-E001");
            }
            lines.Add("");
            lines.Add("原始验收报告：" + reportPath);
            File.WriteAllLines(path, lines, new UTF8Encoding(true));
        }

        private void ApplyBatchValue()
        {
            if (sheetTable.Rows.Count == 0 || batchFieldBox.SelectedItem == null) return;
            grid.EndEdit();
            var choice = batchFieldBox.SelectedItem as BatchFieldChoice;
            if (choice == null) return;
            string value = Sanitize(batchValueBox.Text);
            foreach (DataRow row in sheetTable.Rows) row[choice.Field] = value;
            statusLabel.Text = "已批量填写：" + choice.DisplayName;
        }

        private void SyncGlobalFields()
        {
            if (sheetTable.Rows.Count == 0) return;
            grid.EndEdit();
            foreach (DataRow row in sheetTable.Rows)
            {
                if (!string.IsNullOrWhiteSpace(ownerBox.Text))
                    row["建设单位"] = Sanitize(ownerBox.Text);
                if (!string.IsNullOrWhiteSpace(projectBox.Text))
                    row["设计项目名"] = Sanitize(projectBox.Text);
                if (!string.IsNullOrWhiteSpace(dateBox.Text))
                    row["日期"] = Sanitize(dateBox.Text);
                if (!string.IsNullOrWhiteSpace(numberBox.Text))
                    row["设计项目号"] = Sanitize(numberBox.Text);
                if (!string.IsNullOrWhiteSpace(subitemBox.Text))
                    row["子项名称"] = Sanitize(subitemBox.Text);
                if (!string.IsNullOrWhiteSpace(drawingTypeBox.Text))
                    row["图别"] = Sanitize(drawingTypeBox.Text);
                if (!string.IsNullOrWhiteSpace(scaleBox.Text))
                    row["比例"] = Sanitize(scaleBox.Text);
                if (!string.IsNullOrWhiteSpace(unitBox.Text))
                    row["单位"] = Sanitize(unitBox.Text);
                if (!string.IsNullOrWhiteSpace(revisionBox.Text))
                    row["版本号"] = Sanitize(revisionBox.Text);
            }
            statusLabel.Text = "已应用顶部统一信息";
        }

        private void SyncPersonnelFieldsToAll(bool updateStatus)
        {
            if (sheetTable.Rows.Count == 0) return;
            grid.EndEdit();
            foreach (DataRow row in sheetTable.Rows)
            {
                foreach (SignatureFieldDefinition signature in SignatureFields)
                {
                    TextBox nameBox;
                    TextBox signatureBox;
                    string name = personnelNameBoxes.TryGetValue(signature.TextField, out nameBox)
                        ? Sanitize(nameBox.Text)
                        : string.Empty;
                    string signaturePath =
                        personnelSignatureBoxes.TryGetValue(signature.SignatureColumn, out signatureBox)
                            ? signatureBox.Text.Trim()
                            : string.Empty;
                    if (string.Equals(name, "[清空]", StringComparison.Ordinal))
                    {
                        row[signature.TextField] = "[清空]";
                    }
                    else if (!string.IsNullOrWhiteSpace(name))
                    {
                        row[signature.TextField] = name;
                    }
                    if (!string.IsNullOrWhiteSpace(signaturePath))
                    {
                        explicitlyClearedSignatures.Remove(signature.SignatureColumn);
                        row[signature.AnchorField] = string.Empty;
                        row[signature.SignatureColumn] = signaturePath;
                    }
                    else if (explicitlyClearedSignatures.Contains(signature.SignatureColumn))
                    {
                        row[signature.AnchorField] = string.Empty;
                        row[signature.SignatureColumn] = ClearSignatureSentinel;
                    }
                }
            }
            if (updateStatus)
            {
                statusLabel.Text = "已同步全部人员姓名和签字图块";
            }
        }

        private void SyncTopFieldsToAll(bool updateStatus)
        {
            if (sheetTable.Rows.Count == 0)
            {
                if (updateStatus)
                {
                    MessageBox.Show(
                        "请先执行“① 扫描图纸”。扫描完成后也会自动应用顶部信息。",
                        "尚未扫描",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information
                    );
                }
                return;
            }
            SyncGlobalFields();
            SyncPersonnelFieldsToAll(false);
            if (updateStatus)
            {
                statusLabel.Text = "已应用顶部统一信息、人员姓名和签字图块";
            }
        }

        private void ExportFieldTable()
        {
            if (sheetTable.Rows.Count == 0)
            {
                MessageBox.Show("没有可导出的字段表，请先扫描。", "尚未扫描", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            grid.EndEdit();
            using (var dialog = new SaveFileDialog())
            {
                dialog.Filter = "制表符字段表|*.tsv";
                dialog.FileName = "图签字段配置.tsv";
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                WriteFieldTable(dialog.FileName);
                statusLabel.Text = "字段表已导出";
            }
        }

        private void ImportFieldTable()
        {
            if (sheetTable.Rows.Count == 0)
            {
                MessageBox.Show("请先扫描当前图纸，再导入字段表。", "尚未扫描", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            using (var dialog = new OpenFileDialog())
            {
                dialog.Filter = "制表符字段表|*.tsv";
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                var current = new Dictionary<string, DataRow>(StringComparer.OrdinalIgnoreCase);
                foreach (DataRow row in sheetTable.Rows)
                {
                    current[(string)row["drawing"] + "|" + (string)row["old_frame_handle"]] = row;
                }
                string[] lines = File.ReadAllLines(dialog.FileName, Encoding.UTF8);
                if (lines.Length == 0) return;
                string[] headers = lines[0].Split('\t');
                var indexes = new Dictionary<string, int>(StringComparer.Ordinal);
                for (int i = 0; i < headers.Length; i++) indexes[headers[i]] = i;
                int imported = 0;
                for (int i = 1; i < lines.Length; i++)
                {
                    string[] values = lines[i].Split('\t');
                    string key = GetValue(values, indexes, "drawing") + "|" + GetValue(values, indexes, "old_frame_handle");
                    DataRow row;
                    if (!current.TryGetValue(key, out row)) continue;
                    foreach (string column in ProxyTitleHandleColumns)
                    {
                        if (indexes.ContainsKey(column))
                            row[column] = GetValue(values, indexes, column);
                    }
                    foreach (string tag in EditableTags) row[tag] = GetValue(values, indexes, tag);
                    foreach (SignatureFieldDefinition signature in SignatureFields)
                    {
                        row[signature.SignatureColumn] =
                            GetValue(values, indexes, signature.SignatureColumn);
                    }
                    imported++;
                }
                LoadPersonnelControlsFromFirstRow();
                statusLabel.Text = string.Format("已导入 {0} 个图签的字段", imported);
            }
        }

        private void LoadPersonnelControlsFromFirstRow()
        {
            if (sheetTable.Rows.Count == 0) return;
            DataRow first = sheetTable.Rows[0];
            foreach (SignatureFieldDefinition signature in SignatureFields)
            {
                TextBox nameBox;
                if (personnelNameBoxes.TryGetValue(signature.TextField, out nameBox))
                {
                    nameBox.Text = Convert.ToString(first[signature.TextField]);
                }
                TextBox signatureBox;
                if (personnelSignatureBoxes.TryGetValue(signature.SignatureColumn, out signatureBox))
                {
                    string value = Convert.ToString(first[signature.SignatureColumn]);
                    if (string.Equals(
                        value,
                        ClearSignatureSentinel,
                        StringComparison.Ordinal))
                    {
                        signatureBox.Clear();
                        explicitlyClearedSignatures.Add(signature.SignatureColumn);
                    }
                    else
                    {
                        signatureBox.Text = value;
                        explicitlyClearedSignatures.Remove(signature.SignatureColumn);
                    }
                }
            }
        }

        private void WriteFieldTable(string path)
        {
            WriteFieldTable(path, null);
        }

        private void WriteFieldTable(string path, Dictionary<string, string> stagedSignatures)
        {
            string parent = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            using (var writer = new StreamWriter(path, false, new UTF8Encoding(false)))
            {
                writer.Write("drawing\told_frame_handle");
                foreach (string column in ProxyTitleHandleColumns)
                    writer.Write("\t" + column);
                foreach (string tag in EditableTags) writer.Write("\t" + tag);
                foreach (SignatureFieldDefinition signature in SignatureFields)
                {
                    writer.Write("\t" + signature.SignatureColumn);
                }
                writer.WriteLine();
                foreach (DataRow row in sheetTable.Rows)
                {
                    if (!IsExecutableRow(row)) continue;
                    bool xrefOverlayRow = Convert.ToString(row["scan_status"])
                        .StartsWith(
                            "已识别；可覆盖图名/图号",
                            StringComparison.Ordinal
                        );
                    writer.Write(Sanitize(Convert.ToString(row["drawing"])));
                    writer.Write("\t" + Sanitize(Convert.ToString(row["old_frame_handle"])));
                    foreach (string column in ProxyTitleHandleColumns)
                        writer.Write("\t" + Sanitize(Convert.ToString(row[column])));
                    foreach (string tag in EditableTags)
                    {
                        string value = xrefOverlayRow &&
                            tag != "图名" && tag != "图号" &&
                            tag != "设计项目名" && tag != "设计项目号"
                            ? string.Empty
                            : Sanitize(Convert.ToString(row[tag]));
                        writer.Write("\t" + value);
                    }
                    foreach (SignatureFieldDefinition signature in SignatureFields)
                    {
                        string value = xrefOverlayRow
                            ? string.Empty
                            : Sanitize(Convert.ToString(row[signature.SignatureColumn]));
                        if (stagedSignatures != null &&
                            !string.IsNullOrWhiteSpace(value) &&
                            !string.Equals(
                                value,
                                ClearSignatureSentinel,
                                StringComparison.Ordinal))
                        {
                            string staged;
                            if (!stagedSignatures.TryGetValue(Path.GetFullPath(value), out staged))
                            {
                                throw new InvalidOperationException("签字图块未完成暂存：" + value);
                            }
                            value = staged;
                        }
                        writer.Write("\t" + value);
                    }
                    writer.WriteLine();
                }
            }
        }

        private bool ValidateSignatureFiles(out string error)
        {
            var invalid = new List<string>();
            foreach (DataRow row in sheetTable.Rows)
            {
                foreach (SignatureFieldDefinition signature in SignatureFields)
                {
                    string path = Convert.ToString(row[signature.SignatureColumn]).Trim();
                    if (string.IsNullOrWhiteSpace(path) ||
                        string.Equals(
                            path,
                            ClearSignatureSentinel,
                            StringComparison.Ordinal))
                    {
                        continue;
                    }
                    if (!File.Exists(path) ||
                        !string.Equals(Path.GetExtension(path), ".dwg", StringComparison.OrdinalIgnoreCase))
                    {
                        invalid.Add(signature.DisplayName + "：" + path);
                    }
                }
            }
            invalid = invalid.Distinct(StringComparer.OrdinalIgnoreCase).Take(8).ToList();
            if (invalid.Count > 0)
            {
                error = "以下签字图块不存在或不是 DWG：\r\n\r\n" +
                    string.Join("\r\n", invalid.ToArray());
                return false;
            }
            error = string.Empty;
            return true;
        }

        private int CountConfiguredSignatures()
        {
            int count = 0;
            foreach (DataRow row in sheetTable.Rows)
            {
                foreach (SignatureFieldDefinition signature in SignatureFields)
                {
                    string value = Convert.ToString(row[signature.SignatureColumn]).Trim();
                    if (!string.IsNullOrWhiteSpace(value) &&
                        !string.Equals(
                            value,
                            ClearSignatureSentinel,
                            StringComparison.Ordinal))
                    {
                        count++;
                    }
                }
            }
            return count;
        }

        private Dictionary<string, string> PrepareSignatureAssets()
        {
            var staged = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string directory = Path.Combine(sessionRoot, "signature_assets");
            Directory.CreateDirectory(directory);
            foreach (DataRow row in sheetTable.Rows)
            {
                foreach (SignatureFieldDefinition signature in SignatureFields)
                {
                    string value = Convert.ToString(row[signature.SignatureColumn]).Trim();
                    if (string.IsNullOrWhiteSpace(value) ||
                        string.Equals(
                            value,
                            ClearSignatureSentinel,
                            StringComparison.Ordinal))
                    {
                        continue;
                    }
                    string source = Path.GetFullPath(value);
                    if (staged.ContainsKey(source)) continue;
                    string hash;
                    using (SHA256 sha = SHA256.Create())
                    using (FileStream stream = new FileStream(
                        source,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite))
                    {
                        hash = BitConverter.ToString(sha.ComputeHash(stream))
                            .Replace("-", string.Empty)
                            .Substring(0, 12);
                    }
                    string destination = Path.Combine(directory, "CFRSIG_" + hash + ".dwg");
                    File.Copy(source, destination, true);
                    staged[source] = destination;
                }
            }
            return staged;
        }

        private static Dictionary<string, string> ArchiveSignatureAssets(
            string logsDirectory,
            Dictionary<string, string> stagedSignatures)
        {
            var archived = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (stagedSignatures == null || stagedSignatures.Count == 0) return archived;
            string directory = Path.Combine(logsDirectory, "signature_assets");
            Directory.CreateDirectory(directory);
            foreach (KeyValuePair<string, string> item in stagedSignatures)
            {
                string destination = Path.Combine(directory, Path.GetFileName(item.Value));
                File.Copy(item.Value, destination, true);
                archived[item.Key] = destination;
            }
            return archived;
        }

        private static string Sanitize(string value)
        {
            return (value ?? string.Empty).Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
        }

        private async Task<int> RunPowerShellAsync(
            string script,
            string[] arguments,
            int progressStart,
            int progressEnd,
            string progressStage)
        {
            if (!File.Exists(script)) throw new FileNotFoundException("缺少处理脚本", script);
            var command = new StringBuilder();
            command.Append("-NoProfile -ExecutionPolicy Bypass -File ");
            command.Append(QuoteArgument(script));
            foreach (string argument in arguments)
            {
                command.Append(" ");
                command.Append(QuoteArgument(argument));
            }
            return await RunProcessAsync(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                command.ToString(),
                progressStart,
                progressEnd,
                progressStage
            );
        }

        private Task<int> RunProcessAsync(
            string fileName,
            string arguments,
            int progressStart,
            int progressEnd,
            string progressStage)
        {
            var completion = new TaskCompletionSource<int>();
            var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = appRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null)
                {
                    AppendLog(e.Data);
                    UpdateProgressFromProcessLine(
                        e.Data,
                        progressStart,
                        progressEnd,
                        progressStage
                    );
                }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendLog("ERR: " + e.Data);
            };
            try
            {
                if (!process.Start()) throw new InvalidOperationException("无法启动 PowerShell。");
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }
            catch
            {
                process.Dispose();
                throw;
            }
            Task.Factory.StartNew(
                delegate
                {
                    try
                    {
                        process.WaitForExit();
                        int code = process.ExitCode;
                        process.Dispose();
                        completion.TrySetResult(code);
                    }
                    catch (Exception ex)
                    {
                        process.Dispose();
                        completion.TrySetException(ex);
                    }
                },
                TaskCreationOptions.LongRunning
            );
            return completion.Task;
        }

        private void UpdateProgressFromProcessLine(
            string line,
            int progressStart,
            int progressEnd,
            string progressStage)
        {
            Match match = ProcessProgressPattern.Match(line ?? string.Empty);
            if (!match.Success) return;
            int current;
            int total;
            if (!int.TryParse(match.Groups[1].Value, out current) ||
                !int.TryParse(match.Groups[2].Value, out total) ||
                total <= 0)
            {
                return;
            }
            current = Math.Max(0, Math.Min(current, total));
            int percent = progressStart + (int)Math.Round(
                (progressEnd - progressStart) * (current / (double)total)
            );
            SetProgress(
                percent,
                string.Format("{0}（{1}/{2}）", progressStage, current, total)
            );
        }

        private static string QuoteArgument(string value)
        {
            if (value == null) return "\"\"";
            if (value.Length > 0 && !value.Any(ch => char.IsWhiteSpace(ch) || ch == '"')) return value;
            var result = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char ch in value)
            {
                if (ch == '\\')
                {
                    backslashes++;
                }
                else if (ch == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                }
                else
                {
                    result.Append('\\', backslashes);
                    backslashes = 0;
                    result.Append(ch);
                }
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private void AppendLog(string message)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), message);
                return;
            }
            logBox.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + message + Environment.NewLine);
            logBox.SelectionStart = logBox.TextLength;
            logBox.ScrollToCaret();
        }

        private void SetBusy(bool value, string status)
        {
            busy = value;
            scanButton.Enabled = !value;
            applyButton.Enabled = !value;
            nextBatchButton.Enabled = !value;
            reviewNextButton.Enabled = !value;
            confirmReviewButton.Enabled = !value;
            UseWaitCursor = value;
            statusLabel.Text = status;
        }

        private void SetProgress(int value, string stage)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<int, string>(SetProgress), value, stage);
                return;
            }
            int safeValue = Math.Max(progressBar.Minimum, Math.Min(value, progressBar.Maximum));
            progressBar.Value = safeValue;
            progressLabel.ForeColor = safeValue >= 100
                ? Color.FromArgb(170, 203, 188)
                : Color.FromArgb(183, 199, 216);
            progressLabel.Text = string.Format("{0}%  {1}", safeValue, stage);
        }

        private void SetProgressFailed(string stage)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(SetProgressFailed), stage);
                return;
            }
            progressLabel.ForeColor = Color.FromArgb(255, 154, 154);
            progressLabel.Text = string.Format("{0}%  失败：{1}", progressBar.Value, stage);
        }

        private void OpenOutput()
        {
            if (!Directory.Exists(outputBox.Text))
            {
                MessageBox.Show("输出目录尚不存在。", "没有输出", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Process.Start("explorer.exe", QuoteArgument(outputBox.Text));
        }

        // WPF shell integration. These members deliberately expose the proven
        // processing workflow without duplicating any CAD business logic.
        public async Task ShellScanDirectoryAsync(string directory)
        {
            if (busy) throw new InvalidOperationException("当前任务尚未结束。");
            LoadBatchDirectory(directory, true);
            await ScanAsync();
        }

        public async Task ShellApplyAsync()
        {
            if (busy) throw new InvalidOperationException("当前任务尚未结束。");
            await ApplyAsync();
        }

        public void ShellOpenOutput()
        {
            OpenOutput();
        }

        public DataTable ShellTable
        {
            get { return sheetTable; }
        }

        public string ShellInputDirectory
        {
            get { return inputBox.Text; }
        }

        public string ShellOutputDirectory
        {
            get { return outputBox.Text; }
        }

        public string ShellStatus
        {
            get { return statusLabel.Text; }
        }

        public string ShellLog
        {
            get { return logBox.Text; }
        }

        public int ShellProgress
        {
            get { return progressBar.Value; }
        }

        public bool ShellBusy
        {
            get { return busy; }
        }

        public int ShellUnconfirmedReviewCount
        {
            get { return GetUnconfirmedReviewCount(); }
        }

        public int ShellExecutableSheetCount
        {
            get { return GetExecutableSheetCount(); }
        }

        public string ShellOwner { get { return ownerBox.Text; } }
        public string ShellProject { get { return projectBox.Text; } }
        public string ShellSubitem { get { return subitemBox.Text; } }
        public string ShellProjectNumber { get { return numberBox.Text; } }
        public string ShellDate { get { return dateBox.Text; } }
        public string ShellRevision { get { return revisionBox.Text; } }
        public string ShellDrawingType { get { return drawingTypeBox.Text; } }
        public string ShellScale { get { return scaleBox.Text; } }
        public string ShellUnit { get { return unitBox.Text; } }

        public string ShellPersonnelName(string field)
        {
            TextBox box;
            return personnelNameBoxes.TryGetValue(field, out box) ? box.Text : string.Empty;
        }

        public string ShellSignaturePath(string signatureColumn)
        {
            TextBox box;
            return personnelSignatureBoxes.TryGetValue(signatureColumn, out box)
                ? box.Text : string.Empty;
        }

        public void ShellSetSignaturePath(string signatureColumn, string path)
        {
            SignatureFieldDefinition signature = SignatureFields.FirstOrDefault(item =>
                string.Equals(item.SignatureColumn, signatureColumn, StringComparison.Ordinal));
            if (signature == null) throw new ArgumentException("不支持的签字字段：" + signatureColumn);
            TextBox box = personnelSignatureBoxes[signatureColumn];
            if (string.IsNullOrWhiteSpace(path))
            {
                box.Text = string.Empty;
                explicitlyClearedSignatures.Add(signatureColumn);
                if (sheetTable != null)
                    foreach (DataRow row in sheetTable.Rows) row[signatureColumn] = ClearSignatureSentinel;
                return;
            }
            string fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath) || !string.Equals(Path.GetExtension(fullPath), ".dwg", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("请选择有效的签字 DWG 文件。");
            box.Text = fullPath;
            explicitlyClearedSignatures.Remove(signatureColumn);
            if (sheetTable != null)
                foreach (DataRow row in sheetTable.Rows) row[signatureColumn] = fullPath;
        }

        public void ShellSetGlobalField(string field, string value)
        {
            TextBox box = null;
            switch (field)
            {
                case "建设单位": box = ownerBox; break;
                case "设计项目名": box = projectBox; break;
                case "子项名称": box = subitemBox; break;
                case "设计项目号": box = numberBox; break;
                case "日期": box = dateBox; break;
                case "图别": box = drawingTypeBox; break;
                case "比例": box = scaleBox; break;
                case "单位": box = unitBox; break;
                case "版本号": box = revisionBox; break;
            }
            if (box == null) throw new ArgumentException("不支持的统一字段：" + field);
            box.Text = value ?? string.Empty;
        }

        public void ShellSetPersonnelName(string field, string value)
        {
            TextBox box;
            if (!personnelNameBoxes.TryGetValue(field, out box))
                throw new ArgumentException("不支持的人员字段：" + field);
            box.Text = value ?? string.Empty;
        }

        public void ShellClearPersonnelNames()
        {
            if (busy) throw new InvalidOperationException("当前任务尚未结束。");
            foreach (TextBox box in personnelNameBoxes.Values) box.Clear();
        }

        public void ShellClearGlobalFields()
        {
            if (busy) throw new InvalidOperationException("当前任务尚未结束。");
            foreach (TextBox box in new[] { ownerBox, projectBox, subitemBox,
                numberBox, dateBox, drawingTypeBox, scaleBox, unitBox, revisionBox })
                box.Clear();
        }

        public void ShellSetRowValue(int rowIndex, string field, string value)
        {
            if (sheetTable == null || rowIndex < 0 || rowIndex >= sheetTable.Rows.Count)
                throw new ArgumentOutOfRangeException("rowIndex");
            if (!sheetTable.Columns.Contains(field))
                throw new ArgumentException("不支持的图签字段：" + field);
            sheetTable.Rows[rowIndex][field] = value ?? string.Empty;
        }

        public void ShellConfirmRow(int rowIndex)
        {
            if (sheetTable == null || rowIndex < 0 || rowIndex >= sheetTable.Rows.Count)
                throw new ArgumentOutOfRangeException("rowIndex");
            DataRow row = sheetTable.Rows[rowIndex];
            string drawingName = Convert.ToString(row["图名"]).Trim();
            string drawingNumber = Convert.ToString(row["图号"]).Trim();
            if (string.IsNullOrWhiteSpace(drawingName) || string.IsNullOrWhiteSpace(drawingNumber))
                throw new InvalidOperationException("确认前必须填写图名和图号。");
            if (IsSuspiciousRecoveredDrawingNumber(drawingNumber))
                throw new InvalidOperationException("图号不能是 1、2、A 等一至两位详图/剖面标记，请填写完整图号后再确认。");
            row["review_confirmed"] = true;
            row["scan_status"] = row.Field<bool?>("title_only") == true
                ? "人工已确认；可更新图签文字"
                : "人工已确认；可处理";
            ApplyReviewRowStyles();
        }

        public void ShellCommitEditorValues()
        {
            SyncGlobalFields();
            SyncPersonnelFieldsToAll(false);
        }

        public void ShellEnableHosting()
        {
            shellHosted = true;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
        }

        public void ShellShowEditor()
        {
            ShowInTaskbar = true;
            StartPosition = FormStartPosition.CenterScreen;
            WindowState = FormWindowState.Normal;
            Location = new Point(
                Math.Max(0, (Screen.PrimaryScreen.WorkingArea.Width - Width) / 2),
                Math.Max(0, (Screen.PrimaryScreen.WorkingArea.Height - Height) / 2));
            Show();
            Activate();
        }

        public void ShellShutdown()
        {
            busy = false;
            Close();
            Dispose();
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (!busy) return;
            e.Cancel = true;
            MessageBox.Show("当前任务仍在运行，请等待完成后再关闭程序。", "正在处理", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }
}

