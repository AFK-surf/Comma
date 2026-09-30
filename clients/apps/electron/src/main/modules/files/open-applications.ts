/** Main-only AppKit values. Host paths never cross the renderer capability. */
export interface SystemFileApplication {
  applicationPath: string;
  name: string;
  iconDataUrl?: string;
  isDefault: boolean;
}

export interface FileApplicationsPlatform {
  copyFileToClipboard?(path: string): Promise<boolean>;
  listApplicationsForFileName(
    fileName: string
  ): Promise<SystemFileApplication[] | null>;
  listApplicationsForFile(path: string): Promise<SystemFileApplication[] | null>;
  openFileWithApplication(path: string, applicationPath: string): Promise<boolean>;
}
