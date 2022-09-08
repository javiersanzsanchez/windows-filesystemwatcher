using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace windows_filesystemwatcher
{
    public class WatcherQueueMessage
    {

        public String Guid = "";
        public String currentName = "";
        public String previousName = "";
        public String currentParentPath = "";
        public String previousParentPath = "";
        public String fullPath = "";
        public String previousPath = "";
        public String watcherEvent = "";
        private DateTime watcherEventTime;

        public WatcherQueueMessage()
        {
            watcherEventTime = DateTime.Now;
        }

        public String Serialized()
        {
            return Newtonsoft.Json.JsonConvert.SerializeObject(this);
        }

    }
}
