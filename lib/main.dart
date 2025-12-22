import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:async';
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

  // 3 batteries data
  List<double> _batteryVoltages = [0.0, 0.0, 0.0];
  List<String> _batteryModes = ["STANDBY", "STANDBY", "STANDBY"];
  List<bool> _batteryConnected = [false, false, false];

  // Filter state - Default to showing all batteries
  String _currentFilter = "ALL"; // ALL, CHARGING, DISCHARGING, STANDBY

  String _status = "Disconnected";
  final List<String> _log = [];

  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;
  StreamSubscription<List<BluetoothDevice>>? _pairedDevicesSubscription;
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
    _pairedDevicesSubscription?.cancel();
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
            _addLog("Found: $deviceName (${result.device.address})");

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
        _addLog("Polling stopped");
        return;
      }

      try {
        _sendCommand("STATUS");
      } catch (e) {
        _addLog("Poll error: $e");
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

  void _processReceivedData(String data) {
    try {
      if (data.contains("BATT1:") &&
          data.contains("BATT2:") &&
          data.contains("BATT3:")) {
        List<double> voltages = [];
        List<bool> connected = [false, false, false];

        // Extract each battery voltage
        for (int i = 1; i <= 3; i++) {
          try {
            String pattern = "BATT$i:";
            int startIdx = data.indexOf(pattern);

            if (startIdx != -1) {
              startIdx += pattern.length;
              int endIdx = data.indexOf("V", startIdx);

              if (endIdx != -1) {
                String voltStr = data
                    .substring(startIdx, endIdx)
                    .replaceAll("V", "")
                    .trim();
                double voltage = double.tryParse(voltStr) ?? 0.0;

                if (voltage > 0 && voltage < 20) {
                  voltages.add(voltage);
                  connected[i - 1] = true;
                  _addLog("✅ BATT$i: $voltStr V");
                } else {
                  voltages.add(0.0);
                  connected[i - 1] = false;
                  _addLog("⚠️ BATT$i Invalid: $voltStr");
                }
              }
            } else {
              voltages.add(0.0);
              connected[i - 1] = false;
            }
          } catch (e) {
            voltages.add(0.0);
            connected[i - 1] = false;
            _addLog("❌ Parse BATT$i error: $e");
          }
        }

        if (voltages.length == 3) {
          setState(() {
            _batteryVoltages = voltages;
            _batteryConnected = connected;
          });
          _addLog("✅ All voltages updated!");
        }

        // Extract modes
        if (data.contains("MODES:")) {
          try {
            int modesIdx = data.indexOf("MODES:") + 6;
            String modesStr = data.substring(modesIdx);
            if (modesStr.contains(",CONN:")) {
              modesStr = modesStr.split(",CONN:")[0];
            }
            List<String> modes = modesStr
                .split(",")
                .map((m) => m.trim())
                .where((m) => m.isNotEmpty)
                .toList();

            if (modes.length >= 3) {
              setState(() {
                _batteryModes = [modes[0], modes[1], modes[2]];
              });
              _addLog("✅ Modes: ${modes.sublist(0, 3).join(', ')}");
            }
          } catch (e) {
            _addLog("Mode parse error: $e");
          }
        }

        if (data.contains("CONN:")) {
          try {
            int connIdx = data.indexOf("CONN:") + 5;
            String connStr = data.substring(connIdx).trim();
            List<String> connValues = connStr.split(",");

            if (connValues.length >= 3) {
              List<bool> newConnected = [];
              for (String val in connValues.sublist(0, 3)) {
                newConnected.add(val == "1");
              }
              setState(() {
                _batteryConnected = newConnected;
              });
              _addLog("✅ Connection status updated");
            }
          } catch (e) {
            _addLog("Connection status parse error: $e");
          }
        }
      } else {
        _addLog("⚠️ Incomplete data format");
      }
    } catch (e) {
      _addLog("❌ Process error: $e");
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
        _batteryVoltages = [0.0, 0.0, 0.0];
        _batteryModes = ["STANDBY", "STANDBY", "STANDBY"];
        _batteryConnected = [false, false, false];
        _currentFilter = "ALL";
      });
    }
    _addLog("Disconnected");
  }

  Future<void> _stopScanning() async {
    _discoveryStreamSubscription?.cancel();
    setState(() => _isScanning = false);
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

  // Filter batteries based on selected mode
  List<int> _getFilteredBatteries() {
    if (_currentFilter == "ALL") {
      return [0, 1, 2];
    }

    List<int> filteredIndices = [];
    for (int i = 0; i < 3; i++) {
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
        title: const Text('Battery Monitor'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _sendCommand("STATUS"),
              tooltip: "Refresh",
            ),
          IconButton(
            icon: Icon(
              _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
            ),
            onPressed: _isConnected ? _disconnect : _startScanning,
            tooltip: _isConnected ? "Disconnect" : "Connect",
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

                  // Filter buttons (with shorter labels)
                  Card(
                    elevation: 8,
                    color: const Color.fromARGB(255, 145, 201, 246),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(bottom: 6.0),
                            child: Text(
                              "Battery Modes",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 5.0,
                            runSpacing: 5.0,
                            alignment: WrapAlignment.center,
                            children: [
                              _buildFilterButton(
                                "CHARGE",
                                Icons.electric_bolt,
                                "CHARGING",
                              ),
                              _buildFilterButton(
                                "DISCHARGE",
                                Icons.power,
                                "DISCHARGING",
                              ),
                              _buildFilterButton(
                                "STANDBY",
                                Icons.pause,
                                "STANDBY",
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // Show All button (text only)
                          Center(
                            child: TextButton(
                              onPressed: () {
                                setState(() {
                                  _currentFilter = "ALL";
                                });
                                _addLog("Showing all batteries");
                              },
                              child: Text(
                                "SHOW ALL",
                                style: TextStyle(
                                  color: _currentFilter == "ALL"
                                      ? Colors.purple
                                      : Colors.blue,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Voltage dashboard
                  Card(
                    elevation: 8,
                    color: const Color.fromARGB(255, 145, 201, 246),
                    child: Padding(
                      padding: const EdgeInsets.all(10.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Expanded(
                                child: Text(
                                  "Voltage Dashboard",
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.35,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _getFilterColor(_currentFilter),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  _currentFilter == "ALL"
                                      ? "ALL"
                                      : _currentFilter,
                                  style: const TextStyle(
                                    color: Color.fromARGB(255, 233, 240, 242),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "Showing ${filteredBatteries.length} battery(s)",
                            style: const TextStyle(
                              color: Color.fromARGB(255, 15, 78, 251),
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 10),

                          if (filteredBatteries.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(12.0),
                              child: Center(
                                child: Text(
                                  "No batteries match filter",
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 13,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          else
                            ...filteredBatteries
                                .map((index) => _buildVoltageCard(index))
                                .toList(),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),
                  if (_isConnected) _buildControlButtons(),
                  if (_isConnected) const SizedBox(height: 10),
                  SizedBox(height: 160, child: _buildActivityLog()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoltageCard(int batteryIndex) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(
          16.0,
        ), // Increased padding for better spacing
        child: Column(
          children: [
            // Battery label only
            Text(
              "BATTERY ${batteryIndex + 1}",
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 12),
            // Voltage display only (centered and prominent)
            Center(
              child: Text(
                _batteryConnected[batteryIndex] &&
                        _batteryVoltages[batteryIndex] > 0
                    ? '${_batteryVoltages[batteryIndex].toStringAsFixed(2)} V'
                    : '--- V',
                style: TextStyle(
                  fontSize: 32, // Larger font for voltage
                  fontWeight: FontWeight.bold,
                  color: _batteryConnected[batteryIndex]
                      ? Colors.blue
                      : Colors.grey,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterButton(String displayText, IconData icon, String mode) {
    final isSelected = _currentFilter == mode;
    return SizedBox(
      height: 32,
      child: ElevatedButton.icon(
        onPressed: () {
          setState(() {
            _currentFilter = mode;
          });
          _addLog("Modes changed to: $mode");
        },
        icon: Icon(icon, size: 14),
        label: Text(displayText, style: TextStyle(fontSize: 11)),
        style: ElevatedButton.styleFrom(
          backgroundColor: isSelected
              ? _getFilterColor(mode)
              : Colors.grey[200],
          foregroundColor: isSelected ? Colors.white : Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
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
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Row(
          children: [
            Icon(
              _isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _isConnected ? Colors.green : Colors.red,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _status,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: _isConnected ? Colors.green : Colors.red,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _isConnected ? "Connected" : "Tap to connect",
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_isScanning)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButtons() {
    return Card(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 4.0,
          runSpacing: 4.0,
          children: [
            SizedBox(
              height: 30,
              child: ElevatedButton.icon(
                onPressed: () => _sendCommand("STATUS"),
                icon: const Icon(Icons.refresh, size: 12),
                label: const Text("Refresh", style: TextStyle(fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            SizedBox(
              height: 30,
              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _currentFilter = "ALL";
                  });
                  _addLog("Reset filter to ALL");
                },
                icon: const Icon(Icons.filter_alt_off, size: 12),
                label: const Text(
                  "Clear Filter",
                  style: TextStyle(fontSize: 11),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            SizedBox(
              height: 30,
              child: ElevatedButton.icon(
                onPressed: () => _disconnect(),
                icon: const Icon(Icons.power_settings_new, size: 12),
                label: const Text("Disconnect", style: TextStyle(fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityLog() {
    return Card(
      elevation: 8,
      color: const Color.fromARGB(255, 145, 201, 246),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Activity Log",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: const Color.fromARGB(255, 215, 26, 248)!,
                  ),
                ),
                padding: const EdgeInsets.all(4),
                child: _log.isEmpty
                    ? const Center(
                        child: Text(
                          "No activity yet",
                          style: TextStyle(color: Colors.grey, fontSize: 11),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        itemCount: _log.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            _log[index],
                            style: const TextStyle(
                              fontSize: 8,
                              fontFamily: 'Monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
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
