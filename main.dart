import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const Color ink = Color(0xFF050610);
const Color panel = Color(0xFF101126);
const Color panel2 = Color(0xFF191A35);
const Color mint = Color(0xFF9B4DFF);
const Color mintSoft = Color(0xFFC18BFF);
const Color white = Color(0xFFF6F2FF);
const LatLng baghdad = LatLng(33.3152, 44.3661);

void main() => runApp(const SayyarApp());

class SayyarApp extends StatelessWidget {
  const SayyarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SAYYAR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: ink,
        colorScheme: ColorScheme.fromSeed(
          seedColor: mint,
          brightness: Brightness.dark,
          surface: panel,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const SayyarHome(),
    );
  }
}

class SayyarHome extends StatefulWidget {
  const SayyarHome({super.key});

  @override
  State<SayyarHome> createState() => _SayyarHomeState();
}

class _SayyarHomeState extends State<SayyarHome> {
  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  final FlutterTts _tts = FlutterTts();

  StreamSubscription<Position>? _positionSubscription;

  int _tab = 0;
  bool _loadingLocation = false;
  bool _voiceEnabled = true;
  bool _routeLoading = false;
  bool _routing = false;
  bool _traffic = true;

  LatLng? _currentLocation;
  LatLng? _target;

  List<Map<String, dynamic>> _routeSteps = [];
  List<LatLng> _route = [];
  List<Map<String, dynamic>> _results = [];

  int _stepIndex = 0;

  double _routeDistance = 0;
  double _routeDuration = 0;

  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  final Distance _distanceCalc = const Distance();

  String _status = 'جاهز للانطلاق';
  String _destination = 'بغداد';

  LatLng _center = baghdad;

  final Set<String> _saved = {'البيت', 'العمل'};

