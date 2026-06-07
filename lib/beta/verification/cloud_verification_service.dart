import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:medTrackPlus/beta/core/interfaces/i_cloud_verification_service.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart';

/// Result of a video upload — caller may need both the URL (for immediate
/// playback) and the storage path (so it can be deleted if the user later
/// rejects the recording in the "no, couldn't take it" flow).
class VideoUploadResult {
  final String downloadUrl;
  final String storagePath;
  const VideoUploadResult({
    required this.downloadUrl,
    required this.storagePath,
  });
}

/// Concrete implementation of [ICloudVerificationService].
///
/// Storage scheme:
///   videos/{deviceId}/{ISO8601-timestamp}.mp4
///
/// Firestore scheme:
///   users/{uid}/verifications/{verificationId}                — per-user log
///   dispenser/{macAddress}/verifications/{verificationId}     — per-device log
///                                                              (relatives query this)
class CloudVerificationService implements ICloudVerificationService {
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  CloudVerificationService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  @override
  Future<void> save(String userId, VerificationResult result) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('verifications')
          .doc(result.id)
          .set(result.toFirestore());

      debugPrint('[CloudVerificationService] Saved verification ${result.id}');
    } catch (e) {
      debugPrint('[CloudVerificationService] Save error: $e');
      rethrow;
    }
  }

  /// Saves a verification under the entity document so relatives can review it.
  /// Entity = dispenser (MAC id) or device-free patient ('patient_<uuid>' id);
  /// the collection is resolved from the id prefix.
  /// Pass [extraData] (e.g. {'storagePath': ...}) for fields not modeled by
  /// [VerificationResult].
  Future<void> saveForDevice({
    required String macAddress,
    required VerificationResult result,
    Map<String, dynamic>? extraData,
  }) async {
    try {
      final data = {
        ...result.toFirestore(),
        if (extraData != null) ...extraData,
      };
      final collection =
          macAddress.startsWith('patient_') ? 'patients' : 'dispenser';
      await _firestore
          .collection(collection)
          .doc(macAddress)
          .collection('verifications')
          .doc(result.id)
          .set(data);
      debugPrint(
          '[CloudVerificationService] Saved device verification ${result.id} for $macAddress');
    } catch (e) {
      debugPrint('[CloudVerificationService] saveForDevice error: $e');
      rethrow;
    }
  }

  /// Legacy single-arg upload — kept for backwards compatibility.
  /// Prefer [uploadVideo] which uses the new videos/{deviceId}/ scheme.
  @override
  Future<String> upload(String userId, String localPath) async {
    final result = await uploadVideo(deviceId: userId, localPath: localPath);
    return result.downloadUrl;
  }

  /// Uploads an MP4 video to `videos/{deviceId}/{ISO timestamp}.mp4`.
  /// Returns both the download URL and the storage path for later deletion.
  ///
  /// [onProgress] is invoked with values in [0.0, 1.0] as bytes upload.
  Future<VideoUploadResult> uploadVideo({
    required String deviceId,
    required String localPath,
    String? customTimestamp,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Video file not found: $localPath');
      }

      final ts = customTimestamp ??
          DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      final storagePath = 'videos/$deviceId/$ts.mp4';
      final ref = _storage.ref().child(storagePath);

      final uploadTask = ref.putFile(
        file,
        SettableMetadata(
          contentType: 'video/mp4',
          customMetadata: {
            'deviceId': deviceId,
            'uploadedAt': DateTime.now().toUtc().toIso8601String(),
            // Cleanup function uses this to compute TTL even if mtime is wrong.
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 24))
                .toIso8601String(),
          },
        ),
      );

      uploadTask.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          final progress = snapshot.bytesTransferred / snapshot.totalBytes;
          if (onProgress != null) onProgress(progress.clamp(0.0, 1.0));
          debugPrint(
              '[CloudVerificationService] Upload: ${(progress * 100).toStringAsFixed(0)}%');
        }
      });

      await uploadTask;
      if (onProgress != null) onProgress(1.0);
      final downloadUrl = await ref.getDownloadURL();

      debugPrint(
          '[CloudVerificationService] Video uploaded: $storagePath');
      return VideoUploadResult(
        downloadUrl: downloadUrl,
        storagePath: storagePath,
      );
    } catch (e) {
      debugPrint('[CloudVerificationService] uploadVideo error: $e');
      rethrow;
    }
  }

  /// Uploads a suspicious verification video to `footage/{deviceId}/{timestamp}.mp4`.
  /// Uses the dedicated footage path for suspicious-only recordings that
  /// relatives need to review. Progress is reported via [onProgress] (0.0–1.0).
  Future<VideoUploadResult> uploadFootage({
    required String deviceId,
    required String localPath,
    String? customTimestamp,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Footage file not found: $localPath');
      }

      final ts = customTimestamp ??
          DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      final storagePath = 'footage/$deviceId/$ts.mp4';
      final ref = _storage.ref().child(storagePath);

      final uploadTask = ref.putFile(
        file,
        SettableMetadata(
          contentType: 'video/mp4',
          customMetadata: {
            'deviceId': deviceId,
            'classification': 'suspicious',
            'uploadedAt': DateTime.now().toUtc().toIso8601String(),
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 24))
                .toIso8601String(),
          },
        ),
      );

      uploadTask.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          final progress = snapshot.bytesTransferred / snapshot.totalBytes;
          if (onProgress != null) onProgress(progress.clamp(0.0, 1.0));
          debugPrint(
              '[CloudVerificationService] Footage upload: '
              '${(progress * 100).toStringAsFixed(0)}%');
        }
      });

      await uploadTask;
      if (onProgress != null) onProgress(1.0);
      final downloadUrl = await ref.getDownloadURL();

      debugPrint(
          '[CloudVerificationService] Footage uploaded: $storagePath');
      return VideoUploadResult(
        downloadUrl: downloadUrl,
        storagePath: storagePath,
      );
    } catch (e) {
      debugPrint('[CloudVerificationService] uploadFootage error: $e');
      rethrow;
    }
  }

  /// Deletes a previously uploaded video by its full storage path
  /// (e.g. "videos/AABBCC/2026-...-..mp4"). Used when the user says they
  /// couldn't take the medication in the timeout dialog.
  Future<void> deleteVideo(String storagePath) async {
    try {
      await _storage.ref().child(storagePath).delete();
      debugPrint('[CloudVerificationService] Deleted $storagePath');
    } catch (e) {
      debugPrint('[CloudVerificationService] deleteVideo error: $e');
      // Don't rethrow — deletion failure shouldn't break the flow
    }
  }

  /// Lists all videos for a device, newest first.
  /// Returns list of {name, fullPath, downloadUrl, uploadedAt}.
  Future<List<Map<String, dynamic>>> listVideos(String deviceId) async {
    try {
      final result = await _storage.ref().child('videos/$deviceId').listAll();
      final entries = <Map<String, dynamic>>[];
      for (final item in result.items) {
        try {
          final meta = await item.getMetadata();
          final url = await item.getDownloadURL();
          entries.add({
            'name': item.name,
            'fullPath': item.fullPath,
            'downloadUrl': url,
            'uploadedAt': meta.customMetadata?['uploadedAt'] ??
                meta.timeCreated?.toIso8601String() ??
                '',
            'sizeBytes': meta.size ?? 0,
          });
        } catch (e) {
          debugPrint('[CloudVerificationService] listVideos item error: $e');
        }
      }
      // Newest first
      entries.sort((a, b) =>
          (b['uploadedAt'] as String).compareTo(a['uploadedAt'] as String));
      return entries;
    } catch (e) {
      debugPrint('[CloudVerificationService] listVideos error: $e');
      return [];
    }
  }

  @override
  Future<Map<String, dynamic>> stats(String userId) async {
    try {
      final querySnapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('verifications')
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();

      int totalSessions = querySnapshot.docs.length;
      int successCount = 0;
      double totalScore = 0.0;

      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final classification = data['classification'] as String?;
        final score = (data['accuracyScore'] as num?)?.toDouble() ?? 0.0;

        if (classification == 'success') successCount++;
        totalScore += score;
      }

      return {
        'totalSessions': totalSessions,
        'successCount': successCount,
        'successRate':
            totalSessions > 0 ? successCount / totalSessions : 0.0,
        'averageScore':
            totalSessions > 0 ? totalScore / totalSessions : 0.0,
      };
    } catch (e) {
      debugPrint('[CloudVerificationService] Stats error: $e');
      return {
        'totalSessions': 0,
        'successCount': 0,
        'successRate': 0.0,
        'averageScore': 0.0,
      };
    }
  }
}
