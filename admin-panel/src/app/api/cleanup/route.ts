import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore, getAdminStorage } from '@/lib/firebase-admin';
import { getAdminFromToken } from '@/lib/auth';

/**
 * Audio Cleanup API
 *
 * DELETE /api/cleanup - Clean up old audio files (7 days retention)
 *
 * Can be called:
 * 1. Manually from admin panel (requires admin auth)
 * 2. Via cron job with CLEANUP_SECRET header
 *
 * For cron setup, use services like:
 * - cron-job.org (free)
 * - Vercel Cron (if deployed on Vercel)
 * - Any server with crontab
 *
 * Example cron (daily at 3 AM):
 * 0 3 * * * curl -X DELETE https://your-admin-panel.com/api/cleanup -H "x-cleanup-secret: YOUR_SECRET"
 */

const CLEANUP_SECRET = process.env.CLEANUP_SECRET || 'voicely-cleanup-secret-change-me';
const RETENTION_DAYS = 7;

export async function DELETE(request: NextRequest) {
  try {
    // Check authorization - either admin token or cleanup secret
    const cleanupSecret = request.headers.get('x-cleanup-secret');
    const admin = await getAdminFromToken();

    if (!admin && cleanupSecret !== CLEANUP_SECRET) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    console.log('Starting audio cleanup...');

    const db = getAdminFirestore();
    const storage = getAdminStorage();
    const bucket = storage.bucket();

    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - RETENTION_DAYS);
    const cutoffMs = cutoffDate.getTime();

    let deletedFilesCount = 0;
    let deletedMessagesCount = 0;
    let deletedLogsCount = 0;
    let errorsCount = 0;

    // 1. Delete old audio files from Storage
    try {
      const [files] = await bucket.getFiles({ prefix: 'audio/' });
      console.log(`Found ${files.length} audio files to check`);

      for (const file of files) {
        try {
          const [metadata] = await file.getMetadata();
          const uploadedAt = metadata.metadata?.uploadedAt as string | undefined;
          const timeCreated = metadata.timeCreated as string | undefined;

          let fileDate: Date;
          if (uploadedAt && typeof uploadedAt === 'string') {
            fileDate = new Date(uploadedAt);
          } else if (timeCreated) {
            fileDate = new Date(timeCreated);
          } else {
            continue;
          }

          if (fileDate.getTime() < cutoffMs) {
            await file.delete();
            deletedFilesCount++;
            console.log(`Deleted: ${file.name}`);
          }
        } catch (fileErr) {
          console.error(`Error processing file ${file.name}:`, fileErr);
          errorsCount++;
        }
      }
    } catch (storageErr) {
      console.error('Error accessing storage:', storageErr);
    }

    // 2. Delete old audio messages from Firestore
    try {
      const messagesRef = db.collection('messages');
      const oldMessagesSnapshot = await messagesRef
        .where('timestamp', '<', cutoffDate)
        .where('type', '==', 'audio')
        .limit(500)
        .get();

      if (!oldMessagesSnapshot.empty) {
        const batch = db.batch();
        oldMessagesSnapshot.docs.forEach((doc) => {
          batch.delete(doc.ref);
          deletedMessagesCount++;
        });
        await batch.commit();
        console.log(`Deleted ${oldMessagesSnapshot.size} old message records`);
      }
    } catch (msgErr) {
      console.error('Error cleaning up messages:', msgErr);
    }

    // 3. Delete old usage_logs (keep for 30 days)
    try {
      const thirtyDaysAgo = new Date();
      thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

      const logsRef = db.collection('usage_logs');
      const oldLogsSnapshot = await logsRef
        .where('timestamp', '<', thirtyDaysAgo)
        .limit(500)
        .get();

      if (!oldLogsSnapshot.empty) {
        const batch = db.batch();
        oldLogsSnapshot.docs.forEach((doc) => {
          batch.delete(doc.ref);
          deletedLogsCount++;
        });
        await batch.commit();
        console.log(`Deleted ${oldLogsSnapshot.size} old usage log entries`);
      }
    } catch (logsErr) {
      console.error('Error cleaning up usage logs:', logsErr);
    }

    const result = {
      success: true,
      deletedFiles: deletedFilesCount,
      deletedMessages: deletedMessagesCount,
      deletedLogs: deletedLogsCount,
      errors: errorsCount,
      retentionDays: RETENTION_DAYS,
      message: `Cleanup complete. Deleted ${deletedFilesCount} files, ${deletedMessagesCount} messages, ${deletedLogsCount} logs.`,
    };

    console.log('Cleanup result:', result);
    return NextResponse.json(result);
  } catch (error) {
    console.error('Error in cleanup:', error);
    return NextResponse.json(
      { error: 'Cleanup failed', details: String(error) },
      { status: 500 }
    );
  }
}

// GET endpoint to check cleanup status/info
export async function GET() {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    return NextResponse.json({
      retentionDays: RETENTION_DAYS,
      logsRetentionDays: 30,
      info: 'Use DELETE method to run cleanup. Can be automated with cron job using x-cleanup-secret header.',
    });
  } catch (error) {
    return NextResponse.json({ error: 'Failed to get cleanup info' }, { status: 500 });
  }
}
