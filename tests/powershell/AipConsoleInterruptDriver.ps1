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
# 3. After the event, the driver types 'Y' into the child console's input
#    buffer: the fake child is a batch script, and on Ctrl-C cmd.exe pauses
#    the batch at "Terminate batch job (Y/N)?" waiting for input that no
#    headless console will ever provide. aip launches the harness unredirected
#    (standalone native), so pwsh will not kill the batch itself - it waits
#    for it. Console input is buffered, so the 'Y' is consumed when the
#    prompt appears regardless of timing, and is harmless if the prompt
#    never appears (the child never reads input).
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
    [uint32]$WaitMilliseconds = 30000
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
    private static extern bool WriteConsole(
        IntPtr consoleOutput, string buffer, uint numberOfCharsToWrite,
        out uint numberOfCharsWritten, IntPtr reserved);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleProcessList([Out] uint[] processList, uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr securityAttributes,
        uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    // Diagnostics surfaced through the timeout/exit messages.
    private static string PromptWrite = "not-attempted";

    // Best-effort: type 'Y' into the child console's input buffer so
    // cmd.exe's "Terminate batch job (Y/N)?" prompt (raised by the Ctrl-C
    // event) is answered on a headless console. The input is opened via
    // CONIN$ rather than GetStdHandle: this process inherits a redirected
    // stdin pipe from the CI runner, so the standard input handle points at
    // the pipe, not the attached console. Failures are recorded, not
    // thrown: if the prompt never appears the buffered input is never
    // consumed, and if the write fails the child simply does not exit and
    // the wait times out loudly.
    private static void AnswerBatchTerminationPrompt() {
        const uint GenericWrite = 0x40000000;
        const uint FileShareReadWrite = 3;
        const uint OpenExisting = 3;
        var conin = CreateFile("CONIN$", GenericWrite, FileShareReadWrite, IntPtr.Zero,
                               OpenExisting, 0, IntPtr.Zero);
        if (conin == IntPtr.Zero || conin == new IntPtr(-1)) {
            PromptWrite = $"no-conin(err={Marshal.GetLastWin32Error()})";
            return;
        }
        try {
            uint written;
            var ok = WriteConsole(conin, "Y\r", 2, out written, IntPtr.Zero);
            PromptWrite = ok ? $"ok({written})" : $"failed(err={Marshal.GetLastWin32Error()})";
        }
        finally { CloseHandle(conin); }
    }

    private static string DescribeConsoleState() {
        var pids = new uint[64];
        if (!GetConsoleProcessList(pids, (uint)pids.Length)) {
            return $"console-state=unavailable(err={Marshal.GetLastWin32Error()})";
        }
        var list = "";
        for (var i = 0; i < pids.Length && pids[i] != 0; i++) { list += pids[i] + " "; }
        return $"attached=[{list.Trim()}] prompt-write={PromptWrite}";
    }

    public static int Run(string pwsh, string script, string readyPath, uint waitMilliseconds) {
        const uint CreateNewConsole = 0x00000010;
        const uint CreateNewProcessGroup = 0x00000200;
        const uint AttachParentProcess = 0xFFFFFFFF;
        const uint WaitTimeout = 0x00000102;
        var startup = new STARTUPINFO { cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO)) };
        PROCESS_INFORMATION process;
        var command = new StringBuilder("\"" + pwsh + "\" -NoProfile -File \"" + script + "\"");
        // CREATE_NEW_PROCESS_GROUP makes the child's process group id equal
        // to its process id, so the Ctrl-C can be sent to that exact group.
        // Targeting group 0 ("foreground") is unreliable: on a headless CI
        // console the attached sender ends up being the foreground group and
        // the event kills the sender instead of the child.
        if (!CreateProcess(pwsh, command, IntPtr.Zero, IntPtr.Zero, false,
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
                AnswerBatchTerminationPrompt();
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
    Write-Output ([AipConsoleInterruptDriver]::Run($Pwsh, $ScriptPath, $ReadyPath, $WaitMilliseconds))
    exit 0
}
catch {
    Write-Error "interrupt driver failed: $($_.Exception.Message)"
    exit 1
}
