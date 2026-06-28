# ============================================================================
#  ISS PISS-O-METER  —  launcher
#  A lightweight Windows system-tray gauge for the ISS urine tank fill level,
#  driven by NASA's public ISS live telemetry feed (Lightstreamer, ISSLIVE
#  adapter set, item NODE3000005 = "Urine Tank Qty", in percent).
#
#  Runs as a PowerShell script hosted by the Microsoft-signed pwsh.exe, so it
#  works under Smart App Control without any compiled/unsigned binary on disk.
#  The UI + telemetry are implemented in C#, compiled in-memory via Add-Type.
# ============================================================================
$ErrorActionPreference = 'Stop'

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// ---------------------------------------------------------------------------
//  Telemetry client: keeps a live Lightstreamer streaming session open on a
//  background thread and exposes the latest urine-tank percentage.
// ---------------------------------------------------------------------------
public sealed class PissTracker
{
    const string Server = "https://push.lightstreamer.com";
    const string Cid = "mgQkwtwdysogQz2BJ4Ji kOj2Bg"; // standard public client id
    const string Item = "NODE3000005";                // Urine Tank Qty (%)

    public volatile bool HasData;
    public double Percent;            // 0..100
    public DateTime LastUpdateLocal;
    public volatile string Conn = "connecting";

    static readonly HttpClient _http = new HttpClient() { Timeout = Timeout.InfiniteTimeSpan };

    Thread _thread;
    volatile bool _stop;
    volatile IDisposable _currentResp;
    readonly ManualResetEvent _wake = new ManualResetEvent(false);

    public void Start()
    {
        _thread = new Thread(Run); _thread.IsBackground = true; _thread.Name = "PissTelemetry";
        _thread.Start();
    }

    public void Stop()
    {
        _stop = true; _wake.Set();
        try { var r = _currentResp; if (r != null) r.Dispose(); } catch { }
        try { if (_thread != null) _thread.Join(2000); } catch { }
    }

    public void RefreshNow() { _wake.Set(); }

    void Run()
    {
        int backoff = 2;
        while (!_stop)
        {
            try { Conn = "connecting"; Session(); backoff = 2; }
            catch (Exception ex) { Conn = "offline (" + Short(ex.Message) + ")"; }
            if (_stop) break;
            _wake.WaitOne(TimeSpan.FromSeconds(backoff));
            _wake.Reset();
            backoff = Math.Min(backoff * 2, 30);
        }
    }

    static string Short(string s)
    {
        if (string.IsNullOrEmpty(s)) return "?";
        s = s.Replace("\r", " ").Replace("\n", " ");
        return s.Length > 40 ? s.Substring(0, 40) : s;
    }

    static StringContent Form(string s)
    {
        var c = new StringContent(s, Encoding.ASCII);
        c.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/x-www-form-urlencoded");
        return c;
    }

