param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Payload
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ZensuWindowsProfileJobV1
{
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectBasicAccountingInformation = 1;
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint INFINITE = 0xFFFFFFFF;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint HANDLE_FLAG_INHERIT = 0x00000001;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = new IntPtr(0x00020002);
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = new IntPtr(0x0002000D);
    private const int STD_INPUT_HANDLE = -10;
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;
    private const uint INFRASTRUCTURE_FAILURE_EXIT = 125;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
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
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information,
        uint informationLength,
        IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFOEX startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList,
        int attributeCount,
        int flags,
        ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList,
        uint flags,
        IntPtr attribute,
        IntPtr value,
        IntPtr size,
        IntPtr previousValue,
        IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForMultipleObjects(
        uint count,
        [In] IntPtr[] handles,
        bool waitAll,
        uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(
        uint desiredAccess,
        bool inheritHandle,
        uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetHandleInformation(IntPtr handle, out uint flags);

    private static void Check(bool condition, string operation)
    {
        if (!condition)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value == null)
        {
            throw new ArgumentException("null argument");
        }
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }
        StringBuilder quoted = new StringBuilder();
        quoted.Append('"');
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes += 1;
                continue;
            }
            if (character == '"')
            {
                quoted.Append('\\', backslashes * 2 + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }
            quoted.Append('\\', backslashes);
            backslashes = 0;
            quoted.Append(character);
        }
        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static StringBuilder BuildCommandLine(string command, string[] arguments)
    {
        StringBuilder value = new StringBuilder(QuoteArgument(command));
        foreach (string argument in arguments)
        {
            value.Append(' ');
            value.Append(QuoteArgument(argument));
        }
        return value;
    }

    private static IntPtr BuildEnvironmentBlock(string[] entries)
    {
        if (entries == null || entries.Length == 0)
        {
            throw new ArgumentException("environment is required");
        }
        string[] sorted = (string[])entries.Clone();
        Array.Sort(sorted, StringComparer.OrdinalIgnoreCase);
        StringBuilder block = new StringBuilder();
        foreach (string entry in sorted)
        {
            if (String.IsNullOrEmpty(entry)
                || entry.IndexOf('\0') >= 0
                || entry.IndexOf('=') <= 0)
            {
                throw new ArgumentException("environment entry is invalid");
            }
            block.Append(entry);
            block.Append('\0');
        }
        block.Append('\0');
        byte[] bytes = Encoding.Unicode.GetBytes(block.ToString());
        IntPtr value = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, value, bytes.Length);
        return value;
    }

    private static IntPtr[] UniqueStandardHandles(STARTUPINFO startup)
    {
        IntPtr[] candidates = new IntPtr[] {
            startup.hStdInput,
            startup.hStdOutput,
            startup.hStdError
        };
        System.Collections.Generic.List<IntPtr> unique =
            new System.Collections.Generic.List<IntPtr>();
        foreach (IntPtr handle in candidates)
        {
            if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            {
                throw new Win32Exception("standard handle is unavailable");
            }
            if (!unique.Contains(handle))
            {
                unique.Add(handle);
            }
        }
        return unique.ToArray();
    }

    private static void WaitForEmptyJob(IntPtr job)
    {
        int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
        for (int attempt = 0; attempt < 200; attempt += 1)
        {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
                new JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
            Check(
                QueryInformationJobObject(
                    job,
                    JobObjectBasicAccountingInformation,
                    ref accounting,
                    (uint)size,
                    IntPtr.Zero),
                "QueryInformationJobObject");
            if (accounting.ActiveProcesses == 0)
            {
                return;
            }
            Thread.Sleep(50);
        }
        throw new TimeoutException("Windows Job Object did not become empty");
    }

    public static int Run(
        string command,
        string[] arguments,
        string currentDirectory,
        string[] environmentEntries,
        uint supervisorProcessId,
        uint ownerProcessId)
    {
        if (String.IsNullOrEmpty(command) || !System.IO.Path.IsPathRooted(command))
        {
            throw new ArgumentException("command must be absolute");
        }
        if (arguments == null)
        {
            throw new ArgumentException("arguments are required");
        }
        if (String.IsNullOrEmpty(currentDirectory)
            || !System.IO.Path.IsPathRooted(currentDirectory))
        {
            throw new ArgumentException("working directory must be absolute");
        }

        IntPtr job = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr jobHandleList = IntPtr.Zero;
        IntPtr inheritedHandleList = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        IntPtr[] inheritedHandles = null;
        uint[] inheritedHandleFlags = null;
        int inheritedHandleFlagsCaptured = 0;
        IntPtr supervisorProcess = IntPtr.Zero;
        IntPtr ownerProcess = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        bool processCreated = false;
        bool completed = false;
        try
        {
            supervisorProcess = OpenProcess(
                SYNCHRONIZE,
                false,
                supervisorProcessId);
            Check(supervisorProcess != IntPtr.Zero, "OpenProcess(supervisor)");
            ownerProcess = OpenProcess(SYNCHRONIZE, false, ownerProcessId);
            Check(ownerProcess != IntPtr.Zero, "OpenProcess(owner)");

            job = CreateJobObject(IntPtr.Zero, null);
            Check(job != IntPtr.Zero, "CreateJobObject");

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            Check(
                SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    ref limits,
                    (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))),
                "SetInformationJobObject");

            STARTUPINFOEX startup = new STARTUPINFOEX();
            startup.StartupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFOEX));
            startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
            startup.StartupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
            startup.StartupInfo.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
            startup.StartupInfo.hStdError = GetStdHandle(STD_ERROR_HANDLE);
            inheritedHandles = UniqueStandardHandles(startup.StartupInfo);
            inheritedHandleFlags = new uint[inheritedHandles.Length];
            for (int index = 0; index < inheritedHandles.Length; index += 1)
            {
                Check(
                    GetHandleInformation(inheritedHandles[index], out inheritedHandleFlags[index]),
                    "GetHandleInformation(standard handle)");
                inheritedHandleFlagsCaptured += 1;
                Check(
                    SetHandleInformation(
                        inheritedHandles[index],
                        HANDLE_FLAG_INHERIT,
                        HANDLE_FLAG_INHERIT),
                    "SetHandleInformation(standard handle)");
            }

            IntPtr attributeBytes = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeBytes);
            if (attributeBytes == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "InitializeProcThreadAttributeList(size)");
            }
            attributeList = Marshal.AllocHGlobal(attributeBytes);
            Check(
                InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeBytes),
                "InitializeProcThreadAttributeList");
            startup.lpAttributeList = attributeList;

            jobHandleList = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(jobHandleList, job);
            Check(
                UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    PROC_THREAD_ATTRIBUTE_JOB_LIST,
                    jobHandleList,
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero),
                "UpdateProcThreadAttribute(job list)");

            inheritedHandleList = Marshal.AllocHGlobal(
                IntPtr.Size * inheritedHandles.Length);
            for (int index = 0; index < inheritedHandles.Length; index += 1)
            {
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    index * IntPtr.Size,
                    inheritedHandles[index]);
            }
            Check(
                UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                    inheritedHandleList,
                    new IntPtr(IntPtr.Size * inheritedHandles.Length),
                    IntPtr.Zero,
                    IntPtr.Zero),
                "UpdateProcThreadAttribute(handle list)");

            StringBuilder commandLine = BuildCommandLine(command, arguments);
            environmentBlock = BuildEnvironmentBlock(environmentEntries);
            Check(
                CreateProcessW(
                    command,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CREATE_SUSPENDED
                        | CREATE_UNICODE_ENVIRONMENT
                        | EXTENDED_STARTUPINFO_PRESENT,
                    environmentBlock,
                    currentDirectory,
                    ref startup,
                    out process),
                "CreateProcessW");
            processCreated = true;

            if (ResumeThread(process.hThread) == UInt32.MaxValue)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread");
            }
            IntPtr[] lifetimeHandles = new IntPtr[] {
                supervisorProcess,
                ownerProcess,
                process.hProcess
            };
            uint wait = WaitForMultipleObjects(
                (uint)lifetimeHandles.Length,
                lifetimeHandles,
                false,
                INFINITE);
            if (wait == WAIT_FAILED)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForMultipleObjects");
            }
            if (wait != WAIT_OBJECT_0 + 2)
            {
                if (wait == WAIT_OBJECT_0 || wait == WAIT_OBJECT_0 + 1)
                {
                    Check(
                        TerminateJobObject(job, INFRASTRUCTURE_FAILURE_EXIT),
                        "TerminateJobObject(controller exit)");
                    WaitForEmptyJob(job);
                    throw new InvalidOperationException(
                        "profile controller exited before the suite root");
                }
                throw new InvalidOperationException("unexpected process wait result");
            }
            uint exitCode;
            Check(GetExitCodeProcess(process.hProcess, out exitCode), "GetExitCodeProcess");

            Check(TerminateJobObject(job, INFRASTRUCTURE_FAILURE_EXIT), "TerminateJobObject");
            WaitForEmptyJob(job);
            completed = true;
            return unchecked((int)exitCode);
        }
        finally
        {
            if (!completed && processCreated)
            {
                if (job != IntPtr.Zero)
                {
                    TerminateJobObject(job, INFRASTRUCTURE_FAILURE_EXIT);
                }
                if (process.hProcess != IntPtr.Zero)
                {
                    WaitForSingleObject(process.hProcess, 10000);
                }
            }
            if (process.hThread != IntPtr.Zero)
            {
                CloseHandle(process.hThread);
            }
            if (process.hProcess != IntPtr.Zero)
            {
                CloseHandle(process.hProcess);
            }
            if (attributeList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }
            if (jobHandleList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(jobHandleList);
            }
            if (inheritedHandleList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(inheritedHandleList);
            }
            if (environmentBlock != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(environmentBlock);
            }
            if (inheritedHandles != null && inheritedHandleFlags != null)
            {
                for (int index = 0; index < inheritedHandleFlagsCaptured; index += 1)
                {
                    SetHandleInformation(
                        inheritedHandles[index],
                        HANDLE_FLAG_INHERIT,
                        inheritedHandleFlags[index] & HANDLE_FLAG_INHERIT);
                }
            }
            if (job != IntPtr.Zero)
            {
                CloseHandle(job);
            }
            if (ownerProcess != IntPtr.Zero)
            {
                CloseHandle(ownerProcess);
            }
            if (supervisorProcess != IntPtr.Zero)
            {
                CloseHandle(supervisorProcess);
            }
        }
    }
}
'@

