import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

void main() {
  runApp(const BatteryMonitorApp());
}

class BatteryMonitorApp extends StatelessWidget {
  const BatteryMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Battery Monitor',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const BatteryMonitorScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class BatteryMonitorScreen extends StatefulWidget {
  const BatteryMonitorScreen({super.key});

  @override
  State<BatteryMonitorScreen> createState() => _BatteryMonitorScreenState();
}

class _BatteryMonitorScreenState extends State<BatteryMonitorScreen> {
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isScanning = false;
  bool _isManualMode = false;

  // 5 batteries data
  static const int _numBatteries = 5;
  static const int _numRelays = 10; // 2 relays per battery

  List<double> _batteryVoltages = List.filled(_numBatteries, 0.0);
  List<String> _batteryModes = List.filled(_numBatteries, "STANDBY");
  List<bool> _batteryConnected = List.filled(_numBatteries, false);

  // Manual mode relay states (10 relays)
  // ESP32 MAPPING:
  // Indices 0-4: Charging relays for batteries 0-4
  // Indices 5-9: Discharging relays for batteries 0-4
  List<bool> _relayStates = List.generate(_numRelays, (index) => false);

  String _currentFilter = "ALL";
  String _status = "Disconnected";
  final List<String> _log = [];

  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
  }

  @override
  void dispose() {
    _cleanupResources();
    super.dispose();
  }

  void _cleanupResources() {
    _pollingTimer?.cancel();
    _discoveryStreamSubscription?.cancel();
    _disconnect();
  }

  Future<void> _initializeBluetooth() async {
    await _requestPermissions();
    _addLog("Bluetooth initialized");
  }

  Future<void> _requestPermissions() async {
    try {
      await [
        Permission.bluetooth,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.locationWhenInUse,
      ].request();
      _addLog("Permissions granted");
    } catch (e) {
      _addLog("Permission error: $e");
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      final time = DateTime.now()
          .toLocal()
          .toString()
          .split(' ')[1]
          .split('.')[0];
      _log.insert(0, "[$time] $message");
      if (_log.length > 20) _log.removeLast();
    });
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _status = "Scanning...";
    });

    try {
      _discoveryStreamSubscription = FlutterBluetoothSerial.instance
          .startDiscovery()
          .listen((BluetoothDiscoveryResult result) {
            final deviceName = result.device.name ?? "";
            _addLog("Found: $deviceName");

            if (deviceName.contains("SMART_BATTERY_SYSTEM")) {
              _connectToDevice(result.device);
            }
          });

      Future.delayed(const Duration(seconds: 10), _stopScanning);
    } catch (e) {
      _addLog("Scan error: $e");
      setState(() {
        _isScanning = false;
        _status = "Scan Failed";
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    await _stopScanning();

    setState(() {
      _status = "Connecting...";
    });

    try {
      _connection = await BluetoothConnection.toAddress(device.address);

      if (_connection != null && _connection!.isConnected) {
        setState(() {
          _isConnected = true;
          _isScanning = false;
          _status = "Connected";
        });

        _addLog("✅ Connected to ${device.name}");
        _setupDataListener();
      }
    } catch (e) {
      _addLog("❌ Connection failed: $e");
      setState(() {
        _isScanning = false;
        _status = "Connection Failed";
      });
    }
  }

  void _setupDataListener() {
    if (_connection == null) return;

    _addLog("🔄 Listening for data...");
    _startPolling();

    _connection!.input!.listen(
      (Uint8List data) {
        String receivedData = String.fromCharCodes(data).trim();
        if (receivedData.isNotEmpty) {
          _addLog("📥 Raw: '$receivedData'");
          _processReceivedData(receivedData);
        }
      },
      onDone: () {
        _addLog("Connection closed");
        _disconnect();
      },
      onError: (error) {
        _addLog("❌ Listen error: $error");
        _disconnect();
      },
    );
  }

  void _startPolling() {
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!_isConnected || _connection == null) {
        timer.cancel();
        return;
      }

      if (!_isManualMode) {
        _sendCommand("STATUS");
      }
    });
  }

  Future<void> _sendCommand(String command) async {
    if (_connection == null || !_connection!.isConnected) {
      _addLog("Not connected");
      return;
    }

    try {
      _connection!.output.add(utf8.encode("$command\n"));
      await _connection!.output.allSent;
      _addLog("📤 Sent: $command");
    } catch (e) {
      _addLog("Send error: $e");
    }
  }

  Future<void> _sendModeCommand(String mode) async {
    if (_connection == null || !_connection!.isConnected) return;
    try {
      _connection!.output.add(utf8.encode("MODE:$mode\n"));
      await _connection!.output.allSent;
      _addLog("📤 Sent: MODE:$mode");
    } catch (e) {
      _addLog("Send mode error: $e");
    }
  }

  // Send relay command with CORRECT relay number (1-10)
  Future<void> _sendRelayCommand(int relayNumber, bool state) async {
    if (_connection == null || !_connection!.isConnected) return;

    String command = "RELAY$relayNumber:${state ? 'ON' : 'OFF'}";
    try {
      _connection!.output.add(utf8.encode("$command\n"));
      await _connection!.output.allSent;
      _addLog("📤 Sent: $command");
    } catch (e) {
      _addLog("Send relay error: $e");
    }
  }

  void _processReceivedData(String data) {
    try {
      // Parse battery voltages
      for (int i = 1; i <= _numBatteries; i++) {
        String pattern = "BATT$i:";
        if (data.contains(pattern)) {
          int startIdx = data.indexOf(pattern) + pattern.length;
          int endIdx = data.indexOf("V", startIdx);

          if (endIdx != -1) {
            String voltStr = data.substring(startIdx, endIdx).trim();
            double voltage = double.tryParse(voltStr) ?? 0.0;

            setState(() {
              _batteryVoltages[i - 1] = voltage;
              _batteryConnected[i - 1] = (voltage > 0 && voltage < 20);
            });
            _addLog("BATT$i: $voltStr V");
          }
        }
      }

      // Parse modes
      if (data.contains("MODES:")) {
        int modesIdx = data.indexOf("MODES:") + 6;
        String modesStr = data.substring(modesIdx);

        List<String> modes = modesStr.split(",");
        for (int i = 0; i < modes.length && i < _numBatteries; i++) {
          setState(() {
            _batteryModes[i] = modes[i];
          });
        }
        _addLog("Modes: ${modes.join(', ')}");
      }
    } catch (e) {
      _addLog("Parse error: $e");
    }
  }

  Future<void> _disconnect() async {
    _pollingTimer?.cancel();

    if (_connection != null) {
      try {
        await _connection!.close();
      } catch (e) {
        _addLog("Disconnect error: $e");
      }
    }

    if (mounted) {
      setState(() {
        _isConnected = false;
        _connection = null;
        _status = "Disconnected";
        _batteryVoltages = List.filled(_numBatteries, 0.0);
        _batteryModes = List.filled(_numBatteries, "STANDBY");
        _batteryConnected = List.filled(_numBatteries, false);
        _currentFilter = "ALL";
        _isManualMode = false;
        _relayStates = List.generate(_numRelays, (index) => false);
      });
    }
    _addLog("Disconnected");
  }

  Future<void> _stopScanning() async {
    _discoveryStreamSubscription?.cancel();
    setState(() => _isScanning = false);
  }

  void _toggleManualMode(bool value) {
    setState(() {
      _isManualMode = value;
    });

    if (value) {
      _sendModeCommand("MANUAL");
      _addLog("Manual mode enabled");
    } else {
      _sendModeCommand("AUTO");
      _addLog("Auto mode enabled");
    }
  }

  // Get ESP32 relay indices (0-9)
  // Charging relays: indices 0-4 for batteries 0-4
  // Discharging relays: indices 5-9 for batteries 0-4
  int _getChargingRelayIndex(int batteryIndex) {
    return batteryIndex; // 0,1,2,3,4
  }

  int _getDischargingRelayIndex(int batteryIndex) {
    return batteryIndex + 5; // 5,6,7,8,9
  }

  // Get display relay numbers (1-10) for UI
  int _getDisplayRelayNumber(int relayIndex) {
    return relayIndex + 1;
  }

  // Toggle charging relay for a battery
  void _toggleChargingRelay(int batteryIndex) {
    int relayIndex = _getChargingRelayIndex(batteryIndex);
    int displayNumber = _getDisplayRelayNumber(relayIndex);

    setState(() {
      _relayStates[relayIndex] = !_relayStates[relayIndex];
    });
    _sendRelayCommand(displayNumber, _relayStates[relayIndex]);
    _addLog(
      "Battery ${batteryIndex + 1} Charging: ${_relayStates[relayIndex] ? 'ON' : 'OFF'}",
    );
  }

  // Toggle discharging relay for a battery
  void _toggleDischargingRelay(int batteryIndex) {
    int relayIndex = _getDischargingRelayIndex(batteryIndex);
    int displayNumber = _getDisplayRelayNumber(relayIndex);

    setState(() {
      _relayStates[relayIndex] = !_relayStates[relayIndex];
    });
    _sendRelayCommand(displayNumber, _relayStates[relayIndex]);
    _addLog(
      "Battery ${batteryIndex + 1} Discharging: ${_relayStates[relayIndex] ? 'ON' : 'OFF'}",
    );
  }

  void _allRelaysOn() {
    setState(() {
      for (int i = 0; i < _relayStates.length; i++) {
        _relayStates[i] = true;
      }
    });

    for (int i = 1; i <= 10; i++) {
      _sendRelayCommand(i, true);
    }
    _addLog("All relays turned ON");
  }

  void _allRelaysOff() {
    setState(() {
      for (int i = 0; i < _relayStates.length; i++) {
        _relayStates[i] = false;
      }
    });

    for (int i = 1; i <= 10; i++) {
      _sendRelayCommand(i, false);
    }
    _addLog("All relays turned OFF");
  }

  List<int> _getFilteredBatteries() {
    if (_currentFilter == "ALL") {
      return List.generate(_numBatteries, (index) => index);
    }

    List<int> filteredIndices = [];
    for (int i = 0; i < _numBatteries; i++) {
      if (_batteryModes[i] == _currentFilter) {
        filteredIndices.add(i);
      }
    }
    return filteredIndices;
  }

  @override
  Widget build(BuildContext context) {
    final filteredBatteries = _getFilteredBatteries();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          Row(
            children: [
              Text(
                _isManualMode ? "MANUAL" : "AUTO",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _isManualMode ? Colors.orange : Colors.white,
                ),
              ),
              Switch(
                value: _isManualMode,
                onChanged: _isConnected ? _toggleManualMode : null,
                activeColor: Colors.orange,
              ),
            ],
          ),
          if (_isConnected && !_isManualMode)
            IconButton(
              icon: const Icon(Icons.notifications_active_outlined),
              onPressed: () => _sendCommand("STATUS"),
            ),
          IconButton(
            icon: Icon(
              _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
            ),
            onPressed: _isConnected ? _disconnect : _startScanning,
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/logo1.jpg'),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(
              Colors.black.withOpacity(0.3),
              BlendMode.darken,
            ),
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  _buildStatusCard(),
                  const SizedBox(height: 10),

                  if (_isManualMode && _isConnected)
                    _buildManualDashboard()
                  else
                    _buildAutoDashboard(filteredBatteries),

                  const SizedBox(height: 10),
                  if (_isConnected && !_isManualMode) _buildControlButtons(),
                  SizedBox(height: 160, child: _buildActivityLog()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoDashboard(List<int> filteredBatteries) {
    return Column(
      children: [
        Card(
          elevation: 4,
          color: const Color.fromARGB(255, 145, 201, 246),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Wrap(
                  spacing: 5,
                  children: [
                    _buildFilterButton("ALL", Icons.list, "ALL"),
                    _buildFilterButton(
                      "CHARGING",
                      Icons.electric_bolt,
                      "CHARGING",
                    ),
                    _buildFilterButton(
                      "DISCHARGING",
                      Icons.power,
                      "DISCHARGING",
                    ),
                    _buildFilterButton("STANDBY", Icons.pause, "STANDBY"),
                  ],
                ),
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() => _currentFilter = "ALL");
                      _addLog("Showing all batteries");
                    },
                    child: Text(
                      "SHOW ALL (5 Batteries)",
                      style: TextStyle(
                        color: _currentFilter == "ALL"
                            ? Colors.purple
                            : Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          elevation: 4,
          color: const Color.fromARGB(255, 145, 201, 246),
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Column(
              children: [
                Text(
                  "Showing ${filteredBatteries.length} of $_numBatteries batteries",
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),

                if (filteredBatteries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Center(child: Text("No batteries match filter")),
                  )
                else
                  ...filteredBatteries
                      .map((index) => _buildVoltageCard(index))
                      .toList(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualDashboard() {
    return Card(
      elevation: 4,
      color: const Color.fromARGB(255, 255, 243, 176),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.65,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                const Center(
                  child: Text(
                    "MANUAL CONTROL DASHBOARD",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 20),

                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text(
                          "5 BATTERY VOLTAGES",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (int i = 0; i < _numBatteries; i++) ...[
                          _buildBatteryStatusRow(i),
                          if (i < _numBatteries - 1) const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                Card(
                  color: Colors.orange.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text(
                          "RELAY CONTROL",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        for (int i = 0; i < _numBatteries; i++) ...[
                          _buildBatteryRelayControl(i),
                          if (i < _numBatteries - 1) const Divider(height: 30),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // NEW: Correct relay control with proper mapping
  Widget _buildBatteryRelayControl(int batteryIndex) {
    int chargingRelayIndex = _getChargingRelayIndex(batteryIndex);
    int dischargingRelayIndex = _getDischargingRelayIndex(batteryIndex);

    int chargingDisplayNumber = chargingRelayIndex + 1; // 1,2,3,4,5
    int dischargingDisplayNumber = dischargingRelayIndex + 1; // 6,7,8,9,10

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "BATTERY ${batteryIndex + 1}",
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Colors.orange,
          ),
        ),
        const SizedBox(height: 8),

        // Charging relay (using correct ESP32 index)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 60,
                    child: Text(
                      "RELAY $chargingDisplayNumber",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text("Charging", style: TextStyle(color: Colors.green)),
                ],
              ),
              Row(
                children: [
                  Text(
                    _relayStates[chargingRelayIndex] ? "ON" : "OFF",
                    style: TextStyle(
                      color: _relayStates[chargingRelayIndex]
                          ? Colors.green
                          : Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: _relayStates[chargingRelayIndex],
                    onChanged: (value) => _toggleChargingRelay(batteryIndex),
                    activeColor: Colors.green,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Discharging relay (using correct ESP32 index)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 60,
                    child: Text(
                      "RELAY $dischargingDisplayNumber",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    "Discharging",
                    style: TextStyle(color: Colors.orange),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    _relayStates[dischargingRelayIndex] ? "ON" : "OFF",
                    style: TextStyle(
                      color: _relayStates[dischargingRelayIndex]
                          ? Colors.orange
                          : Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: _relayStates[dischargingRelayIndex],
                    onChanged: (value) => _toggleDischargingRelay(batteryIndex),
                    activeColor: Colors.orange,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBatteryStatusRow(int batteryIndex) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "BATTERY ${batteryIndex + 1}",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                _batteryModes[batteryIndex],
                style: TextStyle(
                  color: _getModeColor(_batteryModes[batteryIndex]),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _batteryConnected[batteryIndex] &&
                        _batteryVoltages[batteryIndex] > 0
                    ? '${_batteryVoltages[batteryIndex].toStringAsFixed(2)} V'
                    : '--- V',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                _batteryConnected[batteryIndex] ? "Connected" : "Disconnected",
                style: TextStyle(
                  color: _batteryConnected[batteryIndex]
                      ? Colors.green
                      : Colors.red,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getModeColor(String mode) {
    switch (mode) {
      case "CHARGING":
        return Colors.green;
      case "DISCHARGING":
        return Colors.orange;
      case "STANDBY":
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  Widget _buildVoltageCard(int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "BATTERY ${index + 1}",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  _batteryModes[index],
                  style: TextStyle(color: _getModeColor(_batteryModes[index])),
                ),
              ],
            ),
            Text(
              _batteryConnected[index] && _batteryVoltages[index] > 0
                  ? '${_batteryVoltages[index].toStringAsFixed(2)} V'
                  : '--- V',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: _batteryConnected[index] ? Colors.blue : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterButton(String text, IconData icon, String filterValue) {
    bool isSelected = _currentFilter == filterValue;
    return ElevatedButton.icon(
      onPressed: () => setState(() => _currentFilter = filterValue),
      icon: Icon(icon, size: 16),
      label: Text(text),
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? Colors.blue : Colors.grey[300],
        foregroundColor: isSelected ? Colors.white : Colors.black,
        minimumSize: const Size(0, 30),
      ),
    );
  }

  Color _getFilterColor(String mode) {
    switch (mode) {
      case "CHARGING":
        return Colors.green;
      case "DISCHARGING":
        return Colors.orange;
      case "STANDBY":
        return Colors.blue;
      case "ALL":
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Row(
          children: [
            Icon(
              _isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _isConnected ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _status,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _isConnected ? Colors.green : Colors.red,
                    ),
                  ),
                  Text(
                    _isManualMode
                        ? "Manual Mode"
                        : _isConnected
                        ? "Smart Battery Switching Auto Mode"
                        : "Tap to connect",
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            if (_isScanning) const CircularProgressIndicator(strokeWidth: 2),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButtons() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Wrap(
          spacing: 95,
          children: [
            ElevatedButton(
              onPressed: () => _sendCommand("STATUS"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 70, 228, 107),
              ),
              child: const Text("Refresh"),
            ),
            ElevatedButton(
              onPressed: _disconnect,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text("Disconnect"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityLog() {
    return Card(
      color: const Color.fromARGB(255, 145, 201, 246),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Activity Log",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(4),
                child: _log.isEmpty
                    ? const Center(child: Text("No activity yet"))
                    : ListView.builder(
                        reverse: true,
                        itemCount: _log.length,
                        itemBuilder: (context, index) => Text(
                          _log[index],
                          style: const TextStyle(
                            fontSize: 8,
                            fontFamily: 'Monospace',
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
