using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using System.Collections.Generic;

namespace MiBoveda {
    public sealed class Entry {
        public string Id { get; set; } = Guid.NewGuid().ToString();
        public string Service { get; set; } = "";
        public string Username { get; set; } = "";
        public string Password { get; set; } = "";
        public string Url { get; set; } = "";
        public string Category { get; set; } = "Personal";
        public string Notes { get; set; } = "";
    }
    public sealed class Envelope {
        public int Version { get; set; } = 1;
        public int Iterations { get; set; } = 600000;
        public string Salt { get; set; } = "";
        public string Nonce { get; set; } = "";
        public string Tag { get; set; } = "";
        public string Ciphertext { get; set; } = "";
    }
    public sealed class Vault : IDisposable {
        const int Iterations = 600000;
        const int MaxBytes = 16 * 1024 * 1024;
        static readonly byte[] Aad = Encoding.UTF8.GetBytes("MiBoveda:v1:PBKDF2-SHA256:600000:AES-256-GCM");
        byte[] key;
        byte[] salt;
        public string Path { get; private set; }
        public List<Entry> Entries { get; private set; }
        Vault(string path, byte[] key, byte[] salt, List<Entry> entries) {
            Path = System.IO.Path.GetFullPath(path); this.key = key; this.salt = salt; Entries = entries;
        }
        static byte[] Derive(string password, byte[] salt) {
            byte[] bytes = Encoding.UTF8.GetBytes(password);
            try { return Rfc2898DeriveBytes.Pbkdf2(bytes, salt, Iterations, HashAlgorithmName.SHA256, 32); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        public static Vault Create(string path, string password) {
            if (password.Length < 14) throw new ArgumentException("Usa una frase maestra de al menos 14 caracteres.");
            if (File.Exists(path)) throw new IOException("Ya existe una bóveda. Ábrela para conservar tus cuentas.");
            byte[] salt = RandomNumberGenerator.GetBytes(32);
            var vault = new Vault(path, Derive(password, salt), salt, new List<Entry>());
            try { vault.Write(vault.Entries, true); return vault; }
            catch { vault.Dispose(); throw; }
        }
        public static Vault Open(string path, string password) {
            var file = new FileInfo(path);
            if (file.Length > MaxBytes) throw new InvalidDataException("El archivo supera el tamaño permitido.");
            var e = JsonSerializer.Deserialize<Envelope>(File.ReadAllText(path, Encoding.UTF8));
            if (e == null || e.Version != 1 || e.Iterations != Iterations)
                throw new InvalidDataException("Formato de bóveda no compatible.");
            byte[] salt = Convert.FromBase64String(e.Salt);
            byte[] nonce = Convert.FromBase64String(e.Nonce);
            byte[] tag = Convert.FromBase64String(e.Tag);
            byte[] encrypted = Convert.FromBase64String(e.Ciphertext);
            if (salt.Length != 32 || nonce.Length != 12 || tag.Length != 16)
                throw new InvalidDataException("La bóveda está dañada.");
            byte[] key = Derive(password, salt);
            byte[] plain = new byte[encrypted.Length];
            try {
                using (var aes = new AesGcm(key, 16)) aes.Decrypt(nonce, encrypted, tag, plain, Aad);
                var entries = JsonSerializer.Deserialize<List<Entry>>(plain);
                if (entries == null || entries.Exists(x => x == null)) throw new InvalidDataException("Datos no válidos.");
                return new Vault(path, key, salt, entries);
            } catch { CryptographicOperations.ZeroMemory(key); throw; }
            finally { CryptographicOperations.ZeroMemory(plain); }
        }
        public void Save(List<Entry> entries) { Write(entries, false); Entries = entries; }
        void Write(List<Entry> entries, bool create) {
            if (key == null) throw new ObjectDisposedException("Bóveda bloqueada");
            byte[] plain = JsonSerializer.SerializeToUtf8Bytes(entries);
            string temp = Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                if (plain.Length > MaxBytes / 2) throw new InvalidDataException("La bóveda está llena.");
                byte[] nonce = RandomNumberGenerator.GetBytes(12);
                byte[] cipher = new byte[plain.Length];
                byte[] tag = new byte[16];
                using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, plain, cipher, tag, Aad);
                var e = new Envelope { Salt = Convert.ToBase64String(salt), Nonce = Convert.ToBase64String(nonce),
                    Tag = Convert.ToBase64String(tag), Ciphertext = Convert.ToBase64String(cipher) };
                byte[] output = JsonSerializer.SerializeToUtf8Bytes(e);
                using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    stream.Write(output, 0, output.Length); stream.Flush(true);
                }
                if (create) File.Move(temp, Path, false);
                else File.Replace(temp, Path, Path + ".previous", true);
            } finally {
                CryptographicOperations.ZeroMemory(plain);
                if (File.Exists(temp)) File.Delete(temp);
            }
        }
        public void Dispose() {
            if (key != null) { CryptographicOperations.ZeroMemory(key); key = null; }
            Entries.Clear();
        }
        public static string GeneratePassword(int length) {
            if (length < 16 || length > 128) throw new ArgumentOutOfRangeException("length");
            const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*+-=?";
            var result = new char[length];
            // Uniform selection from the entire alphabet with the platform CSPRNG.
            for (int i = 0; i < length; i++) result[i] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
            return new string(result);
        }
    }
}
