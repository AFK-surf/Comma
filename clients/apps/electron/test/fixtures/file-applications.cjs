module.exports = {
  listApplicationsForFileName: async () => [
    { applicationPath: "/Applications/Preview.app", name: "Preview", isDefault: true },
  ],
  listApplicationsForFile: async () => [],
  openFileWithApplication: async () => false,
};
