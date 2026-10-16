using System;
using System.Configuration;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Drawing100WpfPreview
{
    [DataContract]
    internal sealed class UpdateInfo
    {
        [DataMember(Name = "success")] public bool Success { get; set; }
        [DataMember(Name = "available")] public bool Available { get; set; }
        [DataMember(Name = "version")] public string Version { get; set; }
        [DataMember(Name = "required")] public bool Required { get; set; }
        [DataMember(Name = "notes")] public string Notes { get; set; }
        [DataMember(Name = "download_url")] public string DownloadUrl { get; set; }
        [DataMember(Name = "sha256")] public string Sha256 { get; set; }
        [DataMember(Name = "size")] public long Size { get; set; }
        [DataMember(Name = "published_at")] public string PublishedAt { get; set; }
    }

    internal static class UpdateStartup
    {
        public const string CurrentVersion = "__CAD100_APP_VERSION__";

        // Return true to continue opening CAD-100. Return false when the app
        // should exit because an update has been launched or is mandatory.
        public static bool CheckAndMaybeUpdate()
        {
            UpdateInfo info;
            try
            {
                info = UpdateClient.GetLatest();
            }
            catch
            {
                // Update checks must never prevent an authorized user from
                // working when the update service is temporarily unavailable.
                return true;
            }

            if (info == null || !info.Success || !info.Available || string.IsNullOrWhiteSpace(info.Version))
                return true;
            if (CompareVersions(info.Version, CurrentVersion) <= 0)
                return true;

            var dialog = new UpdateWindow(info, CurrentVersion);
            bool? install = dialog.ShowDialog();
            if (install == true)
            {
                string error;
                if (UpdateClient.DownloadAndLaunchUpdater(info, out error))
                    return false;

                MessageBox.Show(
                    "更新下载或启动失败：\n" + error,
                    "CAD-100 更新失败",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return !info.Required;
            }

            return !info.Required;
        }

        private static int CompareVersions(string left, string right)
        {
            int[] a = ParseVersion(left);
            int[] b = ParseVersion(right);
            for (int i = 0; i < 4; i++)
            {
                if (a[i] != b[i]) return a[i].CompareTo(b[i]);
            }
            return 0;
        }

        private static int[] ParseVersion(string value)
        {
            var result = new[] { 0, 0, 0, 0 };
            if (string.IsNullOrWhiteSpace(value)) return result;
            string clean = value.Trim();
            int dash = clean.IndexOf('-');
            if (dash >= 0) clean = clean.Substring(0, dash);
            string[] parts = clean.Split('.');
            for (int i = 0; i < result.Length && i < parts.Length; i++)
            {
                int parsed;
                if (int.TryParse(parts[i], out parsed) && parsed >= 0) result[i] = parsed;
            }
            return result;
        }
    }

    internal static class UpdateClient
    {
        public static UpdateInfo GetLatest()
        {
            string apiBase = GetApiBaseUrl();
            if (string.IsNullOrWhiteSpace(apiBase)) return null;

            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            string url = apiBase.TrimEnd('/') + "/api/v1/update/latest";
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.Accept = "application/json";
            request.UserAgent = "CAD-100/" + UpdateStartup.CurrentVersion;
            request.Timeout = 3500;
            request.ReadWriteTimeout = 3500;

            using (var response = (HttpWebResponse)request.GetResponse())
            using (var stream = response.GetResponseStream())
            {
                if (stream == null) return null;
                var serializer = new DataContractJsonSerializer(typeof(UpdateInfo));
                return serializer.ReadObject(stream) as UpdateInfo;
            }
        }

        public static bool DownloadAndLaunchUpdater(UpdateInfo info, out string error)
        {
            error = string.Empty;
            try
            {
                string apiBase = GetApiBaseUrl();
                if (string.IsNullOrWhiteSpace(apiBase))
                {
                    error = "更新服务器地址未配置。";
                    return false;
                }
                if (info == null || string.IsNullOrWhiteSpace(info.DownloadUrl))
                {
                    error = "服务器未提供更新包地址。";
                    return false;
                }

                string downloadUrl = info.DownloadUrl.Trim();
                if (!downloadUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                    !downloadUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                {
                    if (!downloadUrl.StartsWith("/")) downloadUrl = "/" + downloadUrl;
                    downloadUrl = apiBase.TrimEnd('/') + downloadUrl;
                }

                string tempRoot = Path.Combine(Path.GetTempPath(), "CAD100-Update");
                Directory.CreateDirectory(tempRoot);
                string safeVersion = SafeFilePart(info.Version);
                string packagePath = Path.Combine(tempRoot, "CAD-100-" + safeVersion + ".zip");

                DownloadFile(downloadUrl, packagePath);
                if (!string.IsNullOrWhiteSpace(info.Sha256))
                {
                    string actual = Sha256File(packagePath);
                    if (!string.Equals(actual, info.Sha256.Trim(), StringComparison.OrdinalIgnoreCase))
                    {
                        TryDelete(packagePath);
                        error = "更新包完整性校验失败，请重新尝试。";
                        return false;
                    }
                }

                string installDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string updaterSource = Path.Combine(installDir, "CAD100Updater.exe");
                if (!File.Exists(updaterSource))
                {
                    error = "缺少 CAD100Updater.exe，请先安装支持自动更新的版本。";
                    return false;
                }

                string updaterTemp = Path.Combine(tempRoot, "CAD100Updater-" + Guid.NewGuid().ToString("N") + ".exe");
                File.Copy(updaterSource, updaterTemp, true);

                string args =
                    "--package " + Quote(packagePath) +
                    " --target " + Quote(installDir) +
                    " --exe " + Quote("CAD-100.exe") +
                    " --pid " + Process.GetCurrentProcess().Id.ToString() +
                    " --sha " + Quote(info.Sha256 ?? string.Empty);

                var start = new ProcessStartInfo
                {
                    FileName = updaterTemp,
                    Arguments = args,
                    WorkingDirectory = tempRoot,
                    UseShellExecute = true
                };
                Process.Start(start);
                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        private static void DownloadFile(string url, string path)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.UserAgent = "CAD-100/" + UpdateStartup.CurrentVersion;
            request.Timeout = 15000;
            request.ReadWriteTimeout = 120000;
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var input = response.GetResponseStream())
            using (var output = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                if (input == null) throw new IOException("更新服务器未返回文件内容。");
                byte[] buffer = new byte[64 * 1024];
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                    output.Write(buffer, 0, read);
            }
        }

        private static string Sha256File(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                byte[] hash = sha.ComputeHash(stream);
                var sb = new StringBuilder(hash.Length * 2);
                for (int i = 0; i < hash.Length; i++) sb.Append(hash[i].ToString("x2"));
                return sb.ToString();
            }
        }

        private static string GetApiBaseUrl()
        {
            try
            {
                return (ConfigurationManager.AppSettings["LicenseApiBaseUrl"] ?? string.Empty).Trim();
            }
            catch
            {
                return string.Empty;
            }
        }

        private static string SafeFilePart(string value)
        {
            string result = string.IsNullOrWhiteSpace(value) ? "update" : value.Trim();
            foreach (char c in Path.GetInvalidFileNameChars()) result = result.Replace(c, '_');
            return result;
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }

    internal sealed class UpdateWindow : Window
    {
        public UpdateWindow(UpdateInfo info, string currentVersion)
        {
            Title = "CAD-100 · 软件更新";
            Width = 470;
            Height = 420;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = Brushes.White;
            Foreground = new SolidColorBrush(Color.FromRgb(20, 20, 22));
            FontFamily = new FontFamily("Microsoft YaHei UI");

            var root = new Grid { Margin = new Thickness(30) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var title = new TextBlock
            {
                Text = info.Required ? "需要更新后继续使用" : "发现新版本",
                FontSize = 25,
                FontWeight = FontWeights.Bold
            };
            root.Children.Add(title);

            var version = new TextBlock
            {
                Text = "当前版本 " + currentVersion + "   →   新版本 " + info.Version,
                FontSize = 13,
                Foreground = new SolidColorBrush(Color.FromRgb(105, 105, 110)),
                Margin = new Thickness(0, 8, 0, 18)
            };
            Grid.SetRow(version, 1);
            root.Children.Add(version);

            var notes = new TextBox
            {
                Text = string.IsNullOrWhiteSpace(info.Notes) ? "本次版本包含功能改进和稳定性优化。" : info.Notes,
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                BorderBrush = new SolidColorBrush(Color.FromRgb(225, 225, 228)),
                Background = new SolidColorBrush(Color.FromRgb(248, 248, 250)),
                Padding = new Thickness(14),
                FontSize = 13,
                Margin = new Thickness(0, 0, 0, 18)
            };
            Grid.SetRow(notes, 2);
            root.Children.Add(notes);

            var buttons = new Grid();
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var later = new Button
            {
                Content = info.Required ? "退出程序" : "稍后更新",
                Height = 42,
                Background = new SolidColorBrush(Color.FromRgb(242, 242, 244)),
                Foreground = new SolidColorBrush(Color.FromRgb(35, 35, 38)),
                BorderThickness = new Thickness(0),
                FontWeight = FontWeights.SemiBold
            };
            later.Click += delegate { DialogResult = false; Close(); };
            buttons.Children.Add(later);

            var install = new Button
            {
                Content = "立即更新",
                Height = 42,
                Background = new SolidColorBrush(Color.FromRgb(20, 20, 22)),
                Foreground = Brushes.White,
                BorderThickness = new Thickness(0),
                FontWeight = FontWeights.SemiBold
            };
            install.Click += delegate { DialogResult = true; Close(); };
            Grid.SetColumn(install, 2);
            buttons.Children.Add(install);

            Grid.SetRow(buttons, 3);
            root.Children.Add(buttons);
            Content = root;
        }
    }
}
