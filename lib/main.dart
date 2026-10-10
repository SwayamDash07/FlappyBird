import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'game_storage_stub.dart'
    if (dart.library.js_interop) 'game_storage_web.dart'
    as storage;
import 'fullscreen_stub.dart'
    if (dart.library.js_interop) 'fullscreen_web.dart'
    as fullscreen;
import 'game_audio_stub.dart'
    if (dart.library.js_interop) 'game_audio_web.dart'
    as audio;

void main() => runApp(const FlappyBirdApp());

class GameConfig {
  static const width = 288.0, height = 512.0;
  static const step = 1 / 60;
  static const gravity = .25, flap = -4.6, maxFall = 8.0;
  static const birdW = 34.0, birdH = 24.0, hitR = 10.0;
  static const pipeW = 52.0, gap = 106.0, spacing = 156.0, pipeSpeed = 2.0;
  static const firstPipeFactor = 1.6;
  static double get firstPipeDistance =>
      spacing * firstPipeFactor.clamp(1.2, 2.0);
  static const groundY = 450.0, tileW = 32.0;
  // ignore: constant_identifier_names
  static const USE_CHICKEN_COMB = true;
}

enum Phase { ready, playing, hit, cooking, falling, onPan, zoom, title, card }

double _cardBoxAlpha(double elapsed) =>
    Curves.easeOut.transform((elapsed / .20).clamp(0.0, 1.0));

double _cardContentAlpha(double elapsed, double delay) =>
    Curves.easeOut.transform(((elapsed - delay) / .16).clamp(0.0, 1.0));

// ignore: constant_identifier_names
const bool USE_THEMED_MEDAL_LABELS = true;
// ignore: constant_identifier_names
const double PAN_START = 64.0;
// ignore: constant_identifier_names
const double MAX_PAN_SPEED = 1800.0;

class FlappyBirdApp extends StatelessWidget {
  const FlappyBirdApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Flappy Bird',
    home: GamePage(),
  );
}

class GamePage extends StatefulWidget {
  const GamePage({super.key});
  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _focus = FocusNode();
  final _random = math.Random();
  final List<FirePair> _firePairs = [];
  late final Ticker _ticker;
  Timer? _restartTimer;
  ui.Image? _bird;
  ui.Image? _goldenBird, _roastedBird;
  KitchenCache? _kitchen;
  double _kitchenWidth = -1;
  double _worldWidth = GameConfig.width;
  Phase _phase = Phase.ready;
  double _birdY = 210, _velocity = 0, _angle = 0;
  double _groundOffset = 0, _time = 0, _wingTime = 0, _flapAge = 1;
  double _landscapeTime = 0;
  double _accumulator = 0;
  double _obstacleIntroTime = 0;
  double _deathElapsed = 0, _deathTotal = 0, _fireFrameTime = 0;
  double _panSlideElapsed = 0, _panSlideDuration = .2;
  double _panCenterX = 0, _panStartX = 0, _panTopY = 0;
  double _cookingParticleTimer = 0, _titleEmberTimer = 0;
  bool _panPop = false;
  double _emberSpawnTimer = 0;
  double _scorePop = 0;
  Duration? _lastFrame;
  int _score = 0, _best = 0;
  bool _newBest = false, _buttonPressed = false;
  bool _showRankTooltip = false, _medalBurstEmitted = false;
  bool _showEndLayoutDebug = false;
  final Map<String, double> _debugCardAlphas = {};
  int _debugCardAlphaFrame = 0;
  bool _deathByFire = false;
  bool _panic = false;
  final List<Ember> _embers = List.generate(60, (_) => Ember());
  final List<Ember> _deathParticles = List.generate(30, (_) => Ember());
  final _audio = audio.GameAudio();
  Timer? _sizzleTimer;
  int _activeEmbers = 0;

