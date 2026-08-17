using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace VpsTunnelGuardian
{
    internal static class Program
    {
        private const string AppDataFolderName = "VpsTunnelGuardian";

        [STAThread]
        private static void Main()
        {
            try
            {
                string appDataDirectory = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    AppDataFolderName);
                Directory.CreateDirectory(appDataDirectory);

                ExtractResource("VpsTunnelGuardian.VPS-Tunnel-Guardian.ps1", Path.Combine(appDataDirectory, "VPS-Tunnel-Guardian.ps1"), false);
                ExtractResource("VpsTunnelGuardian.tunnel-logo.ico", Path.Combine(appDataDirectory, "tunnel-logo.ico"), false);
                ExtractResource("VpsTunnelGuardian.settings.json", Path.Combine(appDataDirectory, "settings.json"), true);

                string powerShellPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell\\v1.0\\powershell.exe");
                string scriptPath = Path.Combine(appDataDirectory, "VPS-Tunnel-Guardian.ps1");
                Process.Start(new ProcessStartInfo
                {
                    FileName = powerShellPath,
                    Arguments = "-NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(scriptPath),
                    WorkingDirectory = appDataDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "VPS Tunnel Guardian could not start.\r\n\r\n" + exception.Message,
                    "VPS Tunnel Guardian",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
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
