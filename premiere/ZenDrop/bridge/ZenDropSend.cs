// Zen Drop bridge.
//
// Listary (or anything else outside Premiere) runs this with a file path. It
// forwards the path to the Zen Drop panel's loopback listener and exits.
//
// The port and the focus setting come from the SAME settings.json the panel
// writes, so changing the port in the panel needs no change here.
//
// Usage:
//   ZenDropSend.exe "C:\path\to\file.mp4"            use the panel's current mode
//   ZenDropSend.exe "C:\path\to\file.mp4" --source   force Source Monitor
//   ZenDropSend.exe "C:\path\to\file.mp4" --timeline force straight to timeline
//   ZenDropSend.exe --place                          place what is in the Source Monitor
//   ...--port 47821                                  override the port
//   ...--quiet                                       never show an error box

using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal static class ZenDropSend
{
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    private const int SW_RESTORE = 9;

    private static string SettingsFile()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(Path.Combine(Path.Combine(appData, "Zengane"), "Zen Drop"), "settings.json");
    }

    // Deliberately crude: two scalars out of a flat file beats dragging in a
    // JSON library for a stub that has to stay a single self-contained exe.
    private static string ReadRaw(string json, string key)
    {
        Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*(\"[^\"]*\"|[^,}\\s]+)");
        if (!m.Success) return null;
        string v = m.Groups[1].Value.Trim();
        if (v.StartsWith("\"") && v.EndsWith("\"") && v.Length >= 2) v = v.Substring(1, v.Length - 2);
        return v;
    }

    private static void FocusPremiere()
    {
        try
        {
            foreach (Process p in Process.GetProcesses())
            {
                if (!p.ProcessName.StartsWith("Adobe Premiere Pro", StringComparison.OrdinalIgnoreCase)) continue;
                if (p.MainWindowHandle == IntPtr.Zero) continue;
                // SW_RESTORE un-maximizes a maximized window, so only send it to
                // a window that is actually minimized. Otherwise just raise it.
                if (IsIconic(p.MainWindowHandle)) ShowWindowAsync(p.MainWindowHandle, SW_RESTORE);
                SetForegroundWindow(p.MainWindowHandle);
                return;
            }
        }
        catch { }
    }

    private static int Main(string[] args)
    {
        string path = null;
        string mode = null;
        int port = 0;
        bool quiet = false;
        bool placeOnly = false;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (a.Equals("--source", StringComparison.OrdinalIgnoreCase)) mode = "source";
            else if (a.Equals("--timeline", StringComparison.OrdinalIgnoreCase)) mode = "timeline";
            else if (a.Equals("--place", StringComparison.OrdinalIgnoreCase)) placeOnly = true;
            else if (a.Equals("--quiet", StringComparison.OrdinalIgnoreCase)) quiet = true;
            else if (a.Equals("--port", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                int.TryParse(args[++i], out port);
            }
            else if (path == null) path = a;
        }

        bool focus = true;
        try
        {
            string file = SettingsFile();
            if (File.Exists(file))
            {
                string json = File.ReadAllText(file);
                if (port == 0)
                {
                    string rawPort = ReadRaw(json, "port");
                    if (rawPort != null) int.TryParse(rawPort, out port);
                }
                string rawFocus = ReadRaw(json, "focusPremiere");
                if (rawFocus != null) focus = rawFocus.Equals("true", StringComparison.OrdinalIgnoreCase);
            }
        }
        catch { }

        if (port == 0) port = 47821;

        string url;
        if (placeOnly)
        {
            url = "http://127.0.0.1:" + port + "/place";
        }
        else
        {
            if (string.IsNullOrEmpty(path))
            {
                Fail(quiet, "Zen Drop: no file was given.");
                return 2;
            }
            path = Path.GetFullPath(path);
            if (!File.Exists(path))
            {
                Fail(quiet, "Zen Drop: file not found:\n" + path);
                return 3;
            }
            url = "http://127.0.0.1:" + port + "/drop?path=" + Uri.EscapeDataString(path);
            if (mode != null) url += "&mode=" + mode;
        }

        try
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = 8000;
            req.Method = "GET";
            using (HttpWebResponse res = (HttpWebResponse)req.GetResponse())
            {
                using (StreamReader sr = new StreamReader(res.GetResponseStream()))
                {
                    sr.ReadToEnd();
                }
            }
        }
        catch (WebException ex)
        {
            string detail = ex.Message;
            HttpWebResponse r = ex.Response as HttpWebResponse;
            if (r != null)
            {
                using (StreamReader sr = new StreamReader(r.GetResponseStream())) detail = sr.ReadToEnd();
            }
            Fail(quiet, "Zen Drop could not reach Premiere on port " + port + ".\n\n" +
                        "Open the Zen Drop panel in Premiere (Window > Extensions > Zen Drop).\n\n" + detail);
            return 4;
        }
        catch (Exception ex)
        {
            Fail(quiet, "Zen Drop: " + ex.Message);
            return 5;
        }

        if (focus) FocusPremiere();
        return 0;
    }

    private static void Fail(bool quiet, string msg)
    {
        if (quiet) return;
        MessageBox.Show(msg, "Zen Drop", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
