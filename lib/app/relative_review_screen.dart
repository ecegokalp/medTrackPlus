import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/beta/verification/cloud_verification_service.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:video_player/video_player.dart';

/// Relative-side review of medication verification sessions.
///
/// Layout:
///   AppBar (transparent + deepSea title)
///   ┌── Header card (device + count) ────────────────────────────────┐
///   ┌── Recent recordings carousel (newest first) ───────────────────┐
///   ┌── Selected video (player + custom controls) ──────────────────┐
///   ┌── Metadata card (score, classification, timing, decisions) ──┐
///   ┌── Approve / Deny gradient buttons ────────────────────────────┐
class RelativeReviewScreen extends StatefulWidget {
  final String macAddress;
  final String? verificationId;

  const RelativeReviewScreen({
    super.key,
    required this.macAddress,
    this.verificationId,
  });

  @override
  State<RelativeReviewScreen> createState() => _RelativeReviewScreenState();
}

class _RelativeReviewScreenState extends State<RelativeReviewScreen> {
  final CloudVerificationService _cloud = CloudVerificationService();

  bool _loadingList = true;
  String? _listError;
  List<Map<String, dynamic>> _videos = [];

  Map<String, dynamic>? _selected;
  Map<String, dynamic>? _verification;
  String? _selectedDocId;

  VideoPlayerController? _videoController;
  bool _videoInitialized = false;
  String? _videoError;

  bool _submitting = false;
  bool _loadingDetail = false;

  /// Entity koleksiyonu: cihazlar 'dispenser', device-free hastalar 'patients'.
  CollectionReference<Map<String, dynamic>> get _verificationsRef =>
      FirebaseFirestore.instance
          .collection(widget.macAddress.startsWith('patient_')
              ? 'patients'
              : 'dispenser')
          .doc(widget.macAddress)
          .collection('verifications');

  @override
  void initState() {
    super.initState();
    _loadVideoList();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _loadVideoList() async {
    setState(() {
      _loadingList = true;
      _listError = null;
    });
    try {
      // videos/ (normal kayıtlar) + footage/ (şüpheli kayıtlar) birleşik —
      // yalnızca videos/ listelemek şüpheli oturum kayıtlarını gizliyordu.
      final list = await _cloud.listAllRecordings(widget.macAddress);
      if (!mounted) return;
      setState(() {
        _videos = list;
        _loadingList = false;
      });
      if (widget.verificationId != null) {
        await _selectByVerificationId(widget.verificationId!);
      } else if (list.isNotEmpty) {
        await _selectVideo(list.first);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _listError = 'videos_load_error'.tr(args: [e.toString()]);
          _loadingList = false;
        });
      }
    }
  }

  Future<void> _selectByVerificationId(String verificationId) async {
    try {
      final doc = await _verificationsRef.doc(verificationId).get();
      if (doc.exists) {
        final data = doc.data()!;
        final storagePath = data['storagePath'] as String?;
        Map<String, dynamic>? matchingVideo;
        if (storagePath != null) {
          final found =
              _videos.where((v) => v['fullPath'] == storagePath).toList();
          matchingVideo = found.isEmpty ? null : found.first;
        }
        if (!mounted) return;
        setState(() {
          _selectedDocId = verificationId;
          _verification = data;
          _selected = matchingVideo;
        });
        _initVideoFor(data['footageUrl'] as String? ?? '');
        return;
      }
    } catch (_) {}
    if (_videos.isNotEmpty) {
      await _selectVideo(_videos.first);
    }
  }

  Future<void> _selectVideo(Map<String, dynamic> video) async {
    setState(() {
      _selected = video;
      _selectedDocId = null;
      _verification = null;
      _loadingDetail = true;
    });

    try {
      final query = await _verificationsRef
          .where('storagePath', isEqualTo: video['fullPath'])
          .limit(1)
          .get();
      if (!mounted) return;
      if (query.docs.isNotEmpty) {
        final doc = query.docs.first;
        setState(() {
          _verification = doc.data();
          _selectedDocId = doc.id;
          _loadingDetail = false;
        });
      } else {
        setState(() => _loadingDetail = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingDetail = false);
    }

    _initVideoFor(video['downloadUrl'] as String? ?? '');
  }

  void _initVideoFor(String url) {
    _videoController?.dispose();
    _videoController = null;
    if (mounted) {
      setState(() {
        _videoInitialized = false;
        _videoError = null;
      });
    }
    if (url.isEmpty) {
      if (mounted) setState(() => _videoError = 'video_not_found'.tr());
      return;
    }
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController = ctrl;
    ctrl.initialize().then((_) {
      if (mounted) setState(() => _videoInitialized = true);
    }).catchError((e) {
      if (mounted) setState(() => _videoError = 'video_load_error'.tr());
    });
  }

  Future<void> _submitDecision(String decision) async {
    if (_selectedDocId == null) return;
    setState(() => _submitting = true);
    try {
      await _verificationsRef.doc(_selectedDocId).update({
        'review_decision': decision,
        'review_timestamp': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(decision == 'approved' ? 'approved_label'.tr() : 'rejected_label'.tr()),
        backgroundColor:
            decision == 'approved' ? AppColors.turquoise : Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      await _selectByVerificationId(_selectedDocId!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('decision_send_error'.tr(args: [e.toString()])),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'relative_review_title'.tr(),
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w800,
            color: AppColors.deepSea,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.deepSea),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded,
                color: AppColors.deepSea),
            tooltip: 'refresh'.tr(),
            onPressed: _loadingList ? null : _loadVideoList,
          ),
        ],
      ),
      body: _loadingList
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.skyBlue),
            )
          : _listError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_listError!,
                        style: GoogleFonts.inter(
                            color: Colors.redAccent, fontSize: 14)),
                  ),
                )
              : _videos.isEmpty
                  ? _EmptyState(macAddress: widget.macAddress)
                  : RefreshIndicator(
                      color: AppColors.skyBlue,
                      onRefresh: _loadVideoList,
                      child: ListView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        children: [
                          _HeaderStrip(
                            macAddress: widget.macAddress,
                            count: _videos.length,
                          ),
                          const SizedBox(height: 16),
                          _SectionTitle(
                              icon: Icons.history_rounded,
                              text: 'recent_recordings'.tr()),
                          const SizedBox(height: 8),
                          _VideoCarousel(
                            videos: _videos,
                            selected: _selected,
                            onTap: _selectVideo,
                          ),
                          const SizedBox(height: 20),
                          _SectionTitle(
                              icon: Icons.play_circle_outline_rounded,
                              text: 'selected_verification'.tr()),
                          const SizedBox(height: 8),
                          _VideoPlayerCard(
                            controller: _videoController,
                            initialized: _videoInitialized,
                            errorMessage: _videoError,
                          ),
                          const SizedBox(height: 16),
                          if (_loadingDetail)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                  child: CircularProgressIndicator(
                                      color: AppColors.skyBlue)),
                            )
                          else
                            _MetadataCard(
                              verification: _verification,
                              video: _selected,
                              macAddress: widget.macAddress,
                            ),
                          const SizedBox(height: 16),
                          if (_selectedDocId != null)
                            _DecisionBar(
                              submitting: _submitting,
                              onApprove: () => _submitDecision('approved'),
                              onReject: () => _submitDecision('rejected'),
                            ),
                        ],
                      ),
                    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionTitle({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.deepSea, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.deepSea,
          ),
        ),
      ],
    );
  }
}

