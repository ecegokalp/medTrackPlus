import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";

admin.initializeApp();

const db = admin.firestore();
const messaging = admin.messaging();

/**
 * Firestore onCreate trigger for verification documents.
 *
 * Path: dispenser/{macAddress}/verifications/{verificationId}
 *
 * Document structure:
 * {
 *   classification: "rejected" | "suspicious" | "success",
 *   section: number,
 *   userId: string,
 *   hasDevice: boolean,
 *   metadata?: { ... },
 *   timestamp: server_timestamp
 * }
 *
 * Behavior:
 *   rejected   → Send FCM notification to all relatives
 *   suspicious → Send review FCM notification to all relatives
 *   success    → Log only
 */
async function handleVerificationCreated(
  snap: functions.firestore.QueryDocumentSnapshot,
  entityCollection: "dispenser" | "patients",
  entityId: string,
  verificationId: string
): Promise<null> {
    const data = snap.data();
    const classification: string = data.classification;
    const section: number = data.section ?? 0;
    const hasDevice: boolean = data.hasDevice ?? (entityCollection === "dispenser");

    functions.logger.info(
      `Verification created: ${entityCollection}/${entityId}, classification=${classification}, hasDevice=${hasDevice}`
    );

    // --- SUCCESS: log only ---
    if (classification === "success") {
      functions.logger.info("Classification is success. No notification needed.");
      return null;
    }

    // --- REJECTED or SUSPICIOUS: send FCM to relatives ---
    try {
      // 1. Get entity document to find all related users
      const entityDoc = await db.collection(entityCollection).doc(entityId).get();
      if (!entityDoc.exists) {
        functions.logger.warn(`${entityCollection}/${entityId} not found.`);
        return null;
      }

      const dispenserData = entityDoc.data()!;
      const deviceName: string = entityCollection === "patients"
        ? dispenserData.patient_name ?? entityId
        : dispenserData.device_name ?? entityId;

      // Get medicine name from section_config (device) or medications (patient)
      const sectionConfig: Array<{name?: string}> = entityCollection === "patients"
        ? dispenserData.medications ?? []
        : dispenserData.section_config ?? [];
      const medicineName: string =
        section < sectionConfig.length && sectionConfig[section]?.name
          ? sectionConfig[section].name!
          : `Section ${section}`;

      // 2. Collect all relative emails
      const relativeEmails: Set<string> = new Set();

      const ownerMail = dispenserData.owner_mail;
      if (ownerMail) relativeEmails.add(ownerMail.toLowerCase());

      const secondaryMails: string[] = dispenserData.secondary_mails ?? [];
      for (const m of secondaryMails) relativeEmails.add(m.toLowerCase());

      const readOnlyMails: string[] = dispenserData.read_only_mails ?? [];
      for (const m of readOnlyMails) relativeEmails.add(m.toLowerCase());

      if (relativeEmails.size === 0) {
        functions.logger.info("No relatives found for this dispenser.");
        return null;
      }

      // 3. Collect FCM tokens for all relatives
      const tokens: string[] = [];

      for (const email of relativeEmails) {
        const userQuery = await db
          .collection("users")
          .where("email", "==", email)
          .limit(1)
          .get();

        if (!userQuery.empty) {
          const userData = userQuery.docs[0].data();
          const userTokens: string[] = userData.fcmTokens ?? [];
          tokens.push(...userTokens);
        }
      }

      if (tokens.length === 0) {
        functions.logger.info("No FCM tokens found for relatives.");
        return null;
      }

      // 4. Build notification based on classification and device path
      const {title, body} = buildNotification(
        classification, medicineName, deviceName, hasDevice
      );

      // 5. Send FCM to all tokens
      const message: admin.messaging.MulticastMessage = {
        tokens,
        notification: {title, body},
        data: {
          type: "verification",
          classification,
          macAddress: entityId,
          verificationId,
          section: section.toString(),
          hasDevice: hasDevice.toString(),
        },
        android: {
          priority: "high",
          notification: {
            channelId: classification === "rejected"
              ? "stock_warning_channel"
              : "reminder_channel",
            icon: "notification_bar_icon",
          },
        },
      };

      const response = await messaging.sendEachForMulticast(message);

      functions.logger.info(
        `FCM sent: ${response.successCount} success, ${response.failureCount} failure`
      );

      // Clean up invalid tokens
      if (response.failureCount > 0) {
        await cleanupInvalidTokens(response, tokens);
      }

      return null;
    } catch (error) {
      functions.logger.error("Error in onVerificationCreated:", error);
      return null;
    }
}

