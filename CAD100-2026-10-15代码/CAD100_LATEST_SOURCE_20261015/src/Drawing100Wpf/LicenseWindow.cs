using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CadFrameReplacer;

namespace Drawing100WpfPreview
{
    internal static class LicenseStartup
    {
        public static bool Authorize()
        {
            LicenseResult cached = LicenseClient.ValidateCached(true);
            if (cached.Success) return true;

            var window = new LicenseWindow(cached.Message);
            bool? result = window.ShowDialog();
            return result == true;
        }
    }

    internal sealed class LicenseWindow : Window
    {
        private readonly TextBox nameBox;
        private readonly PasswordBox codeBox;
        private readonly TextBlock statusText;
        private readonly Button activateButton;

        public LicenseWindow(string initialMessage)
        {
            Title = "出图100% · 软件激活";
            Width = 440;
            Height = 480;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = new SolidColorBrush(Color.FromRgb(16, 20, 24));
            Foreground = Brushes.White;
            FontFamily = new FontFamily("Microsoft YaHei UI");

            var root = new Grid { Margin = new Thickness(34, 30, 34, 28) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            var title = new TextBlock
            {
                Text = "出图100%",
                FontSize = 28,
                FontWeight = FontWeights.Bold,
                Margin = new Thickness(0, 0, 0, 6)
            };
            root.Children.Add(title);

            var subtitle = new TextBlock
            {
                Text = "首次使用需要绑定本机。每位授权用户最多绑定 2 台电脑。",
                Foreground = new SolidColorBrush(Color.FromRgb(190, 198, 205)),
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 22)
            };
            Grid.SetRow(subtitle, 1);
            root.Children.Add(subtitle);

            var form = new StackPanel();
            form.Children.Add(Label("姓名"));
            nameBox = InputBox();
            form.Children.Add(nameBox);
            form.Children.Add(Label("激活码"));
            codeBox = new PasswordBox
            {
                Height = 40,
                FontSize = 16,
                Padding = new Thickness(10, 7, 10, 7),
                Margin = new Thickness(0, 6, 0, 14),
                Background = new SolidColorBrush(Color.FromRgb(29, 36, 42)),
                Foreground = Brushes.White,
                BorderBrush = new SolidColorBrush(Color.FromRgb(70, 82, 92)),
                BorderThickness = new Thickness(1)
            };
            form.Children.Add(codeBox);
            Grid.SetRow(form, 2);
            root.Children.Add(form);

            statusText = new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(initialMessage) ? "请输入授权信息。" : initialMessage,
                Foreground = new SolidColorBrush(Color.FromRgb(214, 176, 94)),
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                MinHeight = 34,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 0, 12)
            };
            Grid.SetRow(statusText, 3);
            root.Children.Add(statusText);

            activateButton = new Button
            {
                Content = "激活并进入",
                Height = 44,
                FontWeight = FontWeights.SemiBold,
                FontSize = 14,
                Background = new SolidColorBrush(Color.FromRgb(92, 126, 156)),
                Foreground = Brushes.White,
                BorderThickness = new Thickness(0),
                Margin = new Thickness(0, 0, 0, 18)
            };
            activateButton.Click += ActivateClicked;
            Grid.SetRow(activateButton, 4);
            root.Children.Add(activateButton);

            var devicePanel = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(21, 27, 32)),
                BorderBrush = new SolidColorBrush(Color.FromRgb(46, 56, 64)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12, 10, 12, 10),
                VerticalAlignment = VerticalAlignment.Bottom
            };

            var device = new TextBlock
            {
                Text = "当前设备  " + LicenseClient.DeviceName + "\n设备 ID  " + ShortId(LicenseClient.DeviceId),
                Foreground = new SolidColorBrush(Color.FromRgb(139, 151, 161)),
                FontSize = 11,
                LineHeight = 18,
                TextWrapping = TextWrapping.Wrap
            };
            devicePanel.Child = device;
            Grid.SetRow(devicePanel, 5);
            root.Children.Add(devicePanel);

            Content = root;
            Loaded += delegate { nameBox.Focus(); };
        }

        private async void ActivateClicked(object sender, RoutedEventArgs e)
        {
            activateButton.IsEnabled = false;
            statusText.Text = "正在验证授权…";
            string name = nameBox.Text;
            string code = codeBox.Password;

            LicenseResult result = await System.Threading.Tasks.Task.Run(delegate
            {
                return LicenseClient.Activate(name, code);
            });

            if (result.Success)
            {
                statusText.Foreground = new SolidColorBrush(Color.FromRgb(111, 199, 137));
                statusText.Text = "授权成功：" + result.Name + "（设备 " + result.DevicesUsed + "/" + result.DevicesLimit + "）";
                DialogResult = true;
                Close();
                return;
            }

            statusText.Foreground = new SolidColorBrush(Color.FromRgb(226, 98, 98));
            statusText.Text = result.Message;
            activateButton.IsEnabled = true;
        }

        private static TextBlock Label(string text)
        {
            return new TextBlock
            {
                Text = text,
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(205, 211, 216)),
                Margin = new Thickness(0, 4, 0, 0)
            };
        }

        private static TextBox InputBox()
        {
            return new TextBox
            {
                Height = 40,
                FontSize = 15,
                Padding = new Thickness(10, 7, 10, 7),
                Margin = new Thickness(0, 6, 0, 14),
                Background = new SolidColorBrush(Color.FromRgb(29, 36, 42)),
                Foreground = Brushes.White,
                BorderBrush = new SolidColorBrush(Color.FromRgb(70, 82, 92)),
                BorderThickness = new Thickness(1)
            };
        }

        private static string ShortId(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return "unknown";
            return id.Length <= 16 ? id : id.Substring(0, 8) + "…" + id.Substring(id.Length - 8);
        }
    }
}
