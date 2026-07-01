import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const FzaApp());

// ---------------------------------------------------------------------------
// Brand palette
// ---------------------------------------------------------------------------
const Color kRedTop = Color(0xFF9E1B1E);
const Color kRedBottom = Color(0xFF470B0D);
const Color kSky = Color(0xFF24A7E0); // primary CTA
const Color kSlate = Color(0xFF53697F); // service buttons
const Color kSlateBorder = Color(0xFF8BA0B4);
const LatLng kKuwaitCenter = LatLng(29.3759, 47.9774);

// Arabic-first language toggle, app-wide.
final ValueNotifier<bool> appArabic = ValueNotifier<bool>(true);
bool get isAr => appArabic.value;
String tr(String ar, String en) => appArabic.value ? ar : en;

// ---------------------------------------------------------------------------
// Backend API client (talks to the Fz3a Node server behind /api)
// ---------------------------------------------------------------------------
class Api {
  static String get base =>
      kIsWeb ? '/api' : 'https://tryfz3a.com/api';
  static String? token;
  static Map<String, dynamic>? user;

  static Future<void> loadToken() async {
    final sp = await SharedPreferences.getInstance();
    token = sp.getString('fz3a_token');
  }

  static Future<void> _persist(String? t) async {
    final sp = await SharedPreferences.getInstance();
    if (t == null) {
      await sp.remove('fz3a_token');
    } else {
      await sp.setString('fz3a_token', t);
    }
  }

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  static Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final res = await http.post(Uri.parse('$base$path'),
        headers: _headers, body: jsonEncode(body));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception(data['error'] ?? 'Request failed');
    }
    return data;
  }

  static Future<Map<String, dynamic>> signup({
    required String name,
    required String username,
    required String password,
    String phone = '',
  }) async {
    final d = await _post('/auth/signup', {
      'name': name,
      'username': username,
      'password': password,
      'phone': phone,
      'role': 'rider',
    });
    token = d['token'];
    user = d['user'];
    await _persist(token);
    return d;
  }

  static Future<Map<String, dynamic>> login(
      String username, String password) async {
    final d = await _post(
        '/auth/login', {'username': username, 'password': password});
    token = d['token'];
    user = d['user'];
    await _persist(token);
    return d;
  }

  static Future<bool> restore() async {
    await loadToken();
    if (token == null) return false;
    try {
      final res = await http
          .get(Uri.parse('$base/auth/me'), headers: _headers)
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return false;
      user = (jsonDecode(res.body) as Map<String, dynamic>)['user'];
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> logout() async {
    token = null;
    user = null;
    await _persist(null);
  }

  // Best-effort ride creation; returns ride id or null.
  static Future<int?> createRide({
    required String service,
    required double distanceKm,
    Map<String, dynamic>? pickup,
    Map<String, dynamic>? dropoff,
  }) async {
    try {
      final d = await _post('/rides', {
        'service': service,
        'distanceKm': distanceKm,
        'pickup': pickup,
        'dropoff': dropoff,
      });
      return d['ride']?['id'] as int?;
    } catch (_) {
      return null;
    }
  }

  // Initiate KNET payment. Returns {mode:'knet'|'demo'|'paid', url?}.
  static Future<Map<String, dynamic>> pay(int rideId) async {
    try {
      return await _post('/rides/$rideId/pay', {});
    } catch (_) {
      return {'mode': 'demo'};
    }
  }

  static Future<void> markPaid(int rideId) async {
    try {
      await _post('/rides/$rideId/mark-paid', {});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> getRide(int rideId) async {
    try {
      final res =
          await http.get(Uri.parse('$base/rides/$rideId'), headers: _headers);
      if (res.statusCode != 200) return null;
      return (jsonDecode(res.body) as Map<String, dynamic>)['ride'];
    } catch (_) {
      return null;
    }
  }

  static Future<List<dynamic>> myRides() async {
    try {
      final res =
          await http.get(Uri.parse('$base/rides/mine'), headers: _headers);
      if (res.statusCode != 200) return [];
      return (jsonDecode(res.body) as Map<String, dynamic>)['rides'] ?? [];
    } catch (_) {
      return [];
    }
  }
}

const _redGradient = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [kRedTop, kRedBottom],
  ),
);

class FzaApp extends StatelessWidget {
  const FzaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appArabic,
      builder: (context, ar, _) {
        return MaterialApp(
          title: 'فزعة | Fz3a',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
                seedColor: kRedTop, brightness: Brightness.light),
            scaffoldBackgroundColor: kRedBottom,
          ),
          builder: (context, child) => Directionality(
            textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          home: const FzaShell(),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Pricing engine — capped distance matrix (3-decimal KWD / Fils)
// ---------------------------------------------------------------------------
class KuwaitPricingEngine {
  static const double basePriceKWD = 5.000;
  static const double baseDistanceKm = 5.0;
  static const double perKmRateKWD = 1.000;
  static const double maxPriceCapKWD = 15.000;
  static const double commissionRate = 0.15;

  static Map<String, double> compute(double km) {
    double fare = basePriceKWD;
    if (km > baseDistanceKm) fare += (km - baseDistanceKm) * perKmRateKWD;
    if (fare > maxPriceCapKWD) fare = maxPriceCapKWD;
    fare = double.parse(fare.toStringAsFixed(3));
    final commission =
        double.parse((fare * commissionRate).toStringAsFixed(3));
    final driver = double.parse((fare - commission).toStringAsFixed(3));
    return {
      "distance": double.parse(km.toStringAsFixed(2)),
      "total": fare,
      "commission": commission,
      "driver": driver,
    };
  }
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------
enum ServiceType { winch, flatbed, roadside }

extension ServiceMeta on ServiceType {
  String get ar => switch (this) {
        ServiceType.winch => 'خدمة الونش',
        ServiceType.flatbed => 'خدمة السطحة',
        ServiceType.roadside => 'المساعدة على الطريق',
      };
  String get en => switch (this) {
        ServiceType.winch => 'Tow Truck',
        ServiceType.flatbed => 'Flatbed',
        ServiceType.roadside => 'Road Assistance',
      };
  IconData get icon => switch (this) {
        ServiceType.winch => Icons.local_shipping,
        ServiceType.flatbed => Icons.fire_truck,
        ServiceType.roadside => Icons.car_repair,
      };
  bool get needsDestination => this != ServiceType.roadside;
}

// ---------------------------------------------------------------------------
// Geo models + free OSM services (no API key)
// ---------------------------------------------------------------------------
class PlaceResult {
  final LatLng point;
  final String label;
  const PlaceResult(this.point, this.label);
}

class RouteResult {
  final double distanceKm;
  final List<LatLng> points;
  const RouteResult(this.distanceKm, this.points);
}

class GeoServices {
  static Future<List<PlaceResult>> autocomplete(String q, {LatLng? bias}) async {
    if (q.trim().length < 3) return [];
    final uri = Uri.parse('https://photon.komoot.io/api/').replace(
      queryParameters: {
        'q': q,
        'limit': '6',
        'lang': isAr ? 'default' : 'en',
        'lat': (bias ?? kKuwaitCenter).latitude.toString(),
        'lon': (bias ?? kKuwaitCenter).longitude.toString(),
      },
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final feats = (data['features'] as List?) ?? [];
    return feats.map((f) {
      final c = f['geometry']['coordinates'] as List;
      final p = f['properties'] as Map<String, dynamic>;
      final parts = <String?>[
        p['name'] as String?,
        p['street'] as String?,
        p['city'] as String? ?? p['county'] as String?,
        p['country'] as String?,
      ].where((e) => e != null && e!.isNotEmpty).toList();
      return PlaceResult(
        LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        parts.join(', '),
      );
    }).toList();
  }

  static Future<String> reverse(LatLng pt) async {
    try {
      final uri = Uri.parse('https://photon.komoot.io/reverse').replace(
        queryParameters: {
          'lat': pt.latitude.toString(),
          'lon': pt.longitude.toString(),
          'lang': isAr ? 'default' : 'en',
        },
      );
      final res = await http.get(uri);
      if (res.statusCode != 200) return tr('موقعك الحالي', 'Current location');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final feats = (data['features'] as List?) ?? [];
      if (feats.isEmpty) return tr('موقعك الحالي', 'Current location');
      final p = feats.first['properties'] as Map<String, dynamic>;
      final parts = <String?>[
        p['name'] as String?,
        p['street'] as String?,
        p['city'] as String? ?? p['county'] as String?,
      ].where((e) => e != null && e!.isNotEmpty).toList();
      return parts.isEmpty ? tr('موقعك الحالي', 'Current location') : parts.join(', ');
    } catch (_) {
      return tr('موقعك الحالي', 'Current location');
    }
  }

  static Future<RouteResult> route(LatLng a, LatLng b) async {
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${a.longitude},${a.latitude};${b.longitude},${b.latitude}'
      '?overview=full&geometries=geojson',
    );
    final res = await http.get(uri);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = (data['routes'] as List?) ?? [];
    if (routes.isEmpty) {
      final km = const Distance().as(LengthUnit.Kilometer, a, b);
      return RouteResult(km, [a, b]);
    }
    final r = routes.first as Map<String, dynamic>;
    final km = (r['distance'] as num).toDouble() / 1000.0;
    final coords = (r['geometry']['coordinates'] as List)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    return RouteResult(km, coords);
  }
}

// ---------------------------------------------------------------------------
// Shared chrome: top bar (Contact Support + language toggle)
// ---------------------------------------------------------------------------
class FzaTopBar extends StatelessWidget {
  final VoidCallback? onBack;
  final VoidCallback? onLogout;
  const FzaTopBar({super.key, this.onBack, this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          _pill(
            icon: Icons.headset_mic,
            label: tr('الدعم', 'Contact Support'),
            onTap: () {},
          ),
          if (onBack != null) ...[
            const SizedBox(width: 8),
            _circle(Icons.arrow_back, onBack!),
          ],
          if (onLogout != null) ...[
            const SizedBox(width: 8),
            _circle(Icons.logout, onLogout!),
          ],
          const Spacer(),
          _langToggle(),
        ],
      ),
    );
  }

  Widget _pill({required IconData icon, required String label, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _circle(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.28),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }

  Widget _langToggle() {
    return Material(
      color: Colors.black.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => appArabic.value = !appArabic.value,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _seg('English', !isAr),
            const Text('  |  ',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            _seg('العربية', isAr),
          ]),
        ),
      ),
    );
  }

  Widget _seg(String t, bool active) => Text(
        t,
        style: TextStyle(
          color: active ? Colors.white : Colors.white60,
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
          fontSize: 12,
        ),
      );
}

