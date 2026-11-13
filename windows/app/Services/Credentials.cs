using System;
using System.Runtime.InteropServices;
using System.Text;

namespace OmniCast.Services;

// Stream keys (and later tokens and client secrets) in Windows Credential
// Manager, so they're never written to settings.json. They show up in
// Control Panel > Credential Manager > Windows Credentials as "OmniCast/...".
public static class Credentials
{
    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    private static string Target(string name) => "OmniCast/" + name;

    public static string StreamKeyName(string destinationId) => "stream-key/" + destinationId;

    public static void Write(string name, string secret)
    {
        byte[] blob = Encoding.Unicode.GetBytes(secret ?? "");
        IntPtr mem = Marshal.AllocHGlobal(Math.Max(blob.Length, 1));
        try
        {
            Marshal.Copy(blob, 0, mem, blob.Length);
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Target(name),
                CredentialBlobSize = blob.Length,
                CredentialBlob = mem,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = "OmniCast",
            };
            if (!CredWriteW(ref cred, 0))
                throw new InvalidOperationException($"Couldn't save to Credential Manager (error {Marshal.GetLastWin32Error()})");
        }
        finally
        {
            // Don't leave the secret lying around in unmanaged memory.
            for (int i = 0; i < blob.Length; i++) Marshal.WriteByte(mem, i, 0);
            Marshal.FreeHGlobal(mem);
        }
    }

    public static string? Read(string name)
    {
        if (!CredReadW(Target(name), CRED_TYPE_GENERIC, 0, out IntPtr p))
            return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(p);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0)
                return "";
            return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
        }
        finally
        {
            CredFree(p);
        }
    }

    public static void Delete(string name) => CredDeleteW(Target(name), CRED_TYPE_GENERIC, 0);
}