export const onVerificationCreated = functions
  .region("europe-west1")
  .firestore.document("dispenser/{macAddress}/verifications/{verificationId}")
  .onCreate((snap, context) => handleVerificationCreated(
    snap, "dispenser", context.params.macAddress, context.params.verificationId
  ));

export const onPatientVerificationCreated = functions
  .region("europe-west1")
  .firestore.document("patients/{patientId}/verifications/{verificationId}")
  .onCreate((snap, context) => handleVerificationCreated(
    snap, "patients", context.params.patientId, context.params.verificationId
  ));

/**
 * Shared handler: when review_decision changes to "approved" or "denied",
 * send FCM notification to the patient (userId).
 */
async function handleReviewDecisionUpdate(
  change: functions.Change<functions.firestore.QueryDocumentSnapshot>,
  entityCollection: "dispenser" | "patients",
  entityId: string
): Promise<null> {
    const before = change.before.data();
    const after = change.after.data();

    const oldDecision: string | undefined = before.review_decision;
    const newDecision: string | undefined = after.review_decision;

    // Only trigger when review_decision actually changes to approved/denied
    if (oldDecision === newDecision) return null;
    if (newDecision !== "approved" && newDecision !== "denied") return null;

    const userId: string = after.userId;

    functions.logger.info(
      `Review decision updated: ${entityCollection}/${entityId}, decision=${newDecision}, patient=${userId}`
    );

    try {
      // 1. Get patient FCM tokens
      const userDoc = await db.collection("users").doc(userId).get();
      if (!userDoc.exists) {
        functions.logger.warn(`User ${userId} not found.`);
        return null;
      }

      const userData = userDoc.data()!;
      const tokens: string[] = userData.fcmTokens ?? [];

      if (tokens.length === 0) {
        functions.logger.info("No FCM tokens found for patient.");
        return null;
      }

      // 2. Get entity display name
      const entityDoc = await db.collection(entityCollection).doc(entityId).get();
      const deviceName: string = entityDoc.exists
        ? (entityCollection === "patients"
            ? entityDoc.data()!.patient_name ?? entityId
            : entityDoc.data()!.device_name ?? entityId)
        : entityId;

      // 3. Build notification
      const title = newDecision === "approved"
        ? "Verification Approved"
        : "Verification Denied";
      const body = newDecision === "approved"
        ? `Your verification on ${deviceName} has been approved.`
        : `Your verification on ${deviceName} has been denied. Please check.`;

      // 4. Send FCM
      const message: admin.messaging.MulticastMessage = {
        tokens,
        notification: {title, body},
        data: {
          type: "review_decision",
          decision: newDecision,
          macAddress: entityId,
        },
        android: {
          priority: "high",
          notification: {
            channelId: "reminder_channel",
            icon: "notification_bar_icon",
          },
        },
      };

      const response = await messaging.sendEachForMulticast(message);

      functions.logger.info(
        `FCM sent to patient: ${response.successCount} success, ${response.failureCount} failure`
      );

      if (response.failureCount > 0) {
        await cleanupInvalidTokens(response, tokens);
      }

      return null;
    } catch (error) {
      functions.logger.error("Error in onReviewDecisionUpdate:", error);
      return null;
    }
}

export const onReviewDecisionUpdate = functions
  .region("europe-west1")
  .firestore.document("dispenser/{macAddress}/verifications/{verificationId}")
  .onUpdate((change, context) => handleReviewDecisionUpdate(
    change, "dispenser", context.params.macAddress
  ));

export const onPatientReviewDecisionUpdate = functions
  .region("europe-west1")
  .firestore.document("patients/{patientId}/verifications/{verificationId}")
  .onUpdate((change, context) => handleReviewDecisionUpdate(
    change, "patients", context.params.patientId
  ));

/**
 * Build notification title and body based on classification and device path.
 */
