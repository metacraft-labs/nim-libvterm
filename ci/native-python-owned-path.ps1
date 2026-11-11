# Ordinary Windows filesystem identity and handle-bound deletion only.
# No process instrumentation, injection, registry writes or forced signals.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;
public sealed class NativePythonOwnedPath : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct Time { public uint Low, High; }
  [StructLayout(LayoutKind.Sequential)] struct Info { public uint Attributes; public Time Creation, Access, Write; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
  [StructLayout(LayoutKind.Sequential)] struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool Delete; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int kind,ref Disposition value,uint size);
  readonly SafeFileHandle handle;
  public NativePythonOwnedPath(string path,bool deletion) {
    handle=CreateFileW(path, deletion?0x10081u:0x80u,deletion?1u:3u,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
    if(handle.IsInvalid)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    try { Info i; if(!GetFileInformationByHandle(handle,out i))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    if((i.Attributes&0x400)!=0)throw new IOException("Reparse path refused"); } catch { handle.Dispose(); throw; }
  }
  public string Identity() { Info i; if(!GetFileInformationByHandle(handle,out i))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());return String.Join(":",i.Volume,i.IndexHigh,i.IndexLow,i.Creation.High,i.Creation.Low,i.Attributes,i.Links); }
  public string Hash() { using(var view=new SafeFileHandle(handle.DangerousGetHandle(),false))using(var stream=new FileStream(view,FileAccess.Read)){return Convert.ToHexString(SHA256.HashData(stream));} }
  public void Delete() { var d=new Disposition{Delete=true};if(!SetFileInformationByHandle(handle,4,ref d,1))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
  public void Dispose(){handle.Dispose();}
}
'@
function Get-NativeIdentity([string]$Path) {
    $handle = [NativePythonOwnedPath]::new($Path,$false)
    try { return $handle.Identity() } finally { $handle.Dispose() }
}
function Assert-SafeDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign directory authority' }
    return $item.FullName
}
function Get-RuntimeInventory([string]$Root) {
    $result = @{}
    foreach ($item in @(Get-Item -LiteralPath $Root -Force) + @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Runtime reparse entry refused' }
        $relative = if ($item.FullName -eq $Root) { '.' } else { [IO.Path]::GetRelativePath($Root,$item.FullName).Replace('\','/') }
        $result[$relative] = @{ identity=Get-NativeIdentity $item.FullName; directory=$item.PSIsContainer }
        if (-not $item.PSIsContainer) { $result[$relative].sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash; $result[$relative].length=$item.Length }
    }
    return $result
}