  double get _birdX => (_worldWidth * .28).clamp(80.0, 220.0).toDouble();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FireArt.prewarmEndScreen();
    _ticker = createTicker(_onFrame)..start();
    unawaited(_loadSpritesAndBest());
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  Future<ui.Image> _decode(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  Future<void> _loadSpritesAndBest() async {
    try {
      final savedBest = await storage.loadBestScore();
      final image = await _decode('assets/bird.png');
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _best = savedBest;
        _bird = image;
      });
      final cooked = await Future.wait([
        _makeCookedBird(image, golden: true),
        _makeCookedBird(image, golden: false),
      ]);
      if (!mounted) {
        cooked[0].dispose();
        cooked[1].dispose();
        return;
      }
      setState(() {
        _goldenBird = cooked[0];
        _roastedBird = cooked[1];
      });
    } catch (error) {
      debugPrint('Sprite load failed; using fallback art: $error');
    }
  }

  Future<ui.Image> _makeCookedBird(
    ui.Image image, {
    required bool golden,
  }) async {
    final source = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (source == null) throw StateError('Unable to read bird sprite pixels');
    final pixels = Uint8List.fromList(
      source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
    );
    final width = image.width;
    final height = image.height;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final alpha = pixels[i + 3];
        if (alpha < 128) continue;
        // Preserve both eyes (including their gray rims). The beak and red
        // comb are protected by the low-saturation body-pixel test below.
        final eyeOne = _insideEllipse(
          x,
          y,
          width * .74,
          height * .54,
          width * .055,
          height * .09,
        );
        final eyeTwo = _insideEllipse(
          x,
          y,
          width * .87,
          height * .54,
          width * .055,
          height * .09,
        );
        if (eyeOne || eyeTwo) continue;
        final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
        if ((r - g).abs() > 48 || (g - b).abs() > 48 || r < 145) continue;
        final shade = (r + g + b) ~/ 3;
        final Color replacement;
        if (golden) {
          replacement = shade > 225
              ? const Color(0xffffc55f)
              : shade > 195
              ? const Color(0xffdda04a)
              : const Color(0xffaa6c39);
        } else {
          replacement = shade > 225
              ? const Color(0xffa95e32)
              : shade > 195
              ? const Color(0xff7d482f)
              : const Color(0xff533126);
        }
        pixels[i] = (replacement.r * 255).round().clamp(0, 255);
        pixels[i + 1] = (replacement.g * 255).round().clamp(0, 255);
        pixels[i + 2] = (replacement.b * 255).round().clamp(0, 255);
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: width * 4,
    );
    return completer.future;
  }

  bool _insideEllipse(
    int x,
    int y,
    double cx,
    double cy,
    double rx,
    double ry,
  ) {
    final dx = (x - cx) / rx, dy = (y - cy) / ry;
    return dx * dx + dy * dy <= 1;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lastFrame = null;
      _accumulator = 0;
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
      _lastFrame = null;
      _accumulator = 0;
    }
  }

  void _onFrame(Duration elapsed) {
    final last = _lastFrame;
    _lastFrame = elapsed;
    if (last == null) return;
    _accumulator += ((elapsed - last).inMicroseconds / 1000000).clamp(0.0, .25);
    var changed = false;
    while (_accumulator >= GameConfig.step) {
      _update();
      _accumulator -= GameConfig.step;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _update() {
    const dt = GameConfig.step;
    _time += dt;
    if (_phase == Phase.ready) {
      _fireFrameTime += dt;
      _landscapeTime += dt;
      _wingTime += dt;
      _groundOffset = (_groundOffset + .8) % GameConfig.tileW;
      return;
    }
    if (_phase == Phase.playing) {
      _fireFrameTime += dt;
      _landscapeTime += dt;
      _obstacleIntroTime += dt;
      _tickEmbers(dt);
      _updatePanic();
      final nearest = _nearestFireDistance();
      _audio.setFireProximity(
        nearest <= 0 ? 1 : (1 - nearest / 300).clamp(0.0, 1.0),
      );
      _emberSpawnTimer += dt;
      while (_emberSpawnTimer >= .12) {
        _emberSpawnTimer -= .12;
        _emitFireEmber();
      }
      _velocity = math.min(GameConfig.maxFall, _velocity + GameConfig.gravity);
      _birdY = math.max(GameConfig.birdH / 2, _birdY + _velocity);
      _angle = _lerp(
        _angle,
        (_velocity * .18).clamp(-.45, math.pi / 2).toDouble(),
        .22,
      );
      _wingTime += dt;
      _flapAge += dt;
      _scorePop = math.max(0, _scorePop - dt);
      _groundOffset = (_groundOffset + GameConfig.pipeSpeed) % GameConfig.tileW;
      for (final obstacle in _firePairs) {
        obstacle.x -= GameConfig.pipeSpeed;
        if (!obstacle.passed && _birdX > obstacle.x + GameConfig.pipeW / 2) {
          obstacle.passed = true;
          _score++;
          _audio.playPoint();
          _scorePop = .15;
          if (_score > _best) {
            _best = _score;
            _newBest = true;
            unawaited(_saveBest());
          }
        }
      }
      _firePairs.removeWhere((obstacle) => obstacle.x + GameConfig.pipeW < 0);
      _ensureFireAhead();
      final hitFire = _hitsFire();
      if (hitFire || _birdY + GameConfig.hitR >= GameConfig.groundY) {
        _beginDeath(hitFire);
      }
      return;
    }
    if (_isDeathPhase(_phase)) {
      _deathElapsed += dt;
      _deathTotal += dt;
      if (_phase == Phase.card) _checkCardEntranceAlphas();
      _updateDeathPan(dt);
      _tickEmbers(dt);
      _tickDeathParticles(dt);
      if ((_phase == Phase.cooking || _phase == Phase.falling) &&
          _deathTotal < .68) {
        _cookingParticleTimer += dt;
        while (_cookingParticleTimer >= .16) {
          _cookingParticleTimer -= .16;
          _emitCookingParticles();
        }
      }
      if (_phase == Phase.title || _phase == Phase.card) {
        _titleEmberTimer += dt;
        while (_titleEmberTimer >= .11) {
          _titleEmberTimer -= .11;
          _emitTitleEmber();
        }
      }
      if (_phase == Phase.card &&
          !_medalBurstEmitted &&
          _score >= 10 &&
          _deathElapsed >= .60) {
        _medalBurstEmitted = true;
        _emitMedalBurst();
      }
      if (_phase == Phase.hit) {
        if (_deathElapsed >= .08) _setDeathPhase(Phase.cooking);
        return;
      }
      if (_phase == Phase.cooking || _phase == Phase.falling) {
        if (_birdY > _landingY) _birdY = _landingY;
        if (_birdY < _landingY) {
          _velocity = math.min(
            GameConfig.maxFall,
            _velocity + GameConfig.gravity,
          );
          _birdY = math.min(_landingY, _birdY + _velocity);
        }
        _angle = _lerp(_angle, math.pi / 2, .10);
        if (_phase == Phase.cooking && _deathElapsed >= .70) {
          _setDeathPhase(Phase.falling);
        }
        if (_phase == Phase.falling && _birdY >= _landingY) {
          _birdY = _landingY;
          _velocity = 0;
          _setDeathPhase(Phase.onPan);
          _assertPanAlignment();
        }
        return;
      }
      if (_phase == Phase.onPan) {
        _emberSpawnTimer += dt;
        while (_emberSpawnTimer >= .09) {
          _emberSpawnTimer -= .09;
          _emitPanParticles();
        }
      }
      if (_phase == Phase.onPan && _deathElapsed >= .40) {
        _setDeathPhase(Phase.zoom);
      } else if (_phase == Phase.zoom && _deathElapsed >= .60) {
        _setDeathPhase(Phase.title);
      } else if (_phase == Phase.title && _deathElapsed >= .90) {
        _setDeathPhase(Phase.card);
      }
      return;
    }
  }

  double get _landingY => GameConfig.groundY - 18;

  double _clampPanCenterX(double x) {
    const halfPanWidth = 28.0;
    if (_worldWidth <= halfPanWidth * 2) return _worldWidth / 2;
    return x.clamp(halfPanWidth, _worldWidth - halfPanWidth).toDouble();
  }

  void _updateDeathPan(double dt) {
    final targetX = _clampPanCenterX(_birdX);
    if (_panPop) {
      _panSlideElapsed = math.min(.08, _panSlideElapsed + dt);
      _panCenterX = targetX;
      return;
    }
    final oldT = (_panSlideElapsed / _panSlideDuration).clamp(0.0, 1.0);
    _panSlideElapsed = math.min(_panSlideDuration, _panSlideElapsed + dt);
    final newT = (_panSlideElapsed / _panSlideDuration).clamp(0.0, 1.0);
    final oldEase = Curves.easeOutCubic.transform(oldT);
    final newEase = Curves.easeOutCubic.transform(newT);
    final remaining = 1 - oldEase;
    final step = remaining <= 0
        ? 1.0
        : ((newEase - oldEase) / remaining).clamp(0.0, 1.0);
    _panCenterX += (targetX - _panCenterX) * step;
    if (newT >= 1) _panCenterX = targetX;
  }

  void _assertPanAlignment() {
    assert(() {
      final xError = (_panCenterX - _clampPanCenterX(_birdX)).abs();
      final birdBottom = _birdY + GameConfig.birdH / 2;
      final yError = (birdBottom - _panTopY).abs();
      debugPrint(
        'Landed pan: panCenterX=$_panCenterX, birdCenterX=$_birdX; '
        'birdBottom=$birdBottom, panTopY=$_panTopY',
      );
      assert(xError < .5, 'Pan center must align with bird center');
      assert(yError < 1, 'Bird bottom must meet pan top surface');
      return true;
    }());
  }

  void _beginDeath(bool byFire) {
    _deathByFire = byFire;
    _phase = Phase.hit;
    _deathElapsed = 0;
    _deathTotal = 0;
    _cookingParticleTimer = 0;
    _titleEmberTimer = 0;
    _medalBurstEmitted = false;
    _showRankTooltip = false;
    _panSlideElapsed = 0;
    _panTopY = _landingY + GameConfig.birdH / 2;
    final targetX = _clampPanCenterX(_birdX);
    var timeToLand = 0.0;
    if (byFire) {
      var probeY = _birdY;
      var probeVelocity = _velocity;
      var frames = 0;
      // Mirror the existing death-fall integration without changing it.
      while (probeY < _landingY && frames < 600) {
        probeVelocity = math.min(
          GameConfig.maxFall,
          probeVelocity + GameConfig.gravity,
        );
        probeY = math.min(_landingY, probeY + probeVelocity);
        frames++;
      }
      timeToLand = .08 + frames * GameConfig.step;
    }
    _panPop = timeToLand < .10;
    final availableSlideTime = math.max(0.0, timeToLand - .08);
    _panSlideDuration = _panPop
        ? .08
        : availableSlideTime < .2
        ? availableSlideTime
        : availableSlideTime.clamp(.2, .7).toDouble();
    final fullDistance = math.max(0.0, _worldWidth + PAN_START - targetX);
    final travel = math.min(fullDistance, MAX_PAN_SPEED * _panSlideDuration);
    _panStartX = targetX + travel;
    _panCenterX = _panPop ? targetX : _panStartX;
    for (final p in _deathParticles) {
      p.active = false;
    }
    _fireFrameTime = 0;
    _activeEmbers = 0;
    _emberSpawnTimer = 0;
    for (final p in _embers) {
      p.active = false;
    }
    _wingTime = 0;
    if (!byFire) {
      _birdY = _landingY;
      _velocity = 0;
    }
    _audio.playHit();
    _audio.setFireProximity(0);
    for (var i = 0; i < 24; i++) {
      final p = _embers[i];
      p.active = true;
      p.x = _birdX + (_random.nextDouble() - .5) * 22;
      p.y = _birdY + (_random.nextDouble() - .5) * 16;
      p.vx = (_random.nextDouble() - .5) * 24;
      p.vy = -20 - _random.nextDouble() * 45;
      p.life = .45 + _random.nextDouble() * .8;
      p.maxLife = p.life;
      p.kind = i < 10 ? 1 : 0;
      _activeEmbers++;
    }
  }

  void _setDeathPhase(Phase phase) {
    _phase = phase;
    _deathElapsed = 0;
    if (kDebugMode && phase == Phase.card) {
      _debugCardAlphaFrame = 0;
      _debugCardAlphas
        ..clear()
        ..addAll({
          'box': 0,
          'header': 0,
          'score': 0,
          'medal': 0,
          'meter': 0,
          'button': 0,
        });
    }
    if (phase == Phase.cooking || phase == Phase.onPan) {
      _startSizzle();
    } else if (phase == Phase.zoom || phase == Phase.card) {
      _stopSizzle();
    }
    if (phase == Phase.onPan) _audio.playClang();
    if (phase == Phase.zoom) _audio.playWhoosh();
    if (phase == Phase.title) _audio.playDing();
  }

  void _checkCardEntranceAlphas() {
    if (!kDebugMode) return;
    _debugCardAlphaFrame++;
    final values = <String, double>{
      'box': _cardBoxAlpha(_deathElapsed),
      'header': _cardContentAlpha(_deathElapsed, 0),
      'score': _cardContentAlpha(_deathElapsed, .06),
      'medal': _cardContentAlpha(_deathElapsed, .12),
      'meter': _cardContentAlpha(_deathElapsed, .18),
      'button':
          _cardBoxAlpha(_deathElapsed) * _cardContentAlpha(_deathElapsed, .24),
    };
    values.forEach((name, alpha) {
      final previous = _debugCardAlphas[name] ?? 0;
      if (alpha + 1e-9 < previous) {
        debugPrint(
          'Card entrance alpha decreased: $name $previous -> $alpha '
          'at frame $_debugCardAlphaFrame',
        );
        assert(alpha + 1e-9 >= previous, 'Non-monotonic $name alpha');
      }
      debugPrint(
        'Card entrance frame $_debugCardAlphaFrame $name alpha=$alpha',
      );
      _debugCardAlphas[name] = alpha;
    });
  }

  void _startSizzle() {
    _stopSizzle();
    _audio.playSizzle();
    _sizzleTimer = Timer.periodic(
      const Duration(milliseconds: 145),
      (_) => _audio.playSizzle(),
    );
  }

  void _stopSizzle() {
    _sizzleTimer?.cancel();
    _sizzleTimer = null;
  }

  void _tickEmbers(double dt) {
    for (var i = 0; i < _activeEmbers; i++) {
      final p = _embers[i];
      if (!p.active) continue;
      p.life -= dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vy -= dt * 8;
      if (p.life <= 0) p.active = false;
    }
  }

  void _tickDeathParticles(double dt) {
    for (final p in _deathParticles) {
      if (!p.active) continue;
      p.life -= dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vy -= dt * 6;
      if (p.life <= 0) p.active = false;
    }
  }

  void _emitCookingParticles() {
    for (var n = 0; n < 3; n++) {
      Ember? p;
      for (final candidate in _deathParticles) {
        if (!candidate.active) {
          p = candidate;
          break;
        }
      }
      if (p == null) return;
      p.active = true;
      p.kind = n == 0 ? 1 : 0;
      p.x = _birdX + (_random.nextDouble() - .5) * 22;
      p.y = _birdY + (_random.nextDouble() - .5) * 12;
      p.vx = (_random.nextDouble() - .5) * 18;
      p.vy = -22 - _random.nextDouble() * 26;
      p.life = n == 0 ? .65 : .42 + _random.nextDouble() * .2;
      p.maxLife = p.life;
    }
  }

  void _emitTitleEmber() {
    for (final p in _deathParticles) {
      if (p.active) continue;
      p.active = true;
      p.kind = 0;
      p.x = _worldWidth / 2 + (_random.nextDouble() - .5) * 104;
      p.y = 73 + _random.nextDouble() * 16;
      p.vx = (_random.nextDouble() - .5) * 12;
      p.vy = -18 - _random.nextDouble() * 24;
      p.life = .6 + _random.nextDouble() * .35;
      p.maxLife = p.life;
      return;
    }
  }

  void _emitMedalBurst() {
    final wide = _worldWidth >= GameConfig.height * 1.4;
    final cardX = wide ? _worldWidth * .69 - 140 : (_worldWidth - 280) / 2;
    final cardY = wide ? 126.0 : 178.0;
    for (var i = 0; i < _deathParticles.length; i++) {
      final p = _deathParticles[i];
      if (p.active) continue;
      final a = i * math.pi * 2 / 10;
      p.active = true;
      p.kind = 0;
      p.x = cardX + 43 + math.cos(a) * 18;
      p.y = cardY + 139 + math.sin(a) * 18;
      p.vx = math.cos(a) * (18 + _random.nextDouble() * 20);
      p.vy = math.sin(a) * (18 + _random.nextDouble() * 20) - 14;
      p.life = .35 + _random.nextDouble() * .18;
      p.maxLife = p.life;
      if (i >= 11) break;
    }
  }

  int _reserveParticle() {
    for (var i = 0; i < _activeEmbers; i++) {
      if (!_embers[i].active) return i;
    }
    if (_activeEmbers >= _embers.length) return -1;
    return _activeEmbers++;
  }

  void _emitFireEmber() {
    if (_firePairs.isEmpty) return;
    final index = _reserveParticle();
    if (index < 0) return;
    final obstacle = _firePairs[_random.nextInt(_firePairs.length)];
    final upper = _random.nextBool();
    final gapTop = obstacle.gapCenter - GameConfig.gap / 2;
    final gapBottom = obstacle.gapCenter + GameConfig.gap / 2;
    final p = _embers[index];
    p.active = true;
    p.kind = 0;
    p.x = obstacle.x + _random.nextDouble() * GameConfig.pipeW;
    p.y = upper
        ? _random.nextDouble() * math.max(1, gapTop)
        : gapBottom + _random.nextDouble() * (GameConfig.groundY - gapBottom);
    p.vx = (_random.nextDouble() - .5) * 12;
    p.vy = -24 - _random.nextDouble() * 26;
    p.life = .55 + _random.nextDouble() * .55;
    p.maxLife = p.life;
  }

  void _emitPanParticles() {
    final index = _reserveParticle();
    if (index < 0) return;
    final p = _embers[index];
    p.active = true;
    p.kind = _random.nextInt(3) == 0 ? 1 : 0;
    p.x = _birdX + (_random.nextDouble() - .5) * 56;
    p.y = _landingY + 8 + _random.nextDouble() * 8;
    p.vx = (_random.nextDouble() - .5) * 35;
    p.vy = -16 - _random.nextDouble() * 42;
    p.life = .35 + _random.nextDouble() * .45;
    p.maxLife = p.life;
  }

  double _nearestFireDistance() {
    var nearest = double.infinity;
    for (final obstacle in _firePairs) {
      final distance = obstacle.x - _birdX;
      if (distance >= 0 && distance < nearest) nearest = distance;
    }
    return nearest;
  }

  void _updatePanic() {
    final distance = _nearestFireDistance();
    final next = distance <= 60 && distance >= -GameConfig.pipeW;
    if (next && !_panic) _emitSweatDrop();
    _panic = next;
  }

  void _emitSweatDrop() {
    final index = _reserveParticle();
    if (index < 0) return;
    final p = _embers[index];
    p.active = true;
    p.kind = 3;
    p.x = _birdX + 9;
    p.y = _birdY - 8;
    p.vx = 32;
    p.vy = -22;
    p.life = .42;
    p.maxLife = p.life;
  }

  void _emitFeathers() {
    for (var n = 0; n < 2; n++) {
      final index = _reserveParticle();
      if (index < 0) return;
      final p = _embers[index];
      p.active = true;
      p.kind = 4;
      p.x = _birdX - 10 - _random.nextDouble() * 5;
      p.y = _birdY + (_random.nextDouble() - .5) * 12;
      p.vx = -24 - _random.nextDouble() * 28;
      p.vy = -5 - _random.nextDouble() * 24;
      p.life = .35 + _random.nextDouble() * .18;
      p.maxLife = p.life;
    }
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  void _spawnFirePair({required double x, bool first = false}) {
    final prev = _firePairs.isEmpty ? 235.0 : _firePairs.last.gapCenter;
    const half = GameConfig.gap / 2;
    const minCenter = 68 + half;
    final maxCenter = GameConfig.groundY - 40 - half;
    final low = math.max(minCenter, prev - 56);
    final high = math.min(maxCenter, prev + 56);
    _firePairs.add(
      FirePair(
        x: x,
        gapCenter: low + _random.nextDouble() * (high - low),
        isFirst: first,
      ),
    );
  }

  void _ensureFireAhead() {
    while (_firePairs.isEmpty ||
        _firePairs.last.x < _worldWidth + GameConfig.spacing * 2) {
      final x = _firePairs.isEmpty
          ? _birdX + GameConfig.firstPipeDistance
          : _firePairs.last.x + GameConfig.spacing;
      _spawnFirePair(x: x, first: _firePairs.isEmpty);
    }
  }

  void _logPipeDistances() {
    assert(() {
      final distance = GameConfig.firstPipeDistance;
      debugPrint(
        'First pipe distance: $distance; pipe spacing: ${GameConfig.spacing}',
      );
      assert(distance <= 2 * GameConfig.spacing);
      return true;
    }());
  }

  bool _hitsFire() {
    final radius = GameConfig.hitR;
    for (final obstacle in _firePairs) {
      const inset = GameConfig.pipeW * .15;
      if (_birdX + radius <= obstacle.x + inset ||
          _birdX - radius >= obstacle.x + GameConfig.pipeW - inset) {
        continue;
      }
      final top = obstacle.gapCenter - GameConfig.gap / 2;
      final bottom = obstacle.gapCenter + GameConfig.gap / 2;
      if (_birdY - radius < top || _birdY + radius > bottom) return true;
    }
    return false;
  }

  Future<void> _saveBest() async {
    try {
      await storage.saveBestScore(_best);
    } catch (error) {
      debugPrint('Best score save failed: $error');
    }
  }

  void _input() {
    if (_phase == Phase.ready) {
      _audio.activate();
      _audio.playFlap();
      _emitFeathers();
      setState(() {
        _phase = Phase.playing;
        _score = 0;
        _newBest = false;
        _firePairs.clear();
        _panic = false;
        _birdY = 210;
        _velocity = GameConfig.flap;
        _angle = -.45;
        _flapAge = 0;
        _wingTime = 0;
        _groundOffset = 0;
        _deathElapsed = 0;
        _deathTotal = 0;
        _fireFrameTime = 0;
        _obstacleIntroTime = 0;
        _emberSpawnTimer = 0;
        _activeEmbers = 0;
        _scorePop = 0;
        _logPipeDistances();
        _ensureFireAhead();
      });
    } else if (_phase == Phase.playing) {
      _audio.playFlap();
      _emitFeathers();
      setState(() {
        _velocity = GameConfig.flap;
        _angle = -.45;
        _flapAge = 0;
        _wingTime = 0;
      });
    } else if (_phase == Phase.card) {
      _resetToReady();
    } else if (_isDeathPhase(_phase) && _deathTotal >= 1.2) {
      _setDeathPhase(Phase.card);
      _deathElapsed = 1.30;
    }
  }

  void _resetToReady() {
    _stopSizzle();
    setState(() {
      _phase = Phase.ready;
      _birdY = 210;
      _velocity = 0;
      _angle = 0;
      _firePairs.clear();
      _panic = false;
      _score = 0;
      _newBest = false;
      _groundOffset = 0;
      _buttonPressed = false;
      _deathElapsed = 0;
      _deathTotal = 0;
      _fireFrameTime = 0;
      _obstacleIntroTime = 0;
      _emberSpawnTimer = 0;
      _scorePop = 0;
      _activeEmbers = 0;
      _cookingParticleTimer = 0;
      _titleEmberTimer = 0;
      _medalBurstEmitted = false;
      _showRankTooltip = false;
      for (final p in _deathParticles) {
        p.active = false;
      }
      _deathByFire = false;
      _velocity = 0;
      _angle = 0;
      for (final p in _embers) {
        p.active = false;
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (kDebugMode && key == LogicalKeyboardKey.digit0) {
      setState(() => _showEndLayoutDebug = !_showEndLayoutDebug);
      return KeyEventResult.handled;
    }
    if (kDebugMode &&
        (key == LogicalKeyboardKey.digit1 ||
            key == LogicalKeyboardKey.digit2 ||
            key == LogicalKeyboardKey.digit3 ||
            key == LogicalKeyboardKey.digit4)) {
      final debugScore = switch (key) {
        LogicalKeyboardKey.digit1 => 0,
        LogicalKeyboardKey.digit2 => 7,
        LogicalKeyboardKey.digit3 => 19,
        _ => 45,
      };
      _jumpToDebugEnd(debugScore);
      return KeyEventResult.handled;
    }
    if (kDebugMode &&
        key == LogicalKeyboardKey.digit5 &&
        _phase == Phase.card) {
      setState(() {
        _setDeathPhase(Phase.card);
        _medalBurstEmitted = true;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _audio.muted = !_audio.muted;
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyH && _phase == Phase.card) {
      setState(() => _showRankTooltip = !_showRankTooltip);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.keyW ||
        (_phase == Phase.card && key == LogicalKeyboardKey.enter)) {
      _input();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      unawaited(fullscreen.toggleFullscreen());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _jumpToDebugEnd(int score) {
    setState(() {
      _score = score;
      _newBest = score > _best;
      _phase = Phase.card;
      _deathElapsed = 2.0;
      _deathTotal = 3.0;
      _birdY = _landingY;
      _velocity = 0;
      _angle = math.pi / 2;
      _panCenterX = _birdX;
      _panTopY = GameConfig.groundY - 6;
      _panPop = true;
      _panSlideElapsed = .08;
      _showRankTooltip = false;
      _medalBurstEmitted = true;
      for (final particle in _deathParticles) {
        particle.active = false;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _restartTimer?.cancel();
    _stopSizzle();
    _audio.dispose();
    _ticker.dispose();
    _focus.dispose();
    _bird?.dispose();
    _goldenBird?.dispose();
    _roastedBird?.dispose();
    _kitchen?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff70c5ce),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final scale = constraints.maxHeight / GameConfig.height;
        _worldWidth = constraints.maxWidth / scale;
        if (_kitchen == null || (_kitchenWidth - _worldWidth).abs() > .5) {
          _kitchen?.dispose();
          _kitchen = KitchenCache(_worldWidth);
          _kitchenWidth = _worldWidth;
        }
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              final logical = event.localPosition / scale;
              if (logical.dx >= _worldWidth - 46 && logical.dy <= 46) {
                unawaited(fullscreen.toggleFullscreen());
                return;
              }
              if (_phase == Phase.card) {
                setState(() => _buttonPressed = true);
                _restartTimer?.cancel();
                _restartTimer = Timer(const Duration(milliseconds: 110), () {
                  if (mounted && _phase == Phase.card) _resetToReady();
                });
              } else {
                _input();
              }
            },
            onPointerUp: (_) {
              if (_buttonPressed && mounted) {
                setState(() => _buttonPressed = false);
              }
            },
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: GameRenderer(
                  phase: _phase,
                  birdY: _birdY,
                  birdX: _birdX,
                  velocity: _velocity,
                  angle: _angle,
                  wingTime: _wingTime,
                  flapAge: _flapAge,
                  firePairs: _firePairs,
                  score: _score,
                  best: _best,
                  newBest: _newBest,
                  groundOffset: _groundOffset,
                  obstacleIntroTime: _obstacleIntroTime,
                  time: _time,
                  landscapeTime: _landscapeTime,
                  kitchen: _kitchen!,
                  worldWidth: _worldWidth,
                  deathElapsed: _deathElapsed,
                  deathTotal: _deathTotal,
                  deathByFire: _deathByFire,
                  fireFrameTime: _fireFrameTime,
                  embers: _embers,
                  activeEmbers: _activeEmbers,
                  scorePop: _scorePop,
                  buttonPressed: _buttonPressed,
                  bird: _bird,
                  goldenBird: _goldenBird,
                  roastedBird: _roastedBird,
                  deathParticles: _deathParticles,
                  panCenterX: _panCenterX,
                  panTopY: _panTopY,
                  panSlideElapsed: _panSlideElapsed,
                  panPop: _panPop,
                  panic: _panic,
                  showRankTooltip: _showRankTooltip,
                  showEndLayoutDebug: _showEndLayoutDebug,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class FirePair {
  FirePair({required this.x, required this.gapCenter, this.isFirst = false});
  double x;
  final double gapCenter;
  final bool isFirst;
  bool passed = false;
}

bool _isDeathPhase(Phase phase) => phase.index >= Phase.hit.index;

class Ember {
  bool active = false;
  int kind = 0;
  double x = 0, y = 0, vx = 0, vy = 0, life = 0, maxLife = 1;
}

class FireArt {
  static final List<ui.Picture> frames = List.generate(
    4,
    _buildFrame,
    growable: false,
  );
  static final ui.Picture glow = _buildGlow();
  static final ui.Picture pan = _buildPan();
  static final ui.Picture steam = _buildSteam();
  static final ui.Picture chicken = _buildRoastChicken();
  static final ui.Picture hero = _buildEndHero();
  static final ui.Picture heroGlow = _buildHeroGlow();
  static final ui.Picture scorePlate = _buildScorePlate();
  static final ui.Picture titleGlow = _buildTitleGlow();
  static final List<ui.Picture> titleFlames = List.generate(
    4,
    _buildTitleFlame,
  );
  static final Paint sparklePaint = Paint()
    ..strokeWidth = 2
    ..isAntiAlias = false;
  static final List<ui.Picture> medals = List.generate(4, _buildMedal);
  static final ui.Picture rawMedal = _buildRawMedal();
  static final ui.Picture burner = _buildBurner();
  static final ui.Picture hangingPot = _buildHangingPot();

  static void prewarmEndScreen() {
    final cachedCardArt = <ui.Picture>[scorePlate, rawMedal, ...medals];
    if (cachedCardArt.length != 6) {
      throw StateError('End-screen medal cache did not initialize completely.');
    }
  }

  static ui.Picture _buildFrame(int frame) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    const dark = Color(0xff34272b);
    for (var y = 0; y < 450; y += 8) {
      final t = y / 450;
      final tip = math.min(1.0, y / 72);
      final width =
          (12 + 32 * tip + math.sin(y * .11 + frame * 1.4) * (y < 72 ? 3 : 1.4))
              .round();
      final shift = (math.sin(y * .075 + frame * 1.1) * (y < 72 ? 3 : 1))
          .round();
      final left = (56 - width) ~/ 2 + shift;
      c.drawRect(
        Rect.fromLTWH(left.toDouble(), y.toDouble(), width.toDouble(), 10),
        Paint()
          ..color = dark
          ..isAntiAlias = false,
      );
      final innerLeft = left + 3;
      final innerWidth = width - 6;
      final bodyColor = t < .18
          ? const Color(0xffd54a24)
          : t < .37
          ? const Color(0xffef852c)
          : t < .72
          ? const Color(0xffe9c55f)
          : const Color(0xff438da0);
      c.drawRect(
        Rect.fromLTWH(
          innerLeft.toDouble(),
          (y + 2).toDouble(),
          innerWidth.toDouble(),
          6,
        ),
        Paint()
          ..color = bodyColor
          ..isAntiAlias = false,
      );
      final coreColor = t < .2
          ? const Color(0xffffa844)
          : t < .56
          ? const Color(0xffffdc76)
          : t < .84
          ? const Color(0xffb7e4e8)
          : const Color(0xffedf4dd);
      final coreWidth = math.max(4, innerWidth ~/ 3);
      c.drawRect(
        Rect.fromLTWH(
          (28 - coreWidth ~/ 2 + shift ~/ 2).toDouble(),
          (y + 3).toDouble(),
          coreWidth.toDouble(),
          4,
        ),
        Paint()
          ..color = coreColor
          ..isAntiAlias = false,
      );
    }
    return recorder.endRecording();
  }

  static ui.Picture _buildGlow() {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    final rect = const Rect.fromLTWH(0, 0, 96, 96);
    c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(48, 48),
          48,
          [const Color(0x66ff5a1b), const Color(0x00ff5a1b)],
          [0, 1],
        ),
    );
    return recorder.endRecording();
  }

  static ui.Picture _buildPan() {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    final ink = Paint()
      ..color = const Color(0xff30202b)
      ..isAntiAlias = false;
    final steel = Paint()
      ..color = const Color(0xff626b75)
      ..isAntiAlias = false;
    final shine = Paint()
      ..color = const Color(0xffb5c0c5)
      ..isAntiAlias = false;
    c.drawRect(const Rect.fromLTWH(4, 17, 29, 7), ink);
    c.drawRect(const Rect.fromLTWH(28, 12, 78, 22), ink);
    c.drawRect(const Rect.fromLTWH(34, 15, 66, 15), steel);
    c.drawRect(const Rect.fromLTWH(38, 17, 48, 3), shine);
    c.drawRect(const Rect.fromLTWH(31, 34, 72, 5), ink);
    c.drawRect(const Rect.fromLTWH(37, 39, 60, 3), steel);
    c.drawRect(const Rect.fromLTWH(7, 19, 20, 3), steel);
    return recorder.endRecording();
  }

  static ui.Picture _buildBurner() {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    final ink = Paint()
      ..color = const Color(0xff24292c)
      ..isAntiAlias = false;
    final iron = Paint()
      ..color = const Color(0xff495256)
      ..isAntiAlias = false;
    final glint = Paint()
      ..color = const Color(0xff77817f)
      ..isAntiAlias = false;
    c.drawRect(const Rect.fromLTWH(3, 8, 58, 26), ink);
    c.drawRect(const Rect.fromLTWH(8, 4, 48, 24), iron);
    c.drawRect(const Rect.fromLTWH(12, 0, 40, 9), ink);
    c.drawRect(const Rect.fromLTWH(16, 2, 32, 4), glint);
    c.drawRect(const Rect.fromLTWH(0, 31, 64, 5), ink);
    return recorder.endRecording();
  }

  static ui.Picture _buildHangingPot() {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    final ink = Paint()
      ..color = const Color(0xff22292c)
      ..isAntiAlias = false;
    final iron = Paint()
      ..color = const Color(0xff505b5e)
      ..isAntiAlias = false;
    final rim = Paint()
      ..color = const Color(0xff778080)
      ..isAntiAlias = false;
    c.drawRect(const Rect.fromLTWH(31, 0, 4, 17), ink);
    c.drawRect(const Rect.fromLTWH(8, 14, 50, 6), ink);
    c.drawRect(const Rect.fromLTWH(12, 18, 42, 19), ink);
    c.drawRect(const Rect.fromLTWH(16, 20, 34, 13), iron);
    c.drawRect(const Rect.fromLTWH(12, 35, 42, 5), ink);
    c.drawRect(const Rect.fromLTWH(18, 22, 19, 3), rim);
    return recorder.endRecording();
  }

  static ui.Picture _buildSteam() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final path = Path()
      ..moveTo(8, 62)
      ..cubicTo(0, 48, 22, 43, 13, 30)
      ..cubicTo(7, 20, 22, 14, 19, 2);
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xbfffffff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    return recorder.endRecording();
  }

  static ui.Picture _buildRoastChicken() {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    const ink = Color(0xff39251e);
    const crust = Color(0xff9a4e27);
    const gold = Color(0xffc87a32);
    const light = Color(0xffffd07a);
    final p = Paint()..isAntiAlias = false;
    p.color = ink;
    c.drawRect(const Rect.fromLTWH(9, 8, 34, 21), p);
    c.drawRect(const Rect.fromLTWH(5, 13, 42, 12), p);
    c.drawRect(const Rect.fromLTWH(2, 17, 8, 7), p);
    c.drawRect(const Rect.fromLTWH(40, 4, 9, 8), p);
    c.drawRect(const Rect.fromLTWH(43, 1, 5, 8), p);
    c.drawRect(
      const Rect.fromLTWH(8, 10, 34, 17),
      Paint()
        ..color = crust
        ..isAntiAlias = false,
    );
    c.drawRect(
      const Rect.fromLTWH(5, 15, 40, 9),
      Paint()
        ..color = gold
        ..isAntiAlias = false,
    );
    c.drawRect(
      const Rect.fromLTWH(14, 9, 18, 4),
      Paint()
        ..color = light
        ..isAntiAlias = false,
    );
    c.drawRect(
      const Rect.fromLTWH(32, 25, 11, 6),
      Paint()
        ..color = crust
        ..isAntiAlias = false,
    );
    c.drawRect(
      const Rect.fromLTWH(39, 26, 10, 5),
      Paint()
        ..color = ink
        ..isAntiAlias = false,
    );
    c.drawRect(
      const Rect.fromLTWH(43, 28, 8, 4),
      Paint()
        ..color = light
        ..isAntiAlias = false,
    );
    return recorder.endRecording();
  }

  static ui.Picture _buildEndHero() {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    void block(double x, double y, double w, double h, int color) => c.drawRect(
      Rect.fromLTWH(x, y, w, h),
      Paint()
        ..color = Color(color)
        ..isAntiAlias = false,
    );
    // Handle and cast-iron pan, rendered at the hero's native resolution.
    block(83, 53, 42, 9, 0xff211d21);
    block(87, 55, 35, 4, 0xff5b6265);
    block(13, 48, 81, 21, 0xff1d1b20);
    block(17, 47, 74, 15, 0xff41484b);
    block(24, 49, 57, 3, 0xffaeb4b4);
    block(20, 62, 67, 5, 0xff202024);
    block(28, 59, 51, 3, 0xff656d6e);
    // Whole chicken silhouette, legs, wings, and pixel-shaded roast skin.
    block(25, 28, 67, 31, 0xff3a241b);
    block(31, 22, 56, 43, 0xff3a241b);
    block(24, 34, 10, 20, 0xff3a241b);
    block(76, 18, 14, 13, 0xff3a241b);
    block(83, 14, 8, 13, 0xff3a241b);
    block(31, 27, 56, 32, 0xff8e4826);
    block(27, 34, 62, 20, 0xffbd6b2d);
    block(36, 23, 39, 8, 0xffd58a3d);
    block(32, 52, 48, 7, 0xffa5572b);
    block(43, 27, 26, 4, 0xffffd27b);
    block(35, 32, 11, 4, 0xffe7a950);
    block(64, 40, 15, 4, 0xff70402a);
    block(59, 47, 20, 3, 0xff70402a);
    // Drumsticks with bone ends.
    block(28, 50, 13, 10, 0xff8d4728);
    block(24, 57, 12, 6, 0xffe5d0a0);
    block(76, 48, 13, 11, 0xff8d4728);
    block(84, 56, 12, 6, 0xffe5d0a0);
    // Herb garnish and a few glossy/oil pixels.
    block(50, 18, 4, 7, 0xff68814c);
    block(46, 16, 5, 3, 0xff779151);
    block(54, 14, 5, 4, 0xff71884a);
    block(47, 24, 4, 3, 0xff57723f);
    block(42, 33, 4, 2, 0xffffe5a0);
    block(56, 30, 3, 2, 0xffffe0a0);
    block(67, 35, 3, 2, 0xffffe5a0);
    // Rim highlights and crisp pixel-art shadow.
    block(13, 46, 79, 3, 0xff171519);
    block(16, 45, 74, 2, 0xff9da5a5);
    block(14, 68, 80, 3, 0xff121216);
    return r.endRecording();
  }

  static ui.Picture _buildScorePlate() {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    final p = Paint()..isAntiAlias = false;
    final height = EndScreenLayout.cardDesignHeight;
    p.color = const Color(0xff171414);
    c.drawRect(Rect.fromLTWH(0, 0, 280, height), p);
    p.color = const Color(0xff4a2418);
    c.drawRect(Rect.fromLTWH(3, 3, 274, height - 6), p);
    p.color = const Color(0xff241b19);
    c.drawRect(Rect.fromLTWH(7, 7, 266, height - 14), p);
    p.color = const Color(0xff6a321b);
    c.drawRect(const Rect.fromLTWH(8, 8, 264, 3), p);
    c.drawRect(Rect.fromLTWH(8, height - 12, 264, 3), p);
    p.color = const Color(0xffff7832);
    c.drawRect(Rect.fromLTWH(4, 12, 3, height - 24), p);
    c.drawRect(Rect.fromLTWH(273, 12, 3, height - 24), p);
    // Scorched inset, grease marks, and glowing hairline cracks.
    p.color = const Color(0xff321d18);
    c.drawRect(const Rect.fromLTWH(12, 38, 256, 3), p);
    c.drawRect(const Rect.fromLTWH(181, 22, 70, 4), p);
    // Four rivets.
    for (final point in [
      const Offset(15, 15),
      const Offset(265, 15),
      Offset(15, height - 15),
      Offset(265, height - 15),
    ]) {
      c.drawCircle(point, 4, Paint()..color = const Color(0xff080808));
      c.drawCircle(point, 2, Paint()..color = const Color(0xff7b7771));
      c.drawRect(
        Rect.fromLTWH(point.dx - 1, point.dy - 2, 2, 1),
        Paint()..color = const Color(0xffd1a17b),
      );
    }
    return r.endRecording();
  }

  static ui.Picture _buildRawMedal() {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    const center = Offset(28, 28);
    final dash = Paint()
      ..color = const Color(0xffa99a87)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    for (var i = 0; i < 12; i++) {
      c.drawArc(
        Rect.fromCircle(center: center, radius: 25),
        i * math.pi / 6,
        math.pi / 18,
        false,
        dash,
      );
    }
    final ink = Paint()
      ..color = const Color(0xff302321)
      ..isAntiAlias = false;
    final meat = Paint()
      ..color = const Color(0xffd99c71)
      ..isAntiAlias = false;
    final bone = Paint()
      ..color = const Color(0xfff1dfc4)
      ..isAntiAlias = false;
    // Small pixel drumstick and its forked bone.
    c.drawRect(const Rect.fromLTWH(17, 22, 13, 8), ink);
    c.drawRect(const Rect.fromLTWH(19, 20, 10, 11), meat);
    c.drawRect(const Rect.fromLTWH(26, 24, 10, 5), ink);
    c.drawRect(const Rect.fromLTWH(27, 25, 9, 3), meat);
    c.drawRect(const Rect.fromLTWH(34, 24, 5, 3), bone);
    c.drawRect(const Rect.fromLTWH(37, 21, 3, 4), bone);
    c.drawRect(const Rect.fromLTWH(37, 27, 3, 4), bone);
    return recorder.endRecording();
  }

  static ui.Picture _buildTitleGlow() {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    const rect = Rect.fromLTWH(0, 0, 280, 52);
    c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(140, 28),
          150,
          const [Color(0x55ff5b18), Color(0x00ff5b18)],
          const [0, 1],
        ),
    );
    return r.endRecording();
  }

  static ui.Picture _buildHeroGlow() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = const Rect.fromLTWH(0, 0, 240, 160);
    canvas.drawOval(
      bounds,
      Paint()
        ..shader = ui.Gradient.radial(
          bounds.center,
          112,
          const [Color(0x66ffd595), Color(0x00ffd595)],
          const [0, 1],
        ),
    );
    return recorder.endRecording();
  }

  static ui.Picture _buildTitleFlame(int frame) {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    final tip = frame.isEven ? 3.0 : 1.0;
    c.drawRect(
      Rect.fromLTWH(7, 10 - tip, 5, 4 + tip),
      Paint()
        ..color = const Color(0xff9e2618)
        ..isAntiAlias = false,
    );
    c.drawRect(
      Rect.fromLTWH(8, 7 - tip, 3, 6 + tip),
      Paint()
        ..color = const Color(0xffef5a20)
        ..isAntiAlias = false,
    );
    c.drawRect(
      Rect.fromLTWH(9, 5 - tip, 2, 6 + tip),
      Paint()
        ..color = const Color(0xffffb52f)
        ..isAntiAlias = false,
    );
    c.drawRect(
      Rect.fromLTWH(9, 8 - tip, 1, 3),
      Paint()
        ..color = const Color(0xfffff1b2)
        ..isAntiAlias = false,
    );
    return r.endRecording();
  }

  static ui.Picture _buildMedal(int tier) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    const center = Offset(24, 21);
    final ribbon = tier < 0
        ? const Color(0xff6b6761)
        : const [
            Color(0xffb77847),
            Color(0xffbfc7ce),
            Color(0xffe3ad2f),
            Color(0xffb9dce5),
          ][tier];
    final disc = tier < 0
        ? const Color(0xff595c5e)
        : const [
            Color(0xffb77847),
            Color(0xffd9dce0),
            Color(0xffffcf3f),
            Color(0xffd8f1f5),
          ][tier];
    final ink = Paint()
      ..color = const Color(0xff342a2b)
      ..isAntiAlias = false;
    final bright = Paint()
      ..color = tier < 0 ? const Color(0xff858181) : const Color(0xfffff0bd)
      ..isAntiAlias = false;
    final dark = Paint()
      ..color = const Color(0xff4a3431)
      ..isAntiAlias = false;
    c.drawRect(const Rect.fromLTWH(12, 30, 10, 16), ink);
    c.drawRect(const Rect.fromLTWH(25, 30, 10, 16), ink);
    c.drawRect(
      const Rect.fromLTWH(14, 31, 6, 12),
      Paint()
        ..color = ribbon
        ..isAntiAlias = false,
    );
    c.drawRect(
      const Rect.fromLTWH(27, 31, 6, 12),
      Paint()
        ..color = ribbon
        ..isAntiAlias = false,
    );
    c.drawCircle(center, 19, ink);
    c.drawCircle(center, 16, dark);
    final centerPaint = Paint()
      ..color = tier < 0 ? const Color(0xff4b4d4e) : disc
      ..isAntiAlias = false;
    c.drawCircle(center, 13, centerPaint);
    if (tier < 0) {
      c.drawCircle(
        center,
        15,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xff818385),
      );
    } else {
      c.drawRect(const Rect.fromLTWH(15, 12, 13, 3), bright);
      // A distinct, chunky emblem for each earned rank.
      switch (tier) {
        case 0: // drumstick
          c.drawRect(const Rect.fromLTWH(17, 17, 12, 4), ink);
          c.drawRect(const Rect.fromLTWH(21, 15, 4, 9), bright);
          c.drawRect(const Rect.fromLTWH(15, 20, 5, 5), bright);
          c.drawRect(const Rect.fromLTWH(26, 20, 5, 5), bright);
        case 1: // flame
          c.drawRect(const Rect.fromLTWH(20, 15, 8, 12), ink);
          c.drawRect(const Rect.fromLTWH(18, 19, 12, 8), bright);
          c.drawRect(const Rect.fromLTWH(22, 17, 5, 8), ink);
        case 2: // chef hat
          c.drawRect(const Rect.fromLTWH(16, 20, 16, 7), ink);
          c.drawRect(const Rect.fromLTWH(18, 17, 12, 8), bright);
          c.drawRect(const Rect.fromLTWH(20, 14, 4, 5), bright);
          c.drawRect(const Rect.fromLTWH(26, 15, 4, 5), bright);
        case 3: // star
          c.drawRect(const Rect.fromLTWH(21, 14, 5, 16), bright);
          c.drawRect(const Rect.fromLTWH(16, 19, 15, 5), bright);
          c.drawRect(const Rect.fromLTWH(18, 16, 4, 4), bright);
          c.drawRect(const Rect.fromLTWH(26, 25, 4, 4), bright);
        default:
          break;
      }
      c.drawRect(
        const Rect.fromLTWH(30, 25, 8, 4),
        Paint()
          ..color = const Color(0xff8a532d)
          ..isAntiAlias = false,
      );
    }
    return recorder.endRecording();
  }
}

class KitchenCache {
  KitchenCache(this.viewportWidth)
    : wall = _wall(),
      farDecor = _farDecor(),
      cabinets = _cabinets(),
      counter = _counter(),
      vignette = _vignette(viewportWidth);

  static const tileWidth = 960.0;
  final double viewportWidth;
  final ui.Picture wall, farDecor, cabinets, counter, vignette;

  static ui.Picture _record(void Function(Canvas) draw) {
    final recorder = ui.PictureRecorder();
    draw(Canvas(recorder));
    return recorder.endRecording();
  }

  static ui.Picture _wall() => _record((canvas) {
    const rect = Rect.fromLTWH(0, 0, tileWidth, GameConfig.groundY);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xff385c63), Color(0xff52777a), Color(0xff496d70)],
          stops: [0, .65, 1],
        ).createShader(rect),
    );
    final grout = Paint()..color = const Color(0xff385e63);
    final tile = Paint()..color = const Color(0xff4c7275);
    final alt = Paint()..color = const Color(0xff496d71);
    for (var row = 1; row < 9; row++) {
      final y = 30.0 + row * 42;
      canvas.drawRect(Rect.fromLTWH(0, y, tileWidth, 2), grout);
      final shift = row.isEven ? 0.0 : -48.0;
      for (var x = shift; x < tileWidth; x += 96) {
        canvas.drawRect(
          Rect.fromLTWH(x + 2, y - 40, 92, 38),
          row.isEven ? tile : alt,
        );
        canvas.drawRect(Rect.fromLTWH(x + 94, y - 40, 2, 38), grout);
      }
    }
    final wood = Paint()..color = const Color(0xff34383a);
    final woodMid = Paint()..color = const Color(0xff514a43);
    canvas.drawRect(const Rect.fromLTWH(0, 0, tileWidth, 22), wood);
    canvas.drawRect(const Rect.fromLTWH(0, 20, tileWidth, 5), woodMid);
    for (final x in const [42.0, 176.0, 381.0, 630.0, 844.0]) {
      canvas.drawRect(
        Rect.fromLTWH(x, 3, 72, 2),
        Paint()..color = const Color(0xff5b534a),
      );
    }
    final rail = Paint()
      ..color = const Color(0xff30383b)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(const Offset(0, 31), const Offset(tileWidth, 31), rail);
    canvas.drawLine(
      const Offset(0, 34),
      const Offset(tileWidth, 34),
      Paint()
        ..color = const Color(0xff718080)
        ..strokeWidth = 1,
    );
  });

  static ui.Picture _farDecor() => _record((c) {
    final wood = Paint()..color = const Color(0xff414542);
    final woodLight = Paint()..color = const Color(0xff5a554d);
    final iron = Paint()..color = const Color(0xff343d40);
    // A dusky window and broad, deliberately sparse wall group.
    c.drawRect(const Rect.fromLTWH(70, 70, 142, 126), wood);
    c.drawRect(
      const Rect.fromLTWH(78, 78, 126, 110),
      Paint()..color = const Color(0xff405d66),
    );
    c.drawRect(const Rect.fromLTWH(138, 78, 4, 110), woodLight);
    c.drawRect(const Rect.fromLTWH(78, 128, 126, 4), woodLight);
    c.drawRect(const Rect.fromLTWH(68, 192, 146, 8), woodLight);
    for (final s in const [(97.0, 98.0), (177.0, 109.0), (119.0, 157.0)]) {
      c.drawCircle(
        Offset(s.$1, s.$2),
        2,
        Paint()..color = const Color(0xff91a1a0),
      );
    }

    // Clock.
    c.drawCircle(const Offset(520, 108), 28, iron);
    c.drawCircle(
      const Offset(520, 108),
      22,
      Paint()..color = const Color(0xff9a9b8c),
    );
    c.drawCircle(
      const Offset(520, 108),
      18,
      Paint()..color = const Color(0xff687d7d),
    );
    c.drawLine(
      const Offset(520, 108),
      const Offset(520, 96),
      iron..strokeWidth = 2,
    );
    c.drawLine(
      const Offset(520, 108),
      const Offset(531, 112),
      iron..strokeWidth = 2,
    );

    // Two open shelves with jars and plates, away from the play focal point.
    for (final x in const [302.0, 708.0]) {
      c.drawRect(Rect.fromLTWH(x, 136, 154, 7), wood);
      c.drawRect(Rect.fromLTWH(x + 8, 143, 5, 28), woodLight);
      c.drawRect(Rect.fromLTWH(x + 141, 143, 5, 28), woodLight);
      for (var i = 0; i < 3; i++) {
        final jx = x + 22 + i * 35;
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(jx, 112, 20, 24),
            const Radius.circular(3),
          ),
          Paint()..color = const Color(0xff707a72),
        );
        c.drawRect(Rect.fromLTWH(jx + 5, 106, 10, 7), woodLight);
      }
      c.drawOval(
        Rect.fromLTWH(x + 119, 111, 23, 23),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = const Color(0xff9a9a8c),
      );
    }
    // Hanging rail and muted utensil silhouettes.
    c.drawLine(
      const Offset(836, 112),
      const Offset(944, 112),
      iron..strokeWidth = 4,
    );
    for (var i = 0; i < 3; i++) {
      final x = 850.0 + i * 34;
      c.drawLine(Offset(x, 112), Offset(x, 134), iron..strokeWidth = 2);
      if (i == 0) {
        c.drawOval(
          Rect.fromLTWH(x - 7, 132, 14, 20),
          Paint()..color = const Color(0xff667270),
        );
      } else if (i == 1) {
        c.drawOval(
          Rect.fromLTWH(x - 8, 132, 16, 18),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = const Color(0xff667270),
        );
      } else {
        c.drawRect(
          Rect.fromLTWH(x - 5, 132, 10, 20),
          Paint()..color = const Color(0xff667270),
        );
      }
    }
  });

  static ui.Picture _cabinets() => _record((c) {
    final body = Paint()..color = const Color(0xff39494a);
    final shade = Paint()..color = const Color(0xff455757);
    final edge = Paint()..color = const Color(0xff2d3c3e);
    for (final spec in const [(250.0, 170.0, 190.0), (680.0, 180.0, 170.0)]) {
      final x = spec.$1, y = spec.$2, w = spec.$3;
      c.drawRect(Rect.fromLTWH(x, y, w, 138), edge);
      c.drawRect(Rect.fromLTWH(x + 4, y + 4, w - 8, 130), body);
      c.drawRect(Rect.fromLTWH(x + 12, y + 12, w / 2 - 16, 110), shade);
      c.drawRect(Rect.fromLTWH(x + w / 2 + 4, y + 12, w / 2 - 16, 110), shade);
      c.drawRect(Rect.fromLTWH(x + w / 2 - 2, y + 9, 4, 116), edge);
      c.drawCircle(
        Offset(x + w / 2 - 12, y + 72),
        2,
        Paint()..color = const Color(0xff87928b),
      );
      c.drawCircle(
        Offset(x + w / 2 + 12, y + 72),
        2,
        Paint()..color = const Color(0xff87928b),
      );
      c.drawRect(Rect.fromLTWH(x - 5, y + 138, w + 10, 7), edge);
    }
    // Pot rack under the cabinet line, low-contrast silhouettes.
    final iron = Paint()..color = const Color(0xff303a3b);
    c.drawLine(
      const Offset(478, 188),
      const Offset(625, 188),
      iron..strokeWidth = 4,
    );
    for (final x in const [500.0, 548.0, 597.0]) {
      c.drawLine(Offset(x, 188), Offset(x, 206), iron..strokeWidth = 2);
      c.drawOval(
        Rect.fromLTWH(x - 17, 204, 34, 25),
        Paint()..color = const Color(0xff465151),
      );
      c.drawRect(Rect.fromLTWH(x - 12, 224, 24, 5), iron);
      c.drawLine(
        Offset(x - 17, 213),
        Offset(x - 25, 213),
        iron..strokeWidth = 3,
      );
    }
  });

  static ui.Picture _counter() => _record((c) {
    c.drawRect(
      const Rect.fromLTWH(0, 367, tileWidth, 9),
      Paint()..color = const Color(0xff333b3c),
    );
    c.drawRect(
      const Rect.fromLTWH(0, 376, tileWidth, 74),
      Paint()..color = const Color(0xff514a43),
    );
    c.drawRect(
      const Rect.fromLTWH(0, 381, tileWidth, 4),
      Paint()..color = const Color(0xff6a6055),
    );
    for (final x in const [30.0, 260.0, 500.0, 760.0]) {
      c.drawRect(
        Rect.fromLTWH(x, 402, 5, 48),
        Paint()..color = const Color(0xff413d39),
      );
    }
    final board = Paint()..color = const Color(0xff786b5b);
    final iron = Paint()..color = const Color(0xff333c3d);
    // Cutting board and knife.
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(68, 337, 92, 29),
        const Radius.circular(4),
      ),
      board,
    );
    c.drawRect(const Rect.fromLTWH(112, 326, 43, 4), iron);
    c.drawRect(const Rect.fromLTWH(148, 322, 13, 12), iron);
    // Kettle, intentionally isolated.
    c.drawOval(
      const Rect.fromLTWH(322, 326, 50, 39),
      Paint()..color = const Color(0xff4c5a5a),
    );
    c.drawArc(
      const Rect.fromLTWH(330, 316, 33, 20),
      math.pi,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = iron.color,
    );
    c.drawRect(const Rect.fromLTWH(366, 339, 18, 8), iron);
    c.drawRect(
      const Rect.fromLTWH(339, 321, 15, 6),
      Paint()..color = const Color(0xff64716f),
    );
    // Spacious spice jars and plate stack.
    for (final x in const [550.0, 583.0, 616.0]) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 339, 17, 26),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xff687268),
      );
      c.drawRect(Rect.fromLTWH(x + 4, 334, 9, 6), board);
    }
    for (var i = 0; i < 3; i++) {
      c.drawOval(
        Rect.fromLTWH(758, 352 - i * 7.0, 61, 11),
        Paint()..color = const Color(0xff9a9a8d),
      );
    }
    // Knife block near the tile edge, within bounds.
    c.drawRect(const Rect.fromLTWH(877, 328, 40, 38), board);
    for (var i = 0; i < 3; i++) {
      final x = 883.0 + i * 12;
      c.drawRect(Rect.fromLTWH(x, 310, 3, 20), iron);
      c.drawRect(
        Rect.fromLTWH(x - 1, 306, 5, 8),
        Paint()..color = const Color(0xff68716d),
      );
    }
    // Low, quiet steam over the stock-pot position.
    c.drawRect(const Rect.fromLTWH(420, 348, 4, 16), iron);
    c.drawOval(
      const Rect.fromLTWH(408, 330, 30, 24),
      Paint()..color = const Color(0xff414c4d),
    );
    c.drawRect(const Rect.fromLTWH(413, 327, 20, 4), iron);
    c.drawRect(
      const Rect.fromLTWH(416, 322, 14, 5),
      Paint()..color = const Color(0xff606a67),
    );
    // Rolling pin at the far right.
    c.drawRect(const Rect.fromLTWH(660, 355, 73, 7), board);
    c.drawRect(const Rect.fromLTWH(651, 356, 10, 5), iron);
    c.drawRect(const Rect.fromLTWH(733, 356, 10, 5), iron);
  });

  static ui.Picture _vignette(double width) => _record((c) {
    final rect = Rect.fromLTWH(0, 0, width, GameConfig.height);
    c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(width / 2, GameConfig.height * .48),
          math.max(width, GameConfig.height) * .76,
          const [Color(0x00201820), Color(0x66120f17)],
          const [.42, 1],
        ),
    );
  });

  void dispose() {
    wall.dispose();
    farDecor.dispose();
    cabinets.dispose();
    counter.dispose();
    vignette.dispose();
  }
}

