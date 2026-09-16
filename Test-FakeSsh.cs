using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
class FakeSsh
{
    static void Main(string[] args)
    {
        int port = 0;
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == "-L" || args[i] == "-D") port = Int32.Parse(args[i+1].Split(':')[1]);
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Console.Error.WriteLine("fixture diagnostic");
        Thread.Sleep(20000); // Bounded lifespan even if a test is interrupted.
        listener.Stop();
    }
}
