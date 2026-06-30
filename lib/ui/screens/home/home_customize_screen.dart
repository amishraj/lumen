import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';

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
                      child: ListTile(
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle,
                              color: Color(0xFF6B7080)),
                        ),
                        title: Text(_label(id),
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        trailing: Switch(
                          value: on,
                          activeColor: LumenTheme.accent,
                          onChanged: (v) {
                            setState(() {
                              if (v) {
                                _enabled.add(id);
                              } else {
                                _enabled.remove(id);
                              }
                            });
                            _save();
                          },
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
