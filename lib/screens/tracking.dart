// =============================================================
// TRACKING SCREEN
// Live GPS
// Movement Path
// Speed
// Direction
// Accuracy
// Offline Maps Support
// Location Search
// Route
// Start Navigation
// Turn Instructions
// Off-route Recalculation
// Voice Navigation
// =============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';

class TrackingScreen extends StatefulWidget {
  final double? lat;
  final double? lng;

  const TrackingScreen({
    super.key,
    this.lat,
    this.lng,
  });

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  // =========================================================
  // THEME
  // =========================================================

  static const Color primaryTeal = Color(0xFF395058);

  // =========================================================
  // LOCATION
  // =========================================================

  LatLng? currentLocation;

  double speed = 0.0;
  double heading = 0.0;
  double accuracy = 0.0;

  List<LatLng> path = [];

  late final MapController mapController;

  String currentAddress = "";

  final store = FMTCStore('zaviraStore');

  bool firstCenterDone = false;

  StreamSubscription<Position>? positionSubscription;

  // =========================================================
  // EDITABLE CURRENT LOCATION
  // =========================================================

  LatLng? customStartLocation;

  String customStartAddress = "";

  bool editingStartLocation = false;

  LatLng? get routeStartLocation {
    return customStartLocation ?? currentLocation;
  }

  String get routeStartAddress {
    if (customStartAddress.isNotEmpty) {
      return customStartAddress;
    }

    return currentAddress;
  }

  // =========================================================
  // SEARCH
  // =========================================================

  final TextEditingController searchController =
  TextEditingController();

  List<Map<String, dynamic>> searchResults = [];

  bool isSearching = false;

  Timer? searchTimer;

  int searchRequestId = 0;

  // =========================================================
  // DESTINATION / ROUTE
  // =========================================================

  LatLng? destinationLocation;

  String destinationName = "";

  List<LatLng> routePoints = [];

  double routeDistance = 0.0;

  double routeDuration = 0.0;

  bool routeLoading = false;

  // =========================================================
  // NAVIGATION
  // =========================================================

  bool navigationStarted = false;

  List<Map<String, dynamic>> navigationSteps = [];

  int currentStepIndex = 0;

  String nextInstruction = "Ready to navigate";

  double nextTurnDistance = 0.0;

  double nextTurnTime = 0.0;

  Timer? rerouteTimer;

  bool isRerouting = false;

  // =========================================================
  // ROUTE PROGRESS
  // =========================================================

  int currentRoutePointIndex = 0;

  int lastRoutePointIndex = 0;

  int offRouteCounter = 0;

  // =========================================================
  // VOICE NAVIGATION
  // =========================================================

  final FlutterTts flutterTts = FlutterTts();

  bool voiceEnabled = true;

  String lastSpokenInstruction = "";

  int lastSpokenStepIndex = -1;

  // =========================================================
  // INIT
  // =========================================================

  @override
  void initState() {
    super.initState();

    mapController = MapController();

    setupStore();

    setupTts();

    if (widget.lat != null && widget.lng != null) {
      currentLocation = LatLng(
        widget.lat!,
        widget.lng!,
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (currentLocation != null) {
          mapController.move(
            currentLocation!,
            19,
          );
        }
      });

      getAddress(
        widget.lat!,
        widget.lng!,
      );
    }

