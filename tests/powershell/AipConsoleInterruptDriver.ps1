# Standalone driver for the 'native Windows Ctrl-C' test.
#
# This must run as its own process, never inside the Pester host: the test
# fires a console CTRL_C_EVENT at the child's console while this driver is
# attached to it. If the event ever reaches the attached process, only this
# disposable process can die - the host that reports the test result must
# stay alive so the failure is visible instead of silently killing the
# whole Pester run (which masked the entire Windows suite).
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

    public static int Run(string pwsh, string script, string readyPath, uint waitMilliseconds) {
        const uint CreateNewConsole = 0x00000010;
        const uint AttachParentProcess = 0xFFFFFFFF;
        const uint WaitTimeout = 0x00000102;
        var startup = new STARTUPINFO { cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO)) };
        PROCESS_INFORMATION process;
        var command = new StringBuilder("\"" + pwsh + "\" -NoProfile -File \"" + script + "\"");
        if (!CreateProcess(pwsh, command, IntPtr.Zero, IntPtr.Zero, false,
                CreateNewConsole, IntPtr.Zero, null, ref startup, out process)) {
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
            try {
                if (!GenerateConsoleCtrlEvent(0, 0)) {
                    TerminateProcess(process.hProcess, 1);
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "could not send Ctrl-C");
                }
            }
            finally {
                FreeConsole();
                AttachConsole(AttachParentProcess);
                SetConsoleCtrlHandler(IgnoreCtrl, false);
            }
            if (WaitForSingleObject(process.hProcess, waitMilliseconds) == WaitTimeout) {
                TerminateProcess(process.hProcess, 1);
                throw new TimeoutException("interrupted wrapper did not exit");
            }
            uint status;
            if (!GetExitCodeProcess(process.hProcess, out status)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "could not read interrupted wrapper status");
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
