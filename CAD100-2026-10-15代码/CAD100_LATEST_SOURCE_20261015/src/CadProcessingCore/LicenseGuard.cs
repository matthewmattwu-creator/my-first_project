using System;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace CadFrameReplacer
{
    public sealed class LicenseResult
    {
        public bool Success { get; private set; }
        public string Message { get; private set; }
        public string Name { get; private set; }
        public int DevicesUsed { get; private set; }
        public int DevicesLimit { get; private set; }
        public bool Offline { get; private set; }

        private LicenseResult() { }

        public static LicenseResult Ok(string message, string name, int used, int limit, bool offline)
        {
            return new LicenseResult
            {
                Success = true,
                Message = message ?? string.Empty,
                Name = name ?? string.Empty,
                DevicesUsed = used,
                DevicesLimit = limit,
                Offline = offline
            };
        }

        public static LicenseResult Fail(string message)
        {
            return new LicenseResult
            {
                Success = false,
                Message = string.IsNullOrWhiteSpace(message) ? "授权校验失败。" : message,
                Name = string.Empty,
                DevicesUsed = 0,
                DevicesLimit = 0,
                Offline = false
            };
        }
    }

    [DataContract]
    internal sealed class ActivateRequest
    {
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "code")] public string Code { get; set; }
        [DataMember(Name = "device_id")] public string DeviceId { get; set; }
        [DataMember(Name = "device_name")] public string DeviceName { get; set; }
        [DataMember(Name = "app_version")] public string AppVersion { get; set; }
    }

    [DataContract]
    internal sealed class CheckRequest
    {
        [DataMember(Name = "token")] public string Token { get; set; }
        [DataMember(Name = "device_id")] public string DeviceId { get; set; }
        [DataMember(Name = "app_version")] public string AppVersion { get; set; }
    }

    [DataContract]
    internal sealed class ServerLicenseResponse
    {
        [DataMember(Name = "success")] public bool Success { get; set; }
        [DataMember(Name = "valid")] public bool Valid { get; set; }
        [DataMember(Name = "token")] public string Token { get; set; }
        [DataMember(Name = "message")] public string Message { get; set; }
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "devices_used")] public int DevicesUsed { get; set; }
        [DataMember(Name = "devices_limit")] public int DevicesLimit { get; set; }
        [DataMember(Name = "offline_until_utc")] public string OfflineUntilUtc { get; set; }
    }

    [DataContract]
    internal sealed class CachedLicense
    {
        [DataMember(Name = "token")] public string Token { get; set; }
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "device_id")] public string DeviceId { get; set; }
        [DataMember(Name = "last_server_validation_utc")] public string LastServerValidationUtc { get; set; }
        [DataMember(Name = "offline_until_utc")] public string OfflineUntilUtc { get; set; }
        [DataMember(Name = "last_seen_utc")] public string LastSeenUtc { get; set; }
        [DataMember(Name = "devices_used")] public int DevicesUsed { get; set; }
        [DataMember(Name = "devices_limit")] public int DevicesLimit { get; set; }
    }

    [DataContract]
    internal sealed class SignedTokenPayload
    {
        [DataMember(Name = "uid")] public int UserId { get; set; }
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "device_id")] public string DeviceId { get; set; }
        [DataMember(Name = "iat")] public long IssuedAt { get; set; }
        [DataMember(Name = "exp")] public long ExpiresAt { get; set; }
    }

    public static class LicenseClient
    {
        public const string AppVersion = "2.0.0";
        private const string PublicKeyXmlBase64 = "__CAD100_PUBLIC_KEY_XML_BASE64__";
        private static readonly byte[] CacheEntropy = Encoding.UTF8.GetBytes("CAD-100-License-v2");
        private static readonly object Sync = new object();

        public static string DeviceId
        {
            get { return BuildDeviceId(); }
        }

        public static string DeviceName
        {
            get { return Environment.MachineName; }
        }

        public static LicenseResult Activate(string name, string code)
        {
            name = (name ?? string.Empty).Trim();
            code = (code ?? string.Empty).Trim();
            if (name.Length == 0) return LicenseResult.Fail("请输入姓名。");
            if (code.Length == 0) return LicenseResult.Fail("请输入激活码。");

            string keyError;
            if (!HasProductionPublicKey(out keyError)) return LicenseResult.Fail(keyError);

            try
            {
                var response = PostJson("/api/v1/activate", new ActivateRequest
                {
                    Name = name,
                    Code = code,
                    DeviceId = DeviceId,
                    DeviceName = DeviceName,
                    AppVersion = AppVersion
                });

                if (response == null || !response.Success || string.IsNullOrWhiteSpace(response.Token))
                    return LicenseResult.Fail(response == null ? "授权服务器未返回有效结果。" : response.Message);

                SignedTokenPayload payload;
                string tokenError;
                if (!VerifySignedToken(response.Token, DeviceId, out payload, out tokenError))
                    return LicenseResult.Fail("服务器授权签名无效：" + tokenError);

                DateTime now = DateTime.UtcNow;
                DateTime offlineUntil = ParseUtcOrDefault(response.OfflineUntilUtc, now.AddDays(7));
                var cached = new CachedLicense
                {
                    Token = response.Token,
                    Name = string.IsNullOrWhiteSpace(response.Name) ? payload.Name : response.Name,
                    DeviceId = DeviceId,
                    LastServerValidationUtc = ToUtcString(now),
                    OfflineUntilUtc = ToUtcString(offlineUntil),
                    LastSeenUtc = ToUtcString(now),
                    DevicesUsed = response.DevicesUsed,
                    DevicesLimit = response.DevicesLimit
                };
                SaveCache(cached);
                return LicenseResult.Ok(response.Message ?? "授权成功。", cached.Name, cached.DevicesUsed, cached.DevicesLimit, false);
            }
            catch (Exception ex)
            {
                return LicenseResult.Fail("无法连接授权服务器：" + FriendlyNetworkMessage(ex));
            }
        }

        public static LicenseResult ValidateCached(bool allowOffline)
        {
            lock (Sync)
            {
                CachedLicense cached;
                string cacheError;
                if (!TryLoadCache(out cached, out cacheError)) return LicenseResult.Fail(cacheError);

                if (!string.Equals(cached.DeviceId, DeviceId, StringComparison.OrdinalIgnoreCase))
                    return LicenseResult.Fail("本机授权与当前电脑不匹配，请重新激活。");

                SignedTokenPayload payload;
                string tokenError;
                if (!VerifySignedToken(cached.Token, DeviceId, out payload, out tokenError))
                    return LicenseResult.Fail("本机授权签名无效：" + tokenError);

                DateTime now = DateTime.UtcNow;
                DateTime lastSeen = ParseUtcOrDefault(cached.LastSeenUtc, now);
                if (now < lastSeen.AddMinutes(-10))
                    return LicenseResult.Fail("检测到系统时间明显回退，请校准 Windows 时间后重试。");

                DateTime offlineUntil = ParseUtcOrDefault(cached.OfflineUntilUtc, DateTime.MinValue);
                string apiBase = GetApiBaseUrl();
                if (string.IsNullOrWhiteSpace(apiBase))
                {
                    if (allowOffline && now <= offlineUntil)
                    {
                        cached.LastSeenUtc = ToUtcString(now);
                        SaveCache(cached);
                        return LicenseResult.Ok("离线授权有效。", cached.Name, cached.DevicesUsed, cached.DevicesLimit, true);
                    }
                    return LicenseResult.Fail("授权服务器地址尚未配置。");
                }

                try
                {
                    var response = PostJson("/api/v1/check", new CheckRequest
                    {
                        Token = cached.Token,
                        DeviceId = DeviceId,
                        AppVersion = AppVersion
                    });

                    if (response == null || (!response.Success && !response.Valid))
                    {
                        DeleteCache();
                        return LicenseResult.Fail(response == null ? "授权服务器未返回有效结果。" : response.Message);
                    }

                    string refreshedToken = string.IsNullOrWhiteSpace(response.Token) ? cached.Token : response.Token;
                    SignedTokenPayload refreshedPayload;
                    if (!VerifySignedToken(refreshedToken, DeviceId, out refreshedPayload, out tokenError))
                    {
                        DeleteCache();
                        return LicenseResult.Fail("服务器返回的授权签名无效：" + tokenError);
                    }

                    cached.Token = refreshedToken;
                    cached.Name = string.IsNullOrWhiteSpace(response.Name) ? refreshedPayload.Name : response.Name;
                    cached.LastServerValidationUtc = ToUtcString(now);
                    cached.OfflineUntilUtc = ToUtcString(ParseUtcOrDefault(response.OfflineUntilUtc, now.AddDays(7)));
                    cached.LastSeenUtc = ToUtcString(now);
                    if (response.DevicesLimit > 0) cached.DevicesLimit = response.DevicesLimit;
                    if (response.DevicesUsed >= 0) cached.DevicesUsed = response.DevicesUsed;
                    SaveCache(cached);
                    return LicenseResult.Ok(response.Message ?? "授权有效。", cached.Name, cached.DevicesUsed, cached.DevicesLimit, false);
                }
                catch (Exception ex)
                {
                    if (allowOffline && now <= offlineUntil)
                    {
                        cached.LastSeenUtc = ToUtcString(now);
                        SaveCache(cached);
                        return LicenseResult.Ok("授权服务器暂时不可达，正在使用离线授权。", cached.Name, cached.DevicesUsed, cached.DevicesLimit, true);
                    }
                    return LicenseResult.Fail("授权服务器不可达且离线授权已过期：" + FriendlyNetworkMessage(ex));
                }
            }
        }

        public static void ClearLocalLicense()
        {
            lock (Sync) DeleteCache();
        }

        private static bool HasProductionPublicKey(out string error)
        {
            if (PublicKeyXmlBase64.StartsWith("__CAD100_", StringComparison.Ordinal))
            {
                error = "授权公钥尚未写入程序。请使用 build.ps1 的 -LicensePublicKeyPath 参数构建授权版。";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private static ServerLicenseResponse PostJson<T>(string path, T payload)
        {
            string apiBase = GetApiBaseUrl();
            if (string.IsNullOrWhiteSpace(apiBase))
                throw new InvalidOperationException("LicenseApiBaseUrl 未配置。");

            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(apiBase.TrimEnd('/') + path);
            request.Method = "POST";
            request.ContentType = "application/json; charset=utf-8";
            request.Accept = "application/json";
            request.UserAgent = "CAD-100/" + AppVersion;
            request.Timeout = 5000;
            request.ReadWriteTimeout = 5000;

            var serializer = new DataContractJsonSerializer(typeof(T));
            byte[] body;
            using (var ms = new MemoryStream())
            {
                serializer.WriteObject(ms, payload);
                body = ms.ToArray();
            }
            request.ContentLength = body.Length;
            using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);

            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                using (var stream = response.GetResponseStream())
                    return DeserializeResponse(stream);
            }
            catch (WebException ex)
            {
                if (ex.Response != null)
                {
                    using (var response = ex.Response)
                    using (var stream = response.GetResponseStream())
                    {
                        var parsed = DeserializeResponse(stream);
                        if (parsed != null) return parsed;
                    }
                }
                throw;
            }
        }

        private static ServerLicenseResponse DeserializeResponse(Stream stream)
        {
            if (stream == null) return null;
            var serializer = new DataContractJsonSerializer(typeof(ServerLicenseResponse));
            return serializer.ReadObject(stream) as ServerLicenseResponse;
        }

        private static string GetApiBaseUrl()
        {
            try
            {
                return (ConfigurationManager.AppSettings["LicenseApiBaseUrl"] ?? string.Empty).Trim();
            }
            catch
            {
                return string.Empty;
            }
        }

        private static bool VerifySignedToken(string token, string expectedDeviceId, out SignedTokenPayload payload, out string error)
        {
            payload = null;
            error = string.Empty;
            string keyError;
            if (!HasProductionPublicKey(out keyError))
            {
                error = keyError;
                return false;
            }
            if (string.IsNullOrWhiteSpace(token))
            {
                error = "令牌为空。";
                return false;
            }

            string[] parts = token.Split('.');
            if (parts.Length != 2)
            {
                error = "令牌格式错误。";
                return false;
            }

            try
            {
                byte[] signature = Base64UrlDecode(parts[1]);
                string xml = Encoding.UTF8.GetString(Convert.FromBase64String(PublicKeyXmlBase64));
                var csp = new CspParameters { ProviderType = 24 };
                using (var rsa = new RSACryptoServiceProvider(csp))
                {
                    rsa.PersistKeyInCsp = false;
                    rsa.FromXmlString(xml);
                    byte[] signedBytes = Encoding.UTF8.GetBytes(parts[0]);
                    string sha256Oid = CryptoConfig.MapNameToOID("SHA256");
                    if (!rsa.VerifyData(signedBytes, sha256Oid, signature))
                    {
                        error = "RSA 签名校验失败。";
                        return false;
                    }
                }

                byte[] json = Base64UrlDecode(parts[0]);
                using (var ms = new MemoryStream(json))
                {
                    var serializer = new DataContractJsonSerializer(typeof(SignedTokenPayload));
                    payload = serializer.ReadObject(ms) as SignedTokenPayload;
                }
                if (payload == null)
                {
                    error = "令牌内容为空。";
                    return false;
                }
                if (!string.Equals(payload.DeviceId, expectedDeviceId, StringComparison.OrdinalIgnoreCase))
                {
                    error = "令牌不属于当前电脑。";
                    return false;
                }
                if (DateTime.UtcNow > FromUnixSeconds(payload.ExpiresAt))
                {
                    error = "令牌已过期。";
                    return false;
                }
                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                payload = null;
                return false;
            }
        }

        private static string BuildDeviceId()
        {
            string machineGuid = string.Empty;
            try
            {
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var key = baseKey.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"))
                    machineGuid = Convert.ToString(key == null ? null : key.GetValue("MachineGuid"), CultureInfo.InvariantCulture) ?? string.Empty;
            }
            catch { }
            if (string.IsNullOrWhiteSpace(machineGuid))
            {
                try
                {
                    using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"))
                        machineGuid = Convert.ToString(key == null ? null : key.GetValue("MachineGuid"), CultureInfo.InvariantCulture) ?? string.Empty;
                }
                catch { }
            }

            string raw = "CAD100|" + machineGuid.Trim() + "|" + Environment.MachineName.Trim().ToUpperInvariant();
            using (var sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
                var sb = new StringBuilder(hash.Length * 2);
                for (int i = 0; i < hash.Length; i++) sb.Append(hash[i].ToString("x2", CultureInfo.InvariantCulture));
                return sb.ToString();
            }
        }

        private static string CachePath
        {
            get
            {
                string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return Path.Combine(root, "CAD-100", "license.bin");
            }
        }

        private static void SaveCache(CachedLicense cached)
        {
            string directory = Path.GetDirectoryName(CachePath);
            if (!Directory.Exists(directory)) Directory.CreateDirectory(directory);
            byte[] plain;
            var serializer = new DataContractJsonSerializer(typeof(CachedLicense));
            using (var ms = new MemoryStream())
            {
                serializer.WriteObject(ms, cached);
                plain = ms.ToArray();
            }
            byte[] protectedBytes = ProtectedData.Protect(plain, CacheEntropy, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(CachePath, protectedBytes);
        }

        private static bool TryLoadCache(out CachedLicense cached, out string error)
        {
            cached = null;
            error = string.Empty;
            if (!File.Exists(CachePath))
            {
                error = "此电脑尚未激活。";
                return false;
            }
            try
            {
                byte[] protectedBytes = File.ReadAllBytes(CachePath);
                byte[] plain = ProtectedData.Unprotect(protectedBytes, CacheEntropy, DataProtectionScope.CurrentUser);
                var serializer = new DataContractJsonSerializer(typeof(CachedLicense));
                using (var ms = new MemoryStream(plain))
                    cached = serializer.ReadObject(ms) as CachedLicense;
                if (cached == null || string.IsNullOrWhiteSpace(cached.Token))
                {
                    error = "本机授权文件损坏，请重新激活。";
                    return false;
                }
                return true;
            }
            catch
            {
                error = "本机授权文件无法读取，请重新激活。";
                return false;
            }
        }

        private static void DeleteCache()
        {
            try { if (File.Exists(CachePath)) File.Delete(CachePath); }
            catch { }
        }

        private static string FriendlyNetworkMessage(Exception ex)
        {
            if (ex == null) return "未知网络错误。";
            if (ex is WebException) return ((WebException)ex).Status + " / " + ex.Message;
            return ex.Message;
        }

        private static DateTime ParseUtcOrDefault(string value, DateTime fallback)
        {
            DateTime parsed;
            if (!string.IsNullOrWhiteSpace(value) && DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
                return parsed.ToUniversalTime();
            return fallback;
        }

        private static string ToUtcString(DateTime value)
        {
            return value.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
        }

        private static DateTime FromUnixSeconds(long seconds)
        {
            return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(seconds);
        }

        private static byte[] Base64UrlDecode(string value)
        {
            string s = value.Replace('-', '+').Replace('_', '/');
            switch (s.Length % 4)
            {
                case 2: s += "=="; break;
                case 3: s += "="; break;
            }
            return Convert.FromBase64String(s);
        }
    }

    public static class CoreLicenseGuard
    {
        public static void EnsureAuthorized(string operation)
        {
            LicenseResult result = LicenseClient.ValidateCached(true);
            if (!result.Success)
                throw new UnauthorizedAccessException("授权校验失败（" + operation + "）：" + result.Message);
        }
    }
}
