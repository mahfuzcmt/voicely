import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { getAdminFromToken } from '@/lib/auth';

/**
 * Backfill usage stats from existing messages
 * POST /api/stats/backfill
 */
export async function POST(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const db = getAdminFirestore();

    // Get all audio messages
    const messagesSnapshot = await db
      .collection('messages')
      .where('type', '==', 'audio')
      .get();

    console.log(`Found ${messagesSnapshot.size} audio messages to process`);

    let processed = 0;
    let errors = 0;

    // Process each message
    for (const doc of messagesSnapshot.docs) {
      try {
        const message = doc.data();
        const channelId = message.channelId;
        const senderId = message.senderId;
        const senderName = message.senderName || 'Unknown';
        const durationSeconds = message.audioDuration || 30; // Default 30s if not set
        const timestamp = message.timestamp?.toDate() || new Date();

        // Create date keys
        const dateKey = `${timestamp.getFullYear()}-${String(timestamp.getMonth() + 1).padStart(2, '0')}-${String(timestamp.getDate()).padStart(2, '0')}`;
        const monthKey = `${timestamp.getFullYear()}-${String(timestamp.getMonth() + 1).padStart(2, '0')}`;

        // Update user daily stats
        const userDailyRef = db.collection('user_stats').doc(senderId).collection('daily').doc(dateKey);
        await userDailyRef.set({
          userId: senderId,
          userName: senderName,
          date: dateKey,
          voicesSent: (await userDailyRef.get()).data()?.voicesSent + 1 || 1,
          durationSent: (await userDailyRef.get()).data()?.durationSent + durationSeconds || durationSeconds,
          lastActivity: timestamp,
        }, { merge: true });

        // Update user monthly stats
        const userMonthlyRef = db.collection('user_stats').doc(senderId).collection('monthly').doc(monthKey);
        await userMonthlyRef.set({
          userId: senderId,
          userName: senderName,
          month: monthKey,
          voicesSent: (await userMonthlyRef.get()).data()?.voicesSent + 1 || 1,
          durationSent: (await userMonthlyRef.get()).data()?.durationSent + durationSeconds || durationSeconds,
          lastActivity: timestamp,
        }, { merge: true });

        // Update channel daily stats
        const channelDailyRef = db.collection('channel_stats').doc(channelId).collection('daily').doc(dateKey);
        await channelDailyRef.set({
          channelId: channelId,
          date: dateKey,
          totalVoices: (await channelDailyRef.get()).data()?.totalVoices + 1 || 1,
          totalDuration: (await channelDailyRef.get()).data()?.totalDuration + durationSeconds || durationSeconds,
          lastActivity: timestamp,
        }, { merge: true });

        // Update channel monthly stats
        const channelMonthlyRef = db.collection('channel_stats').doc(channelId).collection('monthly').doc(monthKey);
        await channelMonthlyRef.set({
          channelId: channelId,
          month: monthKey,
          totalVoices: (await channelMonthlyRef.get()).data()?.totalVoices + 1 || 1,
          totalDuration: (await channelMonthlyRef.get()).data()?.totalDuration + durationSeconds || durationSeconds,
          lastActivity: timestamp,
        }, { merge: true });

        // Update channel user stats
        const channelUserRef = db.collection('channel_stats').doc(channelId).collection('users').doc(senderId);
        await channelUserRef.set({
          userId: senderId,
          userName: senderName,
          channelId: channelId,
          totalVoices: (await channelUserRef.get()).data()?.totalVoices + 1 || 1,
          totalDuration: (await channelUserRef.get()).data()?.totalDuration + durationSeconds || durationSeconds,
          lastActivity: timestamp,
        }, { merge: true });

        processed++;
      } catch (err) {
        console.error(`Error processing message ${doc.id}:`, err);
        errors++;
      }
    }

    return NextResponse.json({
      success: true,
      totalMessages: messagesSnapshot.size,
      processed,
      errors,
      message: `Backfill complete. Processed ${processed} messages with ${errors} errors.`,
    });
  } catch (error) {
    console.error('Error in backfill:', error);
    return NextResponse.json(
      { error: 'Backfill failed', details: String(error) },
      { status: 500 }
    );
  }
}
