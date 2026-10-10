int _best = 0;

Future<int> loadBestScore() async => _best;

Future<void> saveBestScore(int value) async {
  _best = value;
}
