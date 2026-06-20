import 'package:flutter/material.dart';

void main() {
  runApp(const KuwaitTowingMarketplaceApp());
}

class KuwaitTowingMarketplaceApp extends StatelessWidget {
  const KuwaitTowingMarketplaceApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kuwait Tow Marketplace',
      theme: ThemeData(
        primaryColor: const Color(0xFF0F172A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          primary: const Color(0xFF0F172A),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: const MasterAppShell(),
    );
  }
}

class MasterAppShell extends StatefulWidget {
  const MasterAppShell({Key? key}) : super(key: key);

  @override
  State<MasterAppShell> createState() => _MasterAppShellState();
}

class _MasterAppShellState extends State<MasterAppShell> {
  int _selectedTabIndex = 0;

  final List<Widget> _appLayoutModules = const [
    ConsumerBookingView(),
    DriverDashboardView(),
    AdminFleetControlView(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _appLayoutModules[_selectedTabIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTabIndex,
        selectedItemColor: Colors.amber[900],
        unselectedItemColor: Colors.blueGrey[400],
        backgroundColor: Colors.white,
        type: BottomNavigationBarType.fixed,
        onTap: (index) => setState(() => _selectedTabIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.pin_drop), label: 'Order Tow'),
          BottomNavigationBarItem(icon: Icon(Icons.local_shipping), label: 'Driver Portal'),
          BottomNavigationBarItem(icon: Icon(Icons.admin_panel_settings), label: 'Admin Hub'),
        ],
      ),
    );
  }
}

/// Core capped pricing matrix for the Kuwait towing marketplace.
/// All currency values are rounded to 3 decimal places (Kuwaiti Fils).
class KuwaitPricingEngine {
  static const double basePriceKWD = 5.000;
  static const double baseDistanceKm = 5.0;
  static const double perKmRateKWD = 1.000;
  static const double maxPriceCapKWD = 15.000;
  static const double marketplaceCommissionRate = 0.15;

  static Map<String, double> computeFareMetrics(double calculatedDistanceKm) {
    double calculatedFare = basePriceKWD;
    if (calculatedDistanceKm > baseDistanceKm) {
      final double incrementalDistance = calculatedDistanceKm - baseDistanceKm;
      calculatedFare += incrementalDistance * perKmRateKWD;
    }
    if (calculatedFare > maxPriceCapKWD) {
      calculatedFare = maxPriceCapKWD;
    }
    calculatedFare = double.parse(calculatedFare.toStringAsFixed(3));

    final double platformRevenueFee =
        double.parse((calculatedFare * marketplaceCommissionRate).toStringAsFixed(3));
    final double driverNetPayout =
        double.parse((calculatedFare - platformRevenueFee).toStringAsFixed(3));

    return {
      "rawDistance": double.parse(calculatedDistanceKm.toStringAsFixed(2)),
      "consumerTotalKWD": calculatedFare,
      "platformCutKWD": platformRevenueFee,
      "driverPayoutKWD": driverNetPayout,
    };
  }
}

class ConsumerBookingView extends StatefulWidget {
  const ConsumerBookingView({Key? key}) : super(key: key);

  @override
  State<ConsumerBookingView> createState() => _ConsumerBookingViewState();
}

class _ConsumerBookingViewState extends State<ConsumerBookingView> {
  double currentSimulatedDistance = 3.5;
  Map<String, double> activePricingBreakdown =
      KuwaitPricingEngine.computeFareMetrics(3.5);
  bool isProcessingKNETSheet = false;

  void _updateSimulatedDistance(double newDistanceValue) {
    setState(() {
      currentSimulatedDistance = newDistanceValue;
      activePricingBreakdown =
          KuwaitPricingEngine.computeFareMetrics(newDistanceValue);
    });
  }

