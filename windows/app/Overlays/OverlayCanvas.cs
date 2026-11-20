using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Graphics.Canvas;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Overlays;

// Shared helpers for overlays: canvas sizes, where PNGs go, and handing a
// finished image to the engine.
public static class OverlayCanvas
{
    // Overlay layouts are designed on a 1920x1080 canvas (1080x1920 for 9:16)
    // and scaled to the real canvas, so they look the same at 720p.
    public const double RefShort = 1080;

    public static string Dir => Path.Combine(AppSettings.DataDir, "overlay");

    public static CanvasDevice Device => CanvasDevice.GetSharedDevice();

    public static (double W, double H) Size(int canvas)
    {
        double h = EngineHost.Current.Settings.VideoHeight;
        double w = Math.Round(h * 16 / 9);
        return canvas == 0 ? (w, h) : (h, w);
    }

    // Reference pixels to canvas pixels.
    public static double Scale => EngineHost.Current.Settings.VideoHeight / RefShort;

    // Saves the image and points the layer at it. Written to a temp file and
    // renamed, so the engine never reads half a PNG.
    public static async Task<bool> PublishAsync(string key, CanvasRenderTarget image)
    {
        Directory.CreateDirectory(Dir);
        string path = Path.Combine(Dir, key + ".png");
        string tmp = path + ".tmp";
        try
        {
            await image.SaveAsync(tmp, CanvasBitmapFileFormat.Png);
            File.Move(tmp, path, true);
        }
        catch (Exception)
        {
            return false;
        }
        return EngineHost.Current.IsRunning && Native.oc_layer_set_image(key, path) != 0;
    }
}
