import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/focusable_item.dart';

/// Lets the user choose which home rows appear and in what order.
class HomeCustomizeScreen extends ConsumerStatefulWidget {
  const HomeCustomizeScreen({super.key});

  @override
  ConsumerState<HomeCustomizeScreen> createState() => _State();
}

class _State extends ConsumerState<HomeCustomizeScreen> {
  // Working list of row ids in display order, with an enabled flag.
  List<String> _order = [];
  Set<String> _enabled = {};
  bool _loaded = false;

  void _ensureLoaded(List<String> config) {
    if (_loaded) return;
    _enabled = config.toSet();
    final rest =
        kAllHomeRows.map((r) => r.id).where((id) => !_enabled.contains(id));
    _order = [...config, ...rest];
    _loaded = true;
  }

  Future<void> _save() async {
    final enabledInOrder = _order.where(_enabled.contains).toList();
    await saveHomeConfig(ref, enabledInOrder);
  }

  String _label(String id) =>
      kAllHomeRows.firstWhere((r) => r.id == id).label;

  // Remote/keyboard has no drag gesture, so Up/Down buttons are the only way
  // to reorder without a pointer.
  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _order.length) return;
    setState(() {
      final id = _order.removeAt(i);
      _order.insert(j, id);
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(homeConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Customize Home')),
      body: config.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (cfg) {
          _ensureLoaded(cfg);
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Drag to reorder · toggle to show/hide',
                      style: TextStyle(color: Color(0xFF9AA0B0), fontSize: 13)),
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _order.length,
                  onReorder: (oldI, newI) {
                    setState(() {
                      if (newI > oldI) newI--;
                      final id = _order.removeAt(oldI);
                      _order.insert(newI, id);
                    });
                    _save();
                  },
                  itemBuilder: (context, i) {
                    final id = _order[i];
                    final on = _enabled.contains(id);
                    return Card(
                      key: ValueKey(id),
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Row(
                          children: [
                            ReorderableDragStartListener(
                              index: i,
                              child: const Padding(
                                padding: EdgeInsets.all(12),
                                child: Icon(Icons.drag_handle, color: Color(0xFF6B7080)),
                              ),
                            ),
                            // Up/down move buttons — the remote/keyboard
                            // equivalent of the drag handle above.
                            FocusableItem(
                              borderRadius: 10,
                              onActivate: () => _move(i, -1),
                              builder: (context, focused) => Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(Icons.keyboard_arrow_up,
                                    size: 20,
                                    color: i == 0
                                        ? const Color(0xFF3A3E4A)
                                        : const Color(0xFF9AA0B0)),
                              ),
                            ),
                            FocusableItem(
                              borderRadius: 10,
                              onActivate: () => _move(i, 1),
                              builder: (context, focused) => Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(Icons.keyboard_arrow_down,
                                    size: 20,
                                    color: i == _order.length - 1
                                        ? const Color(0xFF3A3E4A)
                                        : const Color(0xFF9AA0B0)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_label(id),
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                            FocusableItem(
                              borderRadius: 18,
                              onActivate: () {
                                setState(() {
                                  if (on) {
                                    _enabled.remove(id);
                                  } else {
                                    _enabled.add(id);
                                  }
                                });
                                _save();
                              },
                              builder: (context, focused) => Padding(
                                padding: const EdgeInsets.all(8),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 40,
                                  height: 24,
                                  padding: const EdgeInsets.all(3),
                                  alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                                  decoration: BoxDecoration(
                                    color: on
                                        ? LumenTheme.accent
                                        : const Color(0xFF3A3E4A),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: const BoxDecoration(
                                        color: Colors.white, shape: BoxShape.circle),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