// Reusable Fz3a logo badge (chrome icon clipped from the provided art).
class FzaLogo extends StatelessWidget {
  final double size;
  const FzaLogo({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset('assets/logo.jpg', fit: BoxFit.cover),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// App shell: splash -> booking flow
// ---------------------------------------------------------------------------
class FzaShell extends StatefulWidget {
  const FzaShell({super.key});

  @override
  State<FzaShell> createState() => _FzaShellState();
}

class _FzaShellState extends State<FzaShell> {
  bool _booted = false;
  bool _authed = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    bool authed = false;
    try {
      authed = await Api.restore()
          .timeout(const Duration(seconds: 4), onTimeout: () => false);
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) {
      setState(() {
        _authed = authed;
        _booted = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) return const SplashScreen();
    if (!_authed) {
      return AuthScreen(onAuthed: () => setState(() => _authed = true));
    }
    return BookingFlow(onLogout: () async {
      await Api.logout();
      if (mounted) setState(() => _authed = false);
    });
  }
}

// ---------------------------------------------------------------------------
// Auth screen — rider login / signup
// ---------------------------------------------------------------------------
class AuthScreen extends StatefulWidget {
  final VoidCallback onAuthed;
  const AuthScreen({super.key, required this.onAuthed});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _signup = false;
  bool _busy = false;
  String? _error;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signup) {
        if (_name.text.trim().length < 2) throw Exception(tr('أدخل اسمك', 'Enter your name'));
        await Api.signup(
          name: _name.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          phone: _phone.text.trim(),
        );
      } else {
        await Api.login(_username.text.trim(), _password.text);
      }
      if (Api.user?['role'] != 'rider') {
        await Api.logout();
        throw Exception(tr('استخدم حساب عميل. للسائقين: /driver',
            'Use a rider account. Drivers: open /driver'));
      }
      widget.onAuthed();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: _redGradient,
        child: SafeArea(
          child: Column(
            children: [
              const FzaTopBar(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      const FzaLogo(size: 96),
                      const SizedBox(height: 12),
                      Text(tr('حياك في فزعة', 'Welcome to Fz3a'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      Text(
                          _signup
                              ? tr('أنشئ حسابك', 'Create your account')
                              : tr('سجّل الدخول للمتابعة', 'Sign in to continue'),
                          style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_signup) ...[
                              _field(_name, tr('الاسم الكامل', 'Full name'), Icons.person),
                              const SizedBox(height: 12),
                              _field(_phone, tr('الهاتف (+965)', 'Phone (+965)'),
                                  Icons.phone,
                                  keyboard: TextInputType.phone),
                              const SizedBox(height: 12),
                            ],
                            _field(_username, tr('اسم المستخدم', 'Username'),
                                Icons.alternate_email),
                            const SizedBox(height: 12),
                            _field(_password, tr('كلمة المرور', 'Password'),
                                Icons.lock,
                                obscure: true),
                            if (_error != null) ...[
                              const SizedBox(height: 10),
                              Text(_error!,
                                  style: const TextStyle(color: Colors.red)),
                            ],
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _busy ? null : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kSky,
                                minimumSize: const Size(double.infinity, 52),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              child: _busy
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                          color: Colors.white, strokeWidth: 2.5))
                                  : Text(
                                      _signup
                                          ? tr('إنشاء الحساب', 'Create account')
                                          : tr('تسجيل الدخول', 'Log in'),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16)),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _signup = !_signup;
                                _error = null;
                              }),
                              child: Text(_signup
                                  ? tr('لديك حساب؟ سجّل الدخول',
                                      'Have an account? Log in')
                                  : tr('مستخدم جديد؟ أنشئ حساب',
                                      'New here? Create an account')),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr('سائق؟ افتح صفحة السائق /driver',
                            'Are you a driver? Open /driver'),
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon,
      {bool obscure = false, TextInputType? keyboard}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: _redGradient,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const FzaLogo(size: 150),
              const SizedBox(height: 28),
              const Text('فزعة',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text('Fz3a',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 16,
                      letterSpacing: 4)),
              const SizedBox(height: 40),
              const SizedBox(
                width: 180,
                child: LinearProgressIndicator(
                  color: kSky,
                  backgroundColor: Colors.white24,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                tr('جاري تحميل الخريطة وتحديد موقعك...',
                    'Loading map & locating you...'),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Booking flow
// ---------------------------------------------------------------------------
enum Stage { service, locating, destination, quote, searching, found, tracking }

class BookingFlow extends StatefulWidget {
  final Future<void> Function()? onLogout;
  const BookingFlow({super.key, this.onLogout});

  @override
  State<BookingFlow> createState() => _BookingFlowState();
}

class _BookingFlowState extends State<BookingFlow> {
  final MapController _map = MapController();

  Stage _stage = Stage.service;
  ServiceType? _service;

  LatLng? _pickup;
  String _pickupLabel = '';
  bool _locationDenied = false;

  PlaceResult? _destination;
  RouteResult? _route;
  bool _loadingRoute = false;

  Map<String, double>? _fare;

  // searching / tracking
  double _searchProgress = 0;
  Timer? _searchTimer;
  Timer? _trackTimer;
  Timer? _pollTimer;
  Timer? _fallbackTimer;
  LatLng? _driverPos;
  double _driverRemainingKm = 0;
  int _etaMin = 0;
  int? _rideId;
  bool _realDriver = false;
  Map<String, dynamic>? _rideData; // set when a real driver accepts

  String get _drvName =>
      _rideData?['driverName'] as String? ?? tr('كابتن محمد', 'Captain Mohamad');
  String get _drvPlate => _rideData?['plate']?.toString() ?? '12345';
  String get _drvVehicle {
    final v = _rideData?['vehicleType'] as String?;
    if (v == 'winch') return tr('ونش', 'Tow Truck');
    if (v == 'flatbed') return tr('سطحة', 'Flatbed');
    if (v == 'roadside') return tr('مساعدة', 'Roadside');
    return tr('تويوتا لاندكروزر', 'Toyota Land Cruiser');
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _trackTimer?.cancel();
    _pollTimer?.cancel();
    _fallbackTimer?.cancel();
    super.dispose();
  }

  // ---- flow ----
  Future<void> _chooseService(ServiceType t) async {
    setState(() {
      _service = t;
      _stage = Stage.locating;
      _locationDenied = false;
      _pickup = null;
      _destination = null;
      _route = null;
      _fare = null;
    });
    await _locate();
  }

  Future<void> _locate() async {
    try {
      LocationPermission p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
        setState(() => _locationDenied = true);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await _applyPickup(LatLng(pos.latitude, pos.longitude));
    } catch (_) {
      setState(() => _locationDenied = true);
    }
  }

  Future<void> _applyPickup(LatLng pt) async {
    final label = await GeoServices.reverse(pt);
    if (!mounted) return;
    setState(() {
      _pickup = pt;
      _pickupLabel = label;
      _locationDenied = false;
      _stage =
          _service!.needsDestination ? Stage.destination : Stage.quote;
      if (!_service!.needsDestination) _fare = KuwaitPricingEngine.compute(0);
    });
    _move(pt, 14);
  }

  // Tap-to-select on the map: set pickup while locating, destination after.
  Future<void> _onMapTap(LatLng p) async {
    if (_stage == Stage.locating) {
      await _applyPickup(p);
    } else if (_stage == Stage.destination) {
      final label = await GeoServices.reverse(p);
      await _chooseDestination(PlaceResult(p, label));
    }
  }

  Future<void> _chooseDestination(PlaceResult place) async {
    setState(() {
      _destination = place;
      _loadingRoute = true;
    });
    try {
      final r = await GeoServices.route(_pickup!, place.point);
      if (!mounted) return;
      setState(() {
        _route = r;
        _fare = KuwaitPricingEngine.compute(r.distanceKm);
        _loadingRoute = false;
        _stage = Stage.quote;
      });
      _fit(r.points);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingRoute = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('تعذّر حساب المسار', 'Could not calculate route'))));
    }
  }

  Future<void> _startSearch() async {
    // 1) Create the ride on the backend.
    final id = await Api.createRide(
      service: _service!.name,
      distanceKm: _fare!["distance"] ?? 0,
      pickup: _pickup == null
          ? null
          : {'lat': _pickup!.latitude, 'lng': _pickup!.longitude, 'label': _pickupLabel},
      dropoff: _destination == null
          ? null
          : {
              'lat': _destination!.point.latitude,
              'lng': _destination!.point.longitude,
              'label': _destination!.label,
            },
    );
    _rideId = id;

    // 2) Payment (KNET via gateway, or demo confirm).
    if (id != null) {
      final pay = await Api.pay(id);
      if (pay['mode'] == 'knet' && pay['url'] != null) {
        final ok = await _confirmDemoKnet(gateway: true);
        if (!ok) return;
        try {
          await launchUrl(Uri.parse(pay['url'] as String),
              mode: LaunchMode.externalApplication);
        } catch (_) {}
      } else if (pay['mode'] != 'paid') {
        final ok = await _confirmDemoKnet();
        if (!ok) return;
        await Api.markPaid(id);
      }
    } else {
      final ok = await _confirmDemoKnet();
      if (!ok) return;
    }
    if (!mounted) return;

    // 3) Search: animate the ring, poll for a real driver, fall back to demo.
    setState(() {
      _stage = Stage.searching;
      _searchProgress = 0;
      _realDriver = false;
      _rideData = null;
      _driverPos = null;
    });
    _searchTimer?.cancel();
    _searchTimer = Timer.periodic(const Duration(milliseconds: 240), (t) {
      if (!mounted) return;
      setState(() {
        _searchProgress += 0.06;
        if (_searchProgress >= 1.0) _searchProgress = 0.05; // loop the ring
      });
    });
    _startPolling();
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || _realDriver) return;
      _pollTimer?.cancel();
      _searchTimer?.cancel();
      setState(() => _stage = Stage.found); // simulated driver demo
    });
  }

  // Poll the backend; when a real driver accepts, switch to live tracking.
  void _startPolling() {
    if (_rideId == null) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      final ride = await Api.getRide(_rideId!);
      if (!mounted || ride == null) return;
      final status = ride['status'] as String?;
      if (['accepted', 'enroute', 'arrived', 'completed'].contains(status)) {
        _realDriver = true;
        _fallbackTimer?.cancel();
        _searchTimer?.cancel();
        _rideData = ride;
        final loc = ride['driverLoc'];
        if (loc != null) {
          _driverPos = LatLng((loc['lat'] as num).toDouble(),
              (loc['lng'] as num).toDouble());
          _driverRemainingKm = _pickup == null
              ? 0
              : const Distance().as(LengthUnit.Kilometer, _driverPos!, _pickup!);
          _etaMin = math.max(1, (_driverRemainingKm * 2.6).round());
        }
        if (status == 'completed') {
          t.cancel();
          setState(() => _stage = Stage.tracking);
          _arrived();
          return;
        }
        setState(() => _stage = Stage.tracking);
        _move(_pickup!, 14);
      }
    });
  }

  // KNET confirmation sheet (demo mode marks paid; gateway mode opens hosted page).
  Future<bool> _confirmDemoKnet({bool gateway = false}) async {
    final res = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(22),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: const Color(0xFF005EB8),
                    borderRadius: BorderRadius.circular(6)),
                child: const Text('KNET',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 10),
              Text(tr('الدفع الآمن', 'Secure payment'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ]),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr('المبلغ المستحق', 'Amount due')),
                Text('${_fare!["total"]!.toStringAsFixed(3)} ${tr('د.ك', 'KWD')}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 20, color: kRedTop)),
              ],
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF005EB8),
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                  gateway
                      ? tr('المتابعة إلى KNET', 'Continue to KNET')
                      : tr('ادفع عبر KNET', 'Pay with KNET'),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('إلغاء', 'Cancel')),
            ),
          ],
        ),
      ),
    );
    return res ?? false;
  }

  void _startTracking() {
    // Driver starts a little away and drives to the pickup.
    final start = LatLng(_pickup!.latitude + 0.020, _pickup!.longitude + 0.022);
    _driverPos = start;
    setState(() => _stage = Stage.tracking);
    _move(_pickup!, 14);
    const steps = 26;
    int i = 0;
    _trackTimer?.cancel();
    _trackTimer = Timer.periodic(const Duration(milliseconds: 900), (t) {
      if (!mounted) return;
      i++;
      final frac = i / steps;
      final pos = LatLng(
        start.latitude + (_pickup!.latitude - start.latitude) * frac,
        start.longitude + (_pickup!.longitude - start.longitude) * frac,
      );
      final rem = const Distance().as(LengthUnit.Kilometer, pos, _pickup!);
      setState(() {
        _driverPos = pos;
        _driverRemainingKm = rem;
        _etaMin = math.max(1, (rem * 2.6).round());
      });
      if (i >= steps) {
        t.cancel();
        _arrived();
      }
    });
  }

  void _arrived() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.check_circle, color: Colors.green),
          const SizedBox(width: 8),
          Text(tr('وصلت الفزعة', 'Fz3a has arrived')),
        ]),
        content: Text(isAr
            ? '$_drvName وصل إلى موقعك. حياك الله!'
            : '$_drvName has reached your location. Welcome!'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _reset();
            },
            child: Text(tr('تم', 'Done')),
          ),
        ],
      ),
    );
  }

  void _reset() {
    _searchTimer?.cancel();
    _trackTimer?.cancel();
    _pollTimer?.cancel();
    _fallbackTimer?.cancel();
    setState(() {
      _stage = Stage.service;
      _service = null;
      _pickup = null;
      _destination = null;
      _route = null;
      _fare = null;
      _driverPos = null;
      _rideId = null;
      _realDriver = false;
      _rideData = null;
    });
  }

  void _move(LatLng p, double z) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _map.move(p, z);
        } catch (_) {}
      });

  void _fit(List<LatLng> pts) {
    if (pts.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _map.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(pts),
            padding: const EdgeInsets.all(70)));
      } catch (_) {}
    });
  }

  // ---- build ----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_stage) {
        Stage.service => _serviceScreen(),
        Stage.searching => _searchingScreen(),
        Stage.found => _foundScreen(),
        _ => _mapScreen(),
      },
    );
  }

  // Service selection (img7)
  Widget _serviceScreen() {
    return Container(
      decoration: _redGradient,
      child: SafeArea(
        child: Column(
          children: [
            FzaTopBar(onLogout: widget.onLogout),
            const SizedBox(height: 8),
            const FzaLogo(size: 110),
            const SizedBox(height: 12),
            if (Api.user?['name'] != null)
              Text('${tr('حياك', 'Welcome')}، ${Api.user!['name']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            Text(tr('تحت أمرك طال عمرك', 'At your service'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 22),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                children: [
                  for (final s in ServiceType.values) _serviceButton(s),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const RideHistoryScreen())),
                    icon: const Icon(Icons.history, color: Colors.white70, size: 20),
                    label: Text(tr('رحلاتي السابقة', 'My rides'),
                        style: const TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14, left: 16, right: 16),
              child: Text(
                tr('بس قولنا وين ومتى.. تلقانه عندك',
                    'Just tell us where & when — we’ll be there'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serviceButton(ServiceType s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: kSlate,
        borderRadius: BorderRadius.circular(16),
        elevation: 3,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _chooseService(s),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kSlateBorder, width: 1.2),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'تبي ${s.ar} ؟' : 'Need ${s.en}?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(isAr ? s.en : s.ar,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(s.icon, color: Colors.white, size: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Searching (img5)
  Widget _searchingScreen() {
    final pct = (_searchProgress.clamp(0, 1) * 100).round();
    return Container(
      decoration: _redGradient,
      child: SafeArea(
        child: Column(
          children: [
            const FzaTopBar(),
            const SizedBox(height: 10),
            Text(tr('جاري البحث عن فزعة', 'Searching for Fz3a'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            SizedBox(
              width: 230,
              height: 230,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 230,
                    height: 230,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      value: null,
                      color: kSky,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                  ClipOval(
                    child: Image.asset('assets/mascot.jpg',
                        width: 170, height: 170, fit: BoxFit.cover),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: 90,
              height: 90,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 90,
                    height: 90,
                    child: CircularProgressIndicator(
                      value: _searchProgress.clamp(0, 1).toDouble(),
                      strokeWidth: 6,
                      color: kSky,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  Text('$pct%',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const Spacer(),
            Text(tr('جاري المطابقة مع أقرب فزعة', 'Matching with the nearest Fz3a'),
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // Driver found (img4)
  Widget _foundScreen() {
    return Container(
      decoration: _redGradient,
      child: SafeArea(
        child: Column(
          children: [
            const FzaTopBar(),
            const SizedBox(height: 12),
            Text(tr('تم العثور على فزعة', 'Fz3a Found'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 24),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 38,
                    backgroundColor: kSky,
                    child: Icon(Icons.person, size: 44, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_drvName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(_rideData?['driverPhone']?.toString() ?? '+965 9XXX XXXX',
                            style: const TextStyle(color: Colors.white70)),
                        const Divider(color: Colors.white24, height: 18),
                        Text('${tr('المركبة', 'Vehicle')}: $_drvVehicle',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        Text('${tr('اللوحة', 'Plate')}: $_drvPlate',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(isAr ? '$_drvName في الطريق إليك' : '$_drvName is on his way',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(20),
              child: _primaryButton(tr('حياك', 'Welcome'), _startTracking),
            ),
          ],
        ),
      ),
    );
  }

  // Map-based stages: locating / destination / quote / tracking
  Widget _mapScreen() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _pickup ?? kKuwaitCenter,
            initialZoom: 12,
            onTap: (_, latlng) => _onMapTap(latlng),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.fz3a.app',
            ),
            if (_route != null)
              PolylineLayer(polylines: [
                Polyline(points: _route!.points, strokeWidth: 5, color: kSky),
              ]),
            MarkerLayer(markers: _markers()),
          ],
        ),
        // top bar over a soft red header
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [kRedTop.withValues(alpha: 0.95), Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: FzaTopBar(onBack: _reset),
          ),
        ),
        Align(alignment: Alignment.bottomCenter, child: _bottomPanel()),
      ],
    );
  }

  List<Marker> _markers() {
    final list = <Marker>[];
    if (_pickup != null) {
      list.add(Marker(
        point: _pickup!,
        width: 44,
        height: 44,
        child: const Icon(Icons.my_location, color: Colors.green, size: 36),
      ));
    }
    if (_destination != null) {
      list.add(Marker(
        point: _destination!.point,
        width: 44,
        height: 44,
        child: const Icon(Icons.location_on, color: Colors.red, size: 40),
      ));
    }
    if (_driverPos != null) {
      list.add(Marker(
        point: _driverPos!,
        width: 54,
        height: 54,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: kSky, width: 2),
          ),
          padding: const EdgeInsets.all(6),
          child: const Icon(Icons.local_shipping, color: kRedTop, size: 28),
        ),
      ));
    }
    return list;
  }

  Widget _bottomPanel() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(18),
      constraints: const BoxConstraints(maxWidth: 640),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 16)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _panel(),
      ),
    );
  }

  List<Widget> _panel() {
    final chip = Row(children: [
      Icon(_service!.icon, size: 18, color: kRedTop),
      const SizedBox(width: 6),
      Text(isAr ? _service!.ar : _service!.en,
          style: const TextStyle(fontWeight: FontWeight.bold)),
    ]);

    switch (_stage) {
      case Stage.locating:
        if (_locationDenied) {
          return [
            chip,
            const SizedBox(height: 12),
            Text(tr('فعّل الموقع أو ابحث عن نقطة الانطلاق:',
                'Enable location or search your pickup:')),
            const SizedBox(height: 10),
            PlaceSearchField(
              hint: tr('نقطة الانطلاق', 'Pickup location'),
              bias: kKuwaitCenter,
              onSelected: (p) => _applyPickup(p.point),
            ),
            _tapHint(tr('أو اضغط على الخريطة لتحديد موقعك',
                'Or tap the map to set your pickup')),
            TextButton.icon(
              onPressed: _locate,
              icon: const Icon(Icons.gps_fixed, size: 18),
              label: Text(tr('جرّب GPS مرة أخرى', 'Try GPS again')),
            ),
          ];
        }
        return [
          chip,
          const SizedBox(height: 14),
          Row(children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 12),
            Text(tr('جاري تحديد موقعك...', 'Detecting your location...')),
          ]),
        ];

      case Stage.destination:
        return [
          chip,
          const SizedBox(height: 12),
          _locRow(Icons.my_location, Colors.green, tr('من', 'From'), _pickupLabel),
          const Divider(height: 20),
          Text(tr('إلى وين؟', 'Where to?'),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          PlaceSearchField(
            hint: tr('ابحث عن الوجهة / الورشة', 'Search destination / workshop'),
            bias: _pickup,
            onSelected: _chooseDestination,
          ),
          _tapHint(tr('أو اضغط على الخريطة لاختيار الوجهة',
              'Or tap the map to choose the destination')),
          if (_loadingRoute) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ];

      case Stage.tracking:
        return [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              chip,
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6)),
                child: Text('● ${tr('مباشر', 'Live')} | $_drvName',
                    style: const TextStyle(
                        color: Colors.green, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(children: [
                Text('$_etaMin',
                    style: const TextStyle(
                        fontSize: 30, fontWeight: FontWeight.w900, color: kRedTop)),
                Text(tr('دقيقة', 'Min'),
                    style: const TextStyle(color: Colors.black54)),
              ]),
              Container(width: 1, height: 46, color: Colors.black12),
              Column(children: [
                Text(_driverRemainingKm.toStringAsFixed(1),
                    style: const TextStyle(
                        fontSize: 30, fontWeight: FontWeight.w900, color: kRedTop)),
                Text('km', style: const TextStyle(color: Colors.black54)),
              ]),
              Container(width: 1, height: 46, color: Colors.black12),
              Column(children: [
                Text(tr('منخفض', 'Low'),
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.green)),
                Text(tr('الازدحام', 'Traffic'),
                    style: const TextStyle(color: Colors.black54)),
              ]),
            ],
          ),
          const Divider(height: 22),
          Row(children: [
            const Icon(Icons.local_shipping, color: kRedTop),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isAr ? '$_drvName في الطريق إليك' : '$_drvName is on his way',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ];

      case Stage.quote:
      default:
        final f = _fare!;
        return [
          Text('( ${tr('الفزعة عندك', 'Your Fz3a is set')} )',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: kRedTop)),
          const SizedBox(height: 12),
          chip,
          const SizedBox(height: 10),
          _locRow(Icons.my_location, Colors.green, tr('من', 'From'), _pickupLabel),
          if (_destination != null) ...[
            const SizedBox(height: 8),
            _locRow(Icons.location_on, Colors.red, tr('إلى', 'To'),
                _destination!.label),
          ],
          const Divider(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_service!.needsDestination
                  ? tr('المسافة', 'Distance')
                  : tr('خدمة في الموقع', 'On-site service')),
              Text(
                  _service!.needsDestination
                      ? '${f["distance"]} km'
                      : tr('سعر ثابت', 'Flat rate'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('المجموع', 'Total'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${f["total"]!.toStringAsFixed(3)} ${tr('د.ك', 'KWD')}',
                  style: TextStyle(
                      color: Colors.green[700],
                      fontWeight: FontWeight.w900,
                      fontSize: 22)),
            ],
          ),
          const SizedBox(height: 14),
          _primaryButton(tr('تأكيد ودفع', 'Confirm & Pay'), _startSearch),
          const SizedBox(height: 6),
          Center(
            child: Text(
              tr('سيتم إرسال الملخص إلى بريدك', 'Summary will be sent to your email'),
              style: const TextStyle(color: Colors.black45, fontSize: 11),
            ),
          ),
        ];
    }
  }

  Widget _tapHint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const Icon(Icons.touch_app, size: 16, color: Colors.black45),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
        ],
      ),
    );
  }

  Widget _locRow(IconData icon, Color color, String tag, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tag,
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.black54,
                      fontWeight: FontWeight.w600)),
              Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: kSky,
        minimumSize: const Size(double.infinity, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
    );
  }
}

