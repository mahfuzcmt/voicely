import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { getAdminFromToken } from '@/lib/auth';

// GET usage statistics
export async function GET(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { searchParams } = new URL(request.url);
    const type = searchParams.get('type'); // 'user' or 'channel'
    const id = searchParams.get('id'); // userId or channelId
    const period = searchParams.get('period'); // 'daily', 'monthly', or 'users' (for channel user breakdown)

    if (!type || !period) {
      return NextResponse.json(
        { error: 'type and period are required' },
        { status: 400 }
      );
    }

    const db = getAdminFirestore();
    let stats: unknown[] = [];

    if (type === 'user' && id) {
      // Get user statistics
      if (period === 'daily') {
        const snapshot = await db
          .collection('user_stats')
          .doc(id)
          .collection('daily')
          .orderBy('date', 'desc')
          .limit(30)
          .get();
        stats = snapshot.docs.map((doc) => ({
          ...doc.data(),
          lastActivity: doc.data().lastActivity?.toDate?.() || null,
        }));
      } else if (period === 'monthly') {
        const snapshot = await db
          .collection('user_stats')
          .doc(id)
          .collection('monthly')
          .orderBy('month', 'desc')
          .limit(12)
          .get();
        stats = snapshot.docs.map((doc) => ({
          ...doc.data(),
          lastActivity: doc.data().lastActivity?.toDate?.() || null,
        }));
      }
    } else if (type === 'channel' && id) {
      // Get channel statistics
      if (period === 'daily') {
        const snapshot = await db
          .collection('channel_stats')
          .doc(id)
          .collection('daily')
          .orderBy('date', 'desc')
          .limit(30)
          .get();
        stats = snapshot.docs.map((doc) => ({
          ...doc.data(),
          lastActivity: doc.data().lastActivity?.toDate?.() || null,
        }));
      } else if (period === 'monthly') {
        const snapshot = await db
          .collection('channel_stats')
          .doc(id)
          .collection('monthly')
          .orderBy('month', 'desc')
          .limit(12)
          .get();
        stats = snapshot.docs.map((doc) => ({
          ...doc.data(),
          lastActivity: doc.data().lastActivity?.toDate?.() || null,
        }));
      } else if (period === 'users') {
        // Get per-user stats for a channel
        const snapshot = await db
          .collection('channel_stats')
          .doc(id)
          .collection('users')
          .orderBy('totalDuration', 'desc')
          .limit(100)
          .get();
        stats = snapshot.docs.map((doc) => ({
          ...doc.data(),
          lastActivity: doc.data().lastActivity?.toDate?.() || null,
        }));
      }
    } else if (type === 'all-channels') {
      // Get all channel stats for overview
      const channelsSnapshot = await db.collection('channels').get();

      const allStats = [];
      for (const channelDoc of channelsSnapshot.docs) {
        const channelId = channelDoc.id;
        const channelData = channelDoc.data();

        // Get latest monthly stats
        const monthlySnapshot = await db
          .collection('channel_stats')
          .doc(channelId)
          .collection('monthly')
          .orderBy('month', 'desc')
          .limit(1)
          .get();

        const latestMonthly = monthlySnapshot.docs[0]?.data() || {
          totalVoices: 0,
          totalDuration: 0,
        };

        allStats.push({
          channelId,
          channelName: channelData.name,
          isActive: channelData.isActive !== false,
          memberCount: channelData.memberCount || 0,
          ...latestMonthly,
        });
      }
      stats = allStats;
    } else if (type === 'all-users') {
      // Get all user stats for overview
      const usersSnapshot = await db.collection('users').get();

      const allStats = [];
      for (const userDoc of usersSnapshot.docs) {
        const userId = userDoc.id;
        const userData = userDoc.data();

        // Get latest monthly stats
        const monthlySnapshot = await db
          .collection('user_stats')
          .doc(userId)
          .collection('monthly')
          .orderBy('month', 'desc')
          .limit(1)
          .get();

        const latestMonthly = monthlySnapshot.docs[0]?.data() || {
          voicesSent: 0,
          durationSent: 0,
        };

        allStats.push({
          userId,
          userName: userData.displayName || userData.phoneNumber,
          phoneNumber: userData.phoneNumber,
          ...latestMonthly,
        });
      }
      stats = allStats;
    }

    return NextResponse.json({ stats });
  } catch (error) {
    console.error('Error fetching stats:', error);
    return NextResponse.json(
      { error: 'Failed to fetch stats', details: String(error) },
      { status: 500 }
    );
  }
}