  @override
  void initState() {
    super.initState();

    _tts.setLanguage('ar');
    _tts.setSpeechRate(0.47);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestStartupLocation();
    });
  }

  Future<void> _requestStartupLocation() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: panel,
        icon: const Icon(
          Icons.location_on,
          color: mint,
          size: 42,
        ),
        title: const Text('صلاحية الموقع'),
        content: const Text(
          'يحتاج SAYYAR إلى موقعك الحالي لحساب الطريق وإرشادك بدقة.',
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: mint,
              foregroundColor: ink,
            ),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('السماح بالموقع'),
          ),
        ],
      ),
    );

    if (mounted) {
      await _locate();
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _search.dispose();
    _map.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _locate() async {
    if (_loadingLocation) return;

    setState(() {
      _loadingLocation = true;
      _status = 'جارٍ تحديد الموقع...';
    });

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        if (mounted) {
          setState(() => _status = 'فعّل خدمة الموقع في الهاتف');
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _status = 'إذن الموقع غير متاح');
        }
        return;
      }

      final pos = await Geolocator.getCurrentPosition();

      final point = LatLng(pos.latitude, pos.longitude);

      if (!mounted) return;

      setState(() {
        _currentLocation = point;
        _center = point;
        _status = 'تم تحديد موقعك';
      });

      _map.move(point, 15);

      await _positionSubscription?.cancel();

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 8,
        ),
      ).listen((p) {
        final live = LatLng(p.latitude, p.longitude);

        if (!mounted) return;

        setState(() {
          _currentLocation = live;
        });

        _checkNavigationProgress(live);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'تعذر تحديد الموقع حالياً');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingLocation = false);
      }
    }
  }

  Future<void> _findPlace() async {
    final query = _search.text.trim();

    if (query.isEmpty) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _status = 'جارٍ البحث عن $query...';
      _results = [];
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': '$query, Iraq',
          'format': 'jsonv2',
          'limit': '5',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'SAYYAR-Iraq-Navigation/1.0 (Flutter app)',
          'Accept-Language': 'ar',
        },
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        throw Exception('Search failed');
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      final found = data.cast<Map<String, dynamic>>();

      if (found.isEmpty) {
        if (mounted) {
          setState(() => _status = 'ما لقينا نتيجة، جرّب اسم أوضح');
        }
        return;
      }

      if (!mounted) return;

      setState(() {
        _results = found;
        _status = 'اختار الوجهة من النتائج';
      });

      _showResults();
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'فشل البحث؛ تحقق من الإنترنت وحاول مجدداً';
        });
      }
    }
  }

  void _choosePlace(Map<String, dynamic> place) {
    final lat = double.tryParse('${place['lat']}');
    final lon = double.tryParse('${place['lon']}');

    if (lat == null || lon == null) return;

    final point = LatLng(lat, lon);

    setState(() {
      _target = point;

      _destination = (place['display_name'] ?? 'الوجهة')
          .toString()
          .split(',')
          .take(2)
          .join('،');

      _center = point;
      _routing = false;
      _routeSteps = [];
      _route = [];
      _status = 'تم اختيار $_destination';
    });

    _map.move(point, 14);
  }

  void _showResults() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'اختر الوجهة',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              ..._results.map(
                (place) => ListTile(
                  leading: const Icon(
                    Icons.place,
                    color: mint,
                  ),
                  title: Text(
                    (place['display_name'] ?? '').toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _choosePlace(place);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startRoute() async {
    if (_target == null) {
      setState(() => _status = 'ابحث عن وجهة أولاً');
      return;
    }

    if (_currentLocation == null) {
      await _locate();

      if (_currentLocation == null) {
        if (mounted) {
          setState(() {
            _status = 'اسمح بالوصول للموقع حتى نحسب الطريق الحقيقي';
          });
        }
        return;
      }
    }

    final origin = _currentLocation!;
    final destination = _target!;

    if (_distanceCalc.as(
          LengthUnit.Meter,
          origin,
          destination,
        ) <
        30) {
      setState(() => _status = 'الوجهة قريبة جداً من موقعك الحالي');
      return;
    }

    setState(() {
      _routeLoading = true;
      _status = 'جارٍ حساب مسار الطرق...';
    });

    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson&steps=true&alternatives=false',
      );

      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        throw Exception('Routing failed');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>? ?? [];

      if (body['code'] != 'Ok' || routes.isEmpty) {
        throw Exception('No route');
      }

      final data = routes.first as Map<String, dynamic>;

      final coords = data['geometry']['coordinates'] as List<dynamic>;

      final points = coords.map((item) {
        final xy = item as List<dynamic>;

        return LatLng(
          (xy[1] as num).toDouble(),
          (xy[0] as num).toDouble(),
        );
      }).toList();

      final legs = data['legs'] as List<dynamic>;

      final rawSteps =
          (legs.first as Map<String, dynamic>)['steps'] as List<dynamic>;

      final steps = rawSteps.map((raw) {
        final step = raw as Map<String, dynamic>;

        final maneuver = step['maneuver'] as Map<String, dynamic>;
        final loc = maneuver['location'] as List<dynamic>;

        final type = '${maneuver['type'] ?? ''}';
        final modifier = '${maneuver['modifier'] ?? ''}';
        final road = '${step['name'] ?? ''}';

        final roadText = road.isEmpty ? '' : ' إلى $road';

        String instruction;

        if (type == 'arrive') {
          instruction = 'وصلت إلى وجهتك';
        } else if (type == 'depart' ||
            type == 'continue' ||
            type == 'new name') {
          instruction = 'استمر للأمام$roadText';
        } else if (type == 'roundabout' || type == 'rotary') {
          instruction = 'ادخل الدوار$roadText';
        } else if (modifier.contains('left')) {
          instruction = 'انعطف يساراً$roadText';
        } else if (modifier.contains('right')) {
          instruction = 'انعطف يميناً$roadText';
        } else if (modifier.contains('uturn')) {
          instruction = 'استدر للخلف$roadText';
        } else {
          instruction = 'تابع الطريق$roadText';
        }

        return <String, dynamic>{
          'instruction': instruction,
          'distance': (step['distance'] as num?)?.toDouble() ?? 0.0,
          'lat': (loc[1] as num).toDouble(),
          'lon': (loc[0] as num).toDouble(),
        };
      }).toList();

      if (!mounted) return;

      setState(() {
        _route = points;
        _routeSteps = steps;
        _stepIndex = 0;
        _routeDistance = (data['distance'] as num).toDouble();
        _routeDuration = (data['duration'] as num).toDouble();
        _routing = true;
        _status = 'تم حساب الطريق الحقيقي إلى $_destination';
      });

      _map.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.fromLTRB(42, 120, 42, 260),
        ),
      );

      if (_voiceEnabled) {
        await _speakStep(force: true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'تعذر حساب المسار؛ تحقق من الإنترنت وحاول مجدداً';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _routeLoading = false);
      }
    }
  }

  Future<void> _speakStep({
    bool force = false,
    double? metersOverride,
  }) async {
    if (!_voiceEnabled ||
        _routeSteps.isEmpty ||
        _stepIndex >= _routeSteps.length) {
      return;
    }

    if (!force &&
        DateTime.now().difference(_lastSpokenAt).inSeconds < 12) {
      return;
    }

    _lastSpokenAt = DateTime.now();

    final step = _routeSteps[_stepIndex];

    final point = LatLng(
      step['lat'] as double,
      step['lon'] as double,
    );

    final meters = metersOverride ??
        (_currentLocation == null
            ? step['distance'] as double
            : _distanceCalc.as(
                LengthUnit.Meter,
                _currentLocation!,
                point,
              ));

    final distanceText = meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1)} كيلومتر'
        : '${meters.round()} متر';

    await _tts.stop();

    await _tts.speak(
      '$distanceText، ${step['instruction']}',
    );
  }

  void _checkNavigationProgress(LatLng current) {
    if (!_routing ||
        _routeSteps.isEmpty ||
        _stepIndex >= _routeSteps.length) {
      return;
    }

    final step = _routeSteps[_stepIndex];

    final point = LatLng(
      step['lat'] as double,
      step['lon'] as double,
    );

    final meters = _distanceCalc.as(
      LengthUnit.Meter,
      current,
      point,
    );

    if (meters < 35 && _stepIndex < _routeSteps.length - 1) {
      setState(() => _stepIndex++);

      _speakStep(force: true);
    } else if (meters < 350 &&
        DateTime.now().difference(_lastSpokenAt).inSeconds > 25) {
      _speakStep(
        force: true,
        metersOverride: meters,
      );
    }
  }

  String _formatDistance(double meters) {
    return meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1)} كم'
        : '${meters.round()} م';
  }

  String _formatDuration(double seconds) {
    final minutes = (seconds / 60).round();

    return minutes < 60
        ? '$minutes دقيقة'
        : '${minutes ~/ 60} ساعة و${minutes % 60} دقيقة';
  }

  void _showReport() {
    final types = [
      ('حادث', Icons.car_crash, Colors.redAccent),
      ('ازدحام', Icons.traffic, Colors.orange),
      ('أعمال طريق', Icons.construction, Colors.amber),
      ('إغلاق طريق', Icons.block, Colors.deepOrange),
      ('موقع خطر', Icons.warning_amber, Colors.yellow),
      ('أخرى', Icons.more_horiz, mint),
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'إضافة بلاغ',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                children: types.map((t) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(15),
                    onTap: () {
                      Navigator.pop(context);

                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'البلاغات المجتمعية غير مفعلة حالياً: ${t.$1}',
                          ),
                        ),
                      );
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: panel2,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: mint.withValues(alpha: .22),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            t.$2,
                            color: t.$3,
                            size: 28,
                          ),
                          const SizedBox(height: 7),
                          Text(
                            t.$1,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [
            _mapPage(),
            _searchPage(),
            _favoritesPage(),
            _settingsPage(),
            _accountPage(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF041F1D),
        indicatorColor: mint.withValues(alpha: .15),
        selectedIndex: _tab,
        onDestinationSelected: (value) {
          setState(() => _tab = value);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: 'الرئيسية',
          ),
          NavigationDestination(
            icon: Icon(Icons.search),
            label: 'البحث',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_border),
            selectedIcon: Icon(Icons.star),
            label: 'المفضلة',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'الإعدادات',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'حسابي',
          ),
        ],
      ),
    );
  }

  Widget _mapPage() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: baghdad,
            initialZoom: 12,
            onTap: (_, point) {
              setState(() {
                _target = point;
                _destination = 'نقطة على الخريطة';
                _status = 'تم تحديد نقطة؛ اضغط احسب الطريق';
                _route = [];
                _routeSteps = [];
                _routing = false;
              });
            },
          ),
          children: [
            TileLayer(
              urlTemplate: _traffic
                  ? 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.sayyar.app',
            ),
            if (_route.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _route,
                    strokeWidth: 8,
                    color: const Color(0xAA000000),
                  ),
                  Polyline(
                    points: _route,
                    strokeWidth: 5,
                    color: mint,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                Marker(
                  point: _currentLocation ?? _center,
                  width: 46,
                  height: 46,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF087FCA),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: 3,
                      ),
                    ),
                    child: const Icon(
                      Icons.navigation,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
                if (_target != null)
                  Marker(
                    point: _target!,
                    width: 42,
                    height: 42,
                    child: const Icon(
                      Icons.location_pin,
                      color: Colors.redAccent,
                      size: 42,
                    ),
                  ),
              ],
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        Positioned(
          top: 12,
          left: 14,
          right: 14,
          child: Row(
            children: [
              _circleButton(
                Icons.menu,
                _showDrawer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 54,
                  padding: const EdgeInsetsDirectional.only(
                    start: 16,
                    end: 6,
                  ),
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: mint.withValues(alpha: .55),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _findPlace(),
                          decoration: const InputDecoration(
                            hintText: 'ابحث عن مكان أو عنوان',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _findPlace,
                        icon: const Icon(
                          Icons.search,
                          color: mint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _circleButton(
                _voiceEnabled ? Icons.volume_up : Icons.volume_off,
                () {
                  setState(() {
                    _voiceEnabled = !_voiceEnabled;
                  });

                  if (_voiceEnabled && _routing) {
                    _speakStep(force: true);
                  } else {
                    _tts.stop();
                  }
                },
              ),
            ],
          ),
        ),
        Positioned(
          right: 14,
          top: 92,
          child: Column(
            children: [
              _circleButton(
                Icons.layers_outlined,
                () => setState(() => _traffic = !_traffic),
              ),
              const SizedBox(height: 8),
              _circleButton(
                Icons.add,
                () => _map.move(
                  _map.camera.center,
                  _map.camera.zoom + 1,
                ),
              ),
              const SizedBox(height: 8),
              _circleButton(
                Icons.remove,
                () => _map.move(
                  _map.camera.center,
                  _map.camera.zoom - 1,
                ),
              ),
              const SizedBox(height: 8),
              _circleButton(
                _loadingLocation
                    ? Icons.hourglass_top
                    : Icons.my_location,
                _locate,
              ),
            ],
          ),
        ),
        if (_routing &&
            _routeSteps.isNotEmpty &&
            _stepIndex < _routeSteps.length)
          Positioned(
            top: 82,
            left: 14,
            right: 70,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF32136B),
                    Color(0xFF17152F),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: mintSoft.withValues(alpha: .7),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.turn_right,
                    color: Colors.white,
                    size: 30,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_routeSteps[_stepIndex]['instruction']}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'المسافة: ${_formatDistance(_currentLocation == null ? (_routeSteps[_stepIndex]['distance'] as double) : _distanceCalc.as(LengthUnit.Meter, _currentLocation!, LatLng(_routeSteps[_stepIndex]['lat'] as double, _routeSteps[_stepIndex]['lon'] as double)))}',
                          style: const TextStyle(
                            color: mintSoft,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _voiceEnabled = !_voiceEnabled;
                      });

                      if (_voiceEnabled) {
                        _speakStep(force: true);
                      } else {
                        _tts.stop();
                      }
                    },
                    icon: Icon(
                      _voiceEnabled
                          ? Icons.volume_up
                          : Icons.volume_off,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 12,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: ink.withValues(alpha: .96),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: mint.withValues(alpha: .45),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: mint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      _traffic ? 'حركة الطرق' : 'الخريطة',
                      style: const TextStyle(
                        color: mintSoft,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _destination,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _routing
                                ? '${_formatDistance(_routeDistance)} • ${_formatDuration(_routeDuration)}'
                                : 'SAYYAR • ملاحة العراق',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: mint,
                        foregroundColor: ink,
                      ),
                      onPressed: _routeLoading
                          ? null
                          : (_routing
                              ? () {
                                  setState(() {
                                    _routing = false;
                                    _route = [];
                                    _routeSteps = [];
                                  });
                                  _tts.stop();
                                }
                              : _startRoute),
                      child: Text(
                        _routeLoading
                            ? 'جارٍ الحساب'
                            : (_routing ? 'إيقاف' : 'احسب الطريق'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchPage() {
    return _simplePage(
      icon: Icons.travel_explore,
      title: 'البحث عن الأماكن',
      subtitle: 'اكتب اسم مكان داخل العراق للبحث عنه على الخريطة.',
      child: Column(
        children: [
          TextField(
            controller: _search,
            onSubmitted: (_) => _findPlace(),
            decoration: InputDecoration(
              hintText: 'مثلاً: مول بغداد',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: panel,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _findPlace,
              icon: const Icon(Icons.search),
              label: const Text('ابحث عن الوجهة'),
            ),
          ),
          const SizedBox(height: 18),
          _placeTile(
            'مجمع بغداد التجاري',
            'بغداد',
            Icons.location_city,
          ),
          _placeTile(
            'جامع النور',
            'مكان محفوظ تجريبياً',
            Icons.mosque,
          ),
        ],
      ),
    );
  }

  Widget _favoritesPage() {
    return _simplePage(
      icon: Icons.star_outline,
      title: 'المفضلة',
      subtitle: 'أماكنك المهمة للوصول السريع.',
      child: Column(
        children: [
          _placeTile(
            'البيت',
            'اضغط لإزالة أو حفظ المكان',
            Icons.home,
          ),
          _placeTile(
            'العمل',
            'اضغط لإزالة أو حفظ المكان',
            Icons.work,
          ),
          _placeTile(
            'إضافة مكان',
            'ابحث عن مكان ثم احفظه',
            Icons.add_location_alt,
          ),
          const SizedBox(height: 12),
          Text(
            'المحفوظ حالياً: ${_saved.join('، ')}',
            style: const TextStyle(color: mintSoft),
          ),
        ],
      ),
    );
  }

  Widget _settingsPage() {
    return _simplePage(
      icon: Icons.settings_outlined,
      title: 'الإعدادات',
      subtitle: 'خصص تجربة سيّار.',
      child: Column(
        children: [
          SwitchListTile(
            value: _traffic,
            activeThumbColor: mint,
            title: const Text('الخريطة الداكنة'),
            subtitle: const Text(
              'تبديل بين خريطة CARTO الداكنة وOpenStreetMap',
            ),
            onChanged: (v) => setState(() => _traffic = v),
          ),
          ListTile(
            leading: const Icon(
              Icons.volume_up,
              color: mint,
            ),
            title: const Text('اختبار الإرشاد الصوتي'),
            onTap: () {
              _tts.speak(
                'أهلاً بك في سيّار، طريقك بأمان وأسرع وقت',
              );
            },
          ),
          ListTile(
            leading: const Icon(
              Icons.my_location,
              color: mint,
            ),
            title: const Text('تحديد موقعي'),
            onTap: _locate,
          ),
          const Divider(),
          const ListTile(
            leading: Icon(
              Icons.map_outlined,
              color: mint,
            ),
            title: Text('مصدر الخريطة'),
            subtitle: Text('OpenStreetMap'),
          ),
        ],
      ),
    );
  }

  Widget _accountPage() {
    return _simplePage(
      icon: Icons.person_outline,
      title: 'حسابي',
      subtitle: 'سيّار • SAYYAR',
      child: Column(
        children: [
          const CircleAvatar(
            radius: 42,
            backgroundColor: panel2,
            child: Icon(
              Icons.person,
              color: mint,
              size: 44,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'مستخدم سيّار',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'نسخة تجريبية بدون تسجيل دخول',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 22),
          _placeTile(
            'الخصوصية والأمان',
            'إعدادات الخصوصية',
            Icons.shield_outlined,
          ),
          _placeTile(
            'المساعدة والدعم',
            'معلومات عن التطبيق',
            Icons.help_outline,
          ),
          const SizedBox(height: 20),
          const Text(
            'SAYYAR • IRAQ',
            style: TextStyle(
              color: mint,
              letterSpacing: 3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _simplePage({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: panel2,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon,
                  color: mint,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          child,
        ],
      ),
    );
  }

  Widget _placeTile(
    String title,
    String subtitle,
    IconData icon,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: mint.withValues(alpha: .16),
        ),
      ),
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: panel2,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            icon,
            color: mint,
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white60,
          ),
        ),
        trailing: const Icon(
          Icons.chevron_right,
          color: mintSoft,
        ),
        onTap: () {
          if (title == 'إضافة مكان') {
            setState(() => _tab = 1);
          } else if (title == 'البيت' || title == 'العمل') {
            setState(() {
              if (!_saved.add(title)) {
                _saved.remove(title);
              }
            });
          } else {
            setState(() => _tab = 0);
          }
        },
      ),
    );
  }

  Widget _circleButton(
    IconData icon,
    VoidCallback action,
  ) {
    return Material(
      color: panel,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: action,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: mint.withValues(alpha: .35),
            ),
          ),
          child: Icon(
            icon,
            color: white,
            size: 22,
          ),
        ),
      ),
    );
  }

  void _showDrawer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 18),
            const CircleAvatar(
              radius: 32,
              backgroundColor: panel2,
              child: Icon(
                Icons.alt_route,
                color: mint,
                size: 34,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'سيّار  SAYYAR',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'طريقك.. بأمان وأسرع وقت',
              style: TextStyle(color: mintSoft),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(
                Icons.search,
                color: mint,
              ),
              title: const Text('البحث عن الأماكن'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _tab = 1);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.star,
                color: mint,
              ),
              title: const Text('المفضلة'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _tab = 2);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.settings,
                color: mint,
              ),
              title: const Text('الإعدادات'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _tab = 3);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