function buildNotification(
  classification: string,
  medicineName: string,
  deviceName: string,
  hasDevice: boolean
): {title: string; body: string} {
  if (hasDevice) {
    // --- DEVICE PATH ---
    if (classification === "rejected") {
      return {
        title: "Medication Rejected",
        body: `${medicineName} was rejected on ${deviceName}. Please check.`,
      };
    }
    // suspicious
    return {
      title: "Verification Needs Review",
      body: `${medicineName} on ${deviceName} requires review.`,
    };
  } else {
    // --- DEVICE-FREE PATH ---
    if (classification === "rejected") {
      return {
        title: "Medication Rejected",
        body: `${medicineName} was rejected. Please follow up.`,
      };
    }
    // suspicious
    return {
      title: "Verification Needs Review",
      body: `${medicineName} requires review.`,
    };
  }
}

/**
 * Remove invalid/expired FCM tokens from Firestore.
 */
async function cleanupInvalidTokens(
  response: admin.messaging.BatchResponse,
  tokens: string[]
): Promise<void> {
  const invalidTokens: string[] = [];

  response.responses.forEach((resp, idx) => {
    if (!resp.success) {
      const code = resp.error?.code;
      if (
        code === "messaging/invalid-registration-token" ||
        code === "messaging/registration-token-not-registered"
      ) {
        invalidTokens.push(tokens[idx]);
      }
    }
  });

  if (invalidTokens.length === 0) return;

  // Find and clean up tokens from all users
  for (const token of invalidTokens) {
    const usersWithToken = await db
      .collection("users")
      .where("fcmTokens", "array-contains", token)
      .get();

    for (const userDoc of usersWithToken.docs) {
      await userDoc.ref.update({
        fcmTokens: admin.firestore.FieldValue.arrayRemove([token]),
      });
    }
  }

  functions.logger.info(`Cleaned up ${invalidTokens.length} invalid FCM tokens.`);
}

/**
 * Scheduled cleanup: every hour, list all objects under videos/ in the default
 * Storage bucket and delete any that are older than 24 hours.
 *
 * Files are considered expired based on either:
 *   - customMetadata.expiresAt (set by the client at upload time), or
 *   - timeCreated (fallback, file age >= 24h).
 */
export const cleanupOldVideos = functions
  .region("europe-west1")
  .pubsub.schedule("every 1 hours")
  .timeZone("UTC")
  .onRun(async () => {
    const bucket = admin.storage().bucket();
    // Clean up both videos/ and footage/ prefixes.
    const prefixes = ["videos/", "footage/"];
    const allFiles = [];
    for (const prefix of prefixes) {
      const [files] = await bucket.getFiles({prefix});
      allFiles.push(...files);
    }

    const now = Date.now();
    const ttlMs = 24 * 60 * 60 * 1000;
    let deleted = 0;
    let kept = 0;

    for (const file of allFiles) {
      try {
        const [metadata] = await file.getMetadata();
        const expiresAt = metadata.metadata?.expiresAt as string | undefined;
        const createdAt = metadata.timeCreated;

        let expired = false;
        if (expiresAt) {
          const exp = Date.parse(expiresAt);
          if (!Number.isNaN(exp) && now > exp) expired = true;
        } else if (createdAt) {
          const created = Date.parse(createdAt);
          if (!Number.isNaN(created) && now - created > ttlMs) expired = true;
        }

        if (expired) {
          await file.delete();
          deleted++;
          functions.logger.info(`Deleted expired video: ${file.name}`);
        } else {
          kept++;
        }
      } catch (e) {
        functions.logger.error(
          `Failed to process ${file.name} during cleanup`,
          e
        );
      }
    }

    functions.logger.info(
      `cleanupOldVideos done. deleted=${deleted}, kept=${kept}`
    );
    return null;
  });

/**
 * Storage trigger: when a video is uploaded under videos/{deviceId}/...,
 * stamp a Firestore record so the relative review screen can find it even
 * without a paired verification doc (e.g. orphaned uploads). Optional —
 * primary metadata is written by the Flutter client.
 */
export const onVideoUploaded = functions
  .region("europe-west1")
  .storage.object()
  .onFinalize(async (object) => {
    if (!object.name ||
        (!object.name.startsWith("videos/") && !object.name.startsWith("footage/"))) {
      return null;
    }
    const parts = object.name.split("/");
    if (parts.length < 3) return null;
    const deviceId = parts[1];
    const prefix = parts[0]; // "videos" or "footage"
    functions.logger.info(
      `${prefix} uploaded: ${object.name} (deviceId=${deviceId}, size=${object.size})`
    );
    return null;
  });