    void Session()
    {
        string body = "LS_cid=" + Uri.EscapeDataString(Cid)
            + "&LS_adapter_set=ISSLIVE&LS_send_sync=false&LS_polling=false";
        var req = new HttpRequestMessage(HttpMethod.Post,
            Server + "/lightstreamer/create_session.txt?LS_protocol=TLCP-2.1.0");
        req.Content = Form(body);

        var resp = _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
        _currentResp = resp;
        using (resp)
        using (var stream = resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
        using (var reader = new StreamReader(stream, Encoding.UTF8))
        {
            string sessionId = null, controlLink = Server;
            for (int i = 0; i < 30 && sessionId == null; i++)
            {
                string line = reader.ReadLine();
                if (line == null) return;
                if (line.StartsWith("CONOK,"))
                {
                    var p = line.Split(',');
                    sessionId = p[1];
                    if (p.Length > 4 && p[4] != "*" && p[4].Length > 0)
                        controlLink = "https://" + p[4];
                }
                else if (line.StartsWith("CONERR")) throw new Exception("refused " + line);
            }
            if (sessionId == null) throw new Exception("no session");
            Conn = "live";

            string ctrl = "LS_session=" + Uri.EscapeDataString(sessionId)
                + "&LS_op=add&LS_subId=1&LS_reqId=1&LS_mode=MERGE"
                + "&LS_group=" + Item
                + "&LS_schema=" + Uri.EscapeDataString("TimeStamp Value")
                + "&LS_data_adapter=DEFAULT&LS_snapshot=true&LS_requested_max_frequency=1";
            var creq = new HttpRequestMessage(HttpMethod.Post,
                controlLink + "/lightstreamer/control.txt?LS_protocol=TLCP-2.1.0");
            creq.Content = Form(ctrl);
            using (var cts = new CancellationTokenSource(15000))
            using (var cresp = _http.SendAsync(creq, HttpCompletionOption.ResponseContentRead, cts.Token).GetAwaiter().GetResult())
                cresp.Content.ReadAsStringAsync().GetAwaiter().GetResult();

            var fields = new string[2];
            while (!_stop)
            {
                string line = reader.ReadLine();
                if (line == null) return;
                if (line.Length == 0) continue;
                if (line[0] == 'U' && line.StartsWith("U,"))
                {
                    var parts = line.Split(new char[] { ',' }, 4);
                    if (parts.Length == 4)
                    {
                        ApplyDelta(fields, parts[3]);
                        double v;
                        if (fields[1] != null &&
                            double.TryParse(fields[1], NumberStyles.Any, CultureInfo.InvariantCulture, out v))
                        {
                            Percent = Math.Max(0, Math.Min(100, v));
                            LastUpdateLocal = DateTime.Now;
                            HasData = true;
                        }
                    }
                }
                else if (line.StartsWith("LOOP") || line.StartsWith("END")) return;
            }
        }
    }

    static void ApplyDelta(string[] last, string payload)
    {
        var parts = payload.Split('|');
        int idx = 0;
        foreach (var f in parts)
        {
            if (idx >= last.Length) break;
            if (f.Length == 0) { idx++; continue; }
            if (f[0] == '^') { int n; if (int.TryParse(f.Substring(1), out n)) idx += n; continue; }
            if (f == "#") { last[idx] = null; idx++; continue; }
            if (f == "$") { last[idx] = ""; idx++; continue; }
            try { last[idx] = Uri.UnescapeDataString(f); } catch { last[idx] = f; }
            idx++;
        }
    }
}

// ---------------------------------------------------------------------------
//  Shared rendering of the piss tank (used by both the tray icon and popup).
// ---------------------------------------------------------------------------
public static class TankArt
{
    public static Color Liquid(double pct)
    {
        return pct >= 95 ? Color.FromArgb(214, 170, 0)
             : pct >= 80 ? Color.FromArgb(230, 188, 12)
             :             Color.FromArgb(242, 208, 39);
    }

    public static Color Accent(double pct)
    {
        return pct >= 95 ? Color.FromArgb(229, 57, 53)
             : pct >= 80 ? Color.FromArgb(255, 152, 0)
             : pct >= 60 ? Color.FromArgb(255, 213, 79)
             :             Color.FromArgb(124, 214, 120);
    }

    public static string Status(double pct, bool hasData)
    {
        if (!hasData) return "AWAITING SIGNAL";
        return pct >= 95 ? "CRITICAL - FLUSH!"
             : pct >= 80 ? "DUMP SOON"
             : pct >= 60 ? "FILLING UP"
             :             "NOMINAL";
    }

    public static void DrawTank(Graphics g, RectangleF r, double pct, bool hasData, float outlineW, bool gloss)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float capH = r.Height * 0.12f;
        float capW = r.Width * 0.34f;
        var bodyTop = r.Top + capH;
        var body = new RectangleF(r.Left, bodyTop, r.Width, r.Height - capH);
        float radius = Math.Min(body.Width, body.Height) * 0.18f;

