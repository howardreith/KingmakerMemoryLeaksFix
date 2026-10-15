// KMLD observation-only native helpers. Compiled at runtime by Add-Type (PowerShell 7).
// Every API here is a read-only query of process/system state. Nothing in this file
// writes to another process, suspends it, attaches a debugger, or changes system settings.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Kmld
{
    public sealed class BoundProcess : IDisposable
    {
        const uint PROCESS_QUERY_INFORMATION = 0x0400;
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        const uint PROCESS_VM_READ = 0x0010;
        const uint SYNCHRONIZE = 0x00100000;
        const uint STILL_ACTIVE = 259;

        public int Pid { get; private set; }
        public long CreationFileTimeUtc { get; private set; }
        public string ImagePath { get; private set; }
        SafeProcessHandle handle;

        BoundProcess() { }

        // Binds to the process only if its creation time matches. The handle is held for the
        // object's lifetime, so the PID cannot be recycled to another process while bound.
        public static BoundProcess Bind(int pid, long expectedCreationFileTimeUtc, bool requireVmRead)
        {
            uint access = PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | (requireVmRead ? (PROCESS_VM_READ | PROCESS_QUERY_INFORMATION) : 0);
            var h = OpenProcess(access, false, (uint)pid);
            if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed for pid " + pid);
            var bp = new BoundProcess { Pid = pid, handle = h };
            bp.CreationFileTimeUtc = bp.ReadCreationTime();
            if (expectedCreationFileTimeUtc != 0 && bp.CreationFileTimeUtc != expectedCreationFileTimeUtc)
            {
                h.Dispose();
                throw new InvalidOperationException("Process identity mismatch: pid " + pid + " creation " + bp.CreationFileTimeUtc + " != expected " + expectedCreationFileTimeUtc);
            }
            var sb = new StringBuilder(1024); int len = sb.Capacity;
            bp.ImagePath = QueryFullProcessImageName(h, 0, sb, ref len) ? sb.ToString() : null;
            return bp;
        }

        public static long GetCreationTime(int pid)
        {
            using (var bp = Bind(pid, 0, false)) return bp.CreationFileTimeUtc;
        }

        long ReadCreationTime()
        {
            long c, e, k, u;
            if (!GetProcessTimes(handle, out c, out e, out k, out u)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return c;
        }

        public bool HasExited
        {
            get { uint code; return !GetExitCodeProcess(handle, out code) || code != STILL_ACTIVE; }
        }

        public uint? ExitCode
        {
            get { uint code; if (GetExitCodeProcess(handle, out code) && code != STILL_ACTIVE) return code; return null; }
        }

        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(handle, (uint)milliseconds) == 0;
        }

        public void VerifyIdentity()
        {
            if (ReadCreationTime() != CreationFileTimeUtc) throw new InvalidOperationException("Bound process creation time changed");
        }

        public ProcessSample Sample()
        {
            var s = new ProcessSample();
            var pmc = new PROCESS_MEMORY_COUNTERS_EX(); pmc.cb = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS_EX));
            if (GetProcessMemoryInfo(handle, ref pmc, pmc.cb))
            {
                s.PrivateBytes = (long)pmc.PrivateUsage; s.WorkingSetBytes = (long)pmc.WorkingSetSize;
                s.PeakWorkingSetBytes = (long)pmc.PeakWorkingSetSize; s.PagefileBytes = (long)pmc.PagefileUsage;
                s.PageFaultCount = pmc.PageFaultCount; s.MemoryOk = true;
            }
            else s.Errors.Add("GetProcessMemoryInfo:" + Marshal.GetLastWin32Error());
            uint hc;
            if (GetProcessHandleCount(handle, out hc)) { s.HandleCount = hc; s.HandlesOk = true; }
            else s.Errors.Add("GetProcessHandleCount:" + Marshal.GetLastWin32Error());
            long c, e, k, u;
            if (GetProcessTimes(handle, out c, out e, out k, out u)) { s.CpuSeconds = (k + u) / 1e7; s.CpuOk = true; }
            else s.Errors.Add("GetProcessTimes:" + Marshal.GetLastWin32Error());
            s.ThreadCount = CountThreads(Pid);
            if (s.ThreadCount < 0) s.Errors.Add("Toolhelp32 thread count failed");
            return s;
        }

        // Toolhelp snapshot; safe because the bound handle prevents PID reuse.
        static int CountThreads(int pid)
        {
            var snap = CreateToolhelp32Snapshot(0x00000004 /*TH32CS_SNAPTHREAD*/, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return -1;
            try
            {
                var te = new THREADENTRY32(); te.dwSize = (uint)Marshal.SizeOf(typeof(THREADENTRY32));
                int n = 0;
                if (!Thread32First(snap, ref te)) return -1;
                do { if (te.th32OwnerProcessID == (uint)pid) n++; } while (Thread32Next(snap, ref te));
                return n;
            }
            finally { CloseHandle(snap); }
        }

        // Memory-region census (VirtualQueryEx). Read-only; never reads region contents.
        public List<Region> QueryRegions(bool includeMappedNames)
        {
            var list = new List<Region>();
            IntPtr addr = IntPtr.Zero;
            var mbi = new MEMORY_BASIC_INFORMATION64();
            int size = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION64));
            var nameBuf = new StringBuilder(1024);
            while (true)
            {
                var r = VirtualQueryEx(handle, addr, out mbi, (UIntPtr)size);
                if (r == UIntPtr.Zero) break;
                var reg = new Region { BaseAddress = mbi.BaseAddress, AllocationBase = mbi.AllocationBase, RegionSize = mbi.RegionSize, State = mbi.State, Protect = mbi.Protect, AllocationProtect = mbi.AllocationProtect, Type = mbi.Type };
                if (includeMappedNames && (mbi.Type == 0x1000000 /*MEM_IMAGE*/ || mbi.Type == 0x40000 /*MEM_MAPPED*/) && mbi.State == 0x1000 /*MEM_COMMIT*/)
                {
                    nameBuf.Clear();
                    if (GetMappedFileNameW(handle, new IntPtr((long)mbi.BaseAddress), nameBuf, nameBuf.Capacity) > 0) reg.MappedName = nameBuf.ToString();
                }
                list.Add(reg);
                ulong next = mbi.BaseAddress + mbi.RegionSize;
                if (next <= mbi.BaseAddress) break;
                addr = new IntPtr((long)next);
                if (next >= 0x7FFFFFFFFFFF) break;
            }
            return list;
        }

        public void Dispose() { if (handle != null) handle.Dispose(); }

        [DllImport("kernel32.dll", SetLastError = true)] static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(SafeProcessHandle h, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(SafeProcessHandle h, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(SafeProcessHandle h, uint ms);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessHandleCount(SafeProcessHandle h, out uint count);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(SafeProcessHandle h, int flags, StringBuilder name, ref int size);
        [DllImport("psapi.dll", SetLastError = true)] static extern bool GetProcessMemoryInfo(SafeProcessHandle h, ref PROCESS_MEMORY_COUNTERS_EX c, uint cb);
        [DllImport("psapi.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern uint GetMappedFileNameW(SafeProcessHandle h, IntPtr addr, StringBuilder name, int size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern UIntPtr VirtualQueryEx(SafeProcessHandle h, IntPtr addr, out MEMORY_BASIC_INFORMATION64 mbi, UIntPtr len);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool Thread32First(IntPtr snap, ref THREADENTRY32 te);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool Thread32Next(IntPtr snap, ref THREADENTRY32 te);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_MEMORY_COUNTERS_EX
        {
            public uint cb; public uint PageFaultCount; public UIntPtr PeakWorkingSetSize; public UIntPtr WorkingSetSize;
            public UIntPtr QuotaPeakPagedPoolUsage; public UIntPtr QuotaPagedPoolUsage; public UIntPtr QuotaPeakNonPagedPoolUsage;
            public UIntPtr QuotaNonPagedPoolUsage; public UIntPtr PagefileUsage; public UIntPtr PeakPagefileUsage; public UIntPtr PrivateUsage;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct THREADENTRY32 { public uint dwSize; public uint cntUsage; public uint th32ThreadID; public uint th32OwnerProcessID; public int tpBasePri; public int tpDeltaPri; public uint dwFlags; }
        [StructLayout(LayoutKind.Sequential)]
        public struct MEMORY_BASIC_INFORMATION64
        {
            public ulong BaseAddress; public ulong AllocationBase; public uint AllocationProtect; public uint __alignment1;
            public ulong RegionSize; public uint State; public uint Protect; public uint Type; public uint __alignment2;
        }
    }

    public sealed class Region
    {
        public ulong BaseAddress, AllocationBase, RegionSize; public uint State, Protect, AllocationProtect, Type; public string MappedName;
    }

    public sealed class ProcessSample
    {
        public long PrivateBytes, WorkingSetBytes, PeakWorkingSetBytes, PagefileBytes; public uint PageFaultCount; public uint HandleCount;
        public double CpuSeconds; public int ThreadCount; public bool MemoryOk, HandlesOk, CpuOk;
        public List<string> Errors = new List<string>();
    }

    public static class SystemInfo
    {
        [StructLayout(LayoutKind.Sequential)]
        struct PERFORMANCE_INFORMATION
        {
            public uint cb; public UIntPtr CommitTotal; public UIntPtr CommitLimit; public UIntPtr CommitPeak; public UIntPtr PhysicalTotal;
            public UIntPtr PhysicalAvailable; public UIntPtr SystemCache; public UIntPtr KernelTotal; public UIntPtr KernelPaged;
            public UIntPtr KernelNonpaged; public UIntPtr PageSize; public uint HandleCount; public uint ProcessCount; public uint ThreadCount;
        }
        [DllImport("psapi.dll", SetLastError = true)] static extern bool GetPerformanceInfo(ref PERFORMANCE_INFORMATION pi, uint cb);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool GetDiskFreeSpaceEx(string dir, out ulong freeAvail, out ulong total, out ulong totalFree);

        // Returns [availablePhys, commitTotal, commitLimit, physicalTotal] in bytes, or null.
        public static long[] Memory()
        {
            var pi = new PERFORMANCE_INFORMATION(); pi.cb = (uint)Marshal.SizeOf(typeof(PERFORMANCE_INFORMATION));
            if (!GetPerformanceInfo(ref pi, pi.cb)) return null;
            long page = (long)pi.PageSize;
            return new long[] { (long)pi.PhysicalAvailable * page, (long)pi.CommitTotal * page, (long)pi.CommitLimit * page, (long)pi.PhysicalTotal * page };
        }

        public static long DiskFree(string dir)
        {
            ulong a, t, f; return GetDiskFreeSpaceEx(dir, out a, out t, out f) ? (long)a : -1;
        }

        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);

        // Passive window-state observation: 1 if the foreground window belongs to pid, else 0; -1 if unknown.
        public static int IsForeground(int pid)
        {
            IntPtr fg = GetForegroundWindow(); if (fg == IntPtr.Zero) return -1;
            uint fpid; GetWindowThreadProcessId(fg, out fpid); return fpid == (uint)pid ? 1 : 0;
        }

        // 1 if the given top-level window is minimized, 0 if not, -1 if no window handle.
        public static int IsMinimized(IntPtr hwnd) { return hwnd == IntPtr.Zero ? -1 : (IsIconic(hwnd) ? 1 : 0); }

        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);

        // Milliseconds since the last keyboard/mouse input in the caller's session (no input content is read); -1 if unavailable.
        public static long MillisecondsSinceLastInput()
        {
            var lii = new LASTINPUTINFO(); lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref lii)) return -1;
            return (long)unchecked((uint)Environment.TickCount - lii.dwTime);
        }
    }

    // PDH query for per-process GPU memory counters. Instance names embed "pid_<pid>_".
    public sealed class GpuCounters : IDisposable
    {
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhOpenQuery(string src, IntPtr user, out IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr user, out IntPtr counter);
        [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
        [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhGetRawCounterArray(IntPtr counter, ref uint bufSize, out uint count, IntPtr buffer);

        IntPtr query, dedicated, shared;
        public string Status { get; private set; }
        readonly string pidTag;

        public GpuCounters(int pid)
        {
            pidTag = "pid_" + pid + "_";
            uint rc = PdhOpenQuery(null, IntPtr.Zero, out query);
            if (rc != 0) { Status = "PdhOpenQuery:0x" + rc.ToString("X"); return; }
            rc = PdhAddEnglishCounter(query, @"\GPU Process Memory(*)\Dedicated Usage", IntPtr.Zero, out dedicated);
            if (rc != 0) { Status = "add-dedicated:0x" + rc.ToString("X"); return; }
            rc = PdhAddEnglishCounter(query, @"\GPU Process Memory(*)\Shared Usage", IntPtr.Zero, out shared);
            if (rc != 0) { Status = "add-shared:0x" + rc.ToString("X"); return; }
            Status = "ok";
        }

        // Returns [dedicated, shared] summed over this pid's adapter instances; -1 when unavailable.
        public long[] Read(out string status)
        {
            status = Status;
            if (Status != "ok") return new long[] { -1, -1 };
            uint rc = PdhCollectQueryData(query);
            if (rc != 0) { status = "collect:0x" + rc.ToString("X"); return new long[] { -1, -1 }; }
            int instD, instS;
            long d = Sum(dedicated, out instD), s = Sum(shared, out instS);
            if (instD == 0 && instS == 0) { status = "no-instance-for-pid"; return new long[] { -1, -1 }; }
            return new long[] { d, s };
        }

        long Sum(IntPtr counter, out int matched)
        {
            matched = 0; uint size = 0, count;
            uint rc = PdhGetRawCounterArray(counter, ref size, out count, IntPtr.Zero);
            if (rc != 0x800007D2 /*PDH_MORE_DATA*/ || size == 0) return -1;
            IntPtr buf = Marshal.AllocHGlobal((int)size);
            try
            {
                rc = PdhGetRawCounterArray(counter, ref size, out count, buf);
                if (rc != 0) return -1;
                long total = 0;
                // PDH_RAW_COUNTER_ITEM_W = { LPWSTR szName; PDH_RAW_COUNTER RawValue } where PDH_RAW_COUNTER is
                // 40 bytes on x64 (DWORD, FILETIME, pad, LONGLONG FirstValue @16, LONGLONG, DWORD, pad).
                int itemSize = IntPtr.Size + 40;
                for (int i = 0; i < count; i++)
                {
                    IntPtr item = new IntPtr(buf.ToInt64() + (long)i * itemSize);
                    string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(item));
                    if (name == null || !name.StartsWith(pidTag, StringComparison.Ordinal)) continue;
                    // PDH_RAW_COUNTER: DWORD CStatus; FILETIME TimeStamp; LONGLONG FirstValue; LONGLONG SecondValue; DWORD MultiCount
                    long first = Marshal.ReadInt64(new IntPtr(item.ToInt64() + IntPtr.Size + 16));
                    total += first; matched++;
                }
                return total;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public void Dispose() { if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; } }
    }
}
