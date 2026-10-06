# Types text + Enter into the console of ONE process (by id), not the foreground window.
# Runs as its own short-lived hidden process because AttachConsole detaches the caller from its own console,
# which must not happen to the long-running tray. Used by ClaudeRefresh.ps1.
# Exit code 0 = typed, 3 = failed.
param([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][string]$Text)

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class KeySender {
  [StructLayout(LayoutKind.Explicit, Size=16)] public struct KEY { [FieldOffset(0)] public int Down; [FieldOffset(4)] public ushort Repeat; [FieldOffset(6)] public ushort VK; [FieldOffset(8)] public ushort Scan; [FieldOffset(10)] public char Ch; [FieldOffset(12)] public uint Ctrl; }
  [StructLayout(LayoutKind.Explicit, Size=20)] public struct REC { [FieldOffset(0)] public ushort Type; [FieldOffset(4)] public KEY Key; }
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string n, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteConsoleInputW(IntPtr h, REC[] buf, uint len, out uint written);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  static REC Key(char ch, ushort vk, bool down) { var r = new REC(); r.Type = 1; r.Key.Down = down ? 1 : 0; r.Key.Repeat = 1; r.Key.VK = vk; r.Key.Ch = ch; return r; }
  public static int Type(uint pid, string text) {
    FreeConsole();
    if (!AttachConsole(pid)) return 3;
    try {
      IntPtr cin = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
      var recs = new System.Collections.Generic.List<REC>();
      foreach (char ch in text) { ushort vk = ch == '\r' ? (ushort)0x0D : (ushort)char.ToUpper(ch); recs.Add(Key(ch, vk, true)); recs.Add(Key(ch, vk, false)); }
      uint w; bool ok = WriteConsoleInputW(cin, recs.ToArray(), (uint)recs.Count, out w);
      CloseHandle(cin);
      return ok ? 0 : 3;
    } finally { FreeConsole(); }
  }
}
'@
exit ([KeySender]::Type([uint32]$ProcessId, $Text + "`r"))
