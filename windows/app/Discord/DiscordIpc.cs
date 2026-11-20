using System;
using System.Buffers.Binary;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OmniCast.Discord;

// One connection to a running Discord client's local RPC pipe
// (\\.\pipe\discord-ipc-N). Frames are [opcode u32 LE][length u32 LE][JSON].
public sealed class DiscordIpc : IDisposable
{
    public enum Op : uint { Handshake = 0, Frame = 1, Close = 2, Ping = 3, Pong = 4 }

    private readonly NamedPipeClientStream _pipe;
    private readonly SemaphoreSlim _write = new(1, 1);
    public int Index { get; }

    public event Action<JsonElement>? Message; // called on the reader thread
    public event Action<string>? Closed;

    private DiscordIpc(NamedPipeClientStream pipe, int index)
    {
        _pipe = pipe;
        Index = index;
    }

    // Every Discord client listening on this PC (Discord, PTB, Canary can all run at once).
    public static int[] Running()
    {
        try
        {
            var names = Directory.GetFiles(@"\\.\pipe\");
            var found = new System.Collections.Generic.List<int>();
            for (int i = 0; i < 10; i++)
                if (Array.Exists(names, n => n.EndsWith($"discord-ipc-{i}", StringComparison.OrdinalIgnoreCase)))
                    found.Add(i);
            return found.ToArray();
        }
        catch (Exception)
        {
            return Array.Empty<int>();
        }
    }

    public static async Task<DiscordIpc?> ConnectAsync(int index, CancellationToken ct)
    {
        var pipe = new NamedPipeClientStream(".", $"discord-ipc-{index}", PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            await pipe.ConnectAsync(1000, ct);
            return new DiscordIpc(pipe, index);
        }
        catch (Exception)
        {
            pipe.Dispose();
            return null;
        }
    }

    public void StartReading(CancellationToken ct) => _ = Task.Run(() => ReadLoopAsync(ct));

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        string reason = "closed";
        var header = new byte[8];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await _pipe.ReadExactlyAsync(header, ct);
                var op = (Op)BinaryPrimitives.ReadUInt32LittleEndian(header);
                int len = (int)BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
                if (len < 0 || len >= 4_000_000) { reason = "frame too large"; break; }
                var body = new byte[len];
                await _pipe.ReadExactlyAsync(body, ct);
                using var doc = JsonDocument.Parse(body);
                var root = doc.RootElement.Clone();
                switch (op)
                {
                    case Op.Ping:
                        await SendAsync(Op.Pong, Encoding.UTF8.GetString(body));
                        break;
                    case Op.Close:
                        reason = root.TryGetProperty("message", out var m) ? m.GetString() ?? "closed" : "closed";
                        Closed?.Invoke(reason);
                        return;
                    case Op.Frame:
                        Message?.Invoke(root);
                        break;
                }
            }
        }
        catch (Exception e) when (e is IOException or EndOfStreamException or OperationCanceledException or JsonException or ObjectDisposedException)
        {
        }
        Closed?.Invoke(reason);
    }

    public async Task SendAsync(Op op, string json)
    {
        byte[] body = Encoding.UTF8.GetBytes(json);
        var frame = new byte[8 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame, (uint)op);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(4), (uint)body.Length);
        body.CopyTo(frame, 8);
        await _write.WaitAsync();
        try { await _pipe.WriteAsync(frame); await _pipe.FlushAsync(); }
        catch (Exception) { }
        finally { _write.Release(); }
    }

    public void Dispose() => _pipe.Dispose();
}
