// ============================================================================
// PalmGrowLoader — отдельный Flutter-виджет (лоадер).
// Неоновая пальма "вырастает" из земли на фоне ночного тропического пейзажа,
// затем мягко покачивается на ветру, после чего цикл повторяется.
// ----------------------------------------------------------------------------
// Требуются ассеты:
//   assets/palm_bg.png   — тёмный фон с неоновыми пальмами и отражением
//   assets/palm.png      — неоновая пальма (PNG с прозрачным фоном)
//
// pubspec.yaml:
//   flutter:
//     uses-material-design: true
//     assets:
//       - assets/palm_bg.png
//       - assets/palm.png
//
// Использование:
//   // как полноэкранный лоадер
//   const PalmGrowLoader()
//
//   // или как часть экрана с кастомным размером
//   const SizedBox(
//     height: 400,
//     child: PalmGrowLoader(showHint: true),
//   )
// ============================================================================

import 'dart:math' as PalmMath;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiOverlayStyle;

class PalmGrowLoader extends StatefulWidget {
  /// Длительность одного полного цикла (рост + покачивание + пауза).
  final Duration cycleDuration;

  /// Размер пальмы относительно меньшей стороны контейнера (0..1).
  /// По умолчанию 0.65 — пальма заметная, но не упирается в края.
  final double palmRelativeSize;

  /// Показывать ли подпись "Loading…" под пальмой.
  final bool showHint;

  /// Текст подписи. По умолчанию "Loading".
  final String hintText;

  const PalmGrowLoader({
    Key? key,
    this.cycleDuration = const Duration(seconds: 5),
    this.palmRelativeSize = 0.65,
    this.showHint = true,
    this.hintText = 'Loading',
  }) : super(key: key);

  @override
  State<PalmGrowLoader> createState() => _PalmGrowLoaderState();
}

