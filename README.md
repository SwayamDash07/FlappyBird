# Flappy Bird: Kitchen Escape

A small, slightly chaotic Flappy Bird-inspired game made while learning Flutter at a workshop. Instead of navigating pipes, help a very determined chicken escape a kitchen full of fire.

## Play online

**[Play Flappy Bird: Kitchen Escape](https://swayamdash07.github.io/FlappyBird/)**

## Play

Tap or click the game, or press **Space**, **↑**, or **W** to flap. Dodge the flames and try to beat your high score. If the chicken gets cooked, the end screen has the score, best score, medal, and a **Play Again** button.

Press **M** to toggle sound. Best score is saved in the browser for the web version.

## Run locally

You’ll need the [Flutter SDK](https://docs.flutter.dev/get-started/install) installed.

```bash
git clone https://github.com/SwayamDash07/FlappyBird.git
cd FlappyBird
flutter pub get
flutter run -d chrome
```

To build the web version:

```bash
flutter build web --release
```

The deployable files are generated in `build/web/`.

## Built with

- Flutter and Dart
- Custom-painted game scene and animations
- A kitchen-inspired setting, fire obstacles, and a dramatic “YOU GOT SERVED” game-over screen

This is a learning project from a Flutter workshop. It was a fun way to explore game loops, input, animation, drawing, and saving a high score.
