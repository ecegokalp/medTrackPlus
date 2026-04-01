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
export const onVerificationCreated = functions
  .region("europe-west1")
  .firestore.document("dispenser/{macAddress}/verifications/{verificationId}")
  .onCreate(async (snap, context) => {
    const data = snap.data();
    const {macAddress} = context.params;
    const classification: string = data.classification;
    const section: number = data.section ?? 0;
    const hasDevice: boolean = data.hasDevice ?? true;

    functions.logger.info(
      `Verification created: mac=${macAddress}, classification=${classification}, hasDevice=${hasDevice}`
    );

    // --- SUCCESS: log only ---
    if (classification === "success") {
      functions.logger.info("Classification is success. No notification needed.");
      return null;
    }

    // --- REJECTED or SUSPICIOUS: send FCM to relatives ---
    try {
      // 1. Get dispenser document to find all related users
      const dispenserDoc = await db.collection("dispenser").doc(macAddress).get();
      if (!dispenserDoc.exists) {
        functions.logger.warn(`Dispenser ${macAddress} not found.`);
        return null;
      }

      const dispenserData = dispenserDoc.data()!;
      const deviceName: string = dispenserData.device_name ?? macAddress;

      // Get medicine name from section_config
      const sectionConfig: Array<{name?: string}> = dispenserData.section_config ?? [];
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
          macAddress,
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
  });

/**
 * Firestore onUpdate trigger for verification documents.
 *
 * When review_decision changes to "approved" or "denied",
 * send FCM notification to the patient (userId).
 */
export const onReviewDecisionUpdate = functions
  .region("europe-west1")
  .firestore.document("dispenser/{macAddress}/verifications/{verificationId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    const oldDecision: string | undefined = before.review_decision;
    const newDecision: string | undefined = after.review_decision;

    // Only trigger when review_decision actually changes to approved/denied
    if (oldDecision === newDecision) return null;
    if (newDecision !== "approved" && newDecision !== "denied") return null;

    const {macAddress} = context.params;
    const userId: string = after.userId;

    functions.logger.info(
      `Review decision updated: mac=${macAddress}, decision=${newDecision}, patient=${userId}`
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

      // 2. Get device name
      const dispenserDoc = await db.collection("dispenser").doc(macAddress).get();
      const deviceName: string = dispenserDoc.exists
        ? dispenserDoc.data()!.device_name ?? macAddress
        : macAddress;

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
          macAddress,
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
  });

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
