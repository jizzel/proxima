import 'tool_interface.dart';

/// Registry for all Proxima tools.
class ToolRegistry {
  final Map<String, ProximaTool> _tools = {};

  void register(ProximaTool tool) {
    _tools[tool.name] = tool;
  }

  ProximaTool? lookup(String name) => _tools[name];

  List<ProximaTool> all() => _tools.values.toList();

  bool contains(String name) => _tools.containsKey(name);
}
