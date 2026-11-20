using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Accounts;

public sealed record Category(string Id, string Name, string Image);

public sealed record StreamChannel(string Title, Category? Game);

// One platform's sign-in and channel API. Each platform needs an app the user
// registers (their own Client ID, plus a Secret for Kick and YouTube): the
// steps are in Settings › Accounts.
public abstract class StreamAccount
{
    public abstract string Key { get; }  // twitch, kick, youtube
    public abstract string Name { get; }
    public abstract bool HasGame { get; }
    public abstract bool NeedsSecret { get; }

    protected static AccountsSettings A => EngineHost.Current.Settings.Accounts;
    public string ClientId
    {
        get => A.ClientIds.GetValueOrDefault(Key) ?? "";
        set { A.ClientIds[Key] = value.Trim(); EngineHost.Current.Settings.Save(); }
    }
    public string Login
    {
        get => A.Logins.GetValueOrDefault(Key) ?? "";
        protected set { if (value.Length > 0) A.Logins[Key] = value; else A.Logins.Remove(Key); EngineHost.Current.Settings.Save(); }
    }
    public bool Connected => Login.Length > 0;
    public bool HasSecret => OAuth.Secret(Key + ".secret") is { Length: > 0 };
    public void SetSecret(string s) => OAuth.SetSecret(Key + ".secret", s);

    protected OAuthToken? Token
    {
        get => OAuthToken.FromJson(OAuth.Secret(Key + ".token"));
        set { if (value == null) OAuth.DeleteSecret(Key + ".token"); else OAuth.SetSecret(Key + ".token", value.ToJson()); }
    }

    public void SignOut()
    {
        Token = null;
        Login = "";
    }

    // A fresh access token (refreshed when it's about to run out).
    protected async Task<string> AccessAsync(CancellationToken ct)
    {
        var t = Token ?? throw new AccountException($"{Name} isn't connected. Connect it in Settings › Accounts.");
        if (!t.Expiring) return t.Access;
        try
        {
            t = await RefreshAsync(t, ct);
            Token = t;
            return t.Access;
        }
        catch (Exception)
        {
            SignOut();
            throw new AccountException($"{Name} signed you out. Connect again in Settings › Accounts.");
        }
    }

    protected async Task<JsonElement> SendAsync(HttpMethod method, string url, string? json, CancellationToken ct, Action<HttpRequestHeaders>? headers = null)
    {
        string access = await AccessAsync(ct);
        using var req = new HttpRequestMessage(method, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
        req.Headers.Accept.ParseAdd("application/json");
        headers?.Invoke(req.Headers);
        if (json != null) req.Content = new StringContent(json, Encoding.UTF8, "application/json");
        using var res = await OAuth.Http.SendAsync(req, ct);
        var body = await OAuth.ReadJsonAsync(res, ct);
        if (!res.IsSuccessStatusCode)
            throw new AccountException(OAuth.ErrorText(body, $"Request failed ({(int)res.StatusCode})"));
        return body;
    }

    public abstract Task ConnectAsync(Action<string> progress, CancellationToken ct);
    protected abstract Task<OAuthToken> RefreshAsync(OAuthToken old, CancellationToken ct);
    public abstract Task<StreamChannel> GetAsync(CancellationToken ct);
    public abstract Task UpdateAsync(string? title, Category? game, CancellationToken ct);
    public virtual Task<List<Category>> SearchAsync(string query, CancellationToken ct) => Task.FromResult(new List<Category>());

    protected static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) ? v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : v.ValueKind == JsonValueKind.Number ? v.ToString() : "" : "";
}

// ---------------------------------------------------------------- Twitch: device code, no secret

public sealed class TwitchAccount : StreamAccount
{
    public override string Key => "twitch";
    public override string Name => "Twitch";
    public override bool HasGame => true;
    public override bool NeedsSecret => false;
    private const string Scopes = "channel:manage:broadcast";

    private void Headers(HttpRequestHeaders h) => h.Add("Client-Id", ClientId);

