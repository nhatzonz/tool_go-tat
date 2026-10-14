using System.Threading;
using System.Windows;

namespace GoTat;

public partial class App : Application
{
    Mutex? single;
    EventWaitHandle? showSignal;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Chỉ chạy 1 bản: mở lần hai thì gọi cửa sổ của bản đang chạy lên rồi thoát
        single = new Mutex(true, "GoTat.SingleInstance", out bool first);
        if (!first)
        {
            try { EventWaitHandle.OpenExisting("GoTat.Show").Set(); } catch { }
            Shutdown();
            return;
        }
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "GoTat.Show");

        Store.Load();
        Theme.Apply(Store.Settings.Theme);
        var main = new MainWindow();
        main.Show();

        var waiter = new Thread(() =>
        {
            while (showSignal.WaitOne()) Dispatcher.Invoke(main.ShowFromTray);
        }) { IsBackground = true };
        waiter.Start();
    }
}