class EndScreenLayout {
  static double _measureTextHeight(
    String text,
    double fontSize, {
    double width = 240,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    return painter.height;
  }

  static final double scoreRowHeight = math.max(
    88,
    _measureTextHeight('SCORE', 12) +
        2 +
        _measureTextHeight('000', 40) +
        4 +
        _measureTextHeight('fires dodged', 12),
  );
  static final double rankLabelHeight = _measureTextHeight(
    'MICHELIN STAR',
    16,
    width: 180,
  );
  static final double rankCaptionHeight = _measureTextHeight(
    'NEXT: GOLDEN\nCRISP 30 pts\n(11 to go)',
    12,
    width: 180,
  );
  static final double medalRowHeight = math.max(
    56,
    rankLabelHeight + 2 + rankCaptionHeight,
  );
  static final double medalRowTop = 56 + scoreRowHeight + 16;
  static final double meterBlockHeight =
      math.max(20, _measureTextHeight('DONENESS', 12) + 4) + 14 + 6 + 18;
  static final double meterTop = medalRowTop + medalRowHeight + 16;
  static final double buttonDesignTop = meterTop + meterBlockHeight + 20;
  static final double cardDesignHeight =
      ((buttonDesignTop + 44 + 16) / 8).ceilToDouble() * 8;
  const EndScreenLayout({
    required this.titleRect,
    required this.heroRect,
    required this.cardRect,
    required this.buttonRect,
    required this.viewport,
    required this.scale,
  });

  final Rect titleRect, heroRect, cardRect, buttonRect;
  final Size viewport;
  final double scale;

  factory EndScreenLayout.forViewport(
    double width,
    double height,
    double scale,
  ) {
    const margin = 16.0;
    const gap = 16.0;
    final cardHeight = cardDesignHeight;
    final safeWidth = math.max(1.0, width - margin * 2);
    final wide = width >= GameConfig.height * 1.4;
    late final Rect title;
    late final Rect hero;
    late final Rect card;
    if (wide) {
      final availableHeight = math.max(1.0, height - 72 - margin);
      final cardScale = math.min(1.0, availableHeight / cardHeight);
      final cardWidth = 280.0 * cardScale;
      final heroWidth = math.max(1.0, safeWidth - cardWidth - gap);
      final contentTop = 72.0;
      final contentHeight = height - contentTop - margin;
      final actualCardHeight = cardHeight * cardScale;
      final cardTop = contentTop + (contentHeight - actualCardHeight) / 2;
      title = Rect.fromLTWH(margin, 8, safeWidth, 56);
      hero = Rect.fromLTWH(margin, cardTop, heroWidth, actualCardHeight);
      card = Rect.fromLTWH(
        margin + heroWidth + gap,
        cardTop,
        cardWidth,
        actualCardHeight,
      );
    } else {
      final availableHeight = math.max(1.0, height - 190 - margin);
      final cardScale = math.min(
        1.0,
        math.min(safeWidth / 280, availableHeight / cardHeight),
      );
      final cardWidth = 280.0 * cardScale;
      final actualCardHeight = cardHeight * cardScale;
      title = Rect.fromLTWH(margin, 8, safeWidth, 56);
      hero = Rect.fromLTWH(margin, 70, safeWidth, 112);
      card = Rect.fromLTWH(
        (width - cardWidth) / 2,
        190,
        cardWidth,
        actualCardHeight,
      );
    }
    final sx = card.width / 280;
    final sy = card.height / cardDesignHeight;
    final button = Rect.fromLTWH(
      card.left + 18 * sx,
      card.top + buttonDesignTop * sy,
      card.width - 36 * sx,
      44 * sy,
    );
    return EndScreenLayout(
      titleRect: title,
      heroRect: hero,
      cardRect: card,
      buttonRect: button,
      viewport: Size(width, height),
      scale: scale,
    );
  }
}

class GameRenderer extends CustomPainter {
  GameRenderer({
    required this.phase,
    required this.birdY,
    required this.birdX,
    required this.velocity,
    required this.angle,
    required this.wingTime,
    required this.flapAge,
    required this.firePairs,
    required this.score,
    required this.best,
    required this.newBest,
    required this.groundOffset,
    required this.obstacleIntroTime,
    required this.time,
    required this.landscapeTime,
    required this.kitchen,
    required this.worldWidth,
    required this.deathElapsed,
    required this.deathTotal,
    required this.deathByFire,
    required this.fireFrameTime,
    required this.embers,
    required this.activeEmbers,
    required this.deathParticles,
    required this.scorePop,
    required this.buttonPressed,
    required this.bird,
    required this.goldenBird,
    required this.roastedBird,
    required this.panCenterX,
    required this.panTopY,
    required this.panSlideElapsed,
    required this.panPop,
    required this.panic,
    required this.showRankTooltip,
    required this.showEndLayoutDebug,
  });

