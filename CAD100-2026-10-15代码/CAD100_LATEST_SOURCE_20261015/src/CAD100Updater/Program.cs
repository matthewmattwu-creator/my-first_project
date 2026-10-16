using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace CAD100Updater
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string package = Arg(args, "--package");
                string target = Arg(args, "--target");
                string exe = Arg(args, "--exe");
                string sha = Arg(args, "--sha");
                int pid;
                if (!int.TryParse(Arg(args, "--pid"), out pid)) pid = 0;

                if (string.IsNullOrWhiteSpace(package) || !File.Exists(package))
                    throw new InvalidOperationException("更新包不存在。");
                if (string.IsNullOrWhiteSpace(target) || !Directory.Exists(target))
                    throw new InvalidOperationException("程序目录不存在。");
                if (string.IsNullOrWhiteSpace(exe)) exe = "CAD-100.exe";

                if (!string.IsNullOrWhiteSpace(sha))
                {
                    string actual = Sha256File(package);
                    if (!string.Equals(actual, sha.Trim(), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("更新包 SHA256 校验失败。");
                }

                WaitForProcessExit(pid, 30);

                string stage = Path.Combine(Path.GetTempPath(), "CAD100-Stage-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(stage);
                try
                {
                    ZipFile.ExtractToDirectory(package, stage);
                    string sourceRoot = ResolvePackageRoot(stage);
                    CopyTree(sourceRoot, target);
                }
                finally
                {
                    TryDeleteDirectory(stage);
                    TryDeleteFile(package);
                }

                string appPath = Path.Combine(target, exe);
                if (!File.Exists(appPath))
                    throw new InvalidOperationException("更新完成，但未找到主程序：" + appPath);

                Process.Start(new ProcessStartInfo
                {
                    FileName = appPath,
                    WorkingDirectory = target,
                    UseShellExecute = true
                });
                return 0;
            }
            catch (Exception ex)
            {
                try
                {
                    string log = Path.Combine(Path.GetTempPath(), "CAD100-Updater-error.txt");
                    File.WriteAllText(log, DateTime.Now.ToString("s") + Environment.NewLine + ex, Encoding.UTF8);
                }
                catch { }
                return 1;
            }
        }

        private static string Arg(string[] args, string key)
        {
            for (int i = 0; i < args.Length - 1; i++)
                if (string.Equals(args[i], key, StringComparison.OrdinalIgnoreCase))
                    return args[i + 1];
            return string.Empty;
        }

        private static void WaitForProcessExit(int pid, int seconds)
        {
            if (pid <= 0) return;
            try
            {
                var process = Process.GetProcessById(pid);
                if (!process.HasExited) process.WaitForExit(seconds * 1000);
            }
            catch { }
            Thread.Sleep(500);
        }

        private static string ResolvePackageRoot(string stage)
        {
            if (File.Exists(Path.Combine(stage, "CAD-100.exe"))) return stage;
            string[] dirs = Directory.GetDirectories(stage);
            if (dirs.Length == 1 && File.Exists(Path.Combine(dirs[0], "CAD-100.exe"))) return dirs[0];
            throw new InvalidOperationException("更新包结构不正确，根目录必须包含 CAD-100.exe。");
        }

        private static void CopyTree(string source, string target)
        {
            foreach (string directory in Directory.GetDirectories(source, "*", SearchOption.AllDirectories))
            {
                string relative = directory.Substring(source.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                Directory.CreateDirectory(Path.Combine(target, relative));
            }

            foreach (string file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
            {
                string relative = file.Substring(source.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string destination = Path.Combine(target, relative);
                string parent = Path.GetDirectoryName(destination);
                if (!string.IsNullOrWhiteSpace(parent)) Directory.CreateDirectory(parent);
                CopyWithRetry(file, destination, 30);
            }
        }

        private static void CopyWithRetry(string source, string destination, int attempts)
        {
            Exception last = null;
            for (int i = 0; i < attempts; i++)
            {
                try
                {
                    File.Copy(source, destination, true);
                    return;
                }
                catch (Exception ex)
                {
                    last = ex;
                    Thread.Sleep(500);
                }
            }
            throw new IOException("无法替换文件：" + destination, last);
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

        private static void TryDeleteDirectory(string path)
        {
            try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { }
        }

        private static void TryDeleteFile(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }
}
