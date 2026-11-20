using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OmniCast.Services;

namespace OmniCast.Accounts;

public sealed class AccountException : Exception
{
    public AccountException(string message) : base(message) { }
}

public sealed record OAuthToken(string Access, string Refresh, long Expires)
{
    public bool Expiring => Expires - DateTimeOffset.UtcNow.ToUnixTimeSeconds() < 60;

    public string ToJson() => Discord.Json.Write(new() { ["access"] = Access, ["refresh"] = Refresh, ["expires"] = Expires });

    public static OAuthToken? FromJson(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            return new OAuthToken(r.GetProperty("access").GetString() ?? "", r.GetProperty("refresh").GetString() ?? "", r.GetProperty("expires").GetInt64());
        }
        catch (Exception) { return null; }
    }

    // From a token endpoint's reply; keeps the old refresh token if there's no new one.
    public static OAuthToken FromReply(JsonElement r, string? oldRefresh = null)
    {
        if (!r.TryGetProperty("access_token", out var at) || at.GetString() is not { Length: > 0 } access)
            throw new AccountException(OAuth.ErrorText(r, "No access token"));
        string refresh = r.TryGetProperty("refresh_token", out var rt) && rt.GetString() is { Length: > 0 } s ? s : oldRefresh ?? "";
        long expires = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + (r.TryGetProperty("expires_in", out var e) && e.TryGetInt64(out long ei) ? ei : 3600);
        return new OAuthToken(access, refresh, expires);
    }
}

// Shared OAuth plumbing: secrets and tokens in Credential Manager, form posts,
// PKCE, and the loopback listener that catches a browser sign-in's redirect.
public static class OAuth
{
    public const int Port = 39651;
    public static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public static string? Secret(string name) => Credentials.Read("accounts/" + name);
    public static void SetSecret(string name, string value)
    {
        if (value.Trim().Length > 0) Credentials.Write("accounts/" + name, value.Trim());
    }
    public static void DeleteSecret(string name) => Credentials.Delete("accounts/" + name);

    public static string ErrorText(JsonElement r, string fallback)
    {
        if (r.ValueKind != JsonValueKind.Object) return fallback;
        if (r.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String) return m.GetString()!;
        if (r.TryGetProperty("error_description", out var d) && d.ValueKind == JsonValueKind.String) return d.GetString()!;
        if (r.TryGetProperty("error", out var e))
        {
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty("message", out var em)) return em.GetString() ?? fallback;
            if (e.ValueKind == JsonValueKind.String) return e.GetString()!;
        }
        return fallback;
    }

    // Posts a form; returns (status, JSON body).
    public static async Task<(HttpStatusCode Status, JsonElement Body)> PostFormAsync(string url, Dictionary<string, string> form, CancellationToken ct = default)
    {
        using var res = await Http.PostAsync(url, new FormUrlEncodedContent(form), ct);
        return (res.StatusCode, await ReadJsonAsync(res, ct));
    }

    public static async Task<JsonElement> ReadJsonAsync(HttpResponseMessage res, CancellationToken ct = default)
    {
        string body = await res.Content.ReadAsStringAsync(ct);
        try
        {
            using var doc = JsonDocument.Parse(body.Length > 0 ? body : "{}");
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            using var doc = JsonDocument.Parse("{}");
            return doc.RootElement.Clone();
        }
    }

    public static string Base64Url(byte[] b) => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static (string Verifier, string Challenge, string State) Pkce()
    {
        string verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        string challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        return (verifier, challenge, Base64Url(RandomNumberGenerator.GetBytes(16)));
    }

    public static string Query(Dictionary<string, string> q) =>
        string.Join("&", q.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"{kv.Key}={Uri.EscapeDataString(kv.Value)}"));

    public static void OpenBrowser(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    // Opens the sign-in page and waits (up to 5 minutes) for the browser to come
    // back to http://localhost:39651 or http://127.0.0.1:39651 with ?code=…&state=….
    // Listens on the loopback interface only, never the network.
    public static async Task<string> AuthorizeAsync(string url, string state, CancellationToken ct = default)
    {
        var listeners = new List<TcpListener>();
        foreach (var addr in new[] { IPAddress.Loopback, IPAddress.IPv6Loopback })
        {
            try
            {
                var l = new TcpListener(addr, Port);
                l.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                l.Start();
                listeners.Add(l);
            }
            catch (SocketException) { }
        }
        if (listeners.Count == 0)
            throw new AccountException($"Couldn't listen for the sign-in on port {Port}. Is another sign-in open?");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        try
        {
            OpenBrowser(url);
            var accepts = listeners.Select(l => l.AcceptTcpClientAsync(timeout.Token).AsTask()).ToList();
            while (true)
            {
                Task<TcpClient> done;
                try { done = await Task.WhenAny(accepts); }
                catch (OperationCanceledException) { throw new AccountException("Sign-in timed out"); }
                int i = accepts.IndexOf(done);
                TcpClient client;
                try { client = await done; }
                catch (OperationCanceledException) { throw new AccountException("Sign-in timed out"); }
                accepts[i] = listeners[i].AcceptTcpClientAsync(timeout.Token).AsTask();
                using (client)
                {
                    var (code, error) = await HandleAsync(client, state);
                    if (error != null) throw new AccountException(error);
                    if (code != null) return code;
                }
            }
        }
        finally
        {
            foreach (var l in listeners) l.Stop();
        }
    }

    // Reads one HTTP request and answers it. Returns the code, an error, or neither (e.g. /favicon.ico).
    private static async Task<(string? Code, string? Error)> HandleAsync(TcpClient client, string state)
    {
        var stream = client.GetStream();
        var buf = new byte[8192];
        int n = await stream.ReadAsync(buf);
        string request = Encoding.ASCII.GetString(buf, 0, n);
        string target = request.Split(' ').Skip(1).FirstOrDefault() ?? "/";
        var q = new Dictionary<string, string>();
        int qi = target.IndexOf('?');
        if (qi >= 0)
            foreach (var kv in target[(qi + 1)..].Split('&'))
            {
                int eq = kv.IndexOf('=');
                if (eq > 0) q[Uri.UnescapeDataString(kv[..eq])] = Uri.UnescapeDataString(kv[(eq + 1)..].Replace('+', ' '));
            }
        string? code = null, error = null;
        if (q.TryGetValue("error", out var e))
            error = q.GetValueOrDefault("error_description") ?? e;
        else if (q.TryGetValue("code", out var c))
        {
            if (q.GetValueOrDefault("state") == state) code = c;
            else error = "The sign-in reply didn't match (state)";
        }
        string message = code != null ? "Signed in. You can close this tab and go back to OmniCast."
            : error != null ? $"Sign-in didn't finish: {WebUtility.HtmlEncode(error)}. Try again from OmniCast." : "";
        string html = $"<html><body style=\"font:16px 'Segoe UI',sans-serif;padding:40px\">{message}</body></html>";
        byte[] body = Encoding.UTF8.GetBytes(html);
        string head = $"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
        await stream.WriteAsync(body);
        return (code, error);
    }
}