  final Phase phase;
  final double birdY, birdX, velocity, angle, wingTime, flapAge;
  final List<FirePair> firePairs;
  final int score, best;
  final bool newBest, buttonPressed;
  final double groundOffset,
      obstacleIntroTime,
      time,
      landscapeTime,
      worldWidth,
      deathElapsed,
      deathTotal,
      fireFrameTime,
      scorePop,
      panCenterX,
      panTopY,
      panSlideElapsed;
  final KitchenCache kitchen;
  final bool deathByFire;
  final List<Ember> embers;
  final List<Ember> deathParticles;
  final int activeEmbers;
  final ui.Image? bird;
  final ui.Image? goldenBird, roastedBird;
  final bool panic;
  final bool panPop;
  final bool showRankTooltip;
  final bool showEndLayoutDebug;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / GameConfig.height;
    final layout = EndScreenLayout.forViewport(
      worldWidth,
      GameConfig.height,
      scale,
    );
    canvas.save();
    canvas.scale(scale);
    canvas.clipRect(Rect.fromLTWH(0, 0, worldWidth, GameConfig.height));
    final shake = phase == Phase.hit
        ? math.sin(deathElapsed * 210) * math.max(0, 1 - deathElapsed / .08) * 5
        : 0.0;
    canvas.translate(shake, 0);
    _drawTiledLayer(canvas, kitchen.wall, landscapeTime, .05, scale);
    _drawTiledLayer(canvas, kitchen.farDecor, landscapeTime, .15, scale);
    _drawTiledLayer(canvas, kitchen.cabinets, landscapeTime, .30, scale);
    _drawTiledLayer(canvas, kitchen.counter, landscapeTime, .50, scale);
    final steamX = 419 + math.sin(time * 1.1) * 2;
    canvas.save();
    canvas.translate(steamX, 258 - (time * 5 % 8));
    canvas.scale(.42, .48);
    canvas.drawPicture(FireArt.steam);
    canvas.restore();
    _drawFire(canvas);
    _ground(canvas);
    if (phase.index >= Phase.hit.index) _drawPan(canvas);
    if (phase.index < Phase.zoom.index) _drawBird(canvas);
    if (phase == Phase.playing || _isDeathPhase(phase)) _drawEmbers(canvas);
    if (_isDeathPhase(phase)) _drawDeathParticles(canvas);
    if (phase.index >= Phase.zoom.index) _drawZoom(canvas, layout);
    _drawUi(canvas, layout);
    if (showEndLayoutDebug && phase.index >= Phase.zoom.index) {
      _drawLayoutDebug(canvas, layout);
    }
    if (phase == Phase.hit) _flash(canvas);
    canvas.restore();
  }

