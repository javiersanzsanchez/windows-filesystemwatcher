# windows-filesystemwatcher
Windows service based on FileSystemWatcher Class



# Installing the new Windows Service
Open CMD as administrator and type:
installutil \windows-filesystemwatcher\windows-filesystemwatcher\bin\Debug\windows-filesystemwatcher.exe



# Running the installed Watcher Service
Go to Windows Services configuration (type 'Services' in the Windows menu), look for the installed service and open properties (mouse right click).
Select auto start to run automatically on Windows startup and press start to run it from now.
Enjoy your new custom version control service :)



# Remove the Windows Service
Go to Windows Services configuration (type 'Services' in the Windows menu), look for the installed service and open properties (mouse right click).
Press stop to end service execution.
Open CMD as administrator and type:
installutil /u \windows-filesystemwatcher\windows-filesystemwatcher\bin\Debug\windows-filesystemwatcher.exe
