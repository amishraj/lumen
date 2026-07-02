import 'package:flutter/material.dart';

/// Small IMDb-branded rating chip — the yellow "IMDb" tag + score. Used on
/// cards and heroes instead of a generic star, which read as unprofessional.
class ImdbBadge extends StatelessWidget {
  const ImdbBadge({
    super.key,
    required this.rating,
    this.onLight = false,
    this.compact = true,
  });

  final double rating;
  final bool onLight; // dark score text on a light background
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding:
              EdgeInsets.symmetric(horizontal: compact ? 4 : 5, vertical: 1),
          decoration: BoxDecoration(
            color: const Color(0xFFF5C518), // IMDb yellow
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text('IMDb',
              style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w900,
                  fontSize: compact ? 8.5 : 10,
                  letterSpacing: -0.2)),
        ),
        const SizedBox(width: 4),
        Text(rating.toStringAsFixed(1),
            style: TextStyle(
                color:
                    onLight ? const Color(0xFF15171F) : const Color(0xFFC7CBD6),
                fontSize: compact ? 11 : 12.5,
                fontWeight: FontWeight.w700)),
      ],
    );
  }
}
