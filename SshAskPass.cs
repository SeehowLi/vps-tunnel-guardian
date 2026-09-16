using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

internal static class SshAskPass
{
    private static int Main(string[] arguments)
    {
        // OpenSSH passes a human-readable prompt, NOT a credential filename.
        string credential = Environment.GetEnvironmentVariable("GUARDIAN_CREDENTIAL_FILE");
        if (arguments.Length != 1 || !arguments[0].ToLowerInvariant().Contains("password") ||
            String.IsNullOrEmpty(credential) || !File.Exists(credential))
        {
            return 2;
        }

        byte[] protectedBytes = null;
        byte[] plainBytes = null;
        try
        {
            protectedBytes = File.ReadAllBytes(credential);
            plainBytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Write(Encoding.UTF8.GetString(plainBytes));
            return 0;
        }
        catch
        {
            return 1;
        }
        finally
        {
            if (plainBytes != null)
            {
                Array.Clear(plainBytes, 0, plainBytes.Length);
            }
            if (protectedBytes != null)
            {
                Array.Clear(protectedBytes, 0, protectedBytes.Length);
            }
        }
    }
}
