using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Windows.Forms;

namespace GuardianRuntime
{
    public sealed class DarkButton : Button
    {
        protected override void OnPaint(PaintEventArgs e)
        {
            if (Enabled) { base.OnPaint(e); return; }
            using (var background = new SolidBrush(Color.FromArgb(24,34,50)))
                e.Graphics.FillRectangle(background, ClientRectangle);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Color.FromArgb(100,116,139),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }
    public sealed class SshSession : IDisposable
    {
        private readonly Queue<string> errors = new Queue<string>();
        private readonly object gate = new object();
        public readonly Process Process;
        public volatile bool ErrorClosed;
        public SshSession(ProcessStartInfo info)
        {
            info.RedirectStandardError = true;
            info.RedirectStandardInput = true;
            Process = new Process { StartInfo = info };
            Process.ErrorDataReceived += OnError;
            try
            {
                if (!Process.Start()) throw new InvalidOperationException("SSH did not start");
                Process.StandardInput.Close();
                Process.BeginErrorReadLine();
            }
            catch { Process.Dispose(); throw; }
        }
        private void OnError(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null) { ErrorClosed = true; return; }
            if (e.Data.Length == 0) return;
            lock (gate)
            {
                // Bounded even when a remote endpoint floods channel errors.
                if (errors.Count >= 64) errors.Dequeue();
                errors.Enqueue(e.Data.Length > 512 ? e.Data.Substring(0, 512) : e.Data);
            }
        }
        public string[] Drain()
        {
            lock (gate) { string[] result = errors.ToArray(); errors.Clear(); return result; }
        }
        public void Dispose()
        {
            Process.ErrorDataReceived -= OnError;
            Process.Dispose();
        }
    }

    public static class Native
    {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
        [DllImport("iphlpapi.dll")]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);

        public static Dictionary<int, int> Listeners()
        {
            // TCP_TABLE_OWNER_PID_LISTENER, IPv4. Every managed bind uses 127.0.0.1.
            int size = 0;
            uint code = GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 3, 0);
            if (code != 122 && code != 0) throw new InvalidOperationException("TCP table: " + code);
            for (int attempt = 0; attempt < 3; attempt++)
            {
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    code = GetExtendedTcpTable(buffer, ref size, false, 2, 3, 0);
                    if (code == 122) continue;
                    if (code != 0) throw new InvalidOperationException("TCP table: " + code);
                    int count = Marshal.ReadInt32(buffer);
                    var result = new Dictionary<int, int>();
                    for (int i = 0; i < count; i++)
                    {
                        int offset = 4 + i * 24;
                        uint address = unchecked((uint)Marshal.ReadInt32(buffer, offset + 4));
                        if (address != 0 && address != 0x0100007f) continue;
                        int raw = Marshal.ReadInt32(buffer, offset + 8);
                        int port = ((raw & 255) << 8) | ((raw >> 8) & 255);
                        result[port] = Marshal.ReadInt32(buffer, offset + 20);
                    }
                    return result;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("TCP table changed repeatedly");
        }
    }
}
