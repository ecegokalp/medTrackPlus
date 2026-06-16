import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_compress/video_compress.dart';

import 'package:medTrackPlus/beta/cv_v2/cv_v2_config.dart';
import 'package:medTrackPlus/beta/cv_v2/cv_v2_metrics.dart';
import 'package:medTrackPlus/beta/cv_v2/cv_v2_overlay_painter.dart';
import 'package:medTrackPlus/beta/cv_v2/dev_stream_recorder.dart';
import 'package:medTrackPlus/beta/cv_v2/mlkit_cv_processor_v2.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart'
    show DetectionPhase;
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';
import 'package:medTrackPlus/beta/verification/accuracy_scoring_engine.dart';

/// ── DEV CV LAB (V2) ──────────────────────────────────────────────────
///
/// Developer-Mode-only playground for the EXPERIMENTAL V2 CV pipeline.
/// Nothing here touches the production VerificationScreen or the V1
/// services it uses — this screen is reachable ONLY from Developer Mode.
///
/// What you can test live:
///  • face / lip / pill detection with the improved V2 pipeline
///  • all ratios & accuracies in the corner HUD (mouth ratios, pill
///    confidence components, adaptive brightness, chroma purity, head
///    yaw/pitch/roll vs limits with warnings, latency/fps)
///  • swallow verification ("hapı yuttu mu?") with live counters
///  • video recording (manual or auto on mouth-open) + compress + upload —
///    the same relative-review recording path used in production
///  • live threshold tuning via the settings sheet (sliders)
class CvV2LabScreen extends StatefulWidget {
  const CvV2LabScreen({super.key});

  @override
  State<CvV2LabScreen> createState() => _CvV2LabScreenState();
}

class _CvV2LabScreenState extends State<CvV2LabScreen> {
  CameraController? _controller;
  bool _streaming = false;
  bool _permissionDenied = false;
  bool _isFrontCamera = true;
  InputImageRotation _rotation = InputImageRotation.rotation0deg;

  final CvV2Config _config = CvV2Config();
  MLKitCVProcessorV2? _processor;
  final DevStreamRecorder _recorder = DevStreamRecorder();
  final AccuracyScoringEngine _scoring = AccuracyScoringEngine();

  PillResultV2? _last;
  Size _imageSize = const Size(480, 640);
  bool _isProcessing = false;

  final List<CVFrameData> _frames = [];
  bool _autoRecord = true;
  bool _finalized = false;
  Timer? _recordingLimitTimer;
  static const Duration _maxRecording = Duration(seconds: 30);

  bool _hudExpanded = true;

  // Upload state
  bool _uploading = false;
  double _uploadProgress = 0.0;
  String? _uploadedUrl;
  String? _recordedPath;
  String? _uploadError;

  // Final scoring
  double? _finalScore;
  Map<String, double>? _finalSubScores;
  String _finalClassification = '';

