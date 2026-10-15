// KMLD bounded, read-only content census of selected committed regions of a bound process.
// Purpose: decide whether growing private regions hold Mono managed objects or native (C++) objects,
// and which types dominate, WITHOUT suspending, debugging, or collecting garbage in the target.
// Method: read sampled regions with ReadProcessMemory; at every 16-byte boundary take the first
// qword as a candidate type pointer; tally; then classify the most frequent values:
//   * pointer into a loaded image (e.g. UnityPlayer.dll .rdata)  -> native C++ vtable (native object)
//   * pointer to a structure whose first qword points to a structure containing a (name, namespace)
//     pair of ASCII identifier pointers                           -> Mono MonoVTable -> MonoClass (managed object)
// The Mono interpretation is heuristic (MonoClass layout is not hard-coded beyond "two consecutive
// char* fields"); every resolved name is reported with the evidence used. Content is never stored raw.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Kmld
{
    public sealed class RegionSpan { public ulong Base; public ulong Size; public string Kind; public string Module; }

    public sealed class CandidateType
    {
        public ulong Pointer; public long Count; public string Kind; public string Name; public string Namespace; public string Evidence;
    }

    public sealed class CensusResult
    {
        public long BytesRead; public long BytesRequested; public int RegionsRead; public int ReadFailures; public long ZeroQwords; public long Slots;
        public List<CandidateType> Top = new List<CandidateType>();
        public List<KeyValuePair<string, int>> Utf16Strings = new List<KeyValuePair<string, int>>();
        public List<KeyValuePair<string, int>> AsciiStrings = new List<KeyValuePair<string, int>>();
        public Dictionary<string, long> PointerTargetKinds = new Dictionary<string, long>();
    }

    public static class ContentCensus
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(SafeProcessHandle h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetProcessTimes(SafeProcessHandle h, out long c, out long e, out long k, out long u);

        // samples: regions to read (already filtered by the caller); map: every committed region of the process (for pointer classification).
        public static CensusResult Run(int pid, long expectedCreation, List<RegionSpan> samples, List<RegionSpan> map, long maxBytes, int topN)
        {
            var h = OpenProcess(0x0400 | 0x0010 | 0x1000, false, (uint)pid); // QUERY_INFORMATION | VM_READ | QUERY_LIMITED
            if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess");
            try
            {
                long c, e, k, u;
                if (!GetProcessTimes(h, out c, out e, out k, out u) || c != expectedCreation) throw new InvalidOperationException("identity mismatch");
                map.Sort((a, b) => a.Base.CompareTo(b.Base));
                var res = new CensusResult();
                var counts = new Dictionary<ulong, long>();
                var u16 = new Dictionary<string, int>(); var asc = new Dictionary<string, int>();
                var buf = new byte[1 << 16];
                foreach (var s in samples)
                {
                    if (res.BytesRead >= maxBytes) break;
                    res.RegionsRead++;
                    for (ulong off = 0; off < s.Size && res.BytesRead < maxBytes; off += (ulong)buf.Length)
                    {
                        int want = (int)Math.Min((ulong)buf.Length, s.Size - off);
                        res.BytesRequested += want;
                        IntPtr got;
                        if (!ReadProcessMemory(h, new IntPtr((long)(s.Base + off)), buf, new IntPtr(want), out got) || got.ToInt64() != want) { res.ReadFailures++; continue; }
                        res.BytesRead += want;
                        for (int i = 0; i + 8 <= want; i += 16)
                        {
                            ulong q = BitConverter.ToUInt64(buf, i);
                            res.Slots++;
                            if (q == 0) { res.ZeroQwords++; continue; }
                            long n; counts.TryGetValue(q, out n); counts[q] = n + 1;
                        }
                        ExtractStrings(buf, want, u16, asc);
                    }
                }
                // classify pointer-like values by target region kind
                var ranked = new List<KeyValuePair<ulong, long>>(counts);
                ranked.Sort((a, b) => b.Value.CompareTo(a.Value));
                int examined = 0;
                foreach (var kv in ranked)
                {
                    var r = Find(map, kv.Key);
                    string kind = r == null ? "non-pointer" : (r.Kind == "Image" ? "image:" + (r.Module ?? "?") : r.Kind);
                    long t; res.PointerTargetKinds.TryGetValue(kind, out t); res.PointerTargetKinds[kind] = t + kv.Value;
                    if (examined >= topN || r == null) continue;
                    examined++;
                    var ct = new CandidateType { Pointer = kv.Key, Count = kv.Value, Kind = kind };
                    if (r.Kind != "Image") ResolveMono(h, kv.Key, map, ct);
                    else ct.Evidence = "points into image " + r.Module + " (native vtable or static data)";
                    res.Top.Add(ct);
                }
                res.Utf16Strings = TopK(u16, 40); res.AsciiStrings = TopK(asc, 40);
                return res;
            }
            finally { h.Dispose(); }
        }

        public sealed class ReferrerResult
        {
            public int TargetsSampled; public long BytesScanned; public int Hits; public int Attributed;
            public List<CandidateType> ReferrerTypes = new List<CandidateType>();
            public Dictionary<string, int> FieldOffsets = new Dictionary<string, int>();
        }

        // One-hop referrer census (heuristic). Targets: up to maxTargets objects in targetRegions whose first qword == vtable.
        // Scans scanRegions for qwords equal to a target address; attributes each hit to the nearest preceding 16-byte slot
        // (within maxBackBytes) whose first qword resolves to a Mono class. Read-only.
        public static ReferrerResult Referrers(int pid, long expectedCreation, ulong vtable, List<RegionSpan> targetRegions,
            List<RegionSpan> scanRegions, List<RegionSpan> map, int maxTargets, long maxScanBytes, int maxBackBytes, int maxHits)
        {
            var h = OpenProcess(0x0400 | 0x0010 | 0x1000, false, (uint)pid);
            if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess");
            try
            {
                long c, e, k, u;
                if (!GetProcessTimes(h, out c, out e, out k, out u) || c != expectedCreation) throw new InvalidOperationException("identity mismatch");
                map.Sort((a, b) => a.Base.CompareTo(b.Base));
                var res = new ReferrerResult();
                var targets = new HashSet<ulong>();
                var buf = new byte[1 << 16];
                foreach (var s in targetRegions)
                {
                    for (ulong off = 0; off < s.Size && targets.Count < maxTargets; off += (ulong)buf.Length)
                    {
                        int want = (int)Math.Min((ulong)buf.Length, s.Size - off); IntPtr got;
                        if (!ReadProcessMemory(h, new IntPtr((long)(s.Base + off)), buf, new IntPtr(want), out got) || got.ToInt64() != want) continue;
                        for (int i = 0; i + 8 <= want && targets.Count < maxTargets; i += 16)
                            if (BitConverter.ToUInt64(buf, i) == vtable) targets.Add(s.Base + off + (ulong)i);
                    }
                    if (targets.Count >= maxTargets) break;
                }
                res.TargetsSampled = targets.Count;
                var typeCache = new Dictionary<ulong, CandidateType>();
                var refCounts = new Dictionary<string, CandidateType>();
                foreach (var s in scanRegions)
                {
                    if (res.BytesScanned >= maxScanBytes || res.Hits >= maxHits) break;
                    for (ulong off = 0; off < s.Size && res.BytesScanned < maxScanBytes && res.Hits < maxHits; off += (ulong)buf.Length)
                    {
                        int want = (int)Math.Min((ulong)buf.Length, s.Size - off); IntPtr got;
                        if (!ReadProcessMemory(h, new IntPtr((long)(s.Base + off)), buf, new IntPtr(want), out got) || got.ToInt64() != want) continue;
                        res.BytesScanned += want;
                        for (int i = 0; i + 8 <= want; i += 8)
                        {
                            ulong q = BitConverter.ToUInt64(buf, i);
                            if (!targets.Contains(q)) continue;
                            ulong hit = s.Base + off + (ulong)i;
                            if (targets.Contains(hit)) continue;          // the target's own header slot
                            res.Hits++;
                            ulong slot = hit & ~0xFUL;
                            for (int back = 0; back <= maxBackBytes; back += 16)
                            {
                                ulong cand = slot - (ulong)back;
                                if (cand < s.Base) break;
                                var hb = Read(h, cand, 8); if (hb == null) break;
                                ulong vt = BitConverter.ToUInt64(hb, 0);
                                if (vt == 0 || Find(map, vt) == null) continue;
                                CandidateType ct;
                                if (!typeCache.TryGetValue(vt, out ct))
                                {
                                    ct = new CandidateType { Pointer = vt };
                                    ResolveMono(h, vt, map, ct);
                                    typeCache[vt] = ct;
                                }
                                if (ct.Name == null) continue;
                                res.Attributed++;
                                string key = (ct.Namespace ?? "") + "." + ct.Name;
                                CandidateType agg;
                                if (!refCounts.TryGetValue(key, out agg)) { agg = new CandidateType { Pointer = vt, Name = ct.Name, Namespace = ct.Namespace, Kind = "mono-object", Evidence = ct.Evidence }; refCounts[key] = agg; }
                                agg.Count++;
                                string fo = key + "+0x" + (hit - cand).ToString("X");
                                int n; res.FieldOffsets.TryGetValue(fo, out n); res.FieldOffsets[fo] = n + 1;
                                break;
                            }
                            if (res.Hits >= maxHits) break;
                        }
                    }
                }
                res.ReferrerTypes = new List<CandidateType>(refCounts.Values);
                res.ReferrerTypes.Sort((a, b) => b.Count.CompareTo(a.Count));
                return res;
            }
            finally { h.Dispose(); }
        }

        static RegionSpan Find(List<RegionSpan> map, ulong p)
        {
            int lo = 0, hi = map.Count - 1;
            while (lo <= hi)
            {
                int mid = (lo + hi) / 2; var r = map[mid];
                if (p < r.Base) hi = mid - 1; else if (p >= r.Base + r.Size) lo = mid + 1; else return r;
            }
            return null;
        }

        static byte[] Read(SafeProcessHandle h, ulong addr, int n)
        {
            var b = new byte[n]; IntPtr got;
            return ReadProcessMemory(h, new IntPtr((long)addr), b, new IntPtr(n), out got) && got.ToInt64() == n ? b : null;
        }

        static string ReadIdent(SafeProcessHandle h, ulong addr, List<RegionSpan> map, bool allowEmpty)
        {
            if (Find(map, addr) == null) return null;
            var b = Read(h, addr, 96); if (b == null) return null;
            int len = Array.IndexOf(b, (byte)0); if (len < 0) return null;
            if (len == 0) return allowEmpty ? "" : null;
            for (int i = 0; i < len; i++)
            {
                byte ch = b[i];
                bool ok = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.' || ch == '`' || ch == '<' || ch == '>' || ch == '[' || ch == ']' || ch == ',' || ch == '+' || ch == '-' || ch == '$' || ch == '=';
                if (!ok) return null;
            }
            return Encoding.ASCII.GetString(b, 0, len);
        }

        // Candidate is a MonoVTable if *candidate = klass and klass contains consecutive (name, namespace) char* fields.
        static void ResolveMono(SafeProcessHandle h, ulong candidate, List<RegionSpan> map, CandidateType ct)
        {
            var vt = Read(h, candidate, 8); if (vt == null) { ct.Evidence = "unreadable"; return; }
            ulong klass = BitConverter.ToUInt64(vt, 0);
            if (Find(map, klass) == null) { ct.Evidence = "first qword of target is not a pointer"; return; }
            var kb = Read(h, klass, 0x140); if (kb == null) { ct.Evidence = "klass unreadable"; return; }
            for (int off = 0; off + 16 <= kb.Length; off += 8)
            {
                ulong p1 = BitConverter.ToUInt64(kb, off), p2 = BitConverter.ToUInt64(kb, off + 8);
                string n = ReadIdent(h, p1, map, false); if (n == null || n.Length < 2) continue;
                string ns = ReadIdent(h, p2, map, true); if (ns == null) continue;
                if (ns.Length > 0 && !char.IsUpper(ns[0])) continue;
                ct.Name = n; ct.Namespace = ns; ct.Kind = "mono-object";
                ct.Evidence = "vtable->klass(+0) has (name,namespace) char* pair at klass+0x" + off.ToString("X");
                return;
            }
            ct.Evidence = "no (name,namespace) pair found in klass[0..0x140]";
        }

        public static void ExtractStrings(byte[] b, int n, Dictionary<string, int> u16, Dictionary<string, int> asc)
        {
            // UTF-16LE printable ASCII runs >= 8 chars, ASCII runs >= 12 chars; truncated to 80 chars.
            int run = 0; int start = 0;
            for (int parity = 0; parity < 2; parity++)        // both alignments; managed string data is normally even-aligned
            {
                run = 0;
                for (int i = parity; i + 1 < n; i += 2)
                {
                    bool pr = b[i + 1] == 0 && b[i] >= 0x20 && b[i] < 0x7F;
                    if (pr) { if (run == 0) start = i; run++; }
                    else { if (run >= 8) Add(u16, Encoding.Unicode.GetString(b, start, Math.Min(run, 80) * 2)); run = 0; }
                }
                if (run >= 8) Add(u16, Encoding.Unicode.GetString(b, start, Math.Min(run, 80) * 2));
            }
            run = 0;
            for (int i = 0; i < n; i++)
            {
                bool pr = b[i] >= 0x20 && b[i] < 0x7F;
                if (pr) { if (run == 0) start = i; run++; }
                else { if (run >= 12) Add(asc, Encoding.ASCII.GetString(b, start, Math.Min(run, 80))); run = 0; }
            }
        }

        static void Add(Dictionary<string, int> d, string s) { int n; d.TryGetValue(s, out n); if (n == 0 && d.Count > 200000) return; d[s] = n + 1; }

        static List<KeyValuePair<string, int>> TopK(Dictionary<string, int> d, int k)
        {
            var l = new List<KeyValuePair<string, int>>(d); l.Sort((a, b) => b.Value.CompareTo(a.Value));
            return l.GetRange(0, Math.Min(k, l.Count));
        }
    }
}
