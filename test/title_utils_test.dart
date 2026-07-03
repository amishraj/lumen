import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/title_utils.dart';

void main() {
  group('cleanTitle', () {
    test('strips provider numbering', () {
      expect(cleanTitle('02 - The Godfather - 1972').title, 'The Godfather');
      expect(cleanTitle('1234. Some Movie').title, 'Some Movie');
    });

    test('extracts language tag', () {
      final p = cleanTitle('EN - Vivarium [MULTI-SUB]');
      expect(p.title, 'Vivarium');
      expect(p.lang, 'EN');
    });

    test('handles pipe and colon separators', () {
      expect(cleanTitle('EN | Obsession').lang, 'EN');
      expect(cleanTitle('EN | Obsession').title, 'Obsession');
      expect(cleanTitle('ENG: The Devil Wears Prada 1080p').title,
          'The Devil Wears Prada');
    });

    test('strips quality tokens and bracket tags', () {
      expect(cleanTitle('Movie Name 4K HEVC').title, 'Movie Name');
      expect(cleanTitle('Movie [2160p] (HDR)').title, 'Movie');
    });

    test('strips trailing year but keeps mid-title numbers', () {
      expect(cleanTitle('Blade Runner 2049 - 2017').title, 'Blade Runner 2049');
      expect(cleanTitle('EN - GOAT - 2026').title, 'GOAT');
    });

    test('numbering then language combined', () {
      final p = cleanTitle('03 - EN - The Dark Knight - 2008');
      expect(p.title, 'The Dark Knight');
      expect(p.lang, 'EN');
    });

    test('never returns empty — falls back to raw', () {
      expect(cleanTitle('1080p').title, '1080p');
      expect(cleanTitle('  ').title, isNotEmpty);
    });

    test('plain titles pass through untouched', () {
      final p = cleanTitle('Plain Title');
      expect(p.title, 'Plain Title');
      expect(p.lang, isNull);
    });
  });
}
