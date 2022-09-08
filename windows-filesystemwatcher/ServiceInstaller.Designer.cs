namespace windows_filesystemwatcher
{
    partial class ServiceInstaller
    {
        /// <summary>
        /// Variable del diseñador necesaria.
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary> 
        /// Limpiar los recursos que se estén usando.
        /// </summary>
        /// <param name="disposing">true si los recursos administrados se deben desechar; false en caso contrario.</param>
        protected override void Dispose(bool disposing)
        {
            if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
        }

        #region Código generado por el Diseñador de componentes

        /// <summary>
        /// Método necesario para admitir el Diseñador. No se puede modificar
        /// el contenido de este método con el editor de código.
        /// </summary>
        private void InitializeComponent()
        {
            this.watcherServiceProcessInstaller = new System.ServiceProcess.ServiceProcessInstaller();
            this.watcherServiceInstaller = new System.ServiceProcess.ServiceInstaller();
            // 
            // watcherServiceProcessInstaller
            // 
            this.watcherServiceProcessInstaller.Account = System.ServiceProcess.ServiceAccount.LocalSystem;
            this.watcherServiceProcessInstaller.Password = null;
            this.watcherServiceProcessInstaller.Username = null;
            // 
            // watcherServiceInstaller
            // 
            this.watcherServiceInstaller.Description = "Windows service based on FileSystemWatcher Class.";
            this.watcherServiceInstaller.DisplayName = "VersionFileWatcherService";
            this.watcherServiceInstaller.ServiceName = "FileWatcherService";
            this.watcherServiceInstaller.AfterInstall += new System.Configuration.Install.InstallEventHandler(this.serviceInstaller1_AfterInstall);
            // 
            // ServiceInstaller
            // 
            this.Installers.AddRange(new System.Configuration.Install.Installer[] {
            this.watcherServiceProcessInstaller,
            this.watcherServiceInstaller});

        }

        #endregion

        private System.ServiceProcess.ServiceProcessInstaller watcherServiceProcessInstaller;
        private System.ServiceProcess.ServiceInstaller watcherServiceInstaller;
    }
}