try {
  if ([Text.Encoding]::UTF8.GetByteCount($Payload) -gt 32768) {
    throw 'payload too large'
  }
  $normalized = $Payload.Replace('-', '+').Replace('_', '/')
  switch ($normalized.Length % 4) {
    2 { $normalized += '==' }
    3 { $normalized += '=' }
    0 { }
    default { throw 'payload encoding invalid' }
  }
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
  $decoded = ConvertFrom-Json -InputObject $json
  if ($null -eq $decoded -or $decoded.command -isnot [string] -or
      -not [IO.Path]::IsPathRooted($decoded.command) -or $null -eq $decoded.args -or
      $decoded.cwd -isnot [string] -or -not [IO.Path]::IsPathRooted($decoded.cwd) -or
      $null -eq $decoded.environment -or
      $decoded.supervisorPid -isnot [ValueType] -or
      $decoded.ownerPid -isnot [ValueType]) {
    throw 'payload contract invalid'
  }
  $arguments = @($decoded.args)
  foreach ($argument in $arguments) {
    if ($argument -isnot [string]) {
      throw 'payload argument invalid'
    }
  }
  $environmentEntries = @()
  foreach ($property in @($decoded.environment.PSObject.Properties | Sort-Object Name)) {
    if ($property.Name -notmatch '^[^=\x00\r\n]+$' -or
        $property.Value -isnot [string] -or
        ([string]$property.Value) -match '[\x00\r\n]') {
      throw 'payload environment invalid'
    }
    $environmentEntries += "$($property.Name)=$([string]$property.Value)"
  }
  $null = Add-Type -TypeDefinition $source -Language CSharp
  $exitCode = [ZensuWindowsProfileJobV1]::Run(
    [string]$decoded.command,
    [string[]]$arguments,
    [IO.Path]::GetFullPath([string]$decoded.cwd),
    [string[]]$environmentEntries,
    [uint32]$decoded.supervisorPid,
    [uint32]$decoded.ownerPid
  )
  exit $exitCode
} catch {
  [Console]::Error.WriteLine('windows profile job supervisor failed')
  exit 125
}
