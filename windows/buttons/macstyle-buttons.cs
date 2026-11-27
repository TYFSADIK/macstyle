// macstyle window buttons: the macOS close, minimize and zoom buttons (red, yellow, green) at the
// top left of every app window, in the WhiteSur theme's colours and symbols (themes/WhiteSur-*/labwc,
// MIT, see CREDITS.md).
//
// Windows draws its own window buttons inside each app, so these are small see-through windows
// laid over each app window, owned by it (so they stay on top of it, move, hide and minimize with
// it, and never cover another window). A click sends the window the same command its own buttons
// send. Skipped: dialogs, administrator windows (Windows does not let a normal app command them),
// full-screen windows, and the dock and top bar.
//
// Built by windows/install.ps1 with the C# compiler that ships with Windows (.NET Framework 4,
// C# 5), started at every sign-in. One copy runs per user.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace MacStyle
{
    static class N
    {
        public const int GWL_STYLE = -16, GWL_EXSTYLE = -20, GWLP_HWNDPARENT = -8;
        public const long WS_CHILD = 0x40000000, WS_CAPTION = 0x00C00000, WS_SYSMENU = 0x00080000,
            WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000, WS_DISABLED = 0x08000000;
        public const long WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_LAYERED = 0x80000,
            WS_EX_TOPMOST = 0x8;
        public const int WM_SYSCOMMAND = 0x112, WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
        public const int SC_CLOSE = 0xF060, SC_MINIMIZE = 0xF020, SC_MAXIMIZE = 0xF030, SC_RESTORE = 0xF120;
        public const uint SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOZORDER = 4, SWP_NOACTIVATE = 0x10,
            SWP_SHOWWINDOW = 0x40, SWP_HIDEWINDOW = 0x80, SWP_ASYNCWINDOWPOS = 0x4000;
        public const uint EVENT_SYSTEM_FOREGROUND = 3, EVENT_SYSTEM_MINIMIZESTART = 0x16, EVENT_SYSTEM_MINIMIZEEND = 0x17,
            EVENT_OBJECT_DESTROY = 0x8001, EVENT_OBJECT_SHOW = 0x8002, EVENT_OBJECT_HIDE = 0x8003,
            EVENT_OBJECT_LOCATIONCHANGE = 0x800B, EVENT_OBJECT_REORDER = 0x8004, EVENT_OBJECT_CLOAKED = 0x8017, EVENT_OBJECT_UNCLOAKED = 0x8018;

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int W, H; public SIZE(int w, int h) { W = w; H = h; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLEND { public byte Op, Flags, Alpha, Format; }
        [StructLayout(LayoutKind.Sequential)] public struct TRACKMOUSEEVENT { public int Size; public uint Flags; public IntPtr Window; public uint Hover; }
        [DllImport("user32.dll")] public static extern bool TrackMouseEvent(ref TRACKMOUSEEVENT t);
        [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }

        public delegate bool EnumProc(IntPtr h, IntPtr l);
        public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr h, int obj, int child, uint thread, uint time);

        [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern IntPtr GetWindowLong32(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern IntPtr SetWindowLong32(IntPtr h, int i, IntPtr v);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
        [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO i);
        [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc p, uint pid, uint tid, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref POINT pos, ref SIZE size, IntPtr src, ref POINT srcPos, int key, ref BLEND b, int flags);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int size);
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
        [DllImport("advapi32.dll")] public static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
        [DllImport("advapi32.dll")] public static extern bool GetTokenInformation(IntPtr t, int cls, out int info, int len, out int ret);

        public static long Style(IntPtr h, int i)
        {
            return (IntPtr.Size == 8 ? GetWindowLongPtr64(h, i) : GetWindowLong32(h, i)).ToInt64();
        }
        public static void SetOwner(IntPtr h, IntPtr owner)
        {
            if (IntPtr.Size == 8) SetWindowLongPtr64(h, GWLP_HWNDPARENT, owner); else SetWindowLong32(h, GWLP_HWNDPARENT, owner);
        }
        public static string ClassOf(IntPtr h)
        {
            StringBuilder s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString();
        }
        // The window as it is drawn (without the invisible resize borders)
        public static RECT Frame(IntPtr h)
        {
            RECT r; DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))); return r;
        }
        public static bool Cloaked(IntPtr h)
        {
            int v; return DwmGetWindowAttribute(h, 14, out v, 4) == 0 && v != 0;
        }
    }

    // The three buttons of one window
    class Lights : NativeWindow
    {
        // WhiteSur colours (labwc/*.svg): close, minimize, zoom; grey when the window is not in front
        static readonly Color[] Fill = { ColorTranslator.FromHtml("#e9524a"), ColorTranslator.FromHtml("#f1ae1b"), ColorTranslator.FromHtml("#59c837") };
        static readonly Color GreyDark = ColorTranslator.FromHtml("#5d5d5d"), GreyLight = ColorTranslator.FromHtml("#cecece");
        static readonly Color Symbol = Color.FromArgb(128, 0, 0, 0);

        public readonly IntPtr Target;
        public readonly bool Chromium;
        float s = 1f;
        bool hover, tracking, active, zoomed, canMin, canMax, light;
        int pressed = -1;
        bool shown;
        int lastX = int.MinValue, lastY, lastW, lastH;
        string drawn = "";

        // A plain Win32 window: see-through (layered), never on the taskbar or in Alt+Tab (tool
        // window), never taking the focus. Owned by the app window where Windows allows it (not for
        // Store apps' frames), so it also minimizes and hides with it; Update() keeps it just above
        // its window either way.
        public Lights(IntPtr target)
        {
            Target = target;
            Chromium = N.ClassOf(target) == "Chrome_WidgetWin_1";
            CreateParams cp = new CreateParams();
            cp.Caption = "macstyle window buttons";
            cp.Style = unchecked((int)0x80000000);   // WS_POPUP
            cp.ExStyle = (int)(N.WS_EX_LAYERED | N.WS_EX_TOOLWINDOW | N.WS_EX_NOACTIVATE);
            cp.Width = 1; cp.Height = 1;
            cp.Parent = target;
            try { CreateHandle(cp); } catch { }
            if (Handle == IntPtr.Zero) { cp.Parent = IntPtr.Zero; CreateHandle(cp); }
        }

        public bool Alive { get { return Handle != IntPtr.Zero; } }
        public void Close() { if (Handle != IntPtr.Zero) DestroyHandle(); }

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case N.WM_MOUSEACTIVATE: m.Result = (IntPtr)N.MA_NOACTIVATE; return;   // a click leaves the app in front as it is
                case 0x84: m.Result = (IntPtr)1; return;                              // WM_NCHITTEST: all of it is clickable
                case 0x200:                                                           // WM_MOUSEMOVE
                    if (!tracking) { N.TRACKMOUSEEVENT t = new N.TRACKMOUSEEVENT(); t.Size = Marshal.SizeOf(typeof(N.TRACKMOUSEEVENT)); t.Flags = 2; t.Window = Handle; N.TrackMouseEvent(ref t); tracking = true; }
                    if (!hover) { hover = true; Redraw(); }
                    return;
                case 0x2A3:                                                           // WM_MOUSELEAVE
                    tracking = false; hover = false; pressed = -1; Redraw(); return;
                case 0x201:                                                           // WM_LBUTTONDOWN
                    pressed = Cell(X(m.LParam)); Redraw(); return;
                case 0x202:                                                           // WM_LBUTTONUP
                    {
                        int i = Cell(X(m.LParam)), was = pressed;
                        pressed = -1; Redraw();
                        if (i >= 0 && i == was) Press(i);
                        return;
                    }
            }
            base.WndProc(ref m);
        }

        static int X(IntPtr lp) { return (short)(lp.ToInt64() & 0xFFFF); }

        int U(float v) { return (int)Math.Round(v * s); }
        int Cell(int x) { int i = (x - U(2)) / Math.Max(1, U(20)); return x < U(2) || i > 2 ? -1 : i; }

        // Place over the window's top left corner and redraw when anything changed
        public void Update(bool isActive, bool isLight)
        {
            if (!N.IsWindow(Target) || Handle == IntPtr.Zero) return;
            s = N.GetDpiForWindow(Target) / 96f;
            if (s <= 0) s = 1f;
            long st = N.Style(Target, N.GWL_STYLE);
            canMin = (st & N.WS_MINIMIZEBOX) != 0;
            canMax = (st & N.WS_MAXIMIZEBOX) != 0;
            zoomed = N.IsZoomed(Target);
            active = isActive; light = isLight;

            N.RECT f = N.Frame(Target);
            int w = U(64), h = U(24);
            // Centred on the row of the app's own window buttons, where Windows reports it;
            // Chromium browsers and apps on their tab row
            int cy = U(Chromium ? 20 : 16);
            N.RECT cb, wr;
            if (!Chromium && N.DwmGetWindowAttribute(Target, 5, out cb, Marshal.SizeOf(typeof(N.RECT))) == 0 && N.GetWindowRect(Target, out wr))
            {   // DWMWA_CAPTION_BUTTON_BOUNDS, relative to the window rectangle
                int mid = wr.T + (cb.T + cb.B) / 2 - f.T;
                if (cb.B > cb.T && mid >= U(10) && mid <= U(32)) cy = mid;
            }
            int x = f.L + U(4), y = f.T + cy - h / 2;

            string key = string.Format("{0}{1}{2}{3}{4}{5}{6}{7}{8}", s, hover, active, zoomed, canMin, canMax, light, pressed, w);
            if (key != drawn || w != lastW || h != lastH) { Draw(x, y, w, h); drawn = key; }
            else if (x != lastX || y != lastY) N.SetWindowPos(Handle, IntPtr.Zero, x, y, 0, 0, N.SWP_NOSIZE | N.SWP_NOZORDER | N.SWP_NOACTIVATE | N.SWP_ASYNCWINDOWPOS);
            // Directly above its window: being owned by a window of another app does not keep it
            // there when that app brings its window to the front, so it is put back each time
            IntPtr prev = N.GetWindow(Target, 3);   // GW_HWNDPREV
            if (prev != Handle) N.SetWindowPos(Handle, prev, 0, 0, 0, 0, N.SWP_NOMOVE | N.SWP_NOSIZE | N.SWP_NOACTIVATE | N.SWP_ASYNCWINDOWPOS);
            if (!shown) { N.SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, N.SWP_NOMOVE | N.SWP_NOSIZE | N.SWP_NOZORDER | N.SWP_NOACTIVATE | N.SWP_SHOWWINDOW); shown = true; }
            lastX = x; lastY = y; lastW = w; lastH = h;
        }

        void Draw(int x, int y, int w, int h)
        {
            using (Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(b))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.Clear(Color.FromArgb(1, 0, 0, 0));   // all but invisible, so the whole strip takes the clicks
                    float d = 12f * s, u = d / 14f, cyy = h / 2f;
                    for (int i = 0; i < 3; i++)
                    {
                        bool enabled = i == 0 || (i == 1 && canMin) || (i == 2 && canMax);
                        float cx = U(2) + U(20) * i + U(20) / 2f;
                        Color c = (active || hover) && enabled ? Fill[i] : (light ? GreyLight : GreyDark);
                        if (pressed == i && enabled) c = ControlPaint.Dark(c, 0.15f);
                        using (SolidBrush br = new SolidBrush(c)) g.FillEllipse(br, cx - d / 2, cyy - d / 2, d, d);
                        if (hover && enabled) Glyph(g, i, cx, cyy, u);
                    }
                }
                Push(b, x, y);
            }
        }

        void Glyph(Graphics g, int i, float cx, float cy, float u)
        {
            using (Pen p = new Pen(Symbol, 1.9f * u))
            using (SolidBrush br = new SolidBrush(Symbol))
            {
                p.StartCap = p.EndCap = LineCap.Round;
                if (i == 0)
                {
                    g.DrawLine(p, cx - 2.1f * u, cy - 2.1f * u, cx + 2.1f * u, cy + 2.1f * u);
                    g.DrawLine(p, cx - 2.1f * u, cy + 2.1f * u, cx + 2.1f * u, cy - 2.1f * u);
                }
                else if (i == 1)
                {
                    g.DrawLine(p, cx - 3f * u, cy, cx + 3f * u, cy);
                }
                else if (!zoomed)
                {   // two arrows pointing out (WhiteSur max_hover)
                    g.FillPolygon(br, Pts(cx, cy, u, -1.6f, -3f, 3f, 1.6f, 3f, -2f, 2f, -3f));
                    g.FillPolygon(br, Pts(cx, cy, u, -3f, -1.6f, -3f, 2f, -2f, 3f, 1.6f, 3f));
                }
                else
                {   // two arrows pointing in (WhiteSur max_toggled_hover)
                    g.FillPolygon(br, Pts(cx, cy, u, 4.2f, 0f, 0.8f, 0f, 0f, -0.8f, 0f, -4.2f));
                    g.FillPolygon(br, Pts(cx, cy, u, -4.2f, 0f, -0.8f, 0f, 0f, 0.8f, 0f, 4.2f));
                }
            }
        }

        static PointF[] Pts(float cx, float cy, float u, params float[] v)
        {
            PointF[] r = new PointF[v.Length / 2];
            for (int i = 0; i < r.Length; i++) r[i] = new PointF(cx + v[2 * i] * u, cy + v[2 * i + 1] * u);
            return r;
        }

        void Push(Bitmap b, int x, int y)
        {
            IntPtr screen = N.GetDC(IntPtr.Zero), mem = N.CreateCompatibleDC(screen), hb = IntPtr.Zero, old = IntPtr.Zero;
            try
            {
                hb = b.GetHbitmap(Color.FromArgb(0));
                old = N.SelectObject(mem, hb);
                N.POINT pos = new N.POINT(x, y), src = new N.POINT(0, 0);
                N.SIZE size = new N.SIZE(b.Width, b.Height);
                N.BLEND bl = new N.BLEND { Op = 0, Flags = 0, Alpha = 255, Format = 1 };
                N.UpdateLayeredWindow(Handle, screen, ref pos, ref size, mem, ref src, 0, ref bl, 2);
            }
            finally
            {
                if (old != IntPtr.Zero) N.SelectObject(mem, old);
                if (hb != IntPtr.Zero) N.DeleteObject(hb);
                N.DeleteDC(mem); N.ReleaseDC(IntPtr.Zero, screen);
            }
        }

        void Redraw() { drawn = ""; Update(active, light); }

        void Press(int i)
        {
            int cmd;
            if (i == 0) cmd = N.SC_CLOSE;
            else if (i == 1) { if (!canMin) return; cmd = N.SC_MINIMIZE; }
            else { if (!canMax) return; cmd = N.IsZoomed(Target) ? N.SC_RESTORE : N.SC_MAXIMIZE; }
            N.PostMessage(Target, N.WM_SYSCOMMAND, (IntPtr)cmd, IntPtr.Zero);
        }
    }

    class Manager : ApplicationContext
    {
        readonly Dictionary<IntPtr, Lights> lights = new Dictionary<IntPtr, Lights>();
        readonly Dictionary<int, bool> skipPid = new Dictionary<int, bool>();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly N.WinEventProc onEvent;   // kept here so the garbage collector leaves it alone
        readonly N.EnumProc onWindow;
        readonly List<IntPtr> found = new List<IntPtr>();
        readonly int self = Process.GetCurrentProcess().Id;
        bool light;

        static readonly HashSet<string> SkipClass = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW", "Windows.UI.Core.CoreWindow",
            "XamlExplorerHostIslandWindow", "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow",
            "ForegroundStaging", "MultitaskingViewFrame", "TaskListThumbnailWnd", "#32768", "#32770",
            "Xaml_WindowedPopupClass", "ConsoleWindowClass_Hidden", "SysShadow", "tooltips_class32" };
        static readonly HashSet<string> SkipProcess = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "seelen-ui", "slu-service", "ShellExperienceHost", "StartMenuExperienceHost", "SearchHost",
            "SearchApp", "TextInputHost", "LockApp", "ShellHost", "PowerToys.PowerLauncher", "QuickLook" };

        public Manager()
        {
            onEvent = OnEvent;
            onWindow = OnWindow;
            uint flags = 0x0002;   // out of context, not from this process
            N.SetWinEventHook(N.EVENT_SYSTEM_FOREGROUND, N.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, onEvent, 0, 0, flags);
            N.SetWinEventHook(N.EVENT_SYSTEM_MINIMIZESTART, N.EVENT_SYSTEM_MINIMIZEEND, IntPtr.Zero, onEvent, 0, 0, flags);
            N.SetWinEventHook(N.EVENT_OBJECT_DESTROY, N.EVENT_OBJECT_HIDE, IntPtr.Zero, onEvent, 0, 0, flags);
            N.SetWinEventHook(N.EVENT_OBJECT_LOCATIONCHANGE, N.EVENT_OBJECT_LOCATIONCHANGE, IntPtr.Zero, onEvent, 0, 0, flags);
            N.SetWinEventHook(N.EVENT_OBJECT_REORDER, N.EVENT_OBJECT_REORDER, IntPtr.Zero, onEvent, 0, 0, flags);
            N.SetWinEventHook(N.EVENT_OBJECT_CLOAKED, N.EVENT_OBJECT_UNCLOAKED, IntPtr.Zero, onEvent, 0, 0, flags);
            timer.Interval = 500;   // a full check twice a second, for anything the events miss
            timer.Tick += delegate { Sync(); };
            timer.Start();
            Sync();
        }

        void OnEvent(IntPtr hook, uint ev, IntPtr h, int obj, int child, uint thread, uint time)
        {
            try
            {
                if (ev == N.EVENT_OBJECT_REORDER) { Restack(); return; }   // windows changed order
                if (obj != 0 || child != 0) return;   // the window itself, not a part of it
                Lights l;
                if (ev == N.EVENT_OBJECT_LOCATIONCHANGE)
                {
                    if (lights.TryGetValue(h, out l))
                    {
                        if (Eligible(h)) l.Update(N.GetForegroundWindow() == h, light); else Sync();
                    }
                    return;
                }
                Sync();
            }
            catch (Exception e) { Program.Log(e); }
        }

        void Restack()
        {
            IntPtr fg = N.GetForegroundWindow();
            foreach (KeyValuePair<IntPtr, Lights> p in lights)
                if (p.Value.Alive) p.Value.Update(fg == p.Key, light);
        }

        bool OnWindow(IntPtr h, IntPtr l) { found.Add(h); return true; }

        void Sync()
        {
            try
            {
                object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0);
                light = v is int && (int)v == 1;
                found.Clear();
                N.EnumWindows(onWindow, IntPtr.Zero);
                IntPtr fg = N.GetForegroundWindow();
                HashSet<IntPtr> keep = new HashSet<IntPtr>();
                foreach (IntPtr h in found)
                {
                    try
                    {   // one window going wrong never stops the others
                        if (!Eligible(h)) continue;
                        keep.Add(h);
                        Lights l;
                        if (!lights.TryGetValue(h, out l) || !l.Alive)
                        {
                            l = new Lights(h);
                            lights[h] = l;
                        }
                        l.Update(fg == h, light);
                    }
                    catch (Exception e) { Program.Log(e); }
                }
                List<IntPtr> gone = new List<IntPtr>();
                foreach (KeyValuePair<IntPtr, Lights> p in lights) if (!keep.Contains(p.Key)) gone.Add(p.Key);
                foreach (IntPtr h in gone)
                {
                    Lights l = lights[h];
                    lights.Remove(h);
                    try { l.Close(); } catch (Exception e) { Program.Log(e); }
                }
            }
            catch (Exception e) { Program.Log(e); }
        }

        bool Eligible(IntPtr h)
        {
            if (!N.IsWindow(h) || !N.IsWindowVisible(h) || N.IsIconic(h) || N.Cloaked(h)) return false;
            long st = N.Style(h, N.GWL_STYLE), ex = N.Style(h, N.GWL_EXSTYLE);
            if ((st & N.WS_CHILD) != 0 || (ex & N.WS_EX_TOOLWINDOW) != 0 || (ex & N.WS_EX_NOACTIVATE) != 0) return false;
            // An app window: a system menu and a minimize or maximize button (not a dialog)
            if ((st & N.WS_SYSMENU) == 0 || (st & (N.WS_MINIMIZEBOX | N.WS_MAXIMIZEBOX)) == 0) return false;
            if (SkipClass.Contains(N.ClassOf(h))) return false;
            int pid; N.GetWindowThreadProcessId(h, out pid);
            if (pid == self || Skip(pid)) return false;
            N.RECT f = N.Frame(h);
            if (f.R - f.L < 200 || f.B - f.T < 80) return false;
            // Full screen (a video, a game, F11 in a browser): no buttons, like macOS
            N.MONITORINFO mi = new N.MONITORINFO(); mi.Size = Marshal.SizeOf(typeof(N.MONITORINFO));
            if (N.GetMonitorInfo(N.MonitorFromWindow(h, 2), ref mi) &&
                f.L <= mi.Monitor.L && f.T <= mi.Monitor.T && f.R >= mi.Monitor.R && f.B >= mi.Monitor.B) return false;
            return true;
        }

        // Shell parts, and apps running as administrator (Windows blocks commands to them from a
        // normal app, so their own buttons are the ones that work)
        bool Skip(int pid)
        {
            bool r;
            if (skipPid.TryGetValue(pid, out r)) return r;
            r = false;
            try { r = SkipProcess.Contains(Process.GetProcessById(pid).ProcessName); } catch { r = true; }
            if (!r)
            {
                IntPtr p = N.OpenProcess(0x1000, false, pid), t;   // PROCESS_QUERY_LIMITED_INFORMATION
                if (p == IntPtr.Zero) r = true;
                else
                {
                    int elevated, len;
                    if (N.OpenProcessToken(p, 0x8, out t))
                    {
                        if (N.GetTokenInformation(t, 20, out elevated, 4, out len) && elevated != 0 && !SelfElevated) r = true;
                        N.CloseHandle(t);
                    }
                    N.CloseHandle(p);
                }
            }
            if (skipPid.Count > 2000) skipPid.Clear();
            skipPid[pid] = r;
            return r;
        }

        static bool? selfElevated;
        static bool SelfElevated
        {
            get
            {
                if (selfElevated == null)
                {
                    IntPtr t; int e = 0, len;
                    if (N.OpenProcessToken(Process.GetCurrentProcess().Handle, 0x8, out t)) { N.GetTokenInformation(t, 20, out e, 4, out len); N.CloseHandle(t); }
                    selfElevated = e != 0;
                }
                return selfElevated.Value;
            }
        }
    }

    static class Program
    {
        // Errors go to %LOCALAPPDATA%\macstyle\buttons.log (kept under 64 KB)
        public static void Log(Exception e)
        {
            try
            {
                string dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "macstyle");
                if (!System.IO.Directory.Exists(dir)) return;
                string f = System.IO.Path.Combine(dir, "buttons.log");
                if (System.IO.File.Exists(f) && new System.IO.FileInfo(f).Length > 65536) System.IO.File.Delete(f);
                System.IO.File.AppendAllText(f, DateTime.Now.ToString("s") + " " + e + Environment.NewLine);
            }
            catch { }
        }

        [STAThread]
        static void Main()
        {
            bool first;
            using (Mutex m = new Mutex(true, @"Local\macstyle-window-buttons", out first))
            {
                if (!first) return;   // already running
                try { if (N.SetProcessDpiAwarenessContext((IntPtr)(-4)) == IntPtr.Zero) N.SetProcessDPIAware(); }
                catch { N.SetProcessDPIAware(); }
                Application.ThreadException += delegate(object o, ThreadExceptionEventArgs a) { Log(a.Exception); };
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.Run(new Manager());
            }
        }
    }
}