class _PalmGrowLoaderState extends State<PalmGrowLoader>
    with TickerProviderStateMixin {
  /// Основной контроллер: рост + покачивание + пауза.
  late final AnimationController PalmCycleController;

  /// Постоянное мерцание неона / бликов на воде.
  late final AnimationController PalmAmbientController;

  static const Color PalmNeonColor = Color(0xFF00F0FF);

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    PalmCycleController = AnimationController(
      vsync: this,
      duration: widget.cycleDuration,
    )..repeat();

    PalmAmbientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    PalmCycleController.dispose();
    PalmAmbientController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double palmW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final double palmH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.of(context).size.height;

        final double minSide = palmW < palmH ? palmW : palmH;
        final double palmSize = minSide * widget.palmRelativeSize;

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 1) Неоновый фон
            Image.asset(
              'assets/palm_bg.png',
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),

            // 2) Мерцающие блики на воде поверх фона
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: PalmAmbientController,
                  builder: (BuildContext context, Widget? _) {
                    return CustomPaint(
                      painter: _PalmWaterShimmerPainter(
                        ambient: PalmAmbientController.value,
                      ),
                    );
                  },
                ),
              ),
            ),

            // 3) Сама пальма — растёт, покачивается, исчезает
            Center(
              child: AnimatedBuilder(
                animation:
                Listenable.merge(<Listenable>[PalmCycleController, PalmAmbientController]),
                builder: (BuildContext context, Widget? _) {
                  return _PalmRenderer(
                    progress: PalmCycleController.value,
                    ambient: PalmAmbientController.value,
                    size: palmSize,
                  );
                },
              ),
            ),

            // 4) Подпись "Loading…"
            if (widget.showHint)
              Positioned(
                bottom: palmH * 0.06,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedBuilder(
                    animation: PalmCycleController,
                    builder: (BuildContext context, Widget? _) {
                      final int dots =
                      ((PalmCycleController.value * 8).floor() % 4);
                      return Text(
                        '${widget.hintText}${'.' * dots}',
                        style: TextStyle(
                          color: PalmNeonColor,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 6,
                          shadows: <Shadow>[
                            Shadow(
                              color: PalmNeonColor.withOpacity(0.9),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Рендерит пальму с учётом фазы анимации:
///   0.00 – 0.55  : пальма растёт снизу вверх (ClipRect + scale)
///   0.55 – 0.85  : полностью выросла, мягко покачивается на ветру
///   0.85 – 1.00  : плавно гаснет → цикл стартует снова
class _PalmRenderer extends StatelessWidget {
  final double progress;
  final double ambient;
  final double size;

  const _PalmRenderer({
    required this.progress,
    required this.ambient,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    // Высота, на которую пальма раскрыта снизу (0..1)
    double heightFactor;
    // Масштаб целой пальмы (стартует с маленького ростка)
    double scale;
    // Прозрачность
    double opacity;
    // Угол покачивания
    double swayAngle;

    if (progress < 0.55) {
      // Фаза роста
      final double t = progress / 0.55;
      final double eased = _easeOutCubic(t);
      heightFactor = eased;
      scale = 0.55 + 0.45 * eased;
      opacity = (0.5 + 0.5 * eased).clamp(0.0, 1.0);
      // Едва заметные подёргивания, пока растёт
      swayAngle = PalmMath.sin(t * PalmMath.pi * 6) * 0.02;
    } else if (progress < 0.85) {
      // Фаза покачивания (полностью выросла)
      final double t = (progress - 0.55) / 0.30;
      heightFactor = 1.0;
      scale = 1.0;
      opacity = 1.0;
      swayAngle = PalmMath.sin(t * PalmMath.pi * 3) * 0.06;
    } else {
      // Фаза затухания
      final double t = (progress - 0.85) / 0.15;
      heightFactor = 1.0;
      scale = 1.0 + t * 0.05;
      opacity = (1.0 - t).clamp(0.0, 1.0);
      swayAngle = PalmMath.sin(t * PalmMath.pi * 2) * 0.04;
    }

    // Пульсация неонового свечения
    final double glowPulse = 0.5 +
        0.5 * PalmMath.sin(ambient * 2 * PalmMath.pi);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Свечение под пальмой (земля)
          Positioned(
            bottom: size * 0.04,
            child: IgnorePointer(
              child: Container(
                width: size * (0.45 + heightFactor * 0.25),
                height: size * 0.06,
                decoration: BoxDecoration(
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.circular(size),
                  gradient: RadialGradient(
                    colors: <Color>[
                      const Color(0xFF00F0FF)
                          .withOpacity((0.35 + 0.25 * glowPulse) * opacity),
                      const Color(0xFF00F0FF).withOpacity(0.08 * opacity),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Аура вокруг пальмы (мягкое сияние)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: size * (0.65 * heightFactor + 0.15),
                  height: size * (0.85 * heightFactor + 0.15),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: <Color>[
                        const Color(0xFF00F0FF)
                            .withOpacity((0.18 + 0.10 * glowPulse) * opacity),
                        const Color(0xFF00F0FF).withOpacity(0.06 * opacity),
                        Colors.transparent,
                      ],
                      stops: const <double>[0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Сама пальма: ClipRect + Align снизу = раскрытие снизу вверх
          Transform.rotate(
            angle: swayAngle,
            alignment: Alignment.bottomCenter,
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: ClipRect(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      heightFactor: heightFactor.clamp(0.0001, 1.0),
                      child: Image.asset(
                        'assets/palm.png',
                        fit: BoxFit.contain,
                        width: size,
                        height: size,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static double _easeOutCubic(double t) =>
      1 - PalmMath.pow(1 - t, 3).toDouble();
}

/// Мерцающие неоновые блики на воде поверх фона
class _PalmWaterShimmerPainter extends CustomPainter {
  final double ambient;

  _PalmWaterShimmerPainter({required this.ambient});

  @override
  void paint(Canvas canvas, Size size) {
    final PalmMath.Random rnd = PalmMath.Random(11);
    final Paint paint = Paint();

    // Нижняя половина — вода
    final double waterTop = size.height * 0.55;
    for (int i = 0; i < 28; i++) {
      final double x = rnd.nextDouble() * size.width;
      final double y = waterTop + rnd.nextDouble() * (size.height - waterTop);
      final double t = 0.5 +
          0.5 * PalmMath.sin(ambient * 2 * PalmMath.pi + i * 0.9);
      paint.color =
          const Color(0xFF00F0FF).withOpacity(0.10 + 0.25 * t);
      canvas.drawCircle(Offset(x, y), 1.0 + 1.8 * t, paint);
    }

    // Горизонтальная полоса неонового отражения по центру воды
    final double centerY = size.height * 0.78;
    final Paint reflection = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          Colors.transparent,
          const Color(0xFF00F0FF)
              .withOpacity(0.12 + 0.10 * PalmMath.sin(ambient * 2 * PalmMath.pi)),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, centerY - 8, size.width, 16));
    canvas.drawRect(
      Rect.fromLTWH(0, centerY - 8, size.width, 16),
      reflection,
    );
  }

  @override
  bool shouldRepaint(covariant _PalmWaterShimmerPainter old) =>
      old.ambient != ambient;
}
