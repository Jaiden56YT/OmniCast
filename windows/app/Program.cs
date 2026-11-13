using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace OmniCast;

public static class Program
{
    public static bool StartMinimized { get; private set; }

    [STAThread]
    private static int Main(string[] args)
    {
        if (Benchmark.Requested(args))
            return Benchmark.Run(args);

        WinRT.ComWrappersSupport.InitializeComWrappers();

        // One OmniCast at a time: libobs, the capture devices and the hotkeys
        // can't be shared. A second launch brings the first one to the front.
        var instance = AppInstance.FindOrRegisterForKey("OmniCast.Main");
        if (!instance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            Task.Run(() => instance.RedirectActivationToAsync(activation).AsTask()).Wait();
            return 0;
        }
        instance.Activated += (_, _) => App.Current?.ShowMainWindow();

        StartMinimized = args.Contains("--minimized");
        Application.Start(p =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }
}