// ---------------------------------------------------------------------------
// Rider ride history
// ---------------------------------------------------------------------------
class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = Api.myRides();
  }

  String _svc(String? s) {
    switch (s) {
      case 'winch':
        return tr('ونش', 'Tow Truck');
      case 'flatbed':
        return tr('سطحة', 'Flatbed');
      case 'roadside':
        return tr('مساعدة', 'Roadside');
      default:
        return s ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kRedTop,
        foregroundColor: Colors.white,
        title: Text(tr('رحلاتي السابقة', 'My rides')),
      ),
      body: Container(
        decoration: _redGradient,
        child: FutureBuilder<List<dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(
                  child: CircularProgressIndicator(color: Colors.white));
            }
            final rides = snap.data!;
            if (rides.isEmpty) {
              return Center(
                child: Text(tr('لا توجد رحلات بعد', 'No rides yet'),
                    style: const TextStyle(color: Colors.white70)),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: rides.length,
              itemBuilder: (_, i) {
                final r = rides[i] as Map<String, dynamic>;
                final paid = r['paymentStatus'] == 'paid';
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: kRedTop.withValues(alpha: 0.1),
                      child: const Icon(Icons.local_shipping, color: kRedTop),
                    ),
                    title: Text('${_svc(r['service'] as String?)}  ·  '
                        '${(r['fareKwd'] as num).toStringAsFixed(3)} ${tr('د.ك', 'KWD')}'),
                    subtitle: Text([
                      if (r['pickup']?['label'] != null)
                        '${tr('من', 'From')}: ${r['pickup']['label']}',
                      if (r['dropoff']?['label'] != null)
                        '${tr('إلى', 'To')}: ${r['dropoff']['label']}',
                      '${tr('الحالة', 'Status')}: ${r['status']}'
                          '${paid ? ' · ${tr('مدفوع', 'paid')}' : ''}',
                    ].join('\n')),
                    isThreeLine: true,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Places autocomplete field (Photon, debounced)
// ---------------------------------------------------------------------------
class PlaceSearchField extends StatefulWidget {
  final String hint;
  final LatLng? bias;
  final ValueChanged<PlaceResult> onSelected;
  const PlaceSearchField(
      {super.key, required this.hint, required this.onSelected, this.bias});

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<PlaceResult> _results = [];
  bool _loading = false;

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _loading = true);
      final r = await GeoServices.autocomplete(q, bias: widget.bias);
      if (!mounted) return;
      setState(() {
        _results = r;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _ctrl,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
        ),
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = _results[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.place_outlined, size: 20),
                  title:
                      Text(r.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    _ctrl.text = r.label;
                    setState(() => _results = []);
                    widget.onSelected(r);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