    public override async Task ConnectAsync(Action<string> progress, CancellationToken ct)
    {
        if (ClientId.Length == 0) throw new AccountException("Paste your Twitch Client ID first");
        var (status, dev) = await OAuth.PostFormAsync("https://id.twitch.tv/oauth2/device", new() { ["client_id"] = ClientId, ["scopes"] = Scopes }, ct);
        if (status != HttpStatusCode.OK) throw new AccountException(OAuth.ErrorText(dev, "Twitch didn't accept the Client ID"));
        string device = Str(dev, "device_code"), code = Str(dev, "user_code"), uri = Str(dev, "verification_uri");
        int interval = Math.Max(2, int.TryParse(Str(dev, "interval"), out int iv) ? iv : 5);
        var deadline = DateTime.UtcNow.AddSeconds(int.TryParse(Str(dev, "expires_in"), out int ex) ? ex : 1800);
        progress($"Enter {code} at twitch.tv/activate (opened in your browser).");
        OAuth.OpenBrowser(uri.Length > 0 ? uri : "https://www.twitch.tv/activate");
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromSeconds(interval), ct);
            var (s, body) = await OAuth.PostFormAsync("https://id.twitch.tv/oauth2/token", new()
            {
                ["client_id"] = ClientId, ["scopes"] = Scopes, ["device_code"] = device,
                ["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code",
            }, ct);
            if (s == HttpStatusCode.OK)
            {
                Token = OAuthToken.FromReply(body);
                var users = await SendAsync(HttpMethod.Get, "https://api.twitch.tv/helix/users", null, ct, Headers);
                var u = users.GetProperty("data")[0];
                A.TwitchUserId = Str(u, "id");
                Login = Str(u, "display_name") is { Length: > 0 } dn ? dn : Str(u, "login");
                return;
            }
            if (Str(body, "message") != "authorization_pending")
                throw new AccountException(OAuth.ErrorText(body, "Twitch sign-in failed"));
        }
        throw new AccountException("The Twitch code expired. Try again.");
    }

    protected override async Task<OAuthToken> RefreshAsync(OAuthToken old, CancellationToken ct)
    {
        var (s, body) = await OAuth.PostFormAsync("https://id.twitch.tv/oauth2/token", new() { ["grant_type"] = "refresh_token", ["refresh_token"] = old.Refresh, ["client_id"] = ClientId }, ct);
        if (s != HttpStatusCode.OK) throw new AccountException(OAuth.ErrorText(body, "refresh failed"));
        return OAuthToken.FromReply(body, old.Refresh);
    }

    public override async Task<StreamChannel> GetAsync(CancellationToken ct)
    {
        var r = await SendAsync(HttpMethod.Get, $"https://api.twitch.tv/helix/channels?broadcaster_id={A.TwitchUserId}", null, ct, Headers);
        var c = r.GetProperty("data")[0];
        string gid = Str(c, "game_id");
        return new StreamChannel(Str(c, "title"), gid.Length > 0 ? new Category(gid, Str(c, "game_name"), "") : null);
    }

    public override async Task UpdateAsync(string? title, Category? game, CancellationToken ct)
    {
        var body = new Dictionary<string, object?>();
        if (title != null) body["title"] = title;
        if (game != null) body["game_id"] = game.Id;
        await SendAsync(HttpMethod.Patch, $"https://api.twitch.tv/helix/channels?broadcaster_id={A.TwitchUserId}", Discord.Json.Write(body), ct, Headers);
    }

    public override async Task<List<Category>> SearchAsync(string query, CancellationToken ct)
    {
        var r = await SendAsync(HttpMethod.Get, $"https://api.twitch.tv/helix/search/categories?query={Uri.EscapeDataString(query)}&first=12", null, ct, Headers);
        return r.GetProperty("data").EnumerateArray()
            .Select(d => new Category(Str(d, "id"), Str(d, "name"), Str(d, "box_art_url").Replace("{width}", "52").Replace("{height}", "72"))).ToList();
    }
}

// ---------------------------------------------------------------- Kick: OAuth 2.1 + PKCE, loopback

public sealed class KickAccount : StreamAccount
{
    public override string Key => "kick";
    public override string Name => "Kick";
    public override bool HasGame => true;
    public override bool NeedsSecret => true;
    public static readonly string Redirect = $"http://localhost:{OAuth.Port}/callback";

