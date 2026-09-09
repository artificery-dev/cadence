abstract interface class LibraryWatchService {
  Future<void> start();
  Future<void> stop();
  Future<void> refresh();
}

class NoLibraryWatch implements LibraryWatchService {
  const NoLibraryWatch();
  @override
  Future<void> start() async =>
      throw UnsupportedError('No watch adapter installed');
  @override
  Future<void> stop() async {}
  @override
  Future<void> refresh() async {}
}
