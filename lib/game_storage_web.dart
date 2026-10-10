import 'package:web/web.dart' as web;

Future<int> loadBestScore() async =>
    int.tryParse(web.window.localStorage.getItem('flappy_best') ?? '') ?? 0;

Future<void> saveBestScore(int value) async {
  web.window.localStorage.setItem('flappy_best', '$value');
}
