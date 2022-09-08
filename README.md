# windows-filesystemwatcher
Windows service based on FileSystemWatcher Class



# Installing the new Windows Service
Open CMD as administrator and type:
cd C:\Windows\Microsoft.NET\Framework\v4.0.30319 
InstallUtil.exe \windows-filesystemwatcher\windows-filesystemwatcher\bin\Debug\windows-filesystemwatcher.exe



# Running the installed Watcher Service
Go to Windows Services configuration (type 'Services' in the Windows menu), look for the installed service and open properties (mouse right click).
Select auto start to run automatically on Windows startup and press start to run it from now.
Enjoy your new custom version control service :)



# Activate the Microsoft Message Queue server (MSMQ)
Open Control Panel, select Programs, select "Turn Windows features on or off". You would need administrator privileges for this, expand "Microsoft Message Queue server" and activate "Microsoft Message Queue (MSMQ) Core" and click "ok", wait untill feature is installed.

We confirm if MSMQ was installed. Open "Computer Management" (Win + r and type "compmgmt.msc"), Let us create a private queue called "windows-filesystemwatcher-queue". Right click on "Services and Applications\Message Queuing\Private Queues" (left side panel) and select to create a new queue. The private queue is now created.



# Remove the Windows Service
Go to Windows Services configuration (type 'Services' in the Windows menu), look for the installed service and open properties (mouse right click).
Press stop to end service execution.
Open CMD as administrator and type:
cd C:\Windows\Microsoft.NET\Framework\v4.0.30319 
InstallUtil.exe /u \windows-filesystemwatcher\windows-filesystemwatcher\bin\Debug\windows-filesystemwatcher.exe
