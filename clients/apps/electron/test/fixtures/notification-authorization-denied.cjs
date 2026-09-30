module.exports = {
  authorizationStatus() {
    return Promise.resolve("denied");
  },
  requestAuthorization() {
    return Promise.resolve("denied");
  },
  setBadgeCount() {
    return Promise.resolve("cleared");
  },
};