        var cap = new RectangleF(r.Left + (r.Width - capW) / 2f, r.Top, capW, capH + radius * 0.6f);
        using (var capBrush = new SolidBrush(Color.FromArgb(90, 96, 104)))
        using (var capPath = Rounded(cap, capH * 0.45f))
            g.FillPath(capBrush, capPath);

        using (var bodyPath = Rounded(body, radius))
        {
            using (var bg = new SolidBrush(Color.FromArgb(38, 42, 48)))
                g.FillPath(bg, bodyPath);

            double p = Math.Max(0, Math.Min(100, pct));
            if (hasData && p > 0)
            {
                float fillH = (float)(body.Height * p / 100.0);
                var fillRect = new RectangleF(body.Left, body.Bottom - fillH, body.Width, fillH);
                var old = g.Clip;
                g.SetClip(bodyPath, CombineMode.Replace);
                Color liq = Liquid(p);
                using (var lb = new LinearGradientBrush(
                    new RectangleF(fillRect.Left, fillRect.Top - 1, fillRect.Width, fillRect.Height + 2),
                    ControlPaint.Light(liq), liq, LinearGradientMode.Vertical))
                    g.FillRectangle(lb, fillRect);
                using (var pen = new Pen(ControlPaint.LightLight(liq), Math.Max(1f, outlineW * 0.7f)))
                    g.DrawLine(pen, fillRect.Left, fillRect.Top, fillRect.Right, fillRect.Top);
                g.Clip = old;
            }

            if (gloss)
            {
                var gloss1 = new RectangleF(body.Left + body.Width * 0.12f, body.Top + body.Height * 0.06f,
                                            body.Width * 0.18f, body.Height * 0.8f);
                using (var gp = Rounded(gloss1, gloss1.Width / 2f))
                using (var gb = new SolidBrush(Color.FromArgb(38, 255, 255, 255)))
                    g.FillPath(gb, gp);
            }

            using (var pen = new Pen(Color.FromArgb(225, 225, 230), outlineW))
                g.DrawPath(pen, bodyPath);
        }
    }

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        float d = radius * 2f;
        var path = new GraphicsPath();
        if (d <= 0) { path.AddRectangle(r); return path; }
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

// ---------------------------------------------------------------------------
//  Detailed popup window shown when the tray icon is clicked.
// ---------------------------------------------------------------------------
public sealed class PissPopup : Form
{
    readonly PissTracker _t;
    public PissPopup(PissTracker t)
    {
        _t = t;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(250, 400);
        BackColor = Color.FromArgb(24, 26, 30);
        DoubleBuffered = true;
        KeyPreview = true;
        TopMost = true;
    }

    public void ShowNearTray()
    {
        var wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Right - Width - 12, wa.Bottom - Height - 12);
        Show(); Activate(); Invalidate();
    }