    public override async Task ConnectAsync(Action<string> progress, CancellationToken ct)
    {
        string? secret = OAuth.Secret("kick.secret");
        if (ClientId.Length == 0 || string.IsNullOrEmpty(secret)) throw new AccountException("Paste your Kick Client ID and Secret first");
        var (verifier, challenge, state) = OAuth.Pkce();
        string url = "https://id.kick.com/oauth/authorize?" + OAuth.Query(new()
        {
            ["client_id"] = ClientId, ["code_challenge"] = challenge, ["code_challenge_method"] = "S256",
            ["redirect_uri"] = Redirect, ["response_type"] = "code", ["scope"] = "user:read channel:read channel:write", ["state"] = state,
        });
        progress("Allow access in your browser…");
        string code = await OAuth.AuthorizeAsync(url, state, ct);
        var (s, body) = await OAuth.PostFormAsync("https://id.kick.com/oauth/token", new()
        {
            ["grant_type"] = "authorization_code", ["client_id"] = ClientId, ["client_secret"] = secret,
            ["redirect_uri"] = Redirect, ["code_verifier"] = verifier, ["code"] = code,
        }, ct);
        if (s is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized)
            throw new AccountException($"Kick didn't accept the Client ID or Secret, or the app's redirect URL isn't {Redirect}");
        if (s != HttpStatusCode.OK) throw new AccountException(OAuth.ErrorText(body, "Kick sign-in failed"));
        Token = OAuthToken.FromReply(body);
        var me = await SendAsync(HttpMethod.Get, "https://api.kick.com/public/v1/channels", null, ct);
        Login = Str(me.GetProperty("data")[0], "slug") is { Length: > 0 } slug ? slug : "Kick";
    }

    protected override async Task<OAuthToken> RefreshAsync(OAuthToken old, CancellationToken ct)
    {
        var (s, body) = await OAuth.PostFormAsync("https://id.kick.com/oauth/token", new()
        {
            ["grant_type"] = "refresh_token", ["refresh_token"] = old.Refresh, ["client_id"] = ClientId, ["client_secret"] = OAuth.Secret("kick.secret") ?? "",
        }, ct);
        if (s != HttpStatusCode.OK) throw new AccountException(OAuth.ErrorText(body, "refresh failed"));
        return OAuthToken.FromReply(body, old.Refresh);
    }

    public override async Task<StreamChannel> GetAsync(CancellationToken ct)
    {
        var r = await SendAsync(HttpMethod.Get, "https://api.kick.com/public/v1/channels", null, ct);
        var c = r.GetProperty("data")[0];
        Category? game = null;
        if (c.TryGetProperty("category", out var cat) && cat.ValueKind == JsonValueKind.Object && Str(cat, "id").Length > 0)
            game = new Category(Str(cat, "id"), Str(cat, "name"), Str(cat, "thumbnail"));
        return new StreamChannel(Str(c, "stream_title"), game);
    }

    public override async Task UpdateAsync(string? title, Category? game, CancellationToken ct)
    {
        var body = new Dictionary<string, object?>();
        if (title != null) body["stream_title"] = title;
        if (game != null && long.TryParse(game.Id, out long id)) body["category_id"] = id;
        await SendAsync(HttpMethod.Patch, "https://api.kick.com/public/v1/channels", Discord.Json.Write(body), ct);
    }

    public override async Task<List<Category>> SearchAsync(string query, CancellationToken ct)
    {
        JsonElement r;
        try { r = await SendAsync(HttpMethod.Get, $"https://api.kick.com/public/v2/categories?name={Uri.EscapeDataString(query)}&limit=12", null, ct); }
        catch (AccountException) { r = await SendAsync(HttpMethod.Get, $"https://api.kick.com/public/v1/categories?q={Uri.EscapeDataString(query)}", null, ct); }
        return r.GetProperty("data").EnumerateArray().Take(12).Select(d => new Category(Str(d, "id"), Str(d, "name"), Str(d, "thumbnail"))).ToList();
    }
}

// ---------------------------------------------------------------- YouTube: Google OAuth, PKCE, loopback; title only

public sealed class YouTubeAccount : StreamAccount
{
    public override string Key => "youtube";
    public override string Name => "YouTube";
    public override bool HasGame => false;
    public override bool NeedsSecret => true;
    private static readonly string Redirect = $"http://127.0.0.1:{OAuth.Port}";

