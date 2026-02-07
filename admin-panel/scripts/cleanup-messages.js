#!/usr/bin/env node

/**
 * Firestore Messages Cleanup Script
 * Deletes all messages from Firestore
 * Run via cron every 6 hours
 */

const { initializeApp } = require('firebase/app');
const { getFirestore, collection, getDocs, deleteDoc, doc, writeBatch } = require('firebase/firestore');

// Firebase configuration
const firebaseConfig = {
  apiKey: 'AIzaSyA1KsBNX2HQnkRc4OjW10NDdNrKj-p2se0',
  authDomain: 'voicely-1d3b2.firebaseapp.com',
  projectId: 'voicely-1d3b2',
  storageBucket: 'voicely-1d3b2.firebasestorage.app',
  messagingSenderId: '842514114359',
  appId: '1:842514114359:android:3b9e29dc1f8589a9db5cb2',
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const db = getFirestore(app);

async function deleteAllMessages() {
  console.log(`[${new Date().toISOString()}] Starting messages cleanup...`);

  try {
    const messagesRef = collection(db, 'messages');
    const snapshot = await getDocs(messagesRef);

    if (snapshot.empty) {
      console.log('No messages to delete.');
      return 0;
    }

    const totalMessages = snapshot.size;
    console.log(`Found ${totalMessages} messages to delete.`);

    // Delete in batches of 500 (Firestore limit)
    const batchSize = 500;
    let deleted = 0;

    const docs = snapshot.docs;

    for (let i = 0; i < docs.length; i += batchSize) {
      const batch = writeBatch(db);
      const chunk = docs.slice(i, i + batchSize);

      chunk.forEach((docSnapshot) => {
        batch.delete(docSnapshot.ref);
      });

      await batch.commit();
      deleted += chunk.length;
      console.log(`Deleted ${deleted}/${totalMessages} messages...`);
    }

    console.log(`[${new Date().toISOString()}] Cleanup complete. Deleted ${deleted} messages.`);
    return deleted;

  } catch (error) {
    console.error('Error during cleanup:', error);
    throw error;
  }
}

// Run cleanup
deleteAllMessages()
  .then((count) => {
    console.log(`Successfully deleted ${count} messages.`);
    process.exit(0);
  })
  .catch((error) => {
    console.error('Cleanup failed:', error);
    process.exit(1);
  });
