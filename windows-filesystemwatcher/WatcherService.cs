using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.ServiceProcess;
using System.Text;
using System.Threading.Tasks;
using System.Timers;

namespace windows_filesystemwatcher
{
    public partial class WatcherService : ServiceBase
    {
        public WatcherService()
        {
            InitializeComponent();

            var watcher = new FileSystemWatcher(@"C:\Users\Javier\Desktop\WatchedFolder");

            /*watcher.NotifyFilter = NotifyFilters.Attributes
                                 | NotifyFilters.CreationTime
                                 | NotifyFilters.DirectoryName
                                 | NotifyFilters.FileName
                                 | NotifyFilters.LastAccess
                                 | NotifyFilters.LastWrite
                                 | NotifyFilters.Security
                                 | NotifyFilters.Size;
            */
            watcher.Changed += OnChanged;
            watcher.Created += OnCreated;
            watcher.Deleted += OnDeleted;
            watcher.Renamed += OnRenamed;
            watcher.Error += OnError;

            //watcher.Filter = "*.txt";
            watcher.IncludeSubdirectories = true;
            watcher.EnableRaisingEvents = true;
        }

        protected override void OnStart(string[] args)
        {
            WriteToFile("Service is started at " + DateTime.Now);
        }
        protected override void OnStop()
        {
            WriteToFile("Service is stopped at " + DateTime.Now);
        }
        private void OnElapsedTime(object source, ElapsedEventArgs e)
        {
            WriteToFile("Service is recall at " + DateTime.Now);
        }
        private void OnChanged(object sender, FileSystemEventArgs e)
        {
            if (e.ChangeType != WatcherChangeTypes.Changed)
            {
                return;
            }
            //Console.WriteLine($"Changed: {e.FullPath}");

            WriteToFile($"Changed: {e.FullPath}");
        }

        private void OnCreated(object sender, FileSystemEventArgs e)
        {
            string value = $"Created: {e.FullPath}";
            //Console.WriteLine(value);
            WriteToFile(value);
        }

        private void OnDeleted(object sender, FileSystemEventArgs e)
        {
            //Console.WriteLine($"Deleted: {e.FullPath}");
            WriteToFile($"Deleted: {e.FullPath}");
        }

        private void OnRenamed(object sender, RenamedEventArgs e)
        {
            //Console.WriteLine($"Renamed:");
            //Console.WriteLine($"    Old: {e.OldFullPath}");
            //Console.WriteLine($"    New: {e.FullPath}");
            WriteToFile("Renamed:");
            WriteToFile($"    Old: {e.OldFullPath}");
            WriteToFile($"    New: {e.FullPath}");
        }

        private void OnError(object sender, ErrorEventArgs e) =>
            PrintException(e.GetException());

        private void PrintException(Exception ex)
        {
            if (ex != null)
            {
                //Console.WriteLine($"Message: {ex.Message}");
                //Console.WriteLine("Stacktrace:");
                //Console.WriteLine(ex.StackTrace);
                //Console.WriteLine();
                WriteToFile($"Message: {ex.Message}");
                WriteToFile("Stacktrace:");
                WriteToFile(ex.StackTrace);
                WriteToFile("");
                PrintException(ex.InnerException);
            }
        }
        public void WriteToFile(string Message)
        {
            string path = AppDomain.CurrentDomain.BaseDirectory + "\\Logs";
            if (!Directory.Exists(path))
            {
                Directory.CreateDirectory(path);
            }
            string filepath = AppDomain.CurrentDomain.BaseDirectory + "\\Logs\\ServiceLog_" + DateTime.Now.Date.ToShortDateString().Replace('/', '_') + ".txt";
            if (!File.Exists(filepath))
            {
                // Create a file to write to.   
                using (StreamWriter sw = File.CreateText(filepath))
                {
                    sw.WriteLine(Message);
                }
            }
            else
            {
                using (StreamWriter sw = File.AppendText(filepath))
                {
                    sw.WriteLine(Message);
                }
            }
        }
    }
}