    public override async Task ConnectAsync(Action<string> progress, CancellationToken ct)
    {
        string? secret = OAuth.Secret("youtube.secret");
        if (ClientId.Length == 0 || string.IsNullOrEmpty(secret)) throw new AccountException("Paste your Google Client ID and Secret first");
        var (verifier, challenge, state) = OAuth.Pkce();
        string url = "https://accounts.google.com/o/oauth2/v2/auth?" + OAuth.Query(new()
        {
            ["client_id"] = ClientId, ["redirect_uri"] = Redirect, ["response_type"] = "code", ["scope"] = "https://www.googleapis.com/auth/youtube",
            ["code_challenge"] = challenge, ["code_challenge_method"] = "S256", ["access_type"] = "offline", ["prompt"] = "consent", ["state"] = state,
        });
        progress("Sign in with Google in your browser…");
        string code = await OAuth.AuthorizeAsync(url, state, ct);
        var (s, body) = await OAuth.PostFormAsync("https://oauth2.googleapis.com/token", new()
        {
            ["grant_type"] = "authorization_code", ["client_id"] = ClientId, ["client_secret"] = secret,
            ["redirect_uri"] = Redirect, ["code_verifier"] = verifier, ["code"] = code,
        }, ct);
        if (s != HttpStatusCode.OK) throw new AccountException(OAuth.ErrorText(body, "Google sign-in failed"));
        Token = OAuthToken.FromReply(body);
        var me = await SendAsync(HttpMethod.Get, "https://www.googleapis.com/youtube/v3/channels?mine=true&part=snippet", null, ct);
        var sn = me.TryGetProperty("items", out var items) && items.GetArrayLength() > 0 ? items[0].GetProperty("snippet") : default;
        Login = Str(sn, "customUrl") is { Length: > 0 } cu ? cu : Str(sn, "title") is { Length: > 0 } t ? t : "YouTube";
    }

    protected override async Task<OAuthToken> RefreshAsync(OAuthToken old, CancellationToken ct)
    {
        var (s, body) = await OAuth.PostFormAsync("https://oauth2.googleapis.com/token", new()
        {
            ["grant_type"] = "refresh_token", ["refresh_token"] = old.Refresh, ["client_id"] = ClientId, ["client_secret"] = OAuth.Secret("youtube.secret") ?? "",
        }, ct);
        if (s != HttpStatusCode.OK) throw new AccountException(OAuth.ErrorText(body, "refresh failed"));
        return OAuthToken.FromReply(body, old.Refresh);
    }

    private async Task<JsonElement?> BroadcastAsync(CancellationToken ct)
    {
        foreach (var status in new[] { "active", "upcoming" })
        {
            var r = await SendAsync(HttpMethod.Get, $"https://www.googleapis.com/youtube/v3/liveBroadcasts?broadcastStatus={status}&broadcastType=all&part=snippet", null, ct);
            if (r.TryGetProperty("items", out var items) && items.GetArrayLength() > 0) return items[0];
        }
        return null;
    }

    public override async Task<StreamChannel> GetAsync(CancellationToken ct)
    {
        var b = await BroadcastAsync(ct);
        return new StreamChannel(b is JsonElement e ? Str(e.GetProperty("snippet"), "title") : "", null);
    }

    public override async Task UpdateAsync(string? title, Category? game, CancellationToken ct)
    {
        if (title == null) return;
        var b = await BroadcastAsync(ct) ?? throw new AccountException("No live or scheduled YouTube stream to rename yet. Go live (or schedule one) first.");
        var sn = b.GetProperty("snippet");
        // The PUT replaces the whole snippet: keep what's there.
        var snippet = new Dictionary<string, object?> { ["title"] = title };
        foreach (var k in new[] { "description", "scheduledStartTime", "scheduledEndTime" })
            if (Str(sn, k) is { Length: > 0 } v) snippet[k] = v;
        await SendAsync(HttpMethod.Put, "https://www.googleapis.com/youtube/v3/liveBroadcasts?part=snippet",
            Discord.Json.Write(new() { ["id"] = Str(b, "id"), ["snippet"] = snippet }), ct);
    }
}

public static class StreamAccounts
{
    public static readonly TwitchAccount Twitch = new();
    public static readonly KickAccount Kick = new();
    public static readonly YouTubeAccount YouTube = new();
    public static readonly StreamAccount[] All = { YouTube, Twitch, Kick };
}
