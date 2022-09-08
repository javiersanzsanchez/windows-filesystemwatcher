using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;
using System.Windows.Forms;

namespace windows_filesystemwatcher
{
    public class WatcherQueueMessage
    {

        public ulong Guid;
        public FileSystemEventArgs watcherEventDetails;
        public DateTime watcherEventTime;
        public String changeType;

        public WatcherQueueMessage(FileSystemEventArgs e)
        {
            watcherEventTime = DateTime.Now;
            watcherEventDetails = e;
            setChangeType();
            if (isFile())
                setFileIndex();
        }

        private void setFileIndex()
        {
            WinAPI winapi = new WinAPI();
            Guid = winapi.getFileIndexByPath(watcherEventDetails.FullPath);
        }

        private Boolean isFile() {
            if (!File.Exists(watcherEventDetails.FullPath))
                return false;

            FileAttributes attr = File.GetAttributes(watcherEventDetails.FullPath);

            if (attr.HasFlag(FileAttributes.Directory))
                return false;

            return true;
        }

        private void setChangeType()
        {
            switch ((int)watcherEventDetails.ChangeType)
            {
                case 1:
                    changeType = "CREATED";
                    break;

                case 2:
                    changeType = "DELETED";
                    break;

                case 4:
                    changeType = "CHANGED";
                    break;

                case 8:
                    changeType = "RENAMED";
                    break;

                default:
                    changeType = "ERROR";
                    break;
            }
        }

        public String Serialized()
        {
            return Newtonsoft.Json.JsonConvert.SerializeObject(this);
        }

    }
}
