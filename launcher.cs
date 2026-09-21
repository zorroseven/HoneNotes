using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Hone Notes: a single self-installing exe.
// - Run from anywhere (e.g. Downloads): copies itself to %LOCALAPPDATA%\Programs\HoneNotes, adds
//   Desktop + Start menu shortcuts, and starts the installed copy (replacing an older running one).
// - Run from the install folder: writes the built-in index.html next to itself, opens it in
//   Edge/Chrome app mode, and stays in the tray so "Copy report" can put screenshots on the clipboard
//   as real image files and paste notes + each screenshot with a single Ctrl+V.
static class HoneNotes
{
    const int Port = 47831;
    static readonly string BaseUrl = "http://localhost:" + Port + "/";
    static readonly string MutexName = "HoneNotesHelper-" + Environment.UserName;
    static readonly string InstallDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "HoneNotes");
    static readonly string InstalledExe = Path.Combine(InstallDir, "HoneNotes.exe");
    static readonly string PagePath = Path.Combine(InstallDir, "index.html");
    static readonly string DevMarker = Path.Combine(InstallDir, "dev-source.txt");

    static string token;
    static SynchronizationContext ui;
    static ClipWindow win;
    static string pendingText;
    static StringCollection pendingFiles;
    static System.Windows.Forms.Timer expiry;
    static uint ownClipboardSeq;

    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);

    const int StepDelayMs = 400;
    static readonly string LogFile = Path.Combine(Path.GetTempPath(), "HoneNotes", "helper.log");

    static void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogFile));
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 512 * 1024) File.Delete(LogFile);
            File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + line + Environment.NewLine);
        }
        catch { }
    }

    [STAThread]
    static void Main(string[] args)
    {
        bool openBrowser = true, silent = false;
        string fixedToken = null;
        foreach (string a in args)
        {
            if (a == "--no-browser") openBrowser = false;
            else if (a == "--silent") silent = true;
            else if (a.StartsWith("--token=")) fixedToken = a.Substring(8);
        }

        // Test mode (--no-browser) runs in place; everything else goes through the install folder
        if (openBrowser && !SamePath(Application.ExecutablePath, InstalledExe))
        {
            Install(silent);
            return;
        }

        bool firstInstance;
        using (var mutex = new Mutex(true, MutexName, out firstInstance))
        {
            if (!firstInstance)
            {
                // Already running in the tray: ask it to open the window (it holds the session key)
                if (openBrowser)
                {
                    try { using (var wc = new WebClient()) wc.DownloadString(BaseUrl + "open"); }
                    catch { LaunchBrowser(null); }
                }
                return;
            }

            token = fixedToken ?? Guid.NewGuid().ToString("N");
            Application.EnableVisualStyles();
            win = new ClipWindow();
            ui = new WindowsFormsSynchronizationContext();
            win.HotkeyPressed = OnPasteHotkey;
            win.ClipboardChanged = () =>
            {
                // You copied something else, so don't hijack your next Ctrl+V
                if (pendingFiles != null && GetClipboardSequenceNumber() != ownClipboardSeq) Disarm();
            };

            var listener = new HttpListener();
            listener.Prefixes.Add(BaseUrl);
            try { listener.Start(); }
            catch
            {
                if (openBrowser) LaunchBrowser(null);
                return;
            }
            var thread = new Thread(() => Serve(listener));
            thread.IsBackground = true;
            thread.Start();

            var tray = new NotifyIcon();
            tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            tray.Text = "Hone Notes";
            var menu = new ContextMenuStrip();
            menu.Items.Add("Open Hone Notes", null, (s, e) => LaunchBrowser(token));
            menu.Items.Add("Quit", null, (s, e) => Application.Exit());
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += (s, e) => LaunchBrowser(token);
            tray.Visible = true;

            if (openBrowser) LaunchBrowser(token);
            Application.Run();

            Disarm();
            tray.Visible = false;
            tray.Dispose();
            listener.Close();
        }
    }

    /* ---------- install / update ---------- */

    static bool SamePath(string a, string b)
    {
        return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    }

    static void Install(bool silent)
    {
        bool fresh = !File.Exists(InstalledExe);
        StopRunningCopy();

        Exception error = null;
        for (int i = 0; i < 20; i++)
        {
            try
            {
                Directory.CreateDirectory(InstallDir);
                // Copy the bytes (not the file) so the "downloaded from the internet" mark isn't carried over
                File.WriteAllBytes(InstalledExe, File.ReadAllBytes(Application.ExecutablePath));
                error = null;
                break;
            }
            catch (Exception ex)
            {
                error = ex;
                Thread.Sleep(250);
            }
        }
        if (error != null)
        {
            MessageBox.Show("Couldn't install Hone Notes:\n\n" + error.Message, "Hone Notes", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Hone Notes.lnk"));
        CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Hone Notes.lnk"));
        Log(fresh ? "Installed to " + InstallDir : "Updated " + InstallDir);

        if (fresh && !silent)
        {
            MessageBox.Show("Hone Notes is installed.\n\nOpen it any time from the Hone Notes icon on your desktop or in the Start menu.",
                "Hone Notes", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        Process.Start(InstalledExe);
    }

    // An older copy may be running in the tray and locking the exe: ask it to quit and wait for it
    static void StopRunningCopy()
    {
        Mutex existing;
        if (!Mutex.TryOpenExisting(MutexName, out existing)) return;
        existing.Dispose();
        try { using (var wc = new WebClient()) wc.UploadString(BaseUrl + "quit", ""); } catch { }
        for (int i = 0; i < 40; i++)
        {
            Thread.Sleep(150);
            if (!Mutex.TryOpenExisting(MutexName, out existing)) return;
            existing.Dispose();
        }
    }

    static void CreateShortcut(string lnkPath)
    {
        try
        {
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            object shell = Activator.CreateInstance(shellType);
            object lnk = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
            Type lnkType = lnk.GetType();
            lnkType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { InstalledExe });
            lnkType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { InstallDir });
            lnkType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { InstalledExe + ",0" });
            lnkType.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { "Hone Notes" });
            lnkType.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
            Marshal.ReleaseComObject(lnk);
            Marshal.ReleaseComObject(shell);
        }
        catch (Exception ex)
        {
            Log("Shortcut failed (" + lnkPath + "): " + ex.Message);
        }
    }

    // A dev-source.txt next to the exe holds the path of a checkout to take index.html from,
    // so editing the page there is live on the next open with no rebuild. build.ps1 writes it.
    // Anywhere else the file is absent and the page built into the exe is used.
    static string DevPage()
    {
        try
        {
            if (!File.Exists(DevMarker)) return null;
            string dir = File.ReadAllText(DevMarker).Trim().Trim('"');
            if (dir.Length == 0) return null;
            string page = Path.Combine(dir, "index.html");
            return File.Exists(page) ? page : null;
        }
        catch { return null; }
    }

    // The app page is built into the exe; keep the copy on disk in sync with it
    static void ExtractPage()
    {
        try
        {
            byte[] bytes;
            string dev = DevPage();
            if (dev != null)
            {
                bytes = File.ReadAllBytes(dev);
            }
            else
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("HoneNotes.index.html"))
                using (var ms = new MemoryStream())
                {
                    s.CopyTo(ms);
                    bytes = ms.ToArray();
                }
            }
            if (File.Exists(PagePath) && SameBytes(File.ReadAllBytes(PagePath), bytes)) return;
            Directory.CreateDirectory(InstallDir);
            File.WriteAllBytes(PagePath, bytes);
        }
        catch (Exception ex)
        {
            Log("Couldn't write index.html: " + ex.Message);
        }
    }

    static bool SameBytes(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    static void LaunchBrowser(string key)
    {
        ExtractPage(); // picks up an edited dev source without a rebuild
        if (!File.Exists(PagePath))
        {
            MessageBox.Show("Hone Notes couldn't find its app page.\nPlease run the Hone Notes download again.", "Hone Notes");
            return;
        }
        string url = new Uri(PagePath).AbsoluteUri + (key != null ? "#k=" + key : "");

        string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] browsers = {
            Path.Combine(pf86, @"Microsoft\Edge\Application\msedge.exe"),
            Path.Combine(pf, @"Microsoft\Edge\Application\msedge.exe"),
            Path.Combine(pf, @"Google\Chrome\Application\chrome.exe"),
            Path.Combine(pf86, @"Google\Chrome\Application\chrome.exe"),
            Path.Combine(local, @"Google\Chrome\Application\chrome.exe"),
        };
        foreach (string exe in browsers)
        {
            if (File.Exists(exe))
            {
                Process.Start(exe, "--app=\"" + url + "\"");
                return;
            }
        }
        Process.Start(new Uri(PagePath).AbsoluteUri);
    }

    /* ---------- local HTTP endpoint used by the page ---------- */

    static void Serve(HttpListener listener)
    {
        while (true)
        {
            HttpListenerContext c;
            try { c = listener.GetContext(); }
            catch { return; }
            try { Handle(c); }
            catch (Exception ex)
            {
                try { Reply(c, 500, "{\"ok\":false,\"error\":" + new JavaScriptSerializer().Serialize(ex.Message) + "}"); }
                catch { }
            }
        }
    }

    static void Handle(HttpListenerContext c)
    {
        string path = c.Request.Url.AbsolutePath;
        string origin = c.Request.Headers["Origin"];
        if (c.Request.HttpMethod == "OPTIONS") { Reply(c, 204, null); return; }
        if (path == "/open")
        {
            ui.Post(_ => LaunchBrowser(token), null);
            Reply(c, 200, "{\"ok\":true}");
            return;
        }
        if (path == "/quit" && c.Request.HttpMethod == "POST" && origin == null)
        {
            // Sent by a newer Hone Notes exe that wants to replace this one (browsers always send Origin)
            Reply(c, 200, "{\"ok\":true}");
            ui.Post(_ => Application.Exit(), null);
            return;
        }
        if (path != "/copy" || c.Request.HttpMethod != "POST") { Reply(c, 404, "{\"ok\":false,\"error\":\"not found\"}"); return; }

        // Only the Hone Notes page (a local file, so Origin "null") holding this session's key may use it
        if (origin != null && origin != "null") { Reply(c, 403, "{\"ok\":false,\"error\":\"origin\"}"); return; }
        string body;
        using (var reader = new StreamReader(c.Request.InputStream, Encoding.UTF8)) body = reader.ReadToEnd();
        var json = new JavaScriptSerializer();
        json.MaxJsonLength = int.MaxValue;
        var req = json.Deserialize<CopyRequest>(body);
        if (req == null || req.token != token) { Reply(c, 403, "{\"ok\":false,\"error\":\"token\"}"); return; }

        string text = req.text ?? "";
        var images = req.images ?? new List<ImageData>();
        if (images.Count == 0 && text.Trim().Length == 0) { Reply(c, 400, "{\"ok\":false,\"error\":\"empty\"}"); return; }
        var files = WriteImages(images);
        bool both = false;
        ui.Send(_ => both = Arm(text, files), null);
        Reply(c, 200, "{\"ok\":true,\"images\":" + files.Count + ",\"both\":" + (both ? "true" : "false") + "}");
    }

    static void Reply(HttpListenerContext c, int status, string json)
    {
        var res = c.Response;
        res.StatusCode = status;
        res.AddHeader("Access-Control-Allow-Origin", "*");
        res.AddHeader("Access-Control-Allow-Headers", "Content-Type");
        res.AddHeader("Access-Control-Allow-Private-Network", "true");
        if (json != null)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(json);
            res.ContentType = "application/json";
            res.ContentLength64 = bytes.Length;
            res.OutputStream.Write(bytes, 0, bytes.Length);
        }
        res.Close();
    }

    static StringCollection WriteImages(List<ImageData> images)
    {
        string root = Path.Combine(Path.GetTempPath(), "HoneNotes");
        Directory.CreateDirectory(root);
        foreach (string old in Directory.GetDirectories(root))
        {
            try { Directory.Delete(old, true); } catch { }
        }
        string dir = Path.Combine(root, DateTime.Now.Ticks.ToString());
        Directory.CreateDirectory(dir);
        var list = new StringCollection();
        for (int i = 0; i < images.Count; i++)
        {
            string file = Path.Combine(dir, "screenshot-" + (i + 1) + SafeExt(images[i].name));
            File.WriteAllBytes(file, Convert.FromBase64String(images[i].data));
            list.Add(file);
        }
        return list;
    }

    static string SafeExt(string name)
    {
        string ext = "";
        int dot = (name ?? "").LastIndexOf('.');
        if (dot >= 0) ext = name.Substring(dot).ToLowerInvariant();
        return (ext == ".jpg" || ext == ".gif" || ext == ".webp" || ext == ".bmp") ? ext : ".png";
    }

    /* ---------- clipboard + one-shot Ctrl+V ---------- */

    // Returns true when the next Ctrl+V will paste the notes (if any) + each screenshot separately
    static bool Arm(string text, StringCollection files)
    {
        Disarm();
        var data = new DataObject();
        if (files.Count > 0) data.SetFileDropList(files);
        else data.SetText(text);
        SetClipboard(data);

        if (files.Count == 0) return false;
        if (!win.RegisterPasteHotkey())
        {
            Log("Copy report: couldn't take over Ctrl+V (another program owns it)");
            return false;
        }
        Log("Copy report: armed with " + files.Count + " screenshot(s)" + (text.Trim().Length > 0 ? " + notes" : ", no notes"));
        pendingText = text;
        pendingFiles = files;
        expiry = new System.Windows.Forms.Timer();
        expiry.Interval = 5 * 60 * 1000;
        expiry.Tick += (s, e) => Disarm();
        expiry.Start();
        return true;
    }

    static void Disarm()
    {
        win.UnregisterPasteHotkey();
        pendingText = null;
        pendingFiles = null;
        if (expiry != null)
        {
            expiry.Stop();
            expiry.Dispose();
            expiry = null;
        }
    }

    static async void OnPasteHotkey()
    {
        string text = pendingText ?? "";
        StringCollection files = pendingFiles;
        if (files == null) { win.UnregisterPasteHotkey(); return; }

        if (ForegroundTitle().StartsWith("Hone Notes"))
        {
            // Inside Hone Notes itself: a normal paste, and stay ready for the website
            win.UnregisterPasteHotkey();
            SendCtrlV();
            await Task.Delay(300);
            if (pendingFiles != null) win.RegisterPasteHotkey();
            return;
        }

        Disarm();
        Log("Ctrl+V caught in '" + ForegroundTitle() + "': pasting " + (text.Trim().Length > 0 ? "notes + " : "") + files.Count + " screenshot(s)");
        try
        {
            // Wait until you let go of Ctrl+V so our own paste keys aren't mixed with yours
            await WaitForKeysReleased();

            if (text.Trim().Length > 0)
            {
                var textData = new DataObject();
                textData.SetText(text);
                SetClipboard(textData);
                await Task.Delay(100);
                SendCtrlV();
                Log("  notes pasted");
            }

            // One screenshot per paste: some sites only take the first image of a paste
            foreach (string file in files)
            {
                await Task.Delay(StepDelayMs);
                var one = new StringCollection();
                one.Add(file);
                var fileData = new DataObject();
                fileData.SetFileDropList(one);
                SetClipboard(fileData);
                await Task.Delay(100);
                SendCtrlV();
                Log("  pasted " + Path.GetFileName(file));
            }

            // Leave all screenshots on the clipboard in case you want to paste them again by hand
            await Task.Delay(StepDelayMs);
            var all = new DataObject();
            all.SetFileDropList(files);
            SetClipboard(all);
            Log("  done");
        }
        catch (Exception ex)
        {
            Log("  paste failed: " + ex);
        }
    }

    static async Task WaitForKeysReleased()
    {
        for (int i = 0; i < 60; i++) // up to 3 seconds
        {
            bool held = (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x56) & 0x8000) != 0;
            if (!held) return;
            await Task.Delay(50);
        }
    }

    static void SetClipboard(DataObject data)
    {
        Clipboard.SetDataObject(data, true, 10, 100);
        ownClipboardSeq = GetClipboardSequenceNumber();
    }

    static void SendCtrlV()
    {
        const byte VK_CONTROL = 0x11, VK_V = 0x56;
        const uint KEYUP = 0x0002;
        byte ctrlScan = (byte)MapVirtualKey(VK_CONTROL, 0), vScan = (byte)MapVirtualKey(VK_V, 0);
        keybd_event(VK_CONTROL, ctrlScan, 0, UIntPtr.Zero);
        keybd_event(VK_V, vScan, 0, UIntPtr.Zero);
        keybd_event(VK_V, vScan, KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, ctrlScan, KEYUP, UIntPtr.Zero);
    }

    static string ForegroundTitle()
    {
        var sb = new StringBuilder(256);
        GetWindowText(GetForegroundWindow(), sb, sb.Capacity);
        return sb.ToString();
    }
}

class ClipWindow : NativeWindow
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hWnd);

    const int WM_HOTKEY = 0x0312, WM_CLIPBOARDUPDATE = 0x031D;
    const uint MOD_CONTROL = 0x0002, MOD_NOREPEAT = 0x4000, VK_V = 0x56;

    public Action HotkeyPressed, ClipboardChanged;
    bool registered;

    public ClipWindow()
    {
        CreateHandle(new CreateParams());
        AddClipboardFormatListener(Handle);
    }

    public bool RegisterPasteHotkey()
    {
        if (!registered) registered = RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_NOREPEAT, VK_V);
        return registered;
    }

    public void UnregisterPasteHotkey()
    {
        if (registered)
        {
            UnregisterHotKey(Handle, 1);
            registered = false;
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && HotkeyPressed != null) HotkeyPressed();
        else if (m.Msg == WM_CLIPBOARDUPDATE && ClipboardChanged != null) ClipboardChanged();
        base.WndProc(ref m);
    }
}

public class ImageData
{
    public string name { get; set; }
    public string data { get; set; }
}

public class CopyRequest
{
    public string token { get; set; }
    public string text { get; set; }
    public List<ImageData> images { get; set; }
}
