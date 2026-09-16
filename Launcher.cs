using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Management;
using System.Threading;
using System.Windows.Forms;

namespace VpsTunnelGuardian
{
    internal static class Program
    {
        private const string AppDataFolderName = "VpsTunnelGuardianMulti";

        [STAThread]
        private static void Main()
        {
            bool acquired;
            using (var launchLock = new Mutex(true, "Local\\VpsTunnelGuardianMulti.Launch", out acquired))
            {
            if (!acquired) return;
            try
            {
                string appDataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppDataFolderName);
                // Also detect old releases which do not yet hold our UI mutex.
                using (var query = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
                using (var processes = query.Get())
                {
                    foreach (ManagementObject process in processes)
                    using (process)
                    {
                        string command = process["CommandLine"] as string;
                        if (command != null && command.IndexOf(Path.Combine(appDataDirectory, "VPS-Tunnel-Guardian.ps1"), StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            MessageBox.Show("隧道守护正在运行。请从托盘显示窗口。切换版本需先在托盘退出旧版，这会短暂断开其隧道。", "VPS Tunnel Guardian");
                            return;
                        }
                    }
                }
                Directory.CreateDirectory(appDataDirectory);
                ExtractResource("VpsTunnelGuardian.GuardianRuntime.dll", Path.Combine(appDataDirectory, "GuardianRuntime.dll"), false);
                ExtractResource("VpsTunnelGuardian.VPS-Tunnel-Guardian.ps1", Path.Combine(appDataDirectory, "VPS-Tunnel-Guardian.ps1"), false);
                ExtractResource("VpsTunnelGuardian.SshAskPass.exe", Path.Combine(appDataDirectory, "SshAskPass.exe"), false);
                ExtractResource("VpsTunnelGuardian.tunnel-logo.ico", Path.Combine(appDataDirectory, "tunnel-logo.ico"), false);
                ExtractResource("VpsTunnelGuardian.settings.json", Path.Combine(appDataDirectory, "settings.json"), true);

                string powerShellPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
                string scriptPath = Path.Combine(appDataDirectory, "VPS-Tunnel-Guardian.ps1");
                Process.Start(new ProcessStartInfo
                {
                    FileName = powerShellPath,
                    Arguments = "-NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File " + Quote(scriptPath),
                    WorkingDirectory = appDataDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
            }
            catch (Exception exception)
            {
                MessageBox.Show("VPS Tunnel Guardian could not start.\r\n\r\n" + exception.Message, "VPS Tunnel Guardian", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { launchLock.ReleaseMutex(); }
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void ExtractResource(string resourceName, string destination, bool onlyIfMissing)
        {
            if (onlyIfMissing && File.Exists(destination))
            {
                return;
            }
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
            {
                if (source == null)
                {
                    throw new InvalidOperationException("Missing embedded resource: " + resourceName);
                }
                string temporaryPath = destination + ".tmp";
                using (FileStream destinationStream = new FileStream(temporaryPath, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    source.CopyTo(destinationStream);
                }
                File.Copy(temporaryPath, destination, true);
                File.Delete(temporaryPath);
            }
        }
    }
}
