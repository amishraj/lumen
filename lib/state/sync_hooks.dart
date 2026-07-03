/// Tiny observer seams so shared state code (favorites, settings, the library
/// sync controller) can notify the cloud-backup layer without importing it —
/// keeps the dependency graph acyclic: cloud_sync imports providers, never
/// the reverse.
library;

/// Fired whenever user data worth backing up changes (favorite toggled, pin
/// changed, a setting saved…). CloudSync debounces these into one upload.
void Function()? onUserDataChanged;

/// Fired after a library re-sync completes — stream ids were reassigned, so
/// any pending cloud restore (favorites/progress keyed by url) can now be
/// re-applied against the fresh rows.
Future<void> Function()? onLibrarySynced;