class _HeaderStrip extends StatelessWidget {
  final String macAddress;
  final int count;
  const _HeaderStrip({required this.macAddress, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.skyBlue, AppColors.deepSea],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.medication_rounded,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'device_prefix'.tr(args: [macAddress]),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'video_count_found'.tr(args: [count.toString()]),
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String macAddress;
  const _EmptyState({required this.macAddress});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.skyBlue.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.videocam_off_rounded,
                  color: AppColors.skyBlue, size: 48),
            ),
            const SizedBox(height: 18),
            Text(
              'no_videos_yet'.tr(),
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.deepSea,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'no_videos_desc'.tr(),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: const Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              macAddress,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoCarousel extends StatelessWidget {
  final List<Map<String, dynamic>> videos;
  final Map<String, dynamic>? selected;
  final void Function(Map<String, dynamic>) onTap;
  const _VideoCarousel({
    required this.videos,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 116,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: videos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (ctx, i) {
          final v = videos[i];
          final isSel =
              selected != null && selected!['fullPath'] == v['fullPath'];
          final ts = _formatTimestamp(v['uploadedAt'] as String? ?? '');
          final size = _formatBytes(v['sizeBytes'] as int? ?? 0);
          return GestureDetector(
            onTap: () => onTap(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 158,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: isSel
                    ? const LinearGradient(
                        colors: [AppColors.skyBlue, AppColors.deepSea],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: isSel ? null : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSel
                      ? Colors.transparent
                      : Colors.blueGrey.shade50,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isSel
                        ? AppColors.deepSea.withValues(alpha: 0.30)
                        : Colors.black.withValues(alpha: 0.04),
                    blurRadius: isSel ? 12 : 6,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isSel
                              ? Colors.white.withValues(alpha: 0.20)
                              : AppColors.skyBlue.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.movie_creation_rounded,
                          color: isSel ? Colors.white : AppColors.skyBlue,
                          size: 16,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '#${i + 1}',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: isSel ? Colors.white : AppColors.deepSea,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    ts.isEmpty ? 'date_unknown'.tr() : ts,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isSel
                          ? Colors.white
                          : AppColors.deepSea,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    size,
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: isSel
                          ? Colors.white.withValues(alpha: 0.8)
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _formatTimestamp(String iso) {
    if (iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('dd MMM HH:mm', 'tr').format(dt);
    } catch (_) {
      return iso.length > 16 ? iso.substring(0, 16) : iso;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    double v = bytes.toDouble();
    int u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[u]}';
  }
}

/// Video player with full custom controls (play/pause, scrub bar, fullscreen).
class _VideoPlayerCard extends StatelessWidget {
  final VideoPlayerController? controller;
  final bool initialized;
  final String? errorMessage;

  const _VideoPlayerCard({
    required this.controller,
    required this.initialized,
    required this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    // All our recordings are produced by the in-app encoder in PORTRAIT
    // orientation (480×720). Some Android MediaPlayer versions drop the
    // orientation hint when reading our MP4 and report the natural size as
    // 720×480 (landscape) — that's where the "yanlardan sündürülmüş" /
    // sideways-stretched effect came from. Clamp the displayed aspect to
    // portrait (≤ 1.0) by always using min/max of the two dimensions, so
    // the video is shown taller than wide regardless of metadata weirdness.
    double aspect = 9 / 16; // portrait fallback while loading
    if (initialized &&
        controller != null &&
        controller!.value.isInitialized) {
      final s = controller!.value.size;
      if (s.width > 0 && s.height > 0) {
        final shorter = math.min(s.width, s.height);
        final longer = math.max(s.width, s.height);
        aspect = shorter / longer; // always ≤ 1 → portrait
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade50),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        // Constrain max height so a tall portrait video doesn't push the rest
        // of the page off-screen — we letterbox if needed.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (errorMessage != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline_rounded,
                              color: Colors.white54, size: 36),
                          const SizedBox(height: 8),
                          Text(
                            errorMessage!,
                            style: GoogleFonts.inter(
                                color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!initialized || controller == null)
                  const CircularProgressIndicator(color: AppColors.skyBlue)
                else
                  _VideoSurface(controller: controller!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoSurface extends StatefulWidget {
  final VideoPlayerController controller;
  const _VideoSurface({required this.controller});

  @override
  State<_VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<_VideoSurface> {
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoPlayer(c),
          if (_showControls || !c.value.isPlaying) ...[
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black54, Colors.transparent, Colors.black54],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.45, 1.0],
                ),
              ),
            ),
            Center(
              child: GestureDetector(
                onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    c.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: AppColors.deepSea,
                    size: 36,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Theme(
                    data: ThemeData.dark(),
                    child: VideoProgressIndicator(
                      c,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      colors: const VideoProgressColors(
                        playedColor: AppColors.skyBlue,
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white10,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        _format(c.value.position),
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '/ ${_format(c.value.duration)}',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(
                          c.value.volume > 0
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () =>
                            c.setVolume(c.value.volume > 0 ? 0 : 1),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.fullscreen_rounded,
                            color: Colors.white, size: 22),
                        onPressed: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _FullscreenVideoView(
                              controller: c,
                            ),
                          ));
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _format(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }
}

class _FullscreenVideoView extends StatefulWidget {
  final VideoPlayerController controller;
  const _FullscreenVideoView({required this.controller});

  @override
  State<_FullscreenVideoView> createState() => _FullscreenVideoViewState();
}

class _FullscreenVideoViewState extends State<_FullscreenVideoView> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same portrait-clamp as _VideoPlayerCard — see comment there.
    final s = widget.controller.value.size;
    double aspect = 9 / 16;
    if (s.width > 0 && s.height > 0) {
      final shorter = math.min(s.width, s.height);
      final longer = math.max(s.width, s.height);
      aspect = shorter / longer;
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: _VideoSurface(controller: widget.controller),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetadataCard extends StatelessWidget {
  final Map<String, dynamic>? verification;
  final Map<String, dynamic>? video;
  final String macAddress;

  const _MetadataCard({
    required this.verification,
    required this.video,
    required this.macAddress,
  });

  @override
  Widget build(BuildContext context) {
    final v = verification;
    final score = (v?['accuracyScore'] as num?)?.toDouble();
    final classification = v?['classification'] as String? ?? 'unknown';
    final ts = v?['timestamp'];
    final timeStr = ts is Timestamp
        ? DateFormat('dd MMM yyyy, HH:mm', 'tr').format(ts.toDate())
        : '';
    final section = v?['sectionIndex'] as int?;
    final review = v?['review_decision'] as String?;
    final detectionConfirmed = v?['detectionConfirmed'] as bool?;
    final userConfirmed = v?['userConfirmed'] as bool?;
    final highestPhase = v?['highestPhase'] as String?;

    Color classColor;
    IconData classIcon;
    String classLabel;
    switch (classification) {
      case 'success':
        classColor = AppColors.turquoise;
        classIcon = Icons.verified_rounded;
        classLabel = 'classification_success'.tr();
        break;
      case 'suspicious':
        classColor = Colors.orange;
        classIcon = Icons.help_outline_rounded;
        classLabel = 'classification_suspicious'.tr();
        break;
      case 'rejected':
        classColor = Colors.redAccent;
        classIcon = Icons.cancel_rounded;
        classLabel = 'classification_rejected'.tr();
        break;
      default:
        classColor = Colors.grey;
        classIcon = Icons.info_outline_rounded;
        classLabel = 'classification_unknown'.tr();
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade50),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: classColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(classIcon, color: classColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      classLabel,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: classColor,
                        letterSpacing: 0.6,
                      ),
                    ),
                    if (timeStr.isNotEmpty)
                      Text(
                        timeStr,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                  ],
                ),
              ),
              if (score != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        classColor.withValues(alpha: 0.18),
                        classColor.withValues(alpha: 0.08),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: classColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    '${(score * 100).toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w900,
                      color: classColor,
                      fontSize: 16,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (v == null)
            Text(
              'no_metadata_for_video'.tr(),
              style: GoogleFonts.inter(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (section != null)
                  _Chip(
                    icon: Icons.layers_rounded,
                    label: 'section_label'.tr(),
                    value: '$section',
                    color: AppColors.skyBlue,
                  ),
                if (detectionConfirmed != null)
                  _Chip(
                    icon: Icons.visibility_rounded,
                    label: 'visual_detection_label'.tr(),
                    value: detectionConfirmed ? 'yes'.tr() : 'no'.tr(),
                    color: detectionConfirmed
                        ? AppColors.turquoise
                        : Colors.orange,
                  ),
                if (userConfirmed != null)
                  _Chip(
                    icon: Icons.person_rounded,
                    label: 'confirmation_label'.tr(),
                    value: userConfirmed ? 'yes'.tr() : 'no'.tr(),
                    color: userConfirmed
                        ? AppColors.turquoise
                        : Colors.redAccent,
                  ),
                if (highestPhase != null)
                  _Chip(
                    icon: Icons.show_chart_rounded,
                    label: 'highest_phase_label'.tr(),
                    value: _humanizePhase(highestPhase),
                    color: AppColors.deepSea,
                  ),
              ],
            ),
          if (review != null) ...[
            const Divider(height: 24),
            Row(
              children: [
                Icon(
                  review == 'approved'
                      ? Icons.thumb_up_alt_rounded
                      : Icons.thumb_down_alt_rounded,
                  color: review == 'approved'
                      ? AppColors.turquoise
                      : Colors.redAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '${'relative_decision_prefix'.tr()} ',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Colors.grey.shade700,
                  ),
                ),
                Text(
                  review == 'approved' ? 'approved_label'.tr() : 'rejected_label'.tr(),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: review == 'approved'
                        ? AppColors.turquoise
                        : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(
            macAddress,
            style: GoogleFonts.inter(
              fontSize: 10,
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  static String _humanizePhase(String name) {
    const map = {
      'noFace': 'phase_no_face',
      'faceDetected': 'phase_face_detected',
      'mouthOpen': 'phase_mouth_open',
      'pillOnTongue': 'phase_pill_on_tongue',
      'mouthClosedWithPill': 'phase_mouth_closed_with_pill',
      'drinking': 'phase_drinking',
      'mouthReopened': 'phase_mouth_reopened',
      'swallowConfirmed': 'phase_swallow_confirmed',
      'swallowFailed': 'phase_swallow_failed',
      'timeoutExpired': 'phase_timeout_expired',
    };
    final key = map[name];
    return key != null ? key.tr() : name;
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _Chip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: GoogleFonts.inter(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: AppColors.deepSea,
            ),
          ),
        ],
      ),
    );
  }
}

class _DecisionBar extends StatelessWidget {
  final bool submitting;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _DecisionBar({
    required this.submitting,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _GradientButton(
            label: 'reject'.tr(),
            icon: Icons.thumb_down_alt_rounded,
            colors: const [Color(0xFFE53935), Color(0xFFB71C1C)],
            onPressed: submitting ? null : onReject,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: _GradientButton(
            label: 'approve'.tr(),
            icon: Icons.thumb_up_alt_rounded,
            colors: const [AppColors.turquoise, Color(0xFF1B998B)],
            onPressed: submitting ? null : onApprove,
          ),
        ),
      ],
    );
  }
}

class _GradientButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback? onPressed;

  const _GradientButton({
    required this.label,
    required this.icon,
    required this.colors,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.last.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