    protected override void OnDeactivate(EventArgs e) { Hide(); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Hide(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        bool has = _t.HasData;
        double pct = _t.Percent;
        Color accent = TankArt.Accent(pct);

        using (var pen = new Pen(accent, 2))
            g.DrawRectangle(pen, 1, 1, Width - 3, Height - 3);

        using (var title = new Font("Segoe UI", 13f, FontStyle.Bold))
        using (var sub = new Font("Segoe UI", 8f))
        using (var white = new SolidBrush(Color.White))
        using (var gray = new SolidBrush(Color.FromArgb(150, 154, 160)))
        {
            var sf = new StringFormat(); sf.Alignment = StringAlignment.Center;
            g.DrawString("ISS PISS-O-METER", title, white, new RectangleF(0, 12, Width, 26), sf);
            g.DrawString("Urine Tank  -  NODE3000005", sub, gray, new RectangleF(0, 38, Width, 16), sf);
        }

        var tankRect = new RectangleF(Width / 2f - 55, 64, 110, 200);
        TankArt.DrawTank(g, tankRect, pct, has, 2.2f, true);

        using (var tickPen = new Pen(Color.FromArgb(70, 74, 80), 1))
        using (var tickFont = new Font("Segoe UI", 7f))
        using (var tickBrush = new SolidBrush(Color.FromArgb(130, 134, 140)))
        {
            float bodyTop = tankRect.Top + tankRect.Height * 0.12f;
            float bodyH = tankRect.Height - tankRect.Height * 0.12f;
            for (int q = 0; q <= 100; q += 25)
            {
                float y = bodyTop + bodyH * (1 - q / 100f);
                g.DrawLine(tickPen, tankRect.Right + 4, y, tankRect.Right + 10, y);
                g.DrawString(q + "%", tickFont, tickBrush, tankRect.Right + 12, y - 7);
            }
        }

        using (var big = new Font("Segoe UI", 34f, FontStyle.Bold))
        using (var br = new SolidBrush(Color.White))
        {
            var sf = new StringFormat(); sf.Alignment = StringAlignment.Center;
            string txt = has ? Math.Round(pct).ToString("0") + "%" : "--";
            g.DrawString(txt, big, br, new RectangleF(0, 274, Width, 50), sf);
        }

        string status = TankArt.Status(pct, has);
        using (var sFont = new Font("Segoe UI", 10f, FontStyle.Bold))
        {
            var size = g.MeasureString(status, sFont);
            var pill = new RectangleF((Width - size.Width - 24) / 2f, 330, size.Width + 24, 26);
            using (var pb = new SolidBrush(Color.FromArgb(40, accent)))
            using (var path = RoundedRect(pill, 13))
                g.FillPath(pb, path);
            using (var pen = new Pen(accent, 1.4f))
            using (var path = RoundedRect(pill, 13))
                g.DrawPath(pen, path);
            using (var tb = new SolidBrush(accent))
            {
                var sf = new StringFormat(); sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                g.DrawString(status, sFont, tb, pill, sf);
            }
        }

        using (var f = new Font("Segoe UI", 7.5f))
        using (var br = new SolidBrush(Color.FromArgb(120, 124, 130)))
        {
            string when = _t.HasData ? _t.LastUpdateLocal.ToString("HH:mm:ss") : "--:--:--";
            string foot = "feed: " + _t.Conn + "   -   updated " + when;
            var sf = new StringFormat(); sf.Alignment = StringAlignment.Center;
            g.DrawString(foot, f, br, new RectangleF(0, 366, Width, 16), sf);
        }
    }

    static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        float d = radius * 2f;
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

// ---------------------------------------------------------------------------
//  Tray application context: NotifyIcon, menu, popup, and the UI timer.
// ---------------------------------------------------------------------------
public sealed class PissContext : ApplicationContext
{
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);

    readonly PissTracker _tracker = new PissTracker();
    readonly NotifyIcon _ni = new NotifyIcon();
    readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer();
    PissPopup _popup;

    Icon _lastIcon;
    double _renderedPct = -999;
    bool _renderedHas;

    public PissContext()
    {
        _popup = new PissPopup(_tracker);
        var h = _popup.Handle; // force handle creation while hidden

        var menu = new ContextMenuStrip();
        menu.Items.Add("ISS PISS-O-METER").Enabled = false;
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Show gauge", null, delegate { TogglePopup(); });
        menu.Items.Add("Refresh now", null, delegate { _tracker.RefreshNow(); });
        var startup = new ToolStripMenuItem("Start with Windows", null, OnToggleStartup);
        startup.Checked = IsStartupEnabled();
        menu.Items.Add(startup);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { ExitApp(); });

        _ni.Text = "ISS PISS-O-METER - connecting...";
        _ni.ContextMenuStrip = menu;
        _ni.Visible = true;
        _ni.Icon = RenderTrayIcon(0, false);
        _ni.MouseClick += OnIconClick;

        _tracker.Start();

        _timer.Interval = 1000;
        _timer.Tick += delegate { Refresh(); };
        _timer.Start();
    }

