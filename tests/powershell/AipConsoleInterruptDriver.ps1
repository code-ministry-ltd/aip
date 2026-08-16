# Standalone driver for the 'native Windows Ctrl-C' test.
#
# Two invariants keep this test from destroying the suite around it:
# 1. This must run as its own process, never inside the Pester host. If a
#    console control event ever reaches the attached process, only this
#    disposable process can die - the host that reports the test result
#    must stay alive so the failure is visible instead of silently killing
#    the whole Pester run (which masked the entire Windows suite).
# 2. The child is started with CREATE_NEW_PROCESS_GROUP (group id = its
#    process id) and the event targets that exact group, never group 0
#    ("foreground"): on a headless CI console the attached sender is the
#    foreground group, so group 0 kills the sender instead of the child.
# 3. The fake harness child must be a real executable (the test uses
#    ping.exe renamed), never a .cmd/.bat: a batch would pause at
#    "Terminate batch job (Y/N)?" on the Ctrl-C event and wait for console
#    input a headless CI console never provides, and aip launches the
#    harness unredirected (standalone native), so pwsh will not kill the
#    batch itself - it waits for it. The driver also settles 500ms after
#    the ready signal so the child's long-running command has joined the
#    process group before the event is sent.
#
# Usage:
#   pwsh -NoProfile -File AipConsoleInterruptDriver.ps1 `
#       -Pwsh <path to pwsh> -ScriptPath <child script> -ReadyPath <file> `
#       [-WaitMilliseconds <n>]
# Prints the child's exit code on success (exit 0); prints an error and
# exits 1 when the child could not be started, never became ready, or
# did not exit within the wait window.
param(
    [Parameter(Mandatory)][string]$Pwsh,
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [uint32]$WaitMilliseconds = 30000,
    [string]$CommandLineOverride = ''
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class AipConsoleInterruptDriver {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint controlEvent, uint processGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate bool ConsoleCtrlHandler(uint controlEvent);

    // Static so the delegate stays alive while it is registered.
    private static readonly ConsoleCtrlHandler IgnoreCtrl = _ => true;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleProcessList([Out] uint[] processList, uint size);

    // Timeout diagnostic: which processes are still attached to the child
    // console (this driver includes itself - it queries while attached).
    private static string DescribeConsoleState() {
        var pids = new uint[64];
        if (!GetConsoleProcessList(pids, (uint)pids.Length)) {
            return $"console-state=unavailable(err={Marshal.GetLastWin32Error()})";
        }
        var list = "";
        for (var i = 0; i < pids.Length && pids[i] != 0; i++) { list += pids[i] + " "; }
        return $"attached=[{list.Trim()}]";
    }

    public static int Run(string pwsh, string script, string readyPath, uint waitMilliseconds) {
        var command = "\"" + pwsh + "\" -NoProfile -File \"" + script + "\"";
        return RunCommand(command, readyPath, waitMilliseconds);
    }

    // The full child command line, so diagnostics can experiment with other
    // pwsh launch modes (-Command, profile-based interactive, ...).
    public static int RunCommand(string commandLine, string readyPath, uint waitMilliseconds) {
        const uint CreateNewConsole = 0x00000010;
        const uint CreateNewProcessGroup = 0x00000200;
        const uint AttachParentProcess = 0xFFFFFFFF;
        const uint WaitTimeout = 0x00000102;
        var startup = new STARTUPINFO { cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO)) };
        PROCESS_INFORMATION process;
        var command = new StringBuilder(commandLine);
        // CREATE_NEW_PROCESS_GROUP makes the child's process group id equal
        // to its process id, so the Ctrl-C can be sent to that exact group.
        // Targeting group 0 ("foreground") is unreliable: on a headless CI
        // console the attached sender ends up being the foreground group and
        // the event kills the sender instead of the child.
        // applicationName null: CreateProcess takes the executable from the
        // command line's first (quoted) token.
        if (!CreateProcess(null, command, IntPtr.Zero, IntPtr.Zero, false,
                CreateNewConsole | CreateNewProcessGroup, IntPtr.Zero, null,
                ref startup, out process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "could not start interrupt test process");
        }
        try {
            var deadline = DateTime.UtcNow.AddSeconds(20);
            while (!File.Exists(readyPath) && DateTime.UtcNow < deadline) { Thread.Sleep(50); }
            if (!File.Exists(readyPath)) {
                TerminateProcess(process.hProcess, 1);
                throw new TimeoutException("harness did not become ready");
            }
            // The ready file is written just before the child starts its
            // long-running command; give that command a moment to join the
            // child's process group so the event reaches it.
            Thread.Sleep(500);
            FreeConsole();
            if (!AttachConsole(process.dwProcessId)) {
                TerminateProcess(process.hProcess, 1);
                throw new Win32Exception(Marshal.GetLastWin32Error(), "could not attach to interrupt test console");
            }
            SetConsoleCtrlHandler(IgnoreCtrl, true);
            uint status;
            try {
                if (!GenerateConsoleCtrlEvent(0, process.dwProcessId)) {
                    TerminateProcess(process.hProcess, 1);
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "could not send Ctrl-C");
                }
                // Wait while still attached: a timeout diagnostic needs the
                // child console's process list, not the parent console's.
                if (WaitForSingleObject(process.hProcess, waitMilliseconds) == WaitTimeout) {
                    var state = DescribeConsoleState();
                    TerminateProcess(process.hProcess, 1);
                    throw new TimeoutException($"interrupted wrapper did not exit; {state}");
                }
                if (!GetExitCodeProcess(process.hProcess, out status)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "could not read interrupted wrapper status");
                }
            }
            finally {
                FreeConsole();
                AttachConsole(AttachParentProcess);
                SetConsoleCtrlHandler(IgnoreCtrl, false);
            }
            return unchecked((int)status);
        }
        finally {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
    }
}
'@

try {
    if ($CommandLineOverride) {
        Write-Output ([AipConsoleInterruptDriver]::RunCommand($CommandLineOverride, $ReadyPath, $WaitMilliseconds))
    }
    else {
        Write-Output ([AipConsoleInterruptDriver]::Run($Pwsh, $ScriptPath, $ReadyPath, $WaitMilliseconds))
    }
    exit 0
}
catch {
    Write-Error "interrupt driver failed: $($_.Exception.Message)"
    exit 1
}
