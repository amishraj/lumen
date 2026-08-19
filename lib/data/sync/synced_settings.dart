/// The `set`-namespace allowlist: which app_settings keys sync across
/// devices. Checked BEFORE any JSON encoding — snapshotStreamRow hammers
/// setSetting with multi-hundred-KB blobs on every home refresh.
///
/// This is deliberately NOT CredentialVault._settingsKeys: that list answers
/// "restore this device after a reinstall" and this one answers "share
/// across devices". They differ on purpose — sidebar_width and ui state are
/// form-factor, active_playlist_id is a local autoincrement, and the Lumen
/// session token itself must never round-trip through its own sync.
const kSyncedSettings = {
  'trakt_access_token',
  'trakt_refresh_token',
  'trakt_username',
  'trakt_client_id',
  'trakt_client_secret',
  'rd_token',
  'rd_refresh_token',
  'rd_oauth_client_id',
  'rd_oauth_client_secret',
  'rd_token_expires_at',
  'rd_enabled',
  'tmdb_key',
  'omdb_key',
  'home_rows',
  'seek_previews',
};

bool isSyncedSettingKey(String key) => kSyncedSettings.contains(key);
