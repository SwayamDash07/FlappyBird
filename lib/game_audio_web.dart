import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

class GameAudio {
  web.AudioContext? _context;
  bool muted = false;
  Timer? _ambience;
  Timer? _crackle;
  double _fireProximity = 0;

  void activate() {
    _unlock();
    _ambience ??= Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _tone(82, .22, .006, wave: 'sine', endFrequency: 76);
      if (DateTime.now().millisecond % 3 == 0) {
        _tone(430, .045, .003, wave: 'triangle', endFrequency: 290);
      }
    });
    _crackle ??= Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (_fireProximity > .02) {
        _tone(350 + _fireProximity * 500, .035, .002 + _fireProximity * .009,
            wave: 'sawtooth', endFrequency: 120);
      }
    });
  }

  void setFireProximity(double value) => _fireProximity = value.clamp(0.0, 1.0);

  void playFlap() => _tone(310, .065, .045, wave: 'triangle', endFrequency: 170);
  void playPoint() => _tone(740, .12, .055, endFrequency: 990);

  void _unlock() {
    _context ??= web.AudioContext();
    if (_context!.state == 'suspended') {
      unawaited(_context!.resume().toDart);
    }
  }

  void _tone(
    double frequency,
    double duration,
    double volume, {
    String wave = 'sine',
    double? endFrequency,
  }) {
    if (muted) return;
    try {
      _unlock();
      final context = _context!;
      final now = context.currentTime;
      final oscillator = context.createOscillator()..type = wave;
      final gain = context.createGain();
      oscillator.frequency.setValueAtTime(frequency, now);
      if (endFrequency != null) {
        oscillator.frequency.exponentialRampToValueAtTime(
          endFrequency,
          now + duration,
        );
      }
      gain.gain.setValueAtTime(volume, now);
      gain.gain.exponentialRampToValueAtTime(.001, now + duration);
      oscillator.connect(gain);
      gain.connect(context.destination);
      oscillator.start(now);
      oscillator.stop(now + duration);
    } catch (_) {
      // Audio is optional; browser autoplay and device errors must not break play.
    }
  }

  void playHit() {
    _tone(260, .18, .16, wave: 'sawtooth', endFrequency: 72);
    _tone(920, .08, .06, wave: 'triangle', endFrequency: 210);
  }

  void playWhoosh() =>
      _tone(420, .35, .075, wave: 'sawtooth', endFrequency: 95);

  void playClang() {
    _tone(820, .22, .11, wave: 'square', endFrequency: 280);
    _tone(1240, .14, .04, wave: 'sine', endFrequency: 700);
  }

  void playDing() {
    _tone(880, .42, .10, endFrequency: 1320);
    Timer(
      const Duration(milliseconds: 90),
      () => _tone(1320, .36, .07, endFrequency: 1760),
    );
  }

  void playSizzle() {
    _tone(1850, .055, .018, wave: 'sawtooth', endFrequency: 1050);
    _tone(2420, .035, .009, wave: 'square', endFrequency: 1200);
  }

  void dispose() {
    _ambience?.cancel();
    _crackle?.cancel();
    _context?.close();
    _context = null;
  }
}
