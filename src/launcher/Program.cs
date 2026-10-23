using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("ClipToast")]
[assembly: AssemblyDescription("ClipToast - Seamless Windows Clipboard Media Downloader")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("ClipToast Open Source Project")]
[assembly: AssemblyProduct("ClipToast")]
[assembly: AssemblyCopyright("Copyright (C) 2026 Harsh Pandey")]
[assembly: AssemblyTrademark("ClipToast")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace ClipToastLauncher
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
                string appDir = Path.Combine(exeDir, "app");
                if (!Directory.Exists(appDir) && File.Exists(Path.Combine(exeDir, "downloader.ps1")))
                {
                    appDir = exeDir;
                }
                else if (!Directory.Exists(appDir))
                {
                    string parent = Path.GetDirectoryName(exeDir);
                    if (!string.IsNullOrEmpty(parent) && Directory.Exists(Path.Combine(parent, "app")))
                    {
                        appDir = Path.Combine(parent, "app");
                    }
                }

                string script = "downloader.ps1";
                List<string> psArgs = new List<string>();

                if (args != null && args.Length > 0)
                {
                    string first = args[0].Trim();
                    string firstLower = first.ToLowerInvariant();

                    if (firstLower == "--stop" || firstLower == "-stop" || firstLower == "--exit" || firstLower == "-exit")
                    {
                        try
                        {
                            EventWaitHandle exitEvent;
                            if (EventWaitHandle.TryOpenExisting(@"Local\ClipToast_Tray_Exit", out exitEvent))
                            {
                                exitEvent.Set();
                                exitEvent.Dispose();
                            }
                        }
                        catch {}
                        return 0;
                    }
                    else if (firstLower == "--audio" || firstLower == "-audioonly" || firstLower == "-audio")
                    {
                        script = "downloader.ps1";
                        psArgs.Add("-AudioOnly");
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower == "--video" || firstLower == "-video")
                    {
                        script = "downloader.ps1";
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower == "--tray" || firstLower == "-tray" || firstLower == "tray.ps1")
                    {
                        script = "tray.ps1";
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower == "--settings" || firstLower == "-settings" || firstLower == "settings.ps1")
                    {
                        script = "settings.ps1";
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower == "--action" || firstLower == "-action" || firstLower == "action.ps1")
                    {
                        script = "action.ps1";
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower.StartsWith("cliptoast://"))
                    {
                        script = "action.ps1";
                        psArgs.Add(first);
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower.StartsWith("http://") || firstLower.StartsWith("https://"))
                    {
                        script = "downloader.ps1";
                        psArgs.Add("-InputUrl");
                        psArgs.Add(first);
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else if (firstLower.EndsWith(".ps1"))
                    {
                        script = first;
                        for (int i = 1; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                    else
                    {
                        for (int i = 0; i < args.Length; i++) psArgs.Add(args[i]);
                    }
                }

                string scriptPath = Path.Combine(appDir, script);
                if (!File.Exists(scriptPath))
                {
                    scriptPath = Path.Combine(exeDir, script);
                }

                string sysDir = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string psExe = Path.Combine(sysDir, @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(psExe)) psExe = "powershell.exe";

                StringBuilder cmd = new StringBuilder();
                cmd.Append("-NoProfile -STA -File \"");
                cmd.Append(scriptPath);
                cmd.Append("\"");

                foreach (string arg in psArgs)
                {
                    cmd.Append(" ");
                    if (arg.StartsWith("-") && !arg.Contains(" ") && !arg.Contains("&"))
                    {
                        cmd.Append(arg);
                    }
                    else if (!arg.StartsWith("\"") || !arg.EndsWith("\""))
                    {
                        cmd.Append("\"").Append(arg.Replace("\"", "\\\"")).Append("\"");
                    }
                    else
                    {
                        cmd.Append(arg);
                    }
                }

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = psExe;
                psi.Arguments = cmd.ToString();
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                psi.WorkingDirectory = exeDir;
                psi.EnvironmentVariables["PSExecutionPolicyPreference"] = "Bypass";

                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show("ClipToast launcher error: " + ex.Message, "ClipToast", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