    void OnIconClick(object s, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) TogglePopup();
    }

    void TogglePopup()
    {
        if (_popup.Visible) _popup.Hide();
        else _popup.ShowNearTray();
    }

    void Refresh()
    {
        bool has = _tracker.HasData;
        double pct = _tracker.Percent;

        string tip = has
            ? "ISS PISS-O-METER - " + Math.Round(pct).ToString("0") + "% (" + TankArt.Status(pct, true) + ")"
            : "ISS PISS-O-METER - " + _tracker.Conn;
        if (tip.Length > 63) tip = tip.Substring(0, 63);
        _ni.Text = tip;

        if (has != _renderedHas || Math.Abs(pct - _renderedPct) >= 0.5)
        {
            _ni.Icon = RenderTrayIcon(pct, has);
            _renderedPct = pct; _renderedHas = has;
        }

        if (_popup.Visible) _popup.Invalidate();
    }

    Icon RenderTrayIcon(double pct, bool hasData)
    {
        const int S = 32;
        using (var bmp = new Bitmap(S, S))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                TankArt.DrawTank(g, new RectangleF(5, 2, 22, 28), pct, hasData, 1.6f, false);
            }
            IntPtr hicon = bmp.GetHicon();
            var icon = (Icon)Icon.FromHandle(hicon).Clone();
            DestroyIcon(hicon);
            if (_lastIcon != null) _lastIcon.Dispose();
            _lastIcon = icon;
            return icon;
        }
    }

    // ---- Start-with-Windows via a shortcut in the user's Startup folder ----
    static string StartupCmdPath()
    {
        string dir = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
        return Path.Combine(dir, "IssPissOMeter.cmd");
    }

    static bool IsStartupEnabled() { try { return File.Exists(StartupCmdPath()); } catch { return false; } }

    void OnToggleStartup(object sender, EventArgs e)
    {
        var item = sender as ToolStripMenuItem;
        try
        {
            string p = StartupCmdPath();
            if (File.Exists(p)) { File.Delete(p); if (item != null) item.Checked = false; }
            else
            {
                string content = "@echo off\r\nstart \"\" /min \"" + PissApp.PwshPath
                    + "\" -NoProfile -WindowStyle Hidden -File \"" + PissApp.ScriptPath + "\"\r\n";
                File.WriteAllText(p, content);
                if (item != null) item.Checked = true;
            }
        }
        catch (Exception ex) { MessageBox.Show("Couldn't change startup setting:\n" + ex.Message); }
    }

    void ExitApp()
    {
        _timer.Stop();
        _tracker.Stop();
        _ni.Visible = false;
        _ni.Dispose();
        if (_lastIcon != null) _lastIcon.Dispose();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try { _ni.Dispose(); } catch { }
            try { _popup.Dispose(); } catch { }
            try { _timer.Dispose(); } catch { }
        }
        base.Dispose(disposing);
    }
}

// ---------------------------------------------------------------------------
//  Entry point. PowerShell sets ScriptPath/PwshPath, then calls Run(), which
//  hosts the WinForms message loop on a dedicated STA thread.
// ---------------------------------------------------------------------------
public static class PissApp
{
    public static string ScriptPath = "";
    public static string PwshPath = "";

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    public static void Run()
    {
        var t = new Thread(ThreadMain);
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = false;
        t.Start();
        t.Join();
    }

    static void ThreadMain()
    {
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var ctx = new PissContext())
            Application.Run(ctx);
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies @(
    'System.Windows.Forms',
    'System.Windows.Forms.Primitives',
    'System.Drawing.Common',
    'System.Drawing.Primitives',
    'System.Private.Windows.Core',
    'System.Net.Http',
    'System.Net.Primitives',
    'System.Threading.Thread',
    'System.Threading',
    'System.ComponentModel.Primitives',
    'System.ObjectModel',
    'System.Collections',
    'System.Runtime',
    'netstandard'
)

[PissApp]::ScriptPath = $PSCommandPath
[PissApp]::PwshPath   = (Get-Process -Id $PID).Path
[PissApp]::Run()