    startTracking();
  }

  // =========================================================
  // TEXT TO SPEECH SETUP
  // =========================================================

  Future<void> setupTts() async {
    try {
      await flutterTts.setLanguage("en-US");
      await flutterTts.setSpeechRate(0.48);
      await flutterTts.setVolume(1.0);
      await flutterTts.setPitch(1.0);

      await flutterTts.awaitSpeakCompletion(false);

      debugPrint("TTS initialized");
    } catch (e) {
      debugPrint("TTS SETUP ERROR: $e");
    }
  }

  // =========================================================
  // SPEAK
  // =========================================================

  Future<void> speak(String text) async {
    if (!voiceEnabled || !navigationStarted) {
      return;
    }

    if (text.trim().isEmpty) {
      return;
    }

    try {
      await flutterTts.stop();
      await flutterTts.speak(text);
    } catch (e) {
      debugPrint("TTS ERROR: $e");
    }
  }

  // =========================================================
  // VOICE NAVIGATION
  // =========================================================

  Future<void> speakNavigationInstruction() async {
    if (!navigationStarted ||
        navigationSteps.isEmpty ||
        nextInstruction.isEmpty) {
      return;
    }

    String spokenText;

    if (nextInstruction == "You have arrived") {
      spokenText = "You have arrived at your destination.";
    } else if (nextInstruction == "Start driving") {
      spokenText = "Start driving.";
    } else {
      String distanceText;

      if (nextTurnDistance >= 1000) {
        distanceText =
        "${(nextTurnDistance / 1000).toStringAsFixed(1)} kilometers";
      } else {
        distanceText =
        "${nextTurnDistance.toStringAsFixed(0)} meters";
      }

      String timeText = "";

      if (nextTurnTime > 0) {
        final int minutes = (nextTurnTime / 60).round();

        if (minutes <= 0) {
          timeText = "in less than 1 minute";
        } else if (minutes == 1) {
          timeText = "in about 1 minute";
        } else {
          timeText = "in about $minutes minutes";
        }
      }

      if (timeText.isNotEmpty) {
        spokenText =
        "In $distanceText, $nextInstruction. "
            "Estimated time $timeText.";
      } else {
        spokenText =
        "In $distanceText, $nextInstruction.";
      }
    }

    final String uniqueKey =
        "$currentStepIndex-$spokenText";

    if (uniqueKey == lastSpokenInstruction) {
      return;
    }

    lastSpokenInstruction = uniqueKey;

    await speak(spokenText);
  }

  // =========================================================
  // SEARCH WHEN USER TYPES
  // =========================================================

  void onSearchChanged(String value) {
    searchTimer?.cancel();

    if (value.trim().isEmpty) {
      setState(() {
        searchResults = [];
        isSearching = false;
      });

      return;
    }

    setState(() {
      isSearching = true;
    });

    searchTimer = Timer(
      const Duration(milliseconds: 600),
          () {
        searchLocation(value);
      },
    );
  }

  // =========================================================
  // SEARCH LOCATION
  // =========================================================

  Future<void> searchLocation(String query) async {
    final String cleanQuery = query.trim();

    if (cleanQuery.isEmpty) {
      if (!mounted) return;

      setState(() {
        searchResults = [];
        isSearching = false;
      });

      return;
    }

    final int currentRequest = ++searchRequestId;

    try {
      final List<String> queries = [];

      queries.add(cleanQuery);

      if (!cleanQuery.toLowerCase().contains("pakistan")) {
        queries.add("$cleanQuery Pakistan");
      }

      if (cleanQuery.toLowerCase().contains("szabist")) {
        queries.add("SZABIST Larkana");
        queries.add("SZABIST Larkana Campus");
        queries.add("SZABIST Larkana Sindh");
      }

      if (cleanQuery.toLowerCase().contains("larkana")) {
        queries.add("$cleanQuery Larkana Sindh Pakistan");
      }

      debugPrint("================================");
      debugPrint("SEARCH QUERY: $cleanQuery");
      debugPrint("SEARCH VARIATIONS: $queries");
      debugPrint("================================");

      final List<Map<String, dynamic>> allResults = [];

      for (final searchQuery in queries) {
        try {
          final Uri url = Uri.https(
            'nominatim.openstreetmap.org',
            '/search',
            {
              'q': searchQuery,
              'format': 'jsonv2',
              'addressdetails': '1',
              'limit': '10',
              'dedupe': '1',
              'accept-language': 'en',
            },
          );

          final response = await http.get(
            url,
            headers: {
              'User-Agent':
              'Zavira-App/1.0 (location tracking application)',
              'Accept': 'application/json',
              'Accept-Language': 'en',
            },
          );

          if (response.statusCode != 200) {
            continue;
          }

          final dynamic decoded = jsonDecode(response.body);

          if (decoded is! List) {
            continue;
          }

          for (final item in decoded) {
            if (item is! Map) continue;

            final double? lat = double.tryParse(
              item['lat']?.toString() ?? '',
            );

            final double? lng = double.tryParse(
              item['lon']?.toString() ?? '',
            );

            if (lat == null || lng == null) {
              continue;
            }

            final String name =
                item['display_name']?.toString() ?? '';

            if (name.isEmpty) continue;

            allResults.add({
              'name': name,
              'lat': lat,
              'lng': lng,
              'type': item['type']?.toString() ?? '',
              'place_type': item['class']?.toString() ?? '',
            });
          }
        } catch (e) {
          debugPrint(
            "SEARCH VARIATION ERROR: $e",
          );
        }
      }

      // =====================================================
      // REMOVE DUPLICATES
      // =====================================================

      final Map<String, Map<String, dynamic>> uniqueResults = {};

      for (final result in allResults) {
        final double lat = result['lat'];
        final double lng = result['lng'];

        final String key =
            '${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}';

        uniqueResults[key] = result;
      }

      List<Map<String, dynamic>> results =
      uniqueResults.values.toList();

      // =====================================================
      // SZABIST LARKANA PRIORITY
      // =====================================================

      if (cleanQuery.toLowerCase().contains('szabist')) {
        results.sort((a, b) {
          final String aName =
          a['name'].toString().toLowerCase();

          final String bName =
          b['name'].toString().toLowerCase();

          final bool aLarkana =
          aName.contains('larkana');

          final bool bLarkana =
          bName.contains('larkana');

          if (aLarkana && !bLarkana) {
            return -1;
          }

          if (!aLarkana && bLarkana) {
            return 1;
          }

          return 0;
        });
      }

      // =====================================================
      // LARKANA FALLBACK
      // =====================================================

      if (cleanQuery.toLowerCase().contains('szabist') &&
          !results.any(
                (result) => result['name']
                .toString()
                .toLowerCase()
                .contains('larkana'),
          )) {
        try {
          final Uri larkanaUrl = Uri.https(
            'nominatim.openstreetmap.org',
            '/search',
            {
              'q': 'SZABIST Larkana Campus Pakistan',
              'format': 'jsonv2',
              'addressdetails': '1',
              'limit': '10',
              'accept-language': 'en',
            },
          );

          final response = await http.get(
            larkanaUrl,
            headers: {
              'User-Agent': 'Zavira-App/1.0',
              'Accept': 'application/json',
            },
          );

          if (response.statusCode == 200) {
            final dynamic data =
            jsonDecode(response.body);

            if (data is List) {
              for (final item in data) {
                if (item is! Map) continue;

                final double? lat = double.tryParse(
                  item['lat']?.toString() ?? '',
                );

                final double? lng = double.tryParse(
                  item['lon']?.toString() ?? '',
                );

                if (lat == null || lng == null) {
                  continue;
                }

                final String name =
                    item['display_name']?.toString() ?? '';

                if (name.isEmpty) continue;

                final bool alreadyExists = results.any(
                      (result) {
                    final double rLat = result['lat'];
                    final double rLng = result['lng'];

                    return (rLat - lat).abs() < 0.0001 &&
                        (rLng - lng).abs() < 0.0001;
                  },
                );

                if (!alreadyExists) {
                  results.insert(
                    0,
                    {
                      'name': name,
                      'lat': lat,
                      'lng': lng,
                      'type':
                      item['type']?.toString() ?? '',
                      'place_type':
                      item['class']?.toString() ?? '',
                    },
                  );
                }
              }
            }
          }
        } catch (e) {
          debugPrint(
            "LARKANA FALLBACK ERROR: $e",
          );
        }
      }

      if (results.length > 10) {
        results = results.take(10).toList();
      }

      if (!mounted ||
          currentRequest != searchRequestId) {
        return;
      }

      setState(() {
        searchResults = results;
        isSearching = false;
      });

      debugPrint(
        "FINAL RESULTS: ${results.length}",
      );
    } catch (e) {
      debugPrint(
        "SEARCH ERROR: $e",
      );

      if (!mounted ||
          currentRequest != searchRequestId) {
        return;
      }

      setState(() {
        searchResults = [];
        isSearching = false;
      });
    }
  }

  // =========================================================
  // SELECT LOCATION
  // =========================================================

  Future<void> selectDestination(
      Map<String, dynamic> result) async {
    final double lat = result['lat'] as double;
    final double lng = result['lng'] as double;

    final LatLng selectedLocation =
    LatLng(lat, lng);

    FocusScope.of(context).unfocus();

    // =====================================================
    // EDIT CURRENT LOCATION
    // =====================================================

    if (editingStartLocation) {
      setState(() {
        customStartLocation =
            selectedLocation;

        customStartAddress =
            result['name'].toString();

        editingStartLocation = false;

        searchResults = [];

        searchController.clear();

        routePoints = [];

        routeDistance = 0.0;

        routeDuration = 0.0;

        navigationSteps = [];

        currentStepIndex = 0;

        currentRoutePointIndex = 0;

        lastRoutePointIndex = 0;

        nextInstruction =
        "Ready to navigate";

        nextTurnDistance = 0.0;

        nextTurnTime = 0.0;

        navigationStarted = false;

        routeLoading = true;
      });

      if (destinationLocation != null) {
        await getRoute(destinationLocation!);
      }

      if (!mounted) return;

      setState(() {
        routeLoading = false;
      });

      return;
    }

    // =====================================================
    // NORMAL DESTINATION
    // =====================================================

    searchController.text =
        result['name'].toString();

    setState(() {
      searchResults = [];

      destinationLocation =
          selectedLocation;

      destinationName =
          result['name'].toString();

      routePoints = [];

      routeDistance = 0.0;

      routeDuration = 0.0;

      navigationSteps = [];

      currentStepIndex = 0;

      currentRoutePointIndex = 0;

      lastRoutePointIndex = 0;

      nextInstruction =
      "Ready to navigate";

      nextTurnDistance = 0.0;

      nextTurnTime = 0.0;

      navigationStarted = false;

      routeLoading = true;

      lastSpokenInstruction = "";

      lastSpokenStepIndex = -1;

      offRouteCounter = 0;
    });

    await getRoute(selectedLocation);

    if (!mounted) return;

    setState(() {
      routeLoading = false;
    });
  }

  // =========================================================
  // FIND ROUTE POINT CLOSEST TO A LOCATION
  // =========================================================

  int findNearestRoutePoint(
      LatLng location) {
    if (routePoints.isEmpty) {
      return 0;
    }

    final Distance distance =
    const Distance();

    int nearestIndex = 0;

    double nearestDistance =
        double.infinity;

    // Search all route points.
    // OSRM normally returns a manageable number of points.
    for (int i = 0;
    i < routePoints.length;
    i++) {
      final double d = distance.as(
        LengthUnit.Meter,
        location,
        routePoints[i],
      );

      if (d < nearestDistance) {
        nearestDistance = d;
        nearestIndex = i;
      }
    }

    return nearestIndex;
  }

  // =========================================================
  // GET ROUTE
  // =========================================================

  Future<void> getRoute(
      LatLng destination) async {
    if (routeStartLocation == null) {
      return;
    }

    try {
      final LatLng start =
      routeStartLocation!;

      final Uri url = Uri.parse(
        'https://router.project-osrm.org/'
            'route/v1/driving/'
            '${start.longitude},${start.latitude};'
            '${destination.longitude},${destination.latitude}'
            '?overview=full&geometries=geojson&steps=true',
      );

      final response = await http.get(url);

      debugPrint(
        "ROUTE STATUS: ${response.statusCode}",
      );

      if (response.statusCode != 200) {
        return;
      }

      final dynamic data =
      jsonDecode(response.body);

      if (data['routes'] == null ||
          data['routes'].isEmpty) {
        return;
      }

      final route =
      data['routes'][0];

      // =====================================================
      // ROUTE GEOMETRY
      // =====================================================

      final List coordinates =
      route['geometry']['coordinates'];

      final List<LatLng> points =
      coordinates.map<LatLng>(
            (point) {
          return LatLng(
            point[1].toDouble(),
            point[0].toDouble(),
          );
        },
      ).toList();

      // =====================================================
      // NAVIGATION STEPS
      // =====================================================

      final List<Map<String, dynamic>> newSteps = [];

      if (route['legs'] != null &&
          route['legs'].isNotEmpty) {
        final List steps =
            route['legs'][0]['steps'] ?? [];

        for (final step in steps) {
          if (step is! Map) continue;

          final dynamic maneuver =
          step['maneuver'];

          if (maneuver == null) continue;

          final dynamic location =
          maneuver['location'];

          if (location is! List ||
              location.length < 2) {
            continue;
          }

          final double stepLng =
              double.tryParse(
                location[0].toString(),
              ) ??
                  0.0;

          final double stepLat =
              double.tryParse(
                location[1].toString(),
              ) ??
                  0.0;

          final String type =
              maneuver['type']?.toString() ?? '';

          final String modifier =
              maneuver['modifier']?.toString() ?? '';

          final double distance =
          (step['distance'] ?? 0).toDouble();

          final double duration =
          (step['duration'] ?? 0).toDouble();

          final LatLng stepLocation =
          LatLng(
            stepLat,
            stepLng,
          );

          // =================================================
          // IMPORTANT:
          // Find exact position of this maneuver on
          // the route geometry.
          // =================================================

          int routeIndex = 0;

          if (points.isNotEmpty) {
            final Distance distanceCalculator =
            const Distance();

            double smallest =
                double.infinity;

            for (int i = 0;
            i < points.length;
            i++) {
              final double d =
              distanceCalculator.as(
                LengthUnit.Meter,
                stepLocation,
                points[i],
              );

              if (d < smallest) {
                smallest = d;
                routeIndex = i;
              }
            }
          }

          newSteps.add({
            'location': stepLocation,
            'type': type,
            'modifier': modifier,
            'distance': distance,
            'duration': duration,

            // New field:
            // Actual position of maneuver on route.
            'routeIndex': routeIndex,
          });
        }
      }

      if (!mounted) return;

      setState(() {
        routePoints = points;

        routeDistance =
            route['distance'].toDouble() / 1000;

        routeDuration =
            route['duration'].toDouble() / 60;

        navigationSteps =
            newSteps;

        currentStepIndex = 0;

        currentRoutePointIndex = 0;

        lastRoutePointIndex =
        points.isEmpty
            ? 0
            : points.length - 1;

        nextTurnDistance = 0.0;

        nextTurnTime = 0.0;

        offRouteCounter = 0;
      });

      // =====================================================
      // INITIAL ROUTE PROGRESS
      // =====================================================

      if (currentLocation != null &&
          routePoints.isNotEmpty) {
        currentRoutePointIndex =
            findNearestRoutePoint(
              currentLocation!,
            );
      }

      // =====================================================
      // FIT MAP
      // =====================================================

      if (routePoints.isNotEmpty &&
          !navigationStarted) {
        final bounds =
        LatLngBounds.fromPoints(
          routePoints,
        );

        mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding:
            const EdgeInsets.all(70),
          ),
        );
      }

      debugPrint(
        "ROUTE POINTS: ${routePoints.length}",
      );

      debugPrint(
        "NAVIGATION STEPS: ${navigationSteps.length}",
      );
    } catch (e) {
      debugPrint(
        "ROUTE ERROR: $e",
      );
    }
  }

  // =========================================================
  // START NAVIGATION
  // =========================================================

  void startNavigation() {
    if (destinationLocation == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            "Please select a destination first.",
          ),
        ),
      );

      return;
    }

    if (navigationSteps.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            "Route instructions are not available yet.",
          ),
        ),
      );

      return;
    }

    // =====================================================
    // RESET NAVIGATION PROGRESS
    // =====================================================

    if (currentLocation != null &&
        routePoints.isNotEmpty) {
      currentRoutePointIndex =
          findNearestRoutePoint(
            currentLocation!,
          );
    }

    // Start from first route step.
    currentStepIndex = 0;

    lastSpokenInstruction = "";

    lastSpokenStepIndex = -1;

    offRouteCounter = 0;

    setState(() {
      navigationStarted = true;
    });

    updateNavigationInstruction();

    if (currentLocation != null) {
      mapController.move(
        currentLocation!,
        18,
      );
    }

    Future.delayed(
      const Duration(milliseconds: 700),
          () {
        if (!mounted ||
            !navigationStarted) {
          return;
        }

        speak(
          "Navigation started. $nextInstruction",
        );
      },
    );
  }

  // =========================================================
  // STOP NAVIGATION
  // =========================================================

  void stopNavigation() {
    flutterTts.stop();

    setState(() {
      navigationStarted = false;

      currentStepIndex = 0;

      nextInstruction =
      "Navigation stopped";

      nextTurnDistance = 0.0;

      nextTurnTime = 0.0;

      lastSpokenInstruction = "";

      lastSpokenStepIndex = -1;

      offRouteCounter = 0;
    });
  }

  // =========================================================
  // UPDATE ROUTE PROGRESS
  // =========================================================

  void updateRouteProgress() {
    if (!navigationStarted ||
        currentLocation == null ||
        routePoints.isEmpty) {
      return;
    }

    final int nearestIndex =
    findNearestRoutePoint(
      currentLocation!,
    );

    // GPS can occasionally jump backwards.
    // Do not allow route progress to move
    // backwards because of GPS noise.
    if (nearestIndex >= currentRoutePointIndex) {
      currentRoutePointIndex =
          nearestIndex;
    }

    debugPrint(
      "ROUTE PROGRESS: "
          "$currentRoutePointIndex / $lastRoutePointIndex",
    );
  }

  // =========================================================
  // UPDATE TURN INSTRUCTION
  // =========================================================

  void updateNavigationInstruction() {
    if (!navigationStarted ||
        currentLocation == null ||
        navigationSteps.isEmpty ||
        routePoints.isEmpty) {
      return;
    }

    final Distance distance =
    const Distance();

    // =====================================================
    // UPDATE ROUTE PROGRESS FIRST
    // =====================================================

    updateRouteProgress();

    // =====================================================
    // MOVE THROUGH STEPS SEQUENTIALLY
    //
    // We NEVER select a random closest step.
    // We only move forward from the current step.
    // =====================================================

    while (currentStepIndex <
        navigationSteps.length - 1) {
      final Map<String, dynamic> currentStep =
      navigationSteps[currentStepIndex];

      final int stepRouteIndex =
      (currentStep['routeIndex'] ?? 0) as int;

      final LatLng stepLocation =
      currentStep['location'];

      final double distanceToStep =
      distance.as(
        LengthUnit.Meter,
        currentLocation!,
        stepLocation,
      );

      // ===================================================
      // CONDITION 1:
      // User is very close to the maneuver.
      // ===================================================

      final bool reachedManeuver =
          distanceToStep <= 28;

      // ===================================================
      // CONDITION 2:
      // GPS route progress has passed the maneuver.
      //
      // Small tolerance prevents premature switching.
      // ===================================================

      final bool passedManeuver =
          currentRoutePointIndex >=
              stepRouteIndex;

      if (reachedManeuver ||
          passedManeuver) {
        currentStepIndex++;

        debugPrint(
          "STEP ADVANCED -> "
              "$currentStepIndex",
        );

        continue;
      }

      break;
    }

    // =====================================================
    // CURRENT STEP
    // =====================================================

    final Map<String, dynamic> step =
    navigationSteps[currentStepIndex];

    final String modifier =
        step['modifier']?.toString() ?? '';

    final String type =
        step['type']?.toString() ?? '';

    final double stepDuration =
    (step['duration'] ?? 0).toDouble();

    final LatLng stepLocation =
    step['location'];

    final double distanceToManeuver =
    distance.as(
      LengthUnit.Meter,
      currentLocation!,
      stepLocation,
    );

    // =====================================================
    // ARRIVAL
    // =====================================================

    if (type == 'arrive') {
      final double destinationDistance =
      destinationLocation == null
          ? distanceToManeuver
          : distance.as(
        LengthUnit.Meter,
        currentLocation!,
        destinationLocation!,
      );

      if (destinationDistance <= 40) {
        nextInstruction =
        "You have arrived";

        nextTurnDistance = 0.0;

        nextTurnTime = 0.0;

        if (mounted) {
          setState(() {});
        }

        speakNavigationInstruction();

        return;
      }
    }

    // =====================================================
    // BUILD INSTRUCTION
    // =====================================================

    nextInstruction = buildInstruction(
      type,
      modifier,
    );

    nextTurnDistance =
        distanceToManeuver;

    nextTurnTime =
        stepDuration;

    // =====================================================
    // FIRST STEP
    // =====================================================

    if (currentStepIndex == 0 &&
        type == 'depart') {
      nextInstruction =
      "Start driving";
    }

    // =====================================================
    // UPDATE UI
    // =====================================================

    if (mounted) {
      setState(() {});
    }

    // =====================================================
    // VOICE
    // =====================================================

    speakNavigationInstruction();
  }

  // =========================================================
  // BUILD TURN TEXT
  // =========================================================

  String buildInstruction(
      String type,
      String modifier) {
    if (type == 'arrive') {
      return "You have arrived";
    }

    if (type == 'depart') {
      return "Start driving";
    }

    // IMPORTANT:
    // Check modifier before generic type.

    switch (modifier) {
      case 'left':
        return "Turn left";

      case 'right':
        return "Turn right";

      case 'slight left':
        return "Keep slightly left";

      case 'slight right':
        return "Keep slightly right";

      case 'sharp left':
        return "Turn sharp left";

      case 'sharp right':
        return "Turn sharp right";

      case 'straight':
        return "Continue straight";
    }

    // =====================================================
    // ROUNDABOUT
    // =====================================================

    if (type == 'roundabout' ||
        type == 'rotary') {
      return "Enter roundabout";
    }

    if (type == 'new name') {
      return "Continue on route";
    }

    if (type == 'notification') {
      return "Continue on route";
    }

    return "Continue on route";
  }

  // =========================================================
  // FORMAT TURN TIME
  // =========================================================

  String formatTurnTime(double seconds) {
    if (seconds <= 0) {
      return "";
    }

    final int minutes =
    (seconds / 60).round();

    if (minutes <= 0) {
      return "< 1 min";
    }

    if (minutes == 1) {
      return "1 min";
    }

    return "$minutes min";
  }

  // =========================================================
  // OFF-ROUTE CHECK
  // =========================================================

  void checkOffRoute() {
    if (!navigationStarted ||
        currentLocation == null ||
        routePoints.isEmpty ||
        destinationLocation == null) {
      return;
    }

    // =====================================================
    // Ignore bad GPS accuracy.
    // =====================================================

    if (accuracy > 25) {
      return;
    }

    final Distance distance =
    const Distance();

    double minimumDistance =
        double.infinity;

    // =====================================================
    // Check nearby route points instead of blindly
    // checking every point.
    // =====================================================

    final int start =
    max(
      0,
      currentRoutePointIndex - 30,
    );

    final int end =
    min(
      routePoints.length - 1,
      currentRoutePointIndex + 50,
    );

    for (int i = start;
    i <= end;
    i++) {
      final double d =
      distance.as(
        LengthUnit.Meter,
        currentLocation!,
        routePoints[i],
      );

      if (d < minimumDistance) {
        minimumDistance = d;
      }
    }

    debugPrint(
      "DISTANCE FROM ROUTE: "
          "${minimumDistance.toStringAsFixed(1)}m",
    );

    // =====================================================
    // Require multiple consecutive bad readings.
    //
    // This prevents GPS noise from causing unnecessary
    // rerouting.
    // =====================================================

    if (minimumDistance > 60) {
      offRouteCounter++;

      debugPrint(
        "OFF ROUTE COUNTER: $offRouteCounter",
      );

      if (offRouteCounter >= 3 &&
          !isRerouting) {
        offRouteCounter = 0;
        reroute();
      }
    } else {
      offRouteCounter = 0;
    }
  }

  // =========================================================
  // REROUTE
  // =========================================================

  Future<void> reroute() async {
    if (destinationLocation == null ||
        isRerouting ||
        currentLocation == null) {
      return;
    }

    isRerouting = true;

    flutterTts.stop();

    if (mounted) {
      setState(() {
        nextInstruction =
        "Recalculating route...";
      });
    }

    if (voiceEnabled &&
        navigationStarted) {
      await speak(
        "You are off route. Recalculating.",
      );
    }

    // =====================================================
    // IMPORTANT:
    // Reroute from the ACTUAL GPS location,
    // not from the original route start.
    // =====================================================

    final LatLng actualLocation =
    currentLocation!;

    final LatLng destination =
    destinationLocation!;

    try {
      final Uri url = Uri.parse(
        'https://router.project-osrm.org/'
            'route/v1/driving/'
            '${actualLocation.longitude},${actualLocation.latitude};'
            '${destination.longitude},${destination.latitude}'
            '?overview=full&geometries=geojson&steps=true',
      );

      final response =
      await http.get(url);

      if (response.statusCode != 200) {
        throw Exception(
          "Reroute failed: ${response.statusCode}",
        );
      }

      final dynamic data =
      jsonDecode(response.body);

      if (data['routes'] == null ||
          data['routes'].isEmpty) {
        throw Exception(
          "No reroute found",
        );
      }

      final route =
      data['routes'][0];

      final List coordinates =
      route['geometry']['coordinates'];

      final List<LatLng> points =
      coordinates.map<LatLng>(
            (point) {
          return LatLng(
            point[1].toDouble(),
            point[0].toDouble(),
          );
        },
      ).toList();

      final List<Map<String, dynamic>> newSteps = [];

      if (route['legs'] != null &&
          route['legs'].isNotEmpty) {
        final List steps =
            route['legs'][0]['steps'] ?? [];

        for (final step in steps) {
          if (step is! Map) continue;

          final maneuver =
          step['maneuver'];

          if (maneuver == null) continue;

          final location =
          maneuver['location'];

          if (location is! List ||
              location.length < 2) {
            continue;
          }

          final double stepLng =
              double.tryParse(
                location[0].toString(),
              ) ??
                  0.0;

          final double stepLat =
              double.tryParse(
                location[1].toString(),
              ) ??
                  0.0;

          final String type =
              maneuver['type']?.toString() ?? '';

          final String modifier =
              maneuver['modifier']?.toString() ?? '';

          final double stepDistance =
          (step['distance'] ?? 0)
              .toDouble();

          final double stepDuration =
          (step['duration'] ?? 0)
              .toDouble();

          final LatLng stepLocation =
          LatLng(
            stepLat,
            stepLng,
          );

          int routeIndex = 0;

          if (points.isNotEmpty) {
            final Distance d =
            const Distance();

            double smallest =
                double.infinity;

            for (int i = 0;
            i < points.length;
            i++) {
              final double value =
              d.as(
                LengthUnit.Meter,
                stepLocation,
                points[i],
              );

              if (value < smallest) {
                smallest = value;
                routeIndex = i;
              }
            }
          }

          newSteps.add({
            'location': stepLocation,
            'type': type,
            'modifier': modifier,
            'distance': stepDistance,
            'duration': stepDuration,
            'routeIndex': routeIndex,
          });
        }
      }

      if (!mounted) {
        isRerouting = false;
        return;
      }

      setState(() {
        routePoints = points;

        routeDistance =
            route['distance'].toDouble() / 1000;

        routeDuration =
            route['duration'].toDouble() / 60;

        navigationSteps =
            newSteps;

        currentStepIndex = 0;

        currentRoutePointIndex = 0;

        lastRoutePointIndex =
        points.isEmpty
            ? 0
            : points.length - 1;

        nextInstruction =
        "Route recalculated";

        nextTurnDistance = 0.0;

        nextTurnTime = 0.0;
      });

      if (routePoints.isNotEmpty) {
        currentRoutePointIndex =
            findNearestRoutePoint(
              actualLocation,
            );
      }

      lastSpokenInstruction = "";

      lastSpokenStepIndex = -1;

      isRerouting = false;

      if (mounted &&
          navigationStarted) {
        await Future.delayed(
          const Duration(milliseconds: 300),
        );

        updateNavigationInstruction();
      }
    } catch (e) {
      debugPrint(
        "REROUTE ERROR: $e",
      );

      isRerouting = false;

      if (mounted &&
          navigationStarted) {
        setState(() {
          nextInstruction =
          "Unable to recalculate route";
        });
      }
    }
  }

  // =========================================================
  // OFFLINE CACHE
  // =========================================================

  Future<void> setupStore() async {
    try {
      await store.manage.create();
    } catch (e) {
      debugPrint(
        "CACHE ERROR: $e",
      );
    }
  }

  // =========================================================
  // ADDRESS
  // =========================================================

  Future<void> getAddress(
      double lat,
      double lng) async {
    try {
      final List<Placemark> places =
      await placemarkFromCoordinates(
        lat,
        lng,
      );

      if (places.isEmpty) {
        return;
      }

      final Placemark place =
          places.first;

      if (!mounted) return;

      // Only update normal GPS address
      // if user has not selected a custom start.
      if (customStartLocation == null) {
        setState(() {
          currentAddress = [
            place.thoroughfare,
            place.subLocality,
            place.locality,
            place.administrativeArea,
            place.country,
          ]
              .where(
                (e) =>
            e != null &&
                e.trim().isNotEmpty,
          )
              .join(", ");
        });
      }
    } catch (e) {
      debugPrint(
        "Address Error: $e",
      );
    }
  }

  // =========================================================
  // TRACKING
  // =========================================================

  Future<void> startTracking() async {
    final bool serviceEnabled =
    await Geolocator
        .isLocationServiceEnabled();

    if (!serviceEnabled) {
      return;
    }

    LocationPermission permission =
    await Geolocator.requestPermission();

    if (permission ==
        LocationPermission.denied ||
        permission ==
            LocationPermission.deniedForever) {
      return;
    }

    positionSubscription =
        Geolocator.getPositionStream(
          locationSettings:
          const LocationSettings(
            accuracy:
            LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          ),
        ).listen(
              (Position position) {
            // ===================================================
            // IGNORE VERY BAD GPS
            // ===================================================

            if (position.accuracy > 30) {
              return;
            }

            final LatLng newLoc =
            LatLng(
              position.latitude,
              position.longitude,
            );

            if (!mounted) return;

            setState(() {
              currentLocation =
                  newLoc;

              speed =
                  position.speed * 3.6;

              // Some devices return -1 for unavailable heading.
              if (position.heading >= 0) {
                heading =
                    position.heading;
              }

              accuracy =
                  position.accuracy;

              path.add(newLoc);
            });

            // ===================================================
            // ADDRESS
            // ===================================================

            if (customStartLocation == null) {
              getAddress(
                position.latitude,
                position.longitude,
              );
            }

            // ===================================================
            // NAVIGATION
            // ===================================================

            if (navigationStarted) {
              updateNavigationInstruction();

              checkOffRoute();

              mapController.move(
                newLoc,
                18,
              );
            }

            // ===================================================
            // FIRST GPS CENTER
            // ===================================================

            if (!firstCenterDone &&
                currentLocation != null) {
              mapController.move(
                currentLocation!,
                19,
              );

              firstCenterDone = true;
            }
          },
        );
  }

  // =========================================================
  // ACCURACY COLOR
  // =========================================================

  Color getAccuracyColor() {
    if (accuracy <= 10) {
      return Colors.green;
    }

    if (accuracy <= 25) {
      return Colors.orange;
    }

    return Colors.red;
  }

  // =========================================================
  // ACCURACY TEXT
  // =========================================================

  String getAccuracyText() {
    if (accuracy <= 10) {
      return "High";
    }

    if (accuracy <= 25) {
      return "Medium";
    }

    return "Low";
  }

  // =========================================================
  // VOICE TOGGLE
  // =========================================================

  void toggleVoice() {
    setState(() {
      voiceEnabled =
      !voiceEnabled;
    });

    if (!voiceEnabled) {
      flutterTts.stop();
    } else if (navigationStarted) {
      lastSpokenInstruction = "";

      lastSpokenStepIndex = -1;

      speak(
        "Voice navigation enabled. "
            "$nextInstruction",
      );
    }
  }

  // =========================================================
  // DISPOSE
  // =========================================================

  @override
  void dispose() {
    searchTimer?.cancel();

    rerouteTimer?.cancel();

    positionSubscription?.cancel();

    flutterTts.stop();

    searchController.dispose();

    super.dispose();
  }

  // =========================================================
  // UI
  // =========================================================

  @override
  Widget build(
      BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor:
        primaryTeal,
        centerTitle: true,
        iconTheme:
        const IconThemeData(
          color: Colors.white,
        ),
        title: const Text(
          "Tracking",
          style: TextStyle(
            color: Colors.white,
          ),
        ),

        // =====================================================
        // VOICE BUTTON
        // =====================================================

        actions: [
          IconButton(
            tooltip: voiceEnabled
                ? "Voice navigation ON"
                : "Voice navigation OFF",
            onPressed: toggleVoice,
            icon: Icon(
              voiceEnabled
                  ? Icons.volume_up
                  : Icons.volume_off,
              color: Colors.white,
            ),
          ),
        ],
      ),

      body: currentLocation == null
          ? const Center(
        child:
        CircularProgressIndicator(),
      )
          : Stack(
        children: [
          // =================================================
          // MAP
          // =================================================

          FlutterMap(
            mapController:
            mapController,
            options: MapOptions(
              initialCenter:
              currentLocation!,
              initialZoom: 19,
              maxZoom: 22,
              minZoom: 3,
            ),
            children: [
              TileLayer(
                urlTemplate:
                "https://a.tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName:
                'zavira_tracking_app',
                tileProvider:
                store.getTileProvider(
                  settings:
                  FMTCTileProviderSettings(
                    behavior:
                    CacheBehavior
                        .cacheFirst,
                  ),
                ),
                maxNativeZoom: 19,
              ),

              // =================================================
              // ROUTE + MOVEMENT PATH
              // =================================================

              PolylineLayer(
                polylines: [
                  if (path.length > 1)
                    Polyline(
                      points: path,
                      strokeWidth: 5,
                      color: Colors.blue,
                    ),

                  if (routePoints
                      .isNotEmpty)
                    Polyline(
                      points:
                      routePoints,
                      strokeWidth: 6,
                      color:
                      Colors.green,
                    ),
                ],
              ),

              // =================================================
              // MARKERS
              // =================================================

              MarkerLayer(
                markers: [
                  Marker(
                    point:
                    currentLocation!,
                    width: 80,
                    height: 80,
                    child:
                    Transform.rotate(
                      angle:
                      heading *
                          pi /
                          180,
                      child:
                      const Icon(
                        Icons.navigation,
                        size: 42,
                        color:
                        Colors.blue,
                      ),
                    ),
                  ),

                  if (destinationLocation !=
                      null)
                    Marker(
                      point:
                      destinationLocation!,
                      width: 60,
                      height: 60,
                      child:
                      const Icon(
                        Icons.location_pin,
                        size: 50,
                        color:
                        Colors.red,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // =================================================
          // NAVIGATION INSTRUCTION CARD
          // =================================================

          if (navigationStarted)
            Positioned(
              top: 15,
              left: 15,
              right: 15,
              child:
              Container(
                padding:
                const EdgeInsets.all(
                  14,
                ),
                decoration:
                BoxDecoration(
                  color:
                  Colors.white,
                  borderRadius:
                  BorderRadius.circular(
                    16,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color:
                      Colors.black26,
                      blurRadius: 10,
                      offset:
                      Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration:
                      BoxDecoration(
                        color:
                        primaryTeal
                            .withOpacity(
                          0.12,
                        ),
                        borderRadius:
                        BorderRadius
                            .circular(
                          12,
                        ),
                      ),
                      child: Icon(
                        getInstructionIcon(),
                        color:
                        primaryTeal,
                        size: 28,
                      ),
                    ),

                    const SizedBox(
                      width: 12,
                    ),

                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                        CrossAxisAlignment
                            .start,
                        children: [
                          Text(
                            nextInstruction,
                            style:
                            const TextStyle(
                              fontWeight:
                              FontWeight
                                  .bold,
                              fontSize: 16,
                            ),
                          ),

                          const SizedBox(
                            height: 5,
                          ),

                          Row(
                            children: [
                              const Icon(
                                Icons
                                    .straighten,
                                size: 15,
                                color:
                                Colors
                                    .grey,
                              ),

                              const SizedBox(
                                width: 4,
                              ),

                              Text(
                                nextTurnDistance >
                                    1000
                                    ? "${(nextTurnDistance / 1000).toStringAsFixed(1)} km"
                                    : "${nextTurnDistance.toStringAsFixed(0)} m",
                                style:
                                const TextStyle(
                                  color:
                                  Colors
                                      .grey,
                                  fontSize:
                                  13,
                                  fontWeight:
                                  FontWeight
                                      .w500,
                                ),
                              ),

                              if (nextTurnTime >
                                  0) ...[
                                const SizedBox(
                                  width: 12,
                                ),

                                const Icon(
                                  Icons
                                      .access_time,
                                  size: 15,
                                  color:
                                  Colors
                                      .grey,
                                ),

                                const SizedBox(
                                  width: 4,
                                ),

                                Text(
                                  formatTurnTime(
                                    nextTurnTime,
                                  ),
                                  style:
                                  const TextStyle(
                                    color:
                                    Colors
                                        .grey,
                                    fontSize:
                                    13,
                                    fontWeight:
                                    FontWeight
                                        .w500,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),

                    // VOICE BUTTON
                    IconButton(
                      onPressed:
                      toggleVoice,
                      icon: Icon(
                        voiceEnabled
                            ? Icons
                            .volume_up
                            : Icons
                            .volume_off,
                        color:
                        voiceEnabled
                            ? primaryTeal
                            : Colors
                            .grey,
                      ),
                    ),

                    // STOP BUTTON
                    IconButton(
                      onPressed:
                      stopNavigation,
                      icon:
                      const Icon(
                        Icons.close,
                        color:
                        Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // =================================================
          // TOP SEARCH AREA
          // =================================================

          if (!navigationStarted)
            Positioned(
              top: 15,
              left: 15,
              right: 15,
              child: Column(
                children: [
                  // =================================================
                  // CURRENT LOCATION CARD
                  // =================================================

                  Container(
                    width:
                    double.infinity,
                    margin:
                    const EdgeInsets
                        .only(
                      bottom: 8,
                    ),
                    padding:
                    const EdgeInsets
                        .all(
                      12,
                    ),
                    decoration:
                    BoxDecoration(
                      color:
                      Colors.white,
                      borderRadius:
                      BorderRadius
                          .circular(
                        14,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color:
                          Colors.black26,
                          blurRadius: 8,
                          offset:
                          Offset(
                            0,
                            3,
                          ),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration:
                          BoxDecoration(
                            color: Colors
                                .blue
                                .withOpacity(
                              0.10,
                            ),
                            borderRadius:
                            BorderRadius
                                .circular(
                              10,
                            ),
                          ),
                          child:
                          const Icon(
                            Icons
                                .my_location,
                            color:
                            Colors.blue,
                            size: 23,
                          ),
                        ),

                        const SizedBox(
                          width: 10,
                        ),

                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                            children: [
                              const Text(
                                "Current Location",
                                style:
                                TextStyle(
                                  fontSize:
                                  12,
                                  color:
                                  Colors
                                      .grey,
                                  fontWeight:
                                  FontWeight
                                      .w500,
                                ),
                              ),

                              const SizedBox(
                                height: 3,
                              ),

                              Text(
                                routeStartAddress
                                    .isEmpty
                                    ? "Using your current GPS location"
                                    : routeStartAddress,
                                maxLines:
                                2,
                                overflow:
                                TextOverflow
                                    .ellipsis,
                                style:
                                const TextStyle(
                                  fontSize:
                                  13,
                                  fontWeight:
                                  FontWeight
                                      .w600,
                                ),
                              ),
                            ],
                          ),
                        ),

                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              editingStartLocation =
                              true;

                              searchResults =
                              [];

                              searchController
                                  .clear();
                            });
                          },
                          icon:
                          const Icon(
                            Icons
                                .edit_location_alt,
                            size: 18,
                            color:
                            primaryTeal,
                          ),
                          label:
                          const Text(
                            "Edit",
                            style:
                            TextStyle(
                              color:
                              primaryTeal,
                              fontWeight:
                              FontWeight
                                  .bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // =================================================
                  // EDIT CURRENT LOCATION MESSAGE
                  // =================================================

                  if (editingStartLocation)
                    Container(
                      width:
                      double.infinity,
                      margin:
                      const EdgeInsets
                          .only(
                        bottom: 5,
                      ),
                      padding:
                      const EdgeInsets
                          .all(
                        12,
                      ),
                      decoration:
                      BoxDecoration(
                        color: Colors
                            .blue
                            .shade50,
                        borderRadius:
                        BorderRadius
                            .circular(
                          12,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons
                                .edit_location_alt,
                            color:
                            Colors.blue,
                          ),

                          const SizedBox(
                            width: 8,
                          ),

                          const Expanded(
                            child:
                            Text(
                              "Search and select a new current location",
                              style:
                              TextStyle(
                                color:
                                Colors
                                    .blue,
                                fontWeight:
                                FontWeight
                                    .w600,
                                fontSize:
                                13,
                              ),
                            ),
                          ),

                          IconButton(
                            onPressed:
                                () {
                              setState(
                                    () {
                                  editingStartLocation =
                                  false;

                                  searchResults =
                                  [];

                                  searchController
                                      .clear();
                                },
                              );
                            },
                            icon:
                            const Icon(
                              Icons.close,
                              color:
                              Colors.blue,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // =================================================
                  // SEARCH BAR
                  // =================================================

                  Container(
                    decoration:
                    BoxDecoration(
                      color:
                      Colors.white,
                      borderRadius:
                      BorderRadius
                          .circular(
                        14,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color:
                          Colors.black26,
                          blurRadius: 8,
                          offset:
                          Offset(
                            0,
                            3,
                          ),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Padding(
                          padding:
                          EdgeInsets
                              .only(
                            left: 12,
                          ),
                          child:
                          Icon(
                            Icons.search,
                            color:
                            Colors.grey,
                          ),
                        ),

                        Expanded(
                          child:
                          TextField(
                            controller:
                            searchController,
                            textInputAction:
                            TextInputAction
                                .search,
                            onChanged:
                            onSearchChanged,
                            onSubmitted:
                                (value) {
                              searchTimer
                                  ?.cancel();

                              searchLocation(
                                value,
                              );
                            },
                            decoration:
                            const InputDecoration(
                              hintText:
                              "Search destination...",
                              border:
                              InputBorder
                                  .none,
                              contentPadding:
                              EdgeInsets
                                  .symmetric(
                                horizontal:
                                12,
                                vertical:
                                16,
                              ),
                            ),
                          ),
                        ),

                        if (searchController
                            .text
                            .isNotEmpty)
                          IconButton(
                            icon:
                            const Icon(
                              Icons.clear,
                            ),
                            onPressed:
                                () {
                              searchController
                                  .clear();

                              searchTimer
                                  ?.cancel();

                              setState(() {
                                searchResults =
                                [];

                                isSearching =
                                false;
                              });
                            },
                          ),

                        IconButton(
                          icon:
                          const Icon(
                            Icons
                                .arrow_forward,
                            color:
                            primaryTeal,
                          ),
                          onPressed: () {
                            searchTimer
                                ?.cancel();

                            searchLocation(
                              searchController
                                  .text,
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  // =================================================
                  // SEARCHING
                  // =================================================

                  if (isSearching)
                    Container(
                      width:
                      double.infinity,
                      margin:
                      const EdgeInsets
                          .only(
                        top: 5,
                      ),
                      padding:
                      const EdgeInsets
                          .all(
                        15,
                      ),
                      decoration:
                      BoxDecoration(
                        color:
                        Colors.white,
                        borderRadius:
                        BorderRadius
                            .circular(
                          12,
                        ),
                      ),
                      child: const Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child:
                            CircularProgressIndicator(
                              strokeWidth:
                              2,
                            ),
                          ),

                          SizedBox(
                            width: 12,
                          ),

                          Text(
                            "Searching...",
                          ),
                        ],
                      ),
                    ),

                  // =================================================
                  // SEARCH RESULTS
                  // =================================================

                  if (!isSearching &&
                      searchResults
                          .isNotEmpty)
                    Container(
                      width:
                      double.infinity,
                      margin:
                      const EdgeInsets
                          .only(
                        top: 5,
                      ),
                      constraints:
                      const BoxConstraints(
                        maxHeight: 280,
                      ),
                      decoration:
                      BoxDecoration(
                        color:
                        Colors.white,
                        borderRadius:
                        BorderRadius
                            .circular(
                          12,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color:
                            Colors.black26,
                            blurRadius:
                            8,
                          ),
                        ],
                      ),
                      child:
                      ListView.builder(
                        shrinkWrap:
                        true,
                        itemCount:
                        searchResults
                            .length,
                        itemBuilder:
                            (
                            context,
                            index,
                            ) {
                          final result =
                          searchResults[
                          index];

                          return ListTile(
                            leading:
                            Icon(
                              editingStartLocation
                                  ? Icons
                                  .my_location
                                  : Icons
                                  .location_on,
                              color:
                              editingStartLocation
                                  ? Colors
                                  .blue
                                  : Colors
                                  .red,
                            ),
                            title:
                            Text(
                              result[
                              'name']
                                  .toString(),
                              maxLines:
                              2,
                              overflow:
                              TextOverflow
                                  .ellipsis,
                            ),
                            onTap: () {
                              selectDestination(
                                result,
                              );
                            },
                          );
                        },
                      ),
                    ),

                  // =================================================
                  // ROUTE INFORMATION
                  // =================================================

                  if (destinationLocation !=
                      null &&
                      !routeLoading &&
                      routePoints
                          .isNotEmpty)
                    Container(
                      width:
                      double.infinity,
                      margin:
                      const EdgeInsets
                          .only(
                        top: 8,
                      ),
                      padding:
                      const EdgeInsets
                          .all(
                        14,
                      ),
                      decoration:
                      BoxDecoration(
                        color:
                        Colors.white,
                        borderRadius:
                        BorderRadius
                            .circular(
                          12,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color:
                            Colors.black26,
                            blurRadius:
                            8,
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.route,
                                color:
                                primaryTeal,
                                size: 28,
                              ),

                              const SizedBox(
                                width: 10,
                              ),

                              Expanded(
                                child:
                                Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                                  children: [
                                    Text(
                                      destinationName,
                                      maxLines:
                                      1,
                                      overflow:
                                      TextOverflow
                                          .ellipsis,
                                      style:
                                      const TextStyle(
                                        fontWeight:
                                        FontWeight
                                            .bold,
                                        fontSize:
                                        14,
                                      ),
                                    ),

                                    const SizedBox(
                                      height: 5,
                                    ),

                                    Row(
                                      children: [
                                        const Icon(
                                          Icons
                                              .straighten,
                                          size:
                                          16,
                                          color:
                                          Colors
                                              .grey,
                                        ),

                                        const SizedBox(
                                          width:
                                          4,
                                        ),

                                        Text(
                                          "${routeDistance.toStringAsFixed(1)} km",
                                          style:
                                          const TextStyle(
                                            color:
                                            Colors
                                                .grey,
                                          ),
                                        ),

                                        const SizedBox(
                                          width:
                                          12,
                                        ),

                                        const Icon(
                                          Icons
                                              .access_time,
                                          size:
                                          16,
                                          color:
                                          Colors
                                              .grey,
                                        ),

                                        const SizedBox(
                                          width:
                                          4,
                                        ),

                                        Text(
                                          "${routeDuration.toStringAsFixed(0)} min",
                                          style:
                                          const TextStyle(
                                            color:
                                            Colors
                                                .grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height: 12,
                          ),

                          // =================================================
                          // START BUTTON
                          // =================================================

                          SizedBox(
                            width:
                            double.infinity,
                            height: 48,
                            child:
                            ElevatedButton
                                .icon(
                              onPressed:
                              startNavigation,
                              icon:
                              const Icon(
                                Icons
                                    .navigation,
                              ),
                              label:
                              const Text(
                                "START NAVIGATION",
                                style:
                                TextStyle(
                                  fontWeight:
                                  FontWeight
                                      .bold,
                                ),
                              ),
                              style:
                              ElevatedButton
                                  .styleFrom(
                                backgroundColor:
                                primaryTeal,
                                foregroundColor:
                                Colors
                                    .white,
                                shape:
                                RoundedRectangleBorder(
                                  borderRadius:
                                  BorderRadius
                                      .circular(
                                    12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          // =================================================
          // BOTTOM INFORMATION PANEL
          // =================================================

          Positioned(
            left: 12,
            right: 12,
            bottom: 15,
            child: Container(
              padding:
              const EdgeInsets
                  .all(
                12,
              ),
              decoration:
              BoxDecoration(
                color: Colors.white
                    .withOpacity(
                  0.94,
                ),
                borderRadius:
                BorderRadius
                    .circular(
                  18,
                ),
                boxShadow: const [
                  BoxShadow(
                    color:
                    Colors.black26,
                    blurRadius: 10,
                    offset:
                    Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // =================================================
                  // ACCURACY + SPEED
                  // =================================================

                  Row(
                    children: [
                      Expanded(
                        child:
                        bottomInfoItem(
                          Icons
                              .gps_fixed,
                          "Accuracy",
                          "${accuracy.toStringAsFixed(1)}m",
                          getAccuracyColor(),
                        ),
                      ),

                      Container(
                        width: 1,
                        height: 45,
                        color: Colors
                            .grey
                            .shade300,
                      ),

                      Expanded(
                        child:
                        bottomInfoItem(
                          Icons.speed,
                          "Speed",
                          "${speed.toStringAsFixed(1)} km/h",
                          Colors
                              .deepPurple,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 10,
                  ),

                  // =================================================
                  // LAT / LNG
                  // =================================================

                  Container(
                    width:
                    double.infinity,
                    padding:
                    const EdgeInsets
                        .all(
                      9,
                    ),
                    decoration:
                    BoxDecoration(
                      color: Colors
                          .grey
                          .shade100,
                      borderRadius:
                      BorderRadius
                          .circular(
                        10,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons
                              .my_location,
                          size: 18,
                          color: Colors
                              .black54,
                        ),

                        const SizedBox(
                          width: 7,
                        ),

                        Expanded(
                          child: Text(
                            "Lat: ${currentLocation!.latitude.toStringAsFixed(6)}  "
                                "Lng: ${currentLocation!.longitude.toStringAsFixed(6)}",
                            maxLines: 1,
                            overflow:
                            TextOverflow
                                .ellipsis,
                            style:
                            const TextStyle(
                              fontSize: 12,
                              fontWeight:
                              FontWeight
                                  .w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(
                    height: 8,
                  ),

                  // =================================================
                  // CURRENT ADDRESS
                  // =================================================

                  Row(
                    crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                    children: [
                      const Icon(
                        Icons
                            .location_on,
                        size: 20,
                        color:
                        Colors.teal,
                      ),

                      const SizedBox(
                        width: 7,
                      ),

                      Expanded(
                        child: Text(
                          routeStartAddress
                              .isEmpty
                              ? "Fetching address..."
                              : routeStartAddress,
                          maxLines: 2,
                          overflow:
                          TextOverflow
                              .ellipsis,
                          style:
                          const TextStyle(
                            fontSize: 12,
                            color: Colors
                                .black87,
                            fontWeight:
                            FontWeight
                                .w500,
                          ),
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
    );
  }

  // =========================================================
  // NAVIGATION ICON
  // =========================================================

  IconData getInstructionIcon() {
    if (nextInstruction
        .toLowerCase()
        .contains("left")) {
      return Icons.turn_left;
    }

    if (nextInstruction
        .toLowerCase()
        .contains("right")) {
      return Icons.turn_right;
    }

    if (nextInstruction
        .toLowerCase()
        .contains("roundabout")) {
      return Icons.roundabout_left;
    }

    if (nextInstruction
        .toLowerCase()
        .contains("arrived")) {
      return Icons.flag;
    }

    return Icons.straight;
  }

  // =========================================================
  // BOTTOM INFO ITEM
  // =========================================================

  Widget bottomInfoItem(
      IconData icon,
      String title,
      String value,
      Color color) {
    return Row(
      mainAxisAlignment:
      MainAxisAlignment.center,
      children: [
        Icon(
          icon,
          color: color,
          size: 24,
        ),

        const SizedBox(
          width: 8,
        ),

        Column(
          crossAxisAlignment:
          CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style:
              const TextStyle(
                fontSize: 11,
                color: Colors.grey,
              ),
            ),

            Text(
              value,
              style:
              const TextStyle(
                fontSize: 14,
                fontWeight:
                FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // =========================================================
  // INFO BOX
  // =========================================================

  Widget infoBox(
      String text,
      Color color) {
    return Container(
      padding:
      const EdgeInsets.all(12),
      decoration:
      BoxDecoration(
        color:
        color.withOpacity(0.75),
        borderRadius:
        BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style:
        const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight:
          FontWeight.w600,
        ),
      ),
    );
  }
}