  Timer? _uiTick; // refresh recording elapsed display

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _uiTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _recorder.isRecording) setState(() {});
    });
  }

  Future<void> _bootstrap() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _permissionDenied = true);
      return;
    }
    await _initCamera(front: true);
  }

  Future<void> _initCamera({required bool front}) async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final cam = cameras.firstWhere(
      (c) =>
          c.lensDirection ==
          (front ? CameraLensDirection.front : CameraLensDirection.back),
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    _isFrontCamera = cam.lensDirection == CameraLensDirection.front;
    _rotation = InputImageRotationValue.fromRawValue(cam.sensorOrientation) ??
        InputImageRotation.rotation0deg;
    _processor?.dispose();
    _processor = MLKitCVProcessorV2(rotation: _rotation, config: _config);
    setState(() => _controller = controller);
    await controller.startImageStream(_onFrame);
    _streaming = true;
  }

  Future<void> _switchCamera() async {
    if (_recorder.isRecording) return;
    final old = _controller;
    _streaming = false;
    setState(() => _controller = null);
    try {
      await old?.stopImageStream();
    } catch (_) {}
    await old?.dispose();
    await _initCamera(front: !_isFrontCamera);
  }

  Future<void> _onFrame(CameraImage image) async {
    // Recorder is time-throttled internally; runs even on skipped frames.
    unawaited(_recorder.maybeEncode(image));

    // Manual record requested from the FAB — needs a live frame to size
    // the encoder, so it starts here.
    if (_pendingManualStart && !_recorder.isRecording) {
      _pendingManualStart = false;
      await _startRecording(image);
    }

    if (_isProcessing || _processor == null) return;
    _isProcessing = true;
    try {
      final out = await _processor!.processFrame(image);
      if (out == null) return;
      if (!out.fromCache) {
        _frames.add(out.frameData);

        final phase = out.result.phase;
        // Auto-record: start the moment the mouth opens (like production).
        if (_autoRecord &&
            !_recorder.isRecording &&
            !_finalized &&
            _recordedPath == null &&
            phase == DetectionPhase.mouthOpen) {
          await _startRecording(image);
        }
        // Session end conditions.
        if (!_finalized &&
            (phase == DetectionPhase.swallowConfirmed ||
                phase == DetectionPhase.timeoutExpired)) {
          _finalized = true;
          unawaited(_finalize());
        }
      }
      if (mounted) {
        setState(() {
          _last = out.result;
          _imageSize = Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  // ── Recording ────────────────────────────────────────────────────────

  Future<void> _startRecording(CameraImage frame) async {
    try {
      await _recorder.start(frame, _rotation);
      _recordingLimitTimer?.cancel();
      _recordingLimitTimer = Timer(_maxRecording, () async {
        final p = await _recorder.stop();
        if (p != null && mounted) setState(() => _recordedPath = p);
      });
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kayıt başlatılamadı: $e')),
        );
      }
    }
  }

  Future<void> _toggleManualRecording() async {
    if (_recorder.isRecording) {
      _recordingLimitTimer?.cancel();
      final p = await _recorder.stop();
      if (mounted) setState(() => _recordedPath = p);
    } else {
      // Need a frame to size the encoder — grab the next one via flag.
      _pendingManualStart = true;
    }
  }

  bool _pendingManualStart = false;

  // ── Finalize & scoring ───────────────────────────────────────────────

  Future<void> _finalize() async {
    _recordingLimitTimer?.cancel();
    if (_recorder.isRecording) {
      final p = await _recorder.stop();
      _recordedPath = p;
    }
    final swallowConfirmed =
        _last?.phase == DetectionPhase.swallowConfirmed;
    final pillValidated = swallowConfirmed ||
        _frames.any((f) =>
            f.phase == DetectionPhase.pillOnTongue ||
            f.phase == DetectionPhase.mouthClosedWithPill);
    final drinkReached = _frames.any((f) =>
        f.phase == DetectionPhase.drinking ||
        f.phase == DetectionPhase.mouthReopened);

    final sub = _scoring.calculateSubScores(_frames,
        pillValidated: pillValidated);
    final raw = _scoring.calculate(
      mode: ScoringMode.deviceFree,
      pill: sub['pill'] ?? 0,
      lip: sub['lip'] ?? 0,
      mouth: sub['mouth'] ?? 0,
      timing: 0.5,
      pillToLip: sub['pillToLip'] ?? 0,
    );
    final anchored = _scoring.anchorToDetection(
      raw,
      pillValidated: pillValidated,
      drinkReached: drinkReached,
      swallowConfirmed: swallowConfirmed,
    );
    final cls = _scoring.classifyWithDetection(
      pillValidated: pillValidated,
      swallowConfirmed: swallowConfirmed,
    );
    if (mounted) {
      setState(() {
        _finalScore = anchored;
        _finalSubScores = sub;
        _finalClassification = cls.name;
      });
    }
  }

  Future<void> _uploadRecording() async {
    final path = _recordedPath;
    if (path == null || _uploading) return;
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _uploadError = null;
    });
    try {
      final info = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: false,
      );
      final compressed = info?.file?.path ?? path;
      final ref = FirebaseStorage.instance.ref().child(
          'dev_cv_lab/${DateTime.now().millisecondsSinceEpoch}.mp4');
      final task = ref.putFile(
        File(compressed),
        SettableMetadata(contentType: 'video/mp4'),
      );
      task.snapshotEvents.listen((s) {
        if (mounted && s.totalBytes > 0) {
          setState(() => _uploadProgress = s.bytesTransferred / s.totalBytes);
        }
      });
      await task;
      final url = await ref.getDownloadURL();
      if (mounted) setState(() => _uploadedUrl = url);
    } catch (e) {
      if (mounted) setState(() => _uploadError = '$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _resetSession() {
    _recordingLimitTimer?.cancel();
    if (_recorder.isRecording) {
      _recorder.stop();
    }
    setState(() {
      _processor?.reset();
      _frames.clear();
      _finalized = false;
      _finalScore = null;
      _finalSubScores = null;
      _finalClassification = '';
      _recordedPath = null;
      _uploadedUrl = null;
      _uploadError = null;
      _uploadProgress = 0;
      _last = null;
    });
  }

  @override
  void dispose() {
    _uiTick?.cancel();
    _recordingLimitTimer?.cancel();
    if (_recorder.isRecording) _recorder.stop();
    if (_streaming && _controller != null) {
      _controller!.stopImageStream().catchError((_) {});
    }
    _controller?.dispose();
    _processor?.dispose();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) {
      return Scaffold(
        appBar: AppBar(title: const Text('CV v2 Lab')),
        body: const Center(child: Text('Kamera izni verilmedi')),
      );
    }
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final result = _last;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('CV v2 Accuracy Lab',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.fiber_smart_record),
            tooltip: 'Otomatik kayıt (ağız açılınca): '
                '${_autoRecord ? "AÇIK" : "KAPALI"}',
            color: _autoRecord ? Colors.redAccent : Colors.white54,
            onPressed: () => setState(() => _autoRecord = !_autoRecord),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: _switchCamera,
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Eşik ayarları',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Oturumu sıfırla',
            onPressed: _resetSession,
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Stack(
              children: [
                Positioned.fill(child: CameraPreview(controller)),
                if (result != null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: CvV2OverlayPainter(
                        result: result,
                        imageSize: _imageSize,
                        rotation: _rotation,
                        isFrontCamera: _isFrontCamera,
                      ),
                    ),
                  ),
                // HUD — köşedeki ratio/accuracy paneli
                Positioned(
                  left: 8,
                  top: 8,
                  child: _buildHud(result?.metrics ?? const CvV2Metrics()),
                ),
                // Recording chip
                Positioned(
                  right: 8,
                  top: 8,
                  child: _buildRecordingChip(),
                ),
                // Guidance + result panel
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_finalScore != null) _buildResultCard(),
                      if (result != null && result.guidance.isNotEmpty)
                        _guidanceBar(result.guidance,
                            CvV2OverlayPainter.phaseColor(result.phase)),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: ready
          ? FloatingActionButton(
              backgroundColor:
                  _recorder.isRecording ? Colors.redAccent : Colors.white24,
              onPressed: _toggleManualRecording,
              child: Icon(
                _recorder.isRecording ? Icons.stop : Icons.videocam,
                color: Colors.white,
              ),
            )
          : null,
    );
  }

  Widget _buildRecordingChip() {
    if (!_recorder.isRecording) {
      if (_recordedPath != null) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'Kayıt hazır (${_recorder.encodedFrames} kare)',
            style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    final e = _recorder.elapsed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(
            'REC ${e.inSeconds}s / ${_maxRecording.inSeconds}s '
            '(${_recorder.encodedFrames}f)',
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildHud(CvV2Metrics m) {
    Color angleColor(bool exceeded, bool warning) => exceeded
        ? Colors.redAccent
        : (warning ? Colors.amberAccent : Colors.greenAccent);

    String deg(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}°';

    final rows = <Widget>[
      _hudHeader(m),
      if (_hudExpanded) ...[
        const SizedBox(height: 4),
        _row('faces', '${m.faceCount}  id=${m.trackingId ?? "—"}',
            m.faceDetected ? Colors.greenAccent : Colors.redAccent),
        _row(
          'yaw',
          '${deg(m.yaw)} / ±${m.yawLimit.toStringAsFixed(0)}°'
              '${m.yawExceeded ? "  SINIR AŞILDI!" : m.yawWarning ? "  dikkat" : ""}',
          angleColor(m.yawExceeded, m.yawWarning),
        ),
        _row(
          'pitch',
          '${deg(m.pitch)} / ±${m.pitchLimit.toStringAsFixed(0)}°'
              '${m.pitchExceeded ? "  SINIR AŞILDI!" : m.pitchWarning ? "  dikkat" : ""}',
          angleColor(m.pitchExceeded, m.pitchWarning),
        ),
        _row('roll', deg(m.roll), Colors.white70),
        const Divider(height: 8, color: Colors.white24),
        _row(
          'mouth',
          'raw=${m.mouthRatioRaw.toStringAsFixed(3)} '
              'cor=${m.mouthRatioCorrected.toStringAsFixed(3)} '
              'ema=${m.mouthRatioSmoothed.toStringAsFixed(3)}',
          m.isMouthOpen ? Colors.lightBlueAccent : Colors.white70,
        ),
        _row(
          'open?',
          '${m.isMouthOpen ? "AÇIK" : "kapalı"}  '
              '(>${m.openEnterThreshold.toStringAsFixed(2)} aç, '
              '<${m.openExitThreshold.toStringAsFixed(2)} kapat)',
          m.isMouthOpen ? Colors.lightBlueAccent : Colors.white54,
        ),
        const Divider(height: 8, color: Colors.white24),
        _row(
          'pixel',
          'thr=${m.adaptiveThreshold} μ=${m.meanLuma.toStringAsFixed(0)} '
              'σ=${m.stdLuma.toStringAsFixed(0)} '
              'chroma=${m.chromaAvailable ? "✓" : "✗"}',
          Colors.white70,
        ),
        _row(
          'ratios',
          'bright=${(m.brightRatio * 100).toStringAsFixed(1)}% '
              'cand=${(m.pillLikeRatio * 100).toStringAsFixed(1)}%',
          Colors.white70,
        ),
        _row(
          'blob',
          'n=${m.blobCount} area=${(m.blobAreaRatio * 100).toStringAsFixed(1)}% '
              'asp=${m.blobAspect.toStringAsFixed(1)}',
          Colors.white70,
        ),
        _row(
          'scores',
          'A=${m.areaScore.toStringAsFixed(2)} '
              'C=${m.centralityScore.toStringAsFixed(2)} '
              'P=${m.positionScore.toStringAsFixed(2)} '
              'K=${m.compactnessScore.toStringAsFixed(2)} '
              'col=${m.colorScore.toStringAsFixed(2)} '
              'S=${m.surroundScore.toStringAsFixed(2)} '
              'N=${m.noveltyScore.toStringAsFixed(2)}',
          Colors.white70,
        ),
        _row(
          'teeth',
          'pen=×${m.teethPenalty.toStringAsFixed(2)} '
              'like=${(m.toothLikeness * 100).toStringAsFixed(0)}%'
              '${m.teethPenalty < 0.85 ? "  (diş şüphesi)" : ""}',
          m.teethPenalty < 0.85 ? Colors.amberAccent : Colors.white54,
        ),
        _row(
          'baseline',
          '${m.baselineFrames} kare'
              '${m.baselineFrames >= 5 ? "  HAZIR — diş haritası aktif" : "  toplanıyor (boş ağzı açık tut)"}',
          m.baselineFrames >= 5 ? Colors.greenAccent : Colors.amberAccent,
        ),
        _row(
          'pill conf',
          '${(m.pillConfidence * 100).toStringAsFixed(0)}% '
              '(ema ${(m.pillConfidenceEma * 100).toStringAsFixed(0)}%) '
              'stable=${m.stableFrames}/${m.requiredStableFrames}',
          m.pillConfidenceEma >= _config.pillConfidenceThreshold
              ? Colors.greenAccent
              : Colors.white70,
        ),
        _row(
          'pill→lip',
          m.pillToLipDistance == null
              ? '—'
              : m.pillToLipDistance!.toStringAsFixed(3),
          Colors.white70,
        ),
        const Divider(height: 8, color: Colors.white24),
        _row(
          'swallow',
          '${m.swallowCounter}/${m.swallowRequired} '
              'pillSeen=${m.pillSeenInVerifyCount}',
          m.swallowCounter > 0 ? Colors.cyanAccent : Colors.white54,
        ),
        if (m.drinkLabel != null || m.drinkHits > 0)
          _row('drink', '${m.drinkLabel ?? "?"} '
              '${m.drinkHits}/${m.requiredDrinkHits}', Colors.lightBlueAccent),
        const Divider(height: 8, color: Colors.white24),
        _row(
          'perf',
          '${m.latencyMs.toStringAsFixed(0)}ms '
              '(avg ${m.avgLatencyMs.toStringAsFixed(0)}ms) '
              '${m.fps.toStringAsFixed(0)}fps skip=${m.skipFactor}',
          m.latencyMs > 100
              ? Colors.redAccent
              : (m.latencyMs > 60 ? Colors.amberAccent : Colors.greenAccent),
        ),
        _row('frames', '${_frames.length} kayıtlı örnek', Colors.white54),
      ],
    ];

    return GestureDetector(
      onTap: () => setState(() => _hudExpanded = !_hudExpanded),
      child: Container(
        width: 252,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        ),
      ),
    );
  }

  Widget _hudHeader(CvV2Metrics m) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '${m.phase.name}  [${m.stageName}]',
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Icon(
          _hudExpanded ? Icons.expand_less : Icons.expand_more,
          color: Colors.white54,
          size: 16,
        ),
      ],
    );
  }

  Widget _row(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _guidanceBar(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: const TextStyle(
            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildResultCard() {
    final sub = _finalSubScores ?? {};
    final cls = _finalClassification;
    final color = cls == 'success'
        ? Colors.greenAccent
        : cls == 'suspicious'
            ? Colors.amberAccent
            : Colors.redAccent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SONUÇ: ${cls.toUpperCase()}  •  '
            'Skor: ${((_finalScore ?? 0) * 100).toStringAsFixed(0)}%',
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            'pill=${(sub['pill'] ?? 0).toStringAsFixed(2)}  '
            'lip=${(sub['lip'] ?? 0).toStringAsFixed(2)}  '
            'mouth=${(sub['mouth'] ?? 0).toStringAsFixed(2)}  '
            'pill→lip=${(sub['pillToLip'] ?? 0).toStringAsFixed(2)}',
            style: const TextStyle(
                color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_recordedPath != null && _uploadedUrl == null)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                  ),
                  onPressed: _uploading ? null : _uploadRecording,
                  icon: _uploading
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                            value: _uploadProgress > 0 ? _uploadProgress : null,
                          ),
                        )
                      : const Icon(Icons.cloud_upload, size: 16),
                  label: Text(_uploading
                      ? 'Yükleniyor ${(_uploadProgress * 100).toStringAsFixed(0)}%'
                      : 'Videoyu yükle (test)'),
                ),
              if (_uploadedUrl != null)
                const Expanded(
                  child: Text(
                    '✓ Video yüklendi (dev_cv_lab/)',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 12),
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: _resetSession,
                icon: const Icon(Icons.replay, size: 16, color: Colors.white70),
                label: const Text('Tekrar dene',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
          if (_uploadError != null)
            Text('Yükleme hatası: $_uploadError',
                style:
                    const TextStyle(color: Colors.redAccent, fontSize: 11)),
          if (_recordedPath != null)
            Text('Yerel kayıt: $_recordedPath',
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    fontFamily: 'monospace')),
        ],
      ),
    );
  }

  // ── Settings sheet (live threshold tuning) ───────────────────────────

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15181D),
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          Widget slider(String label, double value, double min, double max,
              void Function(double) onChanged,
              {int decimals = 2}) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(label,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ),
                  Expanded(
                    child: Slider(
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      onChanged: (v) {
                        onChanged(v);
                        setSheet(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(value.toStringAsFixed(decimals),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFamily: 'monospace')),
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  const Text('V2 Eşik Ayarları (canlı)',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  const SizedBox(height: 8),
                  slider('Max yaw (°)', _config.maxYawDeg, 10, 45,
                      (v) => _config.maxYawDeg = v, decimals: 0),
                  slider('Max pitch (°)', _config.maxPitchDeg, 10, 45,
                      (v) => _config.maxPitchDeg = v, decimals: 0),
                  slider('Ağız açık (giriş)', _config.mouthOpenEnter, 0.10,
                      0.60, (v) => _config.mouthOpenEnter = v),
                  slider('Ağız açık (çıkış)', _config.mouthOpenExit, 0.05,
                      0.50, (v) => _config.mouthOpenExit = v),
                  slider('Hap güven eşiği', _config.pillConfidenceThreshold,
                      0.20, 0.80, (v) => _config.pillConfidenceThreshold = v),
                  slider('Chroma nötr maks', _config.chromaNeutralMax, 10, 60,
                      (v) => _config.chromaNeutralMax = v, decimals: 0),
                  slider('Parlaklık k (μ+kσ)', _config.brightnessSigmaK, 0.4,
                      2.0, (v) => _config.brightnessSigmaK = v, decimals: 1),
                  slider(
                      'Stabil kare sayısı',
                      _config.requiredStableFrames.toDouble(),
                      2,
                      10,
                      (v) => _config.requiredStableFrames = v.round(),
                      decimals: 0),
                  slider(
                      'Yutma doğrulama karesi',
                      _config.swallowVerifyFrames.toDouble(),
                      4,
                      15,
                      (v) => _config.swallowVerifyFrames = v.round(),
                      decimals: 0),
                  slider(
                      'Boş ağız güven eşiği',
                      _config.emptyMouthMaxConfidence,
                      0.15,
                      0.70,
                      (v) => _config.emptyMouthMaxConfidence = v),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () {
                      _config.resetToDefaults();
                      setSheet(() {});
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.settings_backup_restore,
                        size: 16, color: Colors.amberAccent),
                    label: const Text('Varsayılanlara dön',
                        style: TextStyle(color: Colors.amberAccent)),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        });
      },
    );
  }
}