  void _drawTiledLayer(
    Canvas canvas,
    ui.Picture picture,
    double seconds,
    double factor,
    double scale,
  ) {
    const tile = KitchenCache.tileWidth;
    final offset =
        (seconds * GameConfig.pipeSpeed / GameConfig.step * factor) % tile;
    var x = -offset;
    while (x < worldWidth + tile) {
      final aligned = (x * scale).roundToDouble() / scale;
      canvas.save();
      canvas.translate(aligned, 0);
      canvas.drawPicture(picture);
      canvas.restore();
      x += tile;
    }
  }

  void _drawFire(Canvas canvas) {
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, worldWidth, GameConfig.groundY));
    final frame = (fireFrameTime / .09).floor() % FireArt.frames.length;
    final intro = (obstacleIntroTime / .25).clamp(0.0, 1.0);
    for (final obstacle in firePairs) {
      if (obstacle.isFirst && intro < 1) {
        canvas.save();
        canvas.translate((1 - intro) * 24, 0);
        canvas.saveLayer(
          Rect.fromLTWH(
            obstacle.x - 8,
            0,
            GameConfig.pipeW + 16,
            GameConfig.groundY,
          ),
          Paint()..color = Color.fromARGB((intro * 255).round(), 255, 255, 255),
        );
      }
      final gapTop = obstacle.gapCenter - GameConfig.gap / 2;
      final gapBottom = obstacle.gapCenter + GameConfig.gap / 2;
      final chainPaint = Paint()
        ..color = const Color(0xff373d3e)
        ..strokeWidth = 2
        ..isAntiAlias = false;
      canvas.drawLine(
        Offset(obstacle.x + GameConfig.pipeW / 2, 22),
        Offset(obstacle.x + GameConfig.pipeW / 2, 46),
        chainPaint,
      );
      canvas.save();
      canvas.translate(obstacle.x - 8, 12);
      canvas.drawPicture(FireArt.hangingPot);
      canvas.restore();
      _drawFlameColumn(
        canvas,
        obstacle.x,
        52,
        GameConfig.pipeW,
        math.max(0, gapTop - 52),
        frame,
        inverted: true,
      );
      final burnerY = GameConfig.groundY - 36;
      _drawFlameColumn(
        canvas,
        obstacle.x,
        gapBottom,
        GameConfig.pipeW,
        math.max(0, burnerY - gapBottom),
        frame,
      );
      canvas.save();
      canvas.translate(obstacle.x - 6, burnerY);
      canvas.drawPicture(FireArt.burner);
      canvas.restore();
      if (obstacle.isFirst && intro < 1) {
        canvas.restore();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _drawFlameColumn(
    Canvas canvas,
    double x,
    double y,
    double width,
    double height,
    int frame, {
    bool inverted = false,
  }) {
    if (height <= 0) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(x - 20, y, width + 40, height));
    canvas.save();
    canvas.translate(x - 20, y);
    canvas.scale((width + 40) / 96, height / 96);
    canvas.drawPicture(FireArt.glow);
    canvas.restore();
    if (inverted) {
      canvas.translate(x, y + height);
      canvas.scale(width / 56, -height / 450);
      canvas.drawPicture(FireArt.frames[frame]);
    } else {
      canvas.translate(x, y);
      canvas.scale(width / 56, height / 450);
      canvas.drawPicture(FireArt.frames[frame]);
    }
    canvas.restore();
  }

  void _drawImage(Canvas canvas, ui.Image image, Rect dst, Paint paint) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      paint,
    );
  }

  void _ground(Canvas canvas) {
    const y = GameConfig.groundY, tile = GameConfig.tileW;
    final paint = Paint()..isAntiAlias = false;
    paint.color = const Color(0xff323638);
    canvas.drawRect(Rect.fromLTWH(0, y, worldWidth, 62), paint);
    final start = -(groundOffset % tile);
    for (var x = start; x < worldWidth + tile; x += tile) {
      for (var row = 0; row < 4; row++) {
        for (var col = 0; col < 2; col++) {
          paint.color = (row + col).isEven
              ? const Color(0xff77736d)
              : const Color(0xffaaa49a);
          canvas.drawRect(
            Rect.fromLTWH(x + col * 16, y + 5 + row * 14, 16, 14),
            paint,
          );
        }
      }
    }
    paint.color = const Color(0xff252a2c);
    canvas.drawRect(Rect.fromLTWH(0, y, worldWidth, 5), paint);
    paint.color = const Color(0xff171b1c);
    canvas.drawRect(Rect.fromLTWH(0, y, worldWidth, 2), paint);
  }

  void _drawPan(Canvas canvas) {
    final wobble = phase == Phase.onPan
        ? math.sin(deathElapsed * 28) *
              (1 - deathElapsed / .40).clamp(0.0, 1.0) *
              .07
        : 0.0;
    final popScale = panPop
        ? .6 + .4 * (panSlideElapsed / .08).clamp(0.0, 1.0)
        : 1.0;
    canvas.save();
    canvas.translate(panCenterX, panTopY);
    canvas.rotate(wobble);
    canvas.scale(56 / 106 * popScale, 20 / 42 * popScale);
    canvas.translate(-55, -12);
    canvas.drawPicture(FireArt.pan);
    canvas.restore();
  }

  void _drawDeathParticles(Canvas canvas) {
    for (final p in deathParticles) {
      if (!p.active) continue;
      final alpha = (p.life / p.maxLife).clamp(0.0, 1.0);
      if (p.kind == 1) {
        canvas.drawCircle(
          Offset(p.x, p.y),
          2 + (1 - alpha) * 4,
          Paint()
            ..color = const Color(0x99e8e2d9).withValues(alpha: alpha * .6),
        );
      } else {
        canvas.drawRect(
          Rect.fromLTWH(p.x, p.y, 3, 3),
          Paint()..color = const Color(0xffff9442).withValues(alpha: alpha),
        );
      }
    }
  }

  void _drawEmbers(Canvas canvas) {
    for (var i = 0; i < activeEmbers; i++) {
      final p = embers[i];
      if (!p.active) continue;
      final progress = (p.life / p.maxLife).clamp(0.0, 1.0);
      if (p.kind == 1) {
        final radius = 3 + (1 - progress) * 5;
        canvas.drawCircle(
          Offset(p.x, p.y),
          radius,
          Paint()
            ..color = const Color(0x99fff2dc).withValues(alpha: .55 * progress),
        );
      } else if (p.kind == 3) {
        canvas.drawOval(
          Rect.fromLTWH(p.x, p.y, 5 * progress, 8 * progress),
          Paint()..color = const Color(0xffbfe8f2).withValues(alpha: progress),
        );
      } else if (p.kind == 4) {
        final feather = Path()
          ..moveTo(p.x, p.y)
          ..quadraticBezierTo(p.x + 5, p.y - 3, p.x + 8, p.y + 1)
          ..quadraticBezierTo(p.x + 4, p.y + 4, p.x, p.y);
        canvas.drawPath(
          feather,
          Paint()..color = const Color(0xfffff3ca).withValues(alpha: progress),
        );
      } else {
        final color = i.isEven
            ? const Color(0xffffcf4d)
            : const Color(0xffff6124);
        canvas.drawRect(
          Rect.fromLTWH(p.x, p.y, 3, 3),
          Paint()..color = color.withValues(alpha: progress),
        );
      }
    }
  }

  void _drawZoom(Canvas canvas, EndScreenLayout layout) {
    final t = phase.index > Phase.zoom.index
        ? 1.0
        : (deathElapsed / .60).clamp(0.0, 1.0);
    final dim = phase == Phase.zoom ? .68 * t : .68;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, worldWidth, GameConfig.height),
      Paint()..color = Colors.black.withValues(alpha: dim),
    );
    _guardComponent(canvas, 'hero', () {
      final target = layout.heroRect.center;
      final start = Offset(panCenterX, panTopY - 40);
      final progress = t >= 1 ? 1.0 : Curves.easeOutBack.transform(t);
      final center = Offset.lerp(start, target, progress)!;
      final maxScale = math.min(
        3.5,
        math.min(layout.heroRect.width / 128, layout.heroRect.height / 80),
      );
      final finalScale = maxScale.clamp(.5, 3.5).toDouble();
      final heroScale = t >= 1
          ? finalScale
          : .58 + (finalScale - .58) * Curves.easeOutCubic.transform(t);
      canvas.save();
      canvas.save();
      canvas.translate(target.dx - 120, target.dy - 80);
      canvas.scale(finalScale);
      canvas.drawPicture(FireArt.heroGlow);
      canvas.restore();
      canvas.translate(center.dx, center.dy);
      canvas.scale(heroScale);
      canvas.translate(-64, -40);
      canvas.drawPicture(FireArt.hero);
      canvas.restore();
      canvas.save();
      canvas.translate(center.dx - 30, center.dy - 54 - t * 8);
      canvas.scale(.32);
      canvas.drawPicture(FireArt.steam);
      canvas.restore();
    });
  }

  void _drawBird(Canvas canvas) {
    final hover = phase == Phase.ready
        ? math.sin(time * math.pi * 2 / 1.2) * 4
        : 0.0;
    final duration = phase == Phase.playing && flapAge < .24 ? .06 : .10;
    final wing =
        _isDeathPhase(phase) || (phase == Phase.playing && velocity > 4)
        ? 1
        : [0, 1, 2, 1][(wingTime / duration).floor() % 4];
    canvas.save();
    var bounce = 0.0;
    if (phase == Phase.onPan) {
      final t = deathElapsed;
      bounce = t < .16
          ? -math.sin(t / .16 * math.pi) * 8
          : t < .28
          ? -math.sin((t - .16) / .12 * math.pi) * 4
          : 0;
    }
    canvas.translate(birdX, birdY + hover + bounce);
    canvas.rotate(angle);
    if (phase == Phase.onPan && deathElapsed < .4) {
      final squash = deathElapsed < .08 ? 1 - deathElapsed * 1.2 : 1.0;
      canvas.scale(1 + (1 - squash) * .65, squash);
    }
    final rect = const Rect.fromLTWH(-17, -12, 34, 24);
    final cook = _isDeathPhase(phase)
        ? ((deathTotal - .08) / .60).clamp(0.0, 1.0)
        : 0.0;
    final paint = Paint()..filterQuality = FilterQuality.none;
    if (bird == null) {
      _fallbackBird(canvas, paint, wing);
    } else if (cook > 0 && (goldenBird != null || roastedBird != null)) {
      final src = Rect.fromLTWH(
        0,
        0,
        bird!.width.toDouble(),
        bird!.height.toDouble(),
      );
      if (cook < .5 && goldenBird != null) {
        _drawImageAlpha(canvas, bird!, src, rect, 1 - cook * 2);
        _drawImageAlpha(canvas, goldenBird!, src, rect, cook * 2);
      } else if (goldenBird != null && roastedBird != null) {
        final t = (cook - .5) * 2;
        _drawImageAlpha(canvas, goldenBird!, src, rect, 1 - t);
        _drawImageAlpha(canvas, roastedBird!, src, rect, t);
      } else {
        _drawImage(canvas, cook < .5 ? goldenBird! : roastedBird!, rect, paint);
      }
    } else {
      final flapScale = wing == 0
          ? 1.04
          : wing == 2
          ? .96
          : 1.0;
      canvas.scale(1, flapScale);
      _drawImage(canvas, bird!, rect, paint);
    }
    if (GameConfig.USE_CHICKEN_COMB) {
      final red = Paint()
        ..color = const Color(0xffc9353e)
        ..isAntiAlias = false;
      canvas.drawRect(const Rect.fromLTWH(-5, -15, 4, 4), red);
      canvas.drawRect(const Rect.fromLTWH(-1, -17, 5, 6), red);
      canvas.drawRect(const Rect.fromLTWH(4, -14, 4, 4), red);
      canvas.drawRect(const Rect.fromLTWH(12, 3, 4, 5), red);
      canvas.drawRect(const Rect.fromLTWH(13, 7, 3, 3), red);
    }
    if (panic && phase == Phase.playing) {
      canvas.drawOval(
        const Rect.fromLTWH(4, -10, 11, 12),
        Paint()..color = const Color(0xfffffff5),
      );
      canvas.drawCircle(
        const Offset(11, -4),
        3,
        Paint()..color = const Color(0xff151515),
      );
    }
    canvas.restore();
  }

  void _drawImageAlpha(
    Canvas canvas,
    ui.Image image,
    Rect src,
    Rect dst,
    double alpha,
  ) {
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.none
        ..color = Color.fromARGB(
          (alpha.clamp(0.0, 1.0) * 255).round(),
          255,
          255,
          255,
        ),
    );
  }

  void _wingOverlay(Canvas canvas, int frame, Paint paint) {
    const y = [-3.0, 0.0, 3.0];
    paint.color = const Color(0xffffd76c);
    canvas.drawRect(const Rect.fromLTWH(-13, -3, 9, 8), paint);
    paint.color = frame == 1
        ? const Color(0xfffffff4)
        : const Color(0xfff3c54a);
    canvas.drawRect(Rect.fromLTWH(-12, y[frame], 7, 3), paint);
    paint.color = const Color(0xff17121a);
    canvas.drawRect(Rect.fromLTWH(-12, y[frame] - 1, 2, 2), paint);
    canvas.drawRect(Rect.fromLTWH(-6, y[frame] + 2, 2, 2), paint);
  }

  void _fallbackBird(Canvas canvas, Paint paint, int wing) {
    paint.color = const Color(0xff17121a);
    canvas.drawRect(const Rect.fromLTWH(-16, -10, 25, 20), paint);
    paint.color = const Color(0xffffc900);
    canvas.drawRect(const Rect.fromLTWH(-14, -8, 21, 16), paint);
    paint.color = const Color(0xfffffff4);
    canvas.drawRect(const Rect.fromLTWH(3, -8, 8, 8), paint);
    paint.color = const Color(0xff17121a);
    canvas.drawRect(const Rect.fromLTWH(7, -6, 3, 4), paint);
    paint.color = const Color(0xffe9000b);
    canvas.drawRect(const Rect.fromLTWH(10, 0, 9, 4), paint);
    paint.color = const Color(0xffff8500);
    canvas.drawRect(const Rect.fromLTWH(-5, 7, 11, 5), paint);
    _wingOverlay(canvas, wing, paint);
  }

  void _drawUi(Canvas canvas, EndScreenLayout layout) {
    if (phase == Phase.ready) {
      _label(canvas, 'GET READY!', Offset(worldWidth / 2 - 67, 75), 17, 2);
      _label(canvas, 'TAP TO FLAP', Offset(worldWidth / 2 - 60, 326), 10, 1.3);
      _label(canvas, 'SPACE / UP / W', Offset(worldWidth / 2 - 48, 344), 7, 1);
    } else if (phase == Phase.playing) {
      final scale = scorePop > 0 ? 1 + .3 * scorePop / .15 : 1.0;
      canvas.save();
      canvas.translate(worldWidth / 2, 48);
      canvas.scale(scale);
      _label(
        canvas,
        '$score',
        Offset(-score.toString().length * 11, -17),
        34,
        5,
      );
      canvas.restore();
    } else if (phase == Phase.title || phase == Phase.card) {
      _guardComponent(
        canvas,
        'title',
        () => _endTitle(canvas, layout.titleRect),
      );
      if (phase == Phase.card) {
        final cardT = (deathElapsed / .45).clamp(0.0, 1.0);
        final positionT = cardT >= 1
            ? 1.0
            : Curves.easeOutBack.transform(cardT);
        final boxScale = cardT >= 1
            ? 1.0
            : .96 + .04 * Curves.easeOutCubic.transform(cardT);
        final boxOpacity = _cardBoxAlpha(deathElapsed);
        final slide = 40 * (1 - positionT);
        final cardRect = Rect.fromCenter(
          center: Offset(
            layout.cardRect.center.dx,
            layout.cardRect.center.dy + slide,
          ),
          width: layout.cardRect.width * boxScale,
          height: layout.cardRect.height * boxScale,
        );
        final buttonRect = layout.buttonRect;
        _guardComponent(
          canvas,
          'scorecard',
          () => _scoreboard(
            canvas,
            cardRect,
            boxOpacity,
            deathElapsed,
            showRankTooltip,
            showEndLayoutDebug,
          ),
        );
        _guardComponent(
          canvas,
          'button',
          () => _drawEndButton(
            canvas,
            layout.cardRect,
            cardRect,
            buttonRect,
            boxOpacity,
            deathElapsed,
          ),
        );
      }
    }
    _fullscreenButton(canvas);
  }

  void _endTitle(Canvas canvas, Rect titleRect) {
    final youT = phase == Phase.title
        ? (deathElapsed / .30).clamp(0.0, 1.0)
        : 1.0;
    final servedT = phase == Phase.title
        ? ((deathElapsed - .50) / .40).clamp(0.0, 1.0)
        : 1.0;
    final slam = phase == Phase.title && youT < 1
        ? 1.4 - .4 * Curves.easeOutBack.transform(youT)
        : 1.0;
    final shake = phase == Phase.title && deathElapsed < .12
        ? math.sin(deathElapsed * 160) * 4 * (1 - deathElapsed / .12)
        : 0.0;
    final centerX = titleRect.center.dx + shake;
    final glowAlpha = .22 + .16 * math.sin(time * 4);
    canvas.save();
    canvas.translate(titleRect.left, titleRect.top);
    canvas.scale(titleRect.width / 280, titleRect.height / 58);
    canvas.saveLayer(
      const Rect.fromLTWH(0, 0, 280, 58),
      Paint()..color = Color.fromARGB((glowAlpha * 255).round(), 255, 255, 255),
    );
    canvas.drawPicture(FireArt.titleGlow);
    canvas.restore();
    canvas.restore();

    var youSize = 16.0;
    var servedSize = youSize * 1.3;
    var you = _makeTitlePainter(
      'YOU GOT',
      youSize,
      Paint()..color = Colors.white,
    );
    var servedMeasure = _makeTitlePainter(
      'SERVED',
      servedSize,
      Paint()..color = Colors.white,
    );
    final gap = 8.0;
    final fit =
        ((titleRect.width - 8) / (you.width + gap + servedMeasure.width))
            .clamp(.5, 1.0)
            .toDouble();
    if (fit < 1) {
      youSize *= fit;
      servedSize *= fit;
      you = _makeTitlePainter(
        'YOU GOT',
        youSize,
        Paint()..color = Colors.white,
      );
      servedMeasure = _makeTitlePainter(
        'SERVED',
        servedSize,
        Paint()..color = Colors.white,
      );
    }
    final totalWidth = you.width + gap + servedMeasure.width;
    final groupLeft = centerX - totalWidth / 2;
    final sharedBaseline = titleRect.center.dy + 6;
    final youY =
        sharedBaseline -
        you.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final servedY =
        sharedBaseline -
        servedMeasure.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final slamX = groupLeft + you.width / 2;
    canvas.save();
    canvas.translate(slamX, titleRect.center.dy);
    canvas.scale(slam);
    canvas.translate(-slamX, -titleRect.center.dy);
    _drawTitleWord(
      canvas,
      'YOU GOT',
      youSize,
      Offset(groupLeft, youY),
      Colors.white,
    );

    final servedX = groupLeft + you.width + gap;
    final servedText = _makeTitlePainter(
      'SERVED',
      servedSize,
      Paint()..color = Colors.white,
    );
    final servedBounds = Rect.fromLTWH(
      servedX,
      servedY,
      servedText.width,
      servedText.height,
    );
    _drawTitleWord(
      canvas,
      'SERVED',
      servedSize,
      Offset(servedX, servedY),
      null,
      shaderBounds: servedBounds,
      heat: servedT,
    );
    if (servedT > .35) {
      final frame = (time / .09).floor() % FireArt.titleFlames.length;
      final count = math.max(3, (servedText.width / 15).floor());
      for (var i = 0; i < count; i++) {
        final x = servedX + i * servedText.width / math.max(1, count - 1) - 10;
        canvas.save();
        canvas.translate(x, servedBounds.top - 9);
        canvas.drawPicture(
          FireArt.titleFlames[(frame + i) % FireArt.titleFlames.length],
        );
        canvas.restore();
      }
    }
    canvas.restore();
    _drawTitleEmbers(canvas, servedBounds, servedT);
  }

  TextPainter _makeTitlePainter(String text, double size, Paint foreground) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            height: 1,
            foreground: foreground,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  void _drawTitleWord(
    Canvas canvas,
    String text,
    double size,
    Offset position,
    Color? color, {
    Rect? shaderBounds,
    double heat = 1,
  }) {
    final shadow = _makeTitlePainter(
      text,
      size,
      Paint()..color = const Color(0xff090604),
    );
    shadow.paint(canvas, position + const Offset(2, 3));
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * .28
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xff100b09);
    _makeTitlePainter(text, size, outlinePaint).paint(canvas, position);
    Paint fillPaint;
    if (shaderBounds != null) {
      try {
        fillPaint = Paint()
          ..shader = ui.Gradient.linear(
            Offset(shaderBounds.left, shaderBounds.top - (time * 7 % 15)),
            Offset(shaderBounds.left, shaderBounds.bottom - (time * 7 % 15)),
            [
              Color.lerp(
                const Color(0xffe97722),
                const Color(0xfffff2a4),
                heat,
              )!,
              Color.lerp(
                const Color(0xffb72b18),
                const Color(0xffff9d26),
                heat,
              )!,
              const Color(0xffc72c17),
            ],
            const [0.0, 0.52, 1.0],
            TileMode.clamp,
          );
      } catch (error) {
        assert(() {
          debugPrint(
            'End-screen SERVED shader failed: $error; using orange fill.',
          );
          return true;
        }());
        fillPaint = Paint()..color = const Color(0xffff7624);
      }
    } else {
      fillPaint = Paint()..color = color ?? const Color(0xffff7624);
    }
    _makeTitlePainter(text, size, fillPaint).paint(canvas, position);
  }

  void _drawTitleEmbers(Canvas canvas, Rect bounds, double heat) {
    if (heat <= .35) return;
    for (var i = 0; i < 7; i++) {
      final phaseOffset = i * 1.73;
      final x =
          bounds.left + (i * 37.0 + time * (8 + i % 3 * 3)) % bounds.width;
      final y = bounds.top - 3 - ((time * 17 + phaseOffset * 5) % 18);
      final size = i.isEven ? 2.0 : 1.5;
      canvas.drawRect(
        Rect.fromLTWH(x, y, size, size),
        Paint()
          ..color = i.isEven
              ? const Color(0xffffdf85)
              : const Color(0xffff6a26),
      );
    }
  }

  void _guardComponent(Canvas canvas, String name, VoidCallback draw) {
    canvas.save();
    try {
      draw();
    } catch (error, stack) {
      assert(() {
        debugPrint('End-screen component "$name" failed: $error\n$stack');
        return true;
      }());
    } finally {
      canvas.restore();
    }
  }

  void _drawLayoutDebug(Canvas canvas, EndScreenLayout layout) {
    final entries = <(Rect, Color)>[
      (layout.titleRect, const Color(0xffff3b30)),
      (layout.heroRect, const Color(0xff34c759)),
      (layout.cardRect, const Color(0xff0a84ff)),
      (layout.buttonRect, const Color(0xffffcc00)),
    ];
    for (final (rect, color) in entries) {
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
    }
    _label(
      canvas,
      'logical ${layout.viewport.width.toStringAsFixed(0)} x ${layout.viewport.height.toStringAsFixed(0)}  scale ${layout.scale.toStringAsFixed(2)}',
      const Offset(12, 486),
      9,
      1,
      color: Colors.white,
    );
  }

  void _scoreboard(
    Canvas canvas,
    Rect drawRect,
    double boxOpacity,
    double cardElapsed,
    bool showRankTooltip,
    bool showLayoutDebug,
  ) {
    const designWidth = 280.0;
    final designHeight = EndScreenLayout.cardDesignHeight;
    final scaleX = drawRect.width / designWidth;
    final scaleY = drawRect.height / designHeight;
    final pulse = .70 + .30 * (.5 + .5 * math.sin(time * 2.4));
    canvas.save();
    canvas.translate(drawRect.left, drawRect.top);
    canvas.scale(scaleX, scaleY);
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, designWidth, designHeight),
      Paint()
        ..color = Colors.white.withValues(alpha: boxOpacity.clamp(0.0, 1.0)),
    );
    canvas.drawPicture(FireArt.scorePlate);
    canvas.drawRect(
      Rect.fromLTWH(2, 2, designWidth - 4, designHeight - 4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xffff7832).withValues(alpha: pulse),
    );
    canvas.restore();

    // Header block.
    _drawCardBlock(
      canvas,
      const Rect.fromLTWH(16, 4, 248, 40),
      _cardContentAlpha(cardElapsed, 0),
      8,
      () {
        canvas.drawRect(
          const Rect.fromLTWH(16, 16, 248, 28),
          Paint()..color = const Color(0xff34201a),
        );
        _cardText(
          canvas,
          'COOK REPORT',
          const Rect.fromLTWH(34, 18, 160, 24),
          14,
          const Color(0xfff6e7c7),
          center: true,
          debug: showLayoutDebug,
        );
        if (newBest) {
          canvas.drawRect(
            const Rect.fromLTWH(198, 5, 76, 20),
            Paint()..color = const Color(0xffb9381c),
          );
          _cardText(
            canvas,
            'NEW BEST',
            const Rect.fromLTWH(198, 5, 76, 20),
            12,
            const Color(0xffffe3b0),
            center: true,
            debug: showLayoutDebug,
          );
        }
      },
    );

    final scoreAlpha = _cardContentAlpha(cardElapsed, .06);
    final countT = ((cardElapsed - .22) / .60).clamp(0.0, 1.0);
    final shownScore = (score * countT).round();
    _drawCardBlock(
      canvas,
      Rect.fromLTWH(16, 54, 248, EndScreenLayout.scoreRowHeight + 4),
      scoreAlpha,
      8,
      () {
        final scoreLabel = _cardText(
          canvas,
          'SCORE',
          const Rect.fromLTWH(20, 56, 120, 18),
          12,
          const Color(0xfff6e7c7),
          debug: showLayoutDebug,
        );
        final numberRect = _cardText(
          canvas,
          '$shownScore',
          Rect.fromLTWH(20, scoreLabel.bottom + 1, 120, 48),
          40,
          const Color(0xfffff4dc),
          debug: showLayoutDebug,
        );
        _cardText(
          canvas,
          'fires dodged',
          Rect.fromLTWH(20, numberRect.bottom + 4, 132, 18),
          12,
          const Color(0xffd4c3ad),
          debug: showLayoutDebug,
        );

        if (newBest) {
          _cardText(
            canvas,
            'BEST',
            const Rect.fromLTWH(174, 58, 72, 18),
            12,
            const Color(0xfff6e7c7),
            debug: showLayoutDebug,
          );
          _cardText(
            canvas,
            '$best',
            const Rect.fromLTWH(174, 79, 82, 30),
            22,
            const Color(0xffffe6ad),
            debug: showLayoutDebug,
          );
        } else {
          canvas.drawRect(
            const Rect.fromLTWH(166, 64, 18, 4),
            Paint()..color = const Color(0xffffd35e),
          );
          canvas.drawRect(
            const Rect.fromLTWH(168, 59, 4, 7),
            Paint()..color = const Color(0xffffd35e),
          );
          canvas.drawRect(
            const Rect.fromLTWH(173, 56, 4, 10),
            Paint()..color = const Color(0xffffd35e),
          );
          canvas.drawRect(
            const Rect.fromLTWH(179, 59, 4, 7),
            Paint()..color = const Color(0xffffd35e),
          );
          _cardText(
            canvas,
            'BEST',
            const Rect.fromLTWH(188, 57, 65, 18),
            12,
            const Color(0xfff6e7c7),
            debug: showLayoutDebug,
          );
          _cardText(
            canvas,
            '$best',
            const Rect.fromLTWH(188, 78, 72, 30),
            22,
            const Color(0xffffe6ad),
            debug: showLayoutDebug,
          );
        }
      },
    );

    final tier = score >= 40
        ? 3
        : score >= 30
        ? 2
        : score >= 20
        ? 1
        : score >= 10
        ? 0
        : -1;
    final medalAlpha = _cardContentAlpha(cardElapsed, .12);
    final rankName = tier < 0
        ? 'RAW'
        : USE_THEMED_MEDAL_LABELS
        ? const ['MEDIUM', 'WELL DONE', 'GOLDEN CRISP', 'MICHELIN STAR'][tier]
        : const ['BRONZE', 'SILVER', 'GOLD', 'PLATINUM'][tier];
    var rankCaption = '';
    if (tier < 0) {
      rankCaption = 'Score 10 to earn your\nfirst medal.';
    } else if (tier == 3) {
      rankCaption = 'MAX RANK! Michelin Star.';
    } else {
      const names = ['MEDIUM', 'WELL DONE', 'GOLDEN CRISP', 'MICHELIN STAR'];
      final next = tier + 1;
      final threshold = (next + 1) * 10;
      final remaining = threshold - score;
      rankCaption = next == 2
          ? 'NEXT: GOLDEN\nCRISP • $threshold pts\n($remaining to go)'
          : 'NEXT: ${names[next]}\n$threshold pts ($remaining to go)';
    }
    if (showRankTooltip) {
      rankCaption = 'RANKS: 10 / 20 / 30 / 40';
    }
    final medalTop = EndScreenLayout.medalRowTop;
    final rankLabelHeight = EndScreenLayout.rankLabelHeight;
    _drawCardBlock(
      canvas,
      Rect.fromLTWH(16, medalTop, 248, EndScreenLayout.medalRowHeight),
      medalAlpha,
      8,
      () {
        _guardComponent(canvas, 'medal', () {
          canvas.save();
          canvas.translate(tier < 0 ? 16 : 20, medalTop + (tier < 0 ? 0 : 4));
          canvas.drawPicture(
            tier < 0 ? FireArt.rawMedal : FireArt.medals[tier],
          );
          canvas.restore();
        });
        final rankRect = _cardText(
          canvas,
          rankName,
          Rect.fromLTWH(84, medalTop, 180, rankLabelHeight + 2),
          16,
          const Color(0xffffe9c8),
          debug: showLayoutDebug,
        );
        _cardText(
          canvas,
          rankCaption,
          Rect.fromLTWH(
            84,
            rankRect.bottom + 2,
            180,
            math.max(
              0,
              medalTop + EndScreenLayout.medalRowHeight - rankRect.bottom - 2,
            ),
          ),
          12,
          const Color(0xfff1ddbf),
          debug: showLayoutDebug,
        );
      },
    );

    final meterAlpha = _cardContentAlpha(cardElapsed, .18);
    _drawCardBlock(
      canvas,
      Rect.fromLTWH(
        16,
        EndScreenLayout.meterTop,
        248,
        EndScreenLayout.meterBlockHeight,
      ),
      meterAlpha,
      8,
      () {
        _drawDoneness(
          canvas,
          shownScore,
          EndScreenLayout.meterTop,
          showLayoutDebug,
        );
      },
    );

    if (showLayoutDebug) {
      canvas.drawRect(
        Rect.fromLTWH(12, 12, 256, designHeight - 24),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xffffffcc),
      );
    }
    canvas.restore();
    if (showLayoutDebug) {
      canvas.drawRect(
        drawRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xffff2d55),
      );
    }
  }

  void _drawEndButton(
    Canvas canvas,
    Rect baseRect,
    Rect drawRect,
    Rect buttonRect,
    double boxOpacity,
    double cardElapsed,
  ) {
    const designWidth = 280.0;
    final designHeight = EndScreenLayout.cardDesignHeight;
    final localButton = Rect.fromLTRB(
      (buttonRect.left - baseRect.left) / baseRect.width * designWidth,
      (buttonRect.top - baseRect.top) / baseRect.height * designHeight,
      (buttonRect.right - baseRect.left) / baseRect.width * designWidth,
      (buttonRect.bottom - baseRect.top) / baseRect.height * designHeight,
    );
    final alpha = _cardContentAlpha(cardElapsed, .24);
    canvas.save();
    canvas.translate(drawRect.left, drawRect.top);
    canvas.scale(drawRect.width / designWidth, drawRect.height / designHeight);
    _drawCardBlock(canvas, localButton, alpha, 8, () {
      _restartButton(canvas, localButton, boxOpacity.clamp(0.0, 1.0));
    });
    canvas.restore();
  }

  void _drawCardBlock(
    Canvas canvas,
    Rect bounds,
    double alpha,
    double slideDistance,
    VoidCallback draw,
  ) {
    final opacity = alpha.clamp(0.0, 1.0).toDouble();
    canvas.saveLayer(
      bounds,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.translate(0, slideDistance * (1 - opacity));
    draw();
    canvas.restore();
  }

  Rect _cardText(
    Canvas canvas,
    String text,
    Rect bounds,
    double fontSize,
    Color color, {
    bool center = false,
    bool debug = false,
  }) {
    TextPainter makePainter(Paint paint) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          height: 1,
          foreground: paint,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: center ? TextAlign.center : TextAlign.left,
    )..layout(maxWidth: bounds.width);

    final outline = makePainter(
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xff090807),
    );
    final fill = makePainter(Paint()..color = color);
    final lineWidth = fill.computeLineMetrics().fold<double>(
      0,
      (widest, line) => math.max(widest, line.width),
    );
    final textX = center
        ? bounds.left + (bounds.width - lineWidth) / 2
        : bounds.left;
    final textY = bounds.top + math.max(0.0, (bounds.height - fill.height) / 2);
    final paintOffset = Offset(bounds.left, textY);
    outline.paint(canvas, paintOffset);
    fill.paint(canvas, paintOffset);
    final measured = Rect.fromLTWH(textX, textY, lineWidth, fill.height);
    if (debug) {
      canvas.drawRect(
        measured,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7
          ..color = const Color(0xff34c759),
      );
    }
    return measured;
  }

  void _drawDoneness(Canvas canvas, int score, double top, bool debug) {
    const x = 20.0, width = 240.0, height = 14.0;
    final y = top + 20;
    final segmentW = width / 5;
    final progress = (score / 10).clamp(0.0, 5.0).toDouble();
    const colors = [
      Color(0xff8b735e),
      Color(0xffb6736f),
      Color(0xffcf7836),
      Color(0xffdbad3c),
      Color(0xffd8d8c5),
    ];
    for (var i = 0; i < 5; i++) {
      final fraction = (progress - i).clamp(0.0, 1.0);
      final rect = Rect.fromLTWH(x + i * segmentW, y, segmentW - 2, height);
      canvas.drawRect(rect, Paint()..color = colors[i].withValues(alpha: .48));
      if (fraction > 0) {
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left + 1,
            y + 1,
            math.max(0, rect.width - 2) * fraction,
            height - 2,
          ),
          Paint()..color = Color.lerp(colors[i], const Color(0xffff9c33), .22)!,
        );
      }
    }
    final pointerX = x + width * progress / 5;
    canvas.drawRect(
      Rect.fromLTWH(pointerX - 1, y + 1, 2, height - 2),
      Paint()..color = const Color(0xfffff2bd),
    );
    _cardText(
      canvas,
      'DONENESS',
      Rect.fromLTWH(20, top, 240, 18),
      12,
      const Color(0xffe4d1b5),
      debug: debug,
    );
    const tickLabels = ['10', '20', '30', '40'];
    for (var i = 0; i < tickLabels.length; i++) {
      final px = x + width * (i + 1) / 5;
      canvas.drawRect(
        Rect.fromLTWH(px - 1, y + height, 2, 6),
        Paint()..color = const Color(0xffe7d0aa),
      );
      _cardText(
        canvas,
        tickLabels[i],
        Rect.fromCenter(
          center: Offset(px, y + height + 15),
          width: 36,
          height: 18,
        ),
        12,
        const Color(0xfff2e5cc),
        center: true,
        debug: debug,
      );
    }
  }

  void _restartButton(Canvas canvas, Rect rect, double opacity) {
    final pressed = buttonPressed ? rect.shift(const Offset(0, 3)) : rect;
    final shadow = pressed.shift(const Offset(0, 4));
    canvas.drawRect(
      shadow,
      Paint()..color = const Color(0xff090807).withValues(alpha: opacity),
    );
    canvas.drawRect(
      pressed,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xffffbd48), Color(0xffe54b1d)],
        ).createShader(pressed),
    );
    canvas.drawRect(
      pressed,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xff100b09).withValues(alpha: opacity),
    );
    canvas.drawRect(
      Rect.fromLTWH(pressed.left + 4, pressed.top + 3, pressed.width - 8, 2),
      Paint()..color = const Color(0xffffe0a0).withValues(alpha: opacity),
    );
    _centerLabel(canvas, 'PLAY AGAIN', pressed.center, 13, opacity);
    final key = RRect.fromRectAndRadius(
      Rect.fromLTWH(pressed.right - 50, pressed.top + 8, 42, 22),
      const Radius.circular(2),
    );
    canvas.drawRRect(
      key,
      Paint()..color = const Color(0xff522318).withValues(alpha: opacity),
    );
    _centerLabel(canvas, 'SPACE', key.center, 12, opacity);
  }

  void _centerLabel(
    Canvas canvas,
    String text,
    Offset center,
    double size,
    double opacity,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w900,
          color: Colors.white.withValues(alpha: opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _label(
      canvas,
      text,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
      size,
      2,
      opacity: opacity,
    );
  }

  void _flash(Canvas canvas) {
    final alpha = math.max(0, 1 - deathElapsed / .08);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, worldWidth, GameConfig.height),
      Paint()..color = const Color(0xffffa43e).withValues(alpha: alpha * .4),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, worldWidth, GameConfig.height),
      Paint()..color = Colors.white.withValues(alpha: alpha * .38),
    );
  }

  void _fullscreenButton(Canvas canvas) {
    final x = worldWidth - 34;
    const y = 12.0, arm = 7.0;
    final paint = Paint()
      ..color = const Color(0xccffffff)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false;
    final path = Path()
      ..moveTo(x, y + arm)
      ..lineTo(x, y)
      ..lineTo(x + arm, y)
      ..moveTo(x + 16 - arm, y)
      ..lineTo(x + 16, y)
      ..lineTo(x + 16, y + arm)
      ..moveTo(x, y + 16 - arm)
      ..lineTo(x, y + 16)
      ..lineTo(x + arm, y + 16)
      ..moveTo(x + 16 - arm, y + 16)
      ..lineTo(x + 16, y + 16)
      ..lineTo(x + 16, y + 16 - arm);
    canvas.drawPath(path, paint);
  }

  void _label(
    Canvas canvas,
    String text,
    Offset position,
    double size,
    double stroke, {
    double opacity = 1,
    Color color = Colors.white,
  }) {
    final outline = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
          height: 1,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..color = const Color(0xff30272b).withValues(alpha: opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    outline.paint(canvas, position);
    final fill = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
          height: 1,
          color: color.withValues(alpha: opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    fill.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant GameRenderer oldDelegate) => true;
}
