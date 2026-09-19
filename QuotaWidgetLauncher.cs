using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace QuotaWidget;

/// <summary>
/// 额度挂件的启动器。
///
/// 它做的事很简单：把内嵌的 widget.ps1 / fetch-quota.mjs / config.json
/// 释放到 %LOCALAPPDATA%\QuotaWidget，然后拉起 PowerShell 执行 widget.ps1。
/// 之所以要包一层 EXE，是为了双击启动时不会闪出黑色控制台窗口。
/// </summary>
internal static class QuotaWidgetLauncher
{
    private const string AppFolderName = "QuotaWidget";

    /// <summary>每次启动都覆盖：脚本本身没有用户数据，升级版本时要跟着换新。</summary>
    private static readonly string[] AlwaysOverwrite = { "widget.ps1", "fetch-quota.mjs" };

    /// <summary>只在缺失时释放：用户改过的配置不能被覆盖。</summary>
    private static readonly string[] KeepIfExists = { "config.json" };

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                AppFolderName);
            Directory.CreateDirectory(dir);

            foreach (string name in AlwaysOverwrite)
                Extract(name, Path.Combine(dir, name), overwrite: true);

            foreach (string name in KeepIfExists)
                Extract(name, Path.Combine(dir, name), overwrite: false);

            string script = Path.Combine(dir, "widget.ps1");
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"",
                WorkingDirectory = dir,
                UseShellExecute = false,
                CreateNoWindow = true,
            };

            // 传给脚本，让它知道该把开机自启快捷方式指向哪个 EXE
            psi.EnvironmentVariables["QUOTA_WIDGET_LAUNCHER"] = Assembly.GetExecutingAssembly().Location;

            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动额度挂件失败：\r\n\r\n" + ex.Message, "额度挂件",
                MessageBoxButtons.OK, MessageBoxIcon.Hand);
            return 1;
        }
    }

    /// <summary>把嵌入资源释放到目标路径。</summary>
    private static void Extract(string resourceName, string targetPath, bool overwrite)
    {
        if (!overwrite && File.Exists(targetPath))
            return;

        Assembly asm = Assembly.GetExecutingAssembly();
        string fullName = "QuotaWidget." + resourceName;

        using Stream stream = asm.GetManifestResourceStream(fullName);
        if (stream == null)
            throw new IOException("内嵌资源缺失: " + fullName);

        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        File.WriteAllBytes(targetPath, buffer.ToArray());
    }
}
