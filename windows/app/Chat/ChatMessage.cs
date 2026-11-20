using System;
using System.Collections.Generic;

namespace OmniCast.Chat;

public enum ChatPlatform { YouTube, Twitch, Kick }

public enum ChatBadge { Owner, Moderator, Vip, Member, Verified }

// A piece of a message: text, or an emote image (with the text it stands for).
public sealed record ChatPart(string Text, string? EmoteUrl = null);

public sealed class ChatMessage
{
    public string Id { get; init; } = "";
    public ChatPlatform Platform { get; init; }
    public string Author { get; init; } = "";
    public string? Color { get; init; } // "#RRGGBB" from the platform, if any
    public List<ChatBadge> Badges { get; init; } = new();
    public List<ChatPart> Parts { get; init; } = new();
    public DateTime Received { get; init; } = DateTime.UtcNow;
}

public enum ChatState { Off, Connecting, Connected, WaitingForLive, Failed }

public sealed record ChatStatus(ChatState State, string Message = "")
{
    public static readonly ChatStatus Off = new(ChatState.Off);

    public string Text => State switch
    {
        ChatState.Off => "Off",
        ChatState.Connecting => Message.Length > 0 ? Message : "Connecting…",
        ChatState.Connected => "Connected",
        ChatState.WaitingForLive => "Waiting for you to go live",
        _ => Message,
    };
}

public static class ChatPlatforms
{
    public static string Name(ChatPlatform p) => p switch
    {
        ChatPlatform.YouTube => "YouTube",
        ChatPlatform.Twitch => "Twitch",
        _ => "Kick",
    };

    public static string Key(ChatPlatform p) => p switch
    {
        ChatPlatform.YouTube => "youtube",
        ChatPlatform.Twitch => "twitch",
        _ => "kick",
    };

    // A desktop browser's user agent: YouTube and Kick serve browsers.
    public const string UserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0";
}
