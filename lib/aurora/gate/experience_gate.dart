import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/experience.dart';
import '../aurora_focus.dart';
import '../aurora_theme.dart';

/// One-time chooser shown on first launch of the 1.1 line: pick the new
/// Aurora experience or keep the classic 1.0 interface. Both live in this
/// build — the choice is persisted and switchable from Settings any time.
class ExperienceGateScreen extends ConsumerWidget {
  const ExperienceGateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.of(context).size;
    final horizontal = size.width > 820;

    final cards = [
      _ExperienceCard(
        autofocus: true,
        badge: 'NEW · 1.1 BETA',
        badgeGradient: true,
        name: 'Aurora',
        blurb: 'The redesigned Lumen — cinematic, fast, built for the couch.',
        bullets: const [
          'Billboard home with live shelves',
          'All-new player: previews, next-up, zapping',
          'Same library, favorites & progress',
        ],
        mock: const _AuroraMock(),
        onPick: () => setUiExperience(ref, kExperienceAurora),
      ),
      _ExperienceCard(
        badge: 'CLASSIC · 1.0',
        name: 'Classic',
        blurb: 'The original interface, exactly as you know it.',
        bullets: const [
          'Familiar sidebar navigation',
          'Every 1.0 feature, unchanged',
          'Switch to Aurora whenever you like',
        ],
        mock: const _ClassicMock(),
        onPick: () => setUiExperience(ref, kExperienceClassic),
      ),
    ];

    return Scaffold(
      backgroundColor: Aurora.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -1.2),
            radius: 1.5,
            colors: [Color(0xFF141B33), Aurora.bg],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShaderMask(
                    shaderCallback: (r) => Aurora.gradient.createShader(r),
                    child: const Text('lumen',
                        style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                            color: Colors.white)),
                  ),
                  const SizedBox(height: 22),
                  const Text('Choose your experience',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8)),
                  const SizedBox(height: 8),
                  const Text(
                    'Both are included in this build. Switch any time in Settings — nothing to reinstall.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Aurora.textDim, fontSize: 14),
                  ),
                  const SizedBox(height: 34),
                  if (horizontal)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 360, child: cards[0]),
                        const SizedBox(width: 22),
                        SizedBox(width: 360, child: cards[1]),
                      ],
                    )
                  else
                    Column(children: [
                      cards[0],
                      const SizedBox(height: 18),
                      cards[1],
                    ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExperienceCard extends StatelessWidget {
  const _ExperienceCard({
    required this.badge,
    required this.name,
    required this.blurb,
    required this.bullets,
    required this.mock,
    required this.onPick,
    this.badgeGradient = false,
    this.autofocus = false,
  });

  final String badge;
  final String name;
  final String blurb;
  final List<String> bullets;
  final Widget mock;
  final VoidCallback onPick;
  final bool badgeGradient;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      autofocus: autofocus,
      radius: 24,
      scale: 1.03,
      onActivate: onPick,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Aurora.glass,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            mock,
            const SizedBox(height: 18),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
              decoration: BoxDecoration(
                gradient: badgeGradient ? Aurora.gradient : null,
                color: badgeGradient ? null : Aurora.glass,
                borderRadius: BorderRadius.circular(6),
                border:
                    badgeGradient ? null : Border.all(color: Aurora.hairline),
              ),
              child: Text(badge,
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: badgeGradient ? Aurora.bg : Aurora.textDim)),
            ),
            const SizedBox(height: 10),
            Text(name,
                style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5)),
            const SizedBox(height: 6),
            Text(blurb,
                style: const TextStyle(
                    color: Aurora.textDim, fontSize: 13, height: 1.45)),
            const SizedBox(height: 12),
            for (final b in bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2.5),
                        child: Icon(Icons.check_rounded,
                            size: 14, color: Aurora.accent),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(b,
                            style: const TextStyle(
                                fontSize: 12.5,
                                color: Aurora.text,
                                height: 1.35)),
                      ),
                    ]),
              ),
            const SizedBox(height: 8),
            AnimatedOpacity(
              duration: Aurora.fast,
              opacity: focused ? 1 : 0.55,
              child: Row(children: [
                Text('Select',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: focused ? Colors.white : Aurora.textDim)),
                const SizedBox(width: 5),
                Icon(Icons.arrow_forward_rounded,
                    size: 15,
                    color: focused ? Colors.white : Aurora.textDim),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stylized miniature of the Aurora home (billboard + shelf).
class _AuroraMock extends StatelessWidget {
  const _AuroraMock();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 8.4,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF0A0D16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Column(children: [
          Expanded(
            flex: 5,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [Color(0xFF2A3A6E), Color(0xFF141B33)],
                ),
              ),
              child: Align(
                alignment: const Alignment(-0.82, 0.55),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          width: 74,
                          height: 8,
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(3))),
                      const SizedBox(height: 5),
                      Row(children: [
                        Container(
                            width: 30,
                            height: 10,
                            decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(5))),
                        const SizedBox(width: 4),
                        Container(
                            width: 30,
                            height: 10,
                            decoration: BoxDecoration(
                                color: const Color(0x33FFFFFF),
                                borderRadius: BorderRadius.circular(5))),
                      ]),
                    ]),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                for (var i = 0; i < 6; i++)
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == 0
                            ? const Color(0x59FFFFFF)
                            : const Color(0x1FFFFFFF),
                        borderRadius: BorderRadius.circular(5),
                        border: i == 0
                            ? Border.all(color: Colors.white, width: 1.5)
                            : null,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Stylized miniature of the classic layout (left rail + rows).
class _ClassicMock extends StatelessWidget {
  const _ClassicMock();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 8.4,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF0A0D16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Row(children: [
          Container(
            width: 34,
            color: const Color(0xFF141722),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(children: [
              for (var i = 0; i < 4; i++)
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: i == 0
                        ? const Color(0xFF7B9BFF)
                        : const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                        width: 90,
                        height: 7,
                        decoration: BoxDecoration(
                            color: const Color(0x40FFFFFF),
                            borderRadius: BorderRadius.circular(3))),
                    const SizedBox(height: 7),
                    Expanded(
                      child: Row(children: [
                        for (var i = 0; i < 5; i++)
                          Expanded(
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                color: const Color(0x1FFFFFFF),
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Row(children: [
                        for (var i = 0; i < 5; i++)
                          Expanded(
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                color: const Color(0x14FFFFFF),
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ]),
            ),
          ),
        ]),
      ),
    );
  }
}
