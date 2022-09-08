using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Messaging;
using System.IO;

namespace windows_filesystemwatcher
{
    public class MessageLoader
    {

        private const String privateQueuePath = ".\\Private$\\windows-filesystemwatcher-queue";

        private MessageQueue myQueue = null;

        public MessageLoader()
        {
            myQueue = new MessageQueue(privateQueuePath);
        }

        // References private queues.
        public void SendPrivate(FileSystemEventArgs e)
        {
            WatcherQueueMessage messageToQueue = new WatcherQueueMessage(e);
            myQueue.Send(messageToQueue.Serialized());
        }

    }

}