  void _triggerKNETGatewayRedirection() {
    setState(() => isProcessingKNETSheet = true);
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => isProcessingKNETSheet = false);
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.gpp_good, color: Colors.blue, size: 28),
              SizedBox(width: 10),
              Text('KNET Approved'),
            ],
          ),
          content: Text(
            'Payment of ${activePricingBreakdown["consumerTotalKWD"]!.toStringAsFixed(3)} KWD successfully completed. Searching for available flatbeds near your area.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            color: const Color(0xFFE2E8F0),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map, size: 80, color: Colors.blueGrey[400]),
                  const SizedBox(height: 10),
                  const Text('Google Maps Layer Mock',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    width: 300,
                    child: Column(
                      children: [
                        Text(
                          'Simulate Distance: ${currentSimulatedDistance.toStringAsFixed(1)} Km',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        Slider(
                          value: currentSimulatedDistance,
                          min: 1.0,
                          max: 25.0,
                          divisions: 24,
                          activeColor: Colors.amber[800],
                          onChanged: _updateSimulatedDistance,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isProcessingKNETSheet)
            Container(
              color: Colors.white.withOpacity(0.95),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.blue),
                    SizedBox(height: 16),
                    Text('Connecting to secure KNET Payment Node...',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          if (!isProcessingKNETSheet)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 15),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total Trip Distance:'),
                        Text('${activePricingBreakdown["rawDistance"]} Km',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Marketplace Fare Due:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                          '${activePricingBreakdown["consumerTotalKWD"]!.toStringAsFixed(3)} KWD',
                          style: TextStyle(
                              color: Colors.green[700],
                              fontWeight: FontWeight.w900,
                              fontSize: 22),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    ElevatedButton(
                      onPressed: _triggerKNETGatewayRedirection,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        minimumSize: const Size(double.infinity, 54),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Confirm Order via KNET Portal',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DriverDashboardView extends StatelessWidget {
  const DriverDashboardView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final mockJobMetrics = KuwaitPricingEngine.computeFareMetrics(12.0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Lead Board'),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              elevation: 2,
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.amber[100],
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text('Flatbed Fleet Active',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF9A3412))),
                        ),
                        Text(
                          'Payout: ${mockJobMetrics["driverPayoutKWD"]!.toStringAsFixed(3)} KWD',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                              fontSize: 16),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    const Text('Pickup: Fahaheel Highway, Blk 2',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    Text('Dropoff: Shuwaikh Industrial Area',
                        style: TextStyle(color: Colors.blueGrey[600])),
                    const Divider(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {},
                            child: const Text('Decline'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {},
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0F172A),
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Accept Tow Run'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdminFleetControlView extends StatefulWidget {
  const AdminFleetControlView({Key? key}) : super(key: key);

  @override
  State<AdminFleetControlView> createState() => _AdminFleetControlViewState();
}

class _AdminFleetControlViewState extends State<AdminFleetControlView> {
  final _adminFormKey = GlobalKey<FormState>();
  String name = '';
  String phone = '';
  String plate = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Marketplace Fleet Console')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _adminFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Register Subscriber Fleet Node',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              TextFormField(
                decoration: const InputDecoration(
                    labelText: 'Driver Full Name',
                    border: OutlineInputBorder()),
                validator: (val) =>
                    (val == null || val.isEmpty) ? 'Required' : null,
                onSaved: (val) => name = val ?? '',
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                    labelText: 'Kuwait Mobile (+965)',
                    border: OutlineInputBorder()),
                keyboardType: TextInputType.phone,
                validator: (val) =>
                    (val == null || val.isEmpty) ? 'Required' : null,
                onSaved: (val) => phone = val ?? '',
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                    labelText: 'License Plate ID',
                    border: OutlineInputBorder()),
                validator: (val) =>
                    (val == null || val.isEmpty) ? 'Required' : null,
                onSaved: (val) => plate = val ?? '',
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  if (_adminFormKey.currentState!.validate()) {
                    _adminFormKey.currentState!.save();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Asset Registered Successfully')),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 56),
                ),
                child: const Text('Deploy Asset Profile to Live Database'